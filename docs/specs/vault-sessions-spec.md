# Vault Sessions Specification

**Status:** Draft
**Author:** David Blumenfeld
**Date:** 2026-03-27

## 1. Problem

Every `vault exec` invocation requires biometric or passcode authentication. In agent workflows (OpenClaw, demos, automation), this means the human must repeatedly approve Touch ID prompts — once per command the agent runs. This breaks the flow and makes unattended agent operation impossible for protected secrets.

## 2. Goal

Allow a human to authenticate once and grant a **scoped, time-limited, usage-limited** session that permits `vault exec` to run without further authentication prompts. The session is restricted to specific named secrets and can only inject them into child processes — it cannot retrieve secret values directly.

## 3. Security Model

### 3.1 Trust Chain

```
Secure Enclave hardware
  └─ enforces: only code-signed binary can access session SE key
       └─ Keychain access group (FWJKHZ4TZD.com.keypo.signer)
            └─ enforces: only our .app bundle can read/write session data
                 └─ our binary enforces: TTL, usage limits, secret scope, exec-only access
                      └─ code signing ensures: binary hasn't been tampered with
```

The session creates a **temporary SE KeyAgreement key** with `open` access control policy (no biometric/passcode gate) but scoped to the app's Keychain access group (`FWJKHZ4TZD.com.keypo.signer`). This means:

- The SE hardware enforces that only binaries signed with our team ID can access the key
- The Keychain access group ensures that only our code-signed `.app` bundle can read or write session metadata, re-wrapped secrets, usage counters, and expiration timestamps — no other process can modify these values
- Our code enforces TTL, usage count, secret-scope restrictions, and exec-only access
- An attacker would need to compromise either the SE (hardware attack) or obtain our Apple Developer signing identity

### 3.2 Keychain as Tamper-Proof Storage

All session state that governs access control — `expiresAt`, `usesRemaining`, secret scope — is stored in the Keychain scoped to `FWJKHZ4TZD.com.keypo.signer`. macOS enforces at the kernel level that only binaries with the matching code-signing identity and entitlement can access these items. This means:

- **Expiration cannot be extended** by an external process
- **Usage counters cannot be reset** by an external process
- **Secret scope cannot be widened** by an external process
- **Session metadata cannot be forged** by an external process

The `.app` bundle is the sole binary authorized to read or write these Keychain items. Combined with code signing (which ensures the binary has not been tampered with), this provides a hardware-rooted guarantee that session limits are enforced as configured.

### 3.3 What a Session Can Do

- Decrypt session-scoped secrets and inject them into a child process via `vault exec`

### 3.4 What a Session Cannot Do

- **Cannot `vault get`**: session-scoped secrets are not retrievable as raw values — sessions only work through `vault exec`
- **Cannot access non-scoped secrets**: secrets not named at session creation are not re-wrapped and remain behind their original policy
- **Cannot outlive its limits**: expired or exhausted sessions self-refuse; the temp SE key is deleted on cleanup
- **Cannot be used by other binaries**: access group scoping ensures only our code-signed binary can touch the session's SE key and Keychain data

### 3.5 Tier Flattening

Sessions do not preserve the original vault tier (biometric/passcode/open) of each secret. All scoped secrets are re-encrypted under the session's single `open`-policy SE key. The original tier is recorded in session metadata and audit log for traceability but has no enforcement effect within the session.

### 3.6 Process Isolation for Session Creation

`session start` performs decryption and re-wrapping in a **child process**, following the same isolation pattern as `vault exec`. The parent process (which may be controlled by an agent) never has access to plaintext secret values. The child process:

1. Authenticates (biometric/passcode)
2. Decrypts the scoped secrets from the vault
3. Re-encrypts them under the session's temp SE key
4. Stores the re-wrapped secrets in Keychain
5. Outputs only the session name and metadata to stdout
6. Exits (plaintext is never returned to the parent)

This ensures that an agent can prompt the user to create a session (e.g., by generating the `session start` command) without being able to observe the decrypted secret values at any point during the process.

## 4. Architecture

### 4.1 Session Lifecycle

```
                          ┌─────────────────────┐
    session start         │  Spawn child process │
    --secrets A,B,C       │  (process isolation) │
    --ttl 30m             └──────────┬───────────┘
    --max-uses 50                    │
                          ┌──────────▼───────────┐
                          │  [child] Authenticate │
                          │  via biometric/       │
                          │  passcode (per tier)  │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [child] Check for    │
                          │  duplicate session    │
                          │  (same secret set)    │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [child] Create temp  │
                          │  SE KeyAgreement key  │
                          │  (open policy,        │
                          │   access-group scoped)│
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [child] Decrypt      │
                          │  scoped secrets from  │
                          │  vault using original │
                          │  tier keys + LAContext │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [child] Re-encrypt   │
                          │  each secret under    │
                          │  temp SE key via ECIES│
                          │  (session name as     │
                          │   HKDF salt)          │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [child] Store in     │
                          │  Keychain: metadata,  │
                          │  re-wrapped secrets,  │
                          │  temp key ref         │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [child] Write audit  │
                          │  log: session.start   │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [child] Output       │
                          │  session name + meta  │
                          │  to stdout, then exit │
                          └──────────┬───────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  [parent] Read stdout │
                          │  (session name only)  │
                          └──────────────────────┘
```

### 4.2 Session Usage (vault exec --session)

```
vault exec --session <name> -- <command>
  │
  ├─ Look up session metadata in Keychain
  ├─ Validate: exists? not expired? uses remaining?
  ├─ Decrypt ALL session-scoped secrets using temp SE key (no auth prompt)
  ├─ Inject into child process environment
  ├─ Decrement usage counter in Keychain
  ├─ Write audit log entry: session.exec
  └─ Forward child exit code
```

When `--session` is provided, `--allow` and `--env` are not accepted. The set of secrets injected is exactly the set scoped to the session — no more, no less. This eliminates ambiguity about which secrets an agent receives and simplifies the interface for automated callers.

### 4.3 Session Cleanup

Sessions are cleaned up when:

1. **Explicit end**: `session end <name>` or `session end --all`
2. **TTL expiry**: checked at usage time; expired sessions are refused and their temp SE key is deleted
3. **Usage exhaustion**: when `uses_remaining` reaches 0, the session is refused and cleaned up
4. **Garbage collection**: `session start` and `session list` opportunistically clean up any expired sessions they encounter

Cleanup deletes the temp SE key from the Secure Enclave, removes all session Keychain items, and writes an audit log entry.

## 5. Storage

### 5.1 Keychain Layout

Each session stores two types of Keychain items, all scoped to access group `FWJKHZ4TZD.com.keypo.signer`:

**Session metadata item** (`kSecClassGenericPassword`):
- `kSecAttrService`: `com.keypo.session`
- `kSecAttrAccount`: `<session-name>`
- `kSecValueData`: JSON-encoded `SessionMetadata`
- `kSecAttrGeneric`: base64-encoded `dataRepresentation` of the temp SE key

**Session secret items** (`kSecClassGenericPassword`):
- `kSecAttrService`: `com.keypo.session.<session-name>`
- `kSecAttrAccount`: `<secret-name>`
- `kSecValueData`: JSON-encoded `EncryptedSecret` (ECIES ciphertext under temp SE key)

### 5.2 SessionMetadata

```
SessionMetadata {
    name: String                    // BIP39 word pair, e.g. "orbital-canvas"
    secrets: [String]               // names of scoped secrets (sorted for dedup comparison)
    originalTiers: [String: String] // secret name -> original policy tier
    createdAt: Date                 // ISO 8601
    expiresAt: Date                 // ISO 8601
    maxUses: Int?                   // nil = unlimited
    usesRemaining: Int?             // nil = unlimited, decremented on each exec
    tempKeyPublicKey: String        // hex, for identification/audit
}
```

### 5.3 SE Key Management

The temporary SE key is created as:

- Type: `SecureEnclave.P256.KeyAgreement.PrivateKey`
- Access control: no biometric/passcode flags (open policy)
- Application tag: `com.keypo.session.<session-name>`
- Access group: `FWJKHZ4TZD.com.keypo.signer`

The `dataRepresentation` (opaque SE token) is stored in the session metadata Keychain item's `kSecAttrGeneric` field, following the same pattern used by `KeychainMetadataStore` for signing keys.

## 6. Session Naming

Session names are generated using the existing `PassphraseGenerator` and `Wordlist.english` (BIP39 English wordlist, 2048 words) already in KeypoCore. Each name is a pair of words joined by a hyphen, e.g. `orbital-canvas`, `thunder-maple`.

- Uses `PassphraseGenerator.generatePassphrase(wordCount: 2)` to select words via `SecRandomCopyBytes`
- 2 words from 2048 = ~22 bits of entropy, sufficient for local disambiguation
- If a collision occurs (name already exists as an active session), regenerate
- Names are case-insensitive, stored lowercase
- No new wordlist is needed — reuses the existing BIP39 wordlist embedded in `Wordlist.swift`

## 7. CLI Interface

### 7.1 session start

```
keypo-signer session start --secrets <names> [--ttl <duration>] [--max-uses <n>]
```

**Arguments:**
- `--secrets` (required): comma-separated secret names. Wildcard `*` is not permitted (sessions must be explicitly scoped).
- `--ttl` (optional): duration string, e.g. `30m`, `2h`, `1d`. Default: `30m`. No hard maximum — values above `24h` emit a stderr warning (`sessions longer than 24h are not recommended`) but are accepted.
- `--max-uses` (optional): positive integer. Default: unlimited. Minimum: 1.
- `--reason` (optional): custom Touch ID prompt message.

**Behavior:**
1. Validate inputs (secrets list, TTL bounds, max-uses)
2. Spawn a child process that performs all secret-touching operations:
   a. Load vault, resolve each secret name to its vault tier
   b. Fail if any named secret does not exist
   c. Check for duplicate sessions: if an active session already exists with the exact same set of secrets (order-independent), fail with exit 126
   d. Group secrets by tier; authenticate each tier that requires it (one LAContext per tier)
   e. Create temp SE KeyAgreement key (open policy, access-group scoped)
   f. Decrypt each scoped secret, re-encrypt under temp key via ECIES (using session name as HKDF salt)
   g. Store session metadata and re-wrapped secrets in Keychain
   h. Write audit log entry (`session.start`)
   i. Opportunistically garbage-collect expired sessions
   j. Output session info to stdout
3. Parent reads child stdout, forwards to caller

**Output (JSON):**
```json
{
  "session": "orbital-canvas",
  "secrets": ["API_KEY", "DB_PASSWORD"],
  "expiresAt": "2026-03-27T15:30:00Z",
  "maxUses": 50,
  "ttl": "30m"
}
```

**Exit codes:**
- 0: session created
- 1: authentication failed or cancelled
- 126: validation error (no secrets, secret not found, invalid TTL, duplicate session, etc.)

### 7.2 session end

```
keypo-signer session end <name>
keypo-signer session end --all
```

**Behavior:**
1. Look up session(s) by name (or all sessions if `--all`)
2. Delete temp SE key from Secure Enclave
3. Delete session metadata and secret items from Keychain
4. Write audit log entry (`session.end`) for each ended session
5. Idempotent: ending a non-existent or already-expired session is not an error

**Output (JSON):**
```json
{
  "ended": ["orbital-canvas"],
  "count": 1
}
```

**Exit codes:**
- 0: session(s) ended (or already absent)
- 126: Keychain error

### 7.3 session list

```
keypo-signer session list
```

**Behavior:**
1. Query all `com.keypo.session` items from Keychain
2. Parse metadata, compute status (active/expired/exhausted)
3. Garbage-collect expired/exhausted sessions (delete SE keys and Keychain items, write audit log entries)
4. Return list of active sessions

**Output (JSON):**
```json
{
  "sessions": [
    {
      "name": "orbital-canvas",
      "secrets": ["API_KEY", "DB_PASSWORD"],
      "expiresAt": "2026-03-27T15:30:00Z",
      "usesRemaining": 42,
      "status": "active"
    }
  ],
  "cleaned": 1
}
```

**Exit codes:**
- 0: success
- 126: Keychain error

### 7.4 session status

```
keypo-signer session status <name>
```

**Behavior:**
1. Look up session by name
2. Return detailed metadata including original tiers

**Output (JSON):**
```json
{
  "name": "orbital-canvas",
  "secrets": ["API_KEY", "DB_PASSWORD"],
  "originalTiers": {
    "API_KEY": "biometric",
    "DB_PASSWORD": "passcode"
  },
  "createdAt": "2026-03-27T15:00:00Z",
  "expiresAt": "2026-03-27T15:30:00Z",
  "maxUses": 50,
  "usesRemaining": 42,
  "status": "active"
}
```

**Exit codes:**
- 0: session found
- 126: session not found or Keychain error

### 7.5 vault exec --session

Extends the existing `vault exec` command:

```
keypo-signer vault exec --session <name> -- <command>
```

**New argument:**
- `--session` (optional): session name to use. Mutually exclusive with `--allow` and `--env` — when a session is provided, the secret scope is fully determined by the session.

**Modified behavior when `--session` is provided:**
1. Reject if `--allow` or `--env` is also provided (exit 126: `--session is mutually exclusive with --allow and --env`)
2. Look up session metadata in Keychain
3. Validate session is active (not expired, uses remaining)
4. Decrypt ALL secrets in the session's scope using temp SE key
5. Inject decrypted values into child process environment
6. Decrement `usesRemaining` in session metadata (atomic Keychain update)
7. Write audit log entry (`session.exec`)
8. Run child process, forward exit code

The session fully defines which secrets are injected. There is no `--allow` filter because the human already declared the exact scope at session creation. This makes the agent's interface simpler and eliminates any ambiguity about what is authorized.

**Exit codes (new):**
- 5: session not found, expired, or exhausted

### 7.6 session refresh

```
keypo-signer session refresh <name> [--ttl <duration>] [--max-uses <n>]
```

**Behavior:**
1. Look up active session by name
2. Authenticate against the original vault tiers (biometric/passcode prompt)
3. Update TTL and/or usage limits
4. Does NOT re-wrap secrets (they're already under the temp key)
5. Write audit log entry (`session.refresh`)

This allows extending a session without recreating it. Authentication is required because extending a session's lifetime is a security-relevant action.

**Exit codes:**
- 0: session refreshed
- 1: authentication failed or cancelled
- 5: session expired (must create a new one)
- 126: session not found

## 8. Audit Logging

### 8.1 Purpose

Every session lifecycle event is recorded in a persistent, append-only audit log. This provides:

- Forensic traceability: which secrets were exposed to which processes, when
- Anomaly detection: unexpected usage patterns (e.g., burst of execs near session expiry)
- Accountability: the human who created the session is linked to all subsequent agent activity

### 8.2 Log Location

`~/.keypo/session-audit.log` — one JSON object per line (JSONL format). The file is append-only; entries are never modified or deleted by the application.

### 8.3 Event Types

| Event | Trigger | Key Fields |
|-------|---------|------------|
| `session.start` | Session created successfully | session name, secrets, tiers, TTL, maxUses |
| `session.exec` | `vault exec --session` succeeds | session name, command (argv[0] only), usesRemaining after decrement |
| `session.exec_denied` | `vault exec --session` refused | session name, reason (expired/exhausted/not_found) |
| `session.end` | Session explicitly ended | session name, trigger (explicit/expired/exhausted/gc) |
| `session.refresh` | Session TTL or usage limit updated | session name, old and new TTL/maxUses |

### 8.4 Log Entry Schema

```
AuditEntry {
    timestamp: String       // ISO 8601 with timezone
    event: String           // event type from table above
    session: String         // session name
    details: [String: Any]  // event-specific fields (see below)
}
```

**Per-event detail fields:**

`session.start`:
```json
{
  "timestamp": "2026-03-27T15:00:00Z",
  "event": "session.start",
  "session": "orbital-canvas",
  "details": {
    "secrets": ["API_KEY", "DB_PASSWORD"],
    "tiers": {"API_KEY": "biometric", "DB_PASSWORD": "passcode"},
    "ttl": "30m",
    "maxUses": 50,
    "expiresAt": "2026-03-27T15:30:00Z"
  }
}
```

`session.exec`:
```json
{
  "timestamp": "2026-03-27T15:05:00Z",
  "event": "session.exec",
  "session": "orbital-canvas",
  "details": {
    "command": "python",
    "secretsInjected": ["API_KEY", "DB_PASSWORD"],
    "usesRemaining": 49,
    "childPid": 12345
  }
}
```

`session.exec_denied`:
```json
{
  "timestamp": "2026-03-27T16:00:00Z",
  "event": "session.exec_denied",
  "session": "orbital-canvas",
  "details": {
    "reason": "expired",
    "command": "python"
  }
}
```

`session.end`:
```json
{
  "timestamp": "2026-03-27T15:30:00Z",
  "event": "session.end",
  "session": "orbital-canvas",
  "details": {
    "trigger": "expired",
    "usesConsumed": 8
  }
}
```

`session.refresh`:
```json
{
  "timestamp": "2026-03-27T15:20:00Z",
  "event": "session.refresh",
  "session": "orbital-canvas",
  "details": {
    "oldExpiresAt": "2026-03-27T15:30:00Z",
    "newExpiresAt": "2026-03-27T16:00:00Z",
    "oldMaxUses": 50,
    "newMaxUses": 100
  }
}
```

### 8.5 Implementation

**SessionAuditLog** — append-only log writer:
- `log(_ entry: AuditEntry)` — serializes to JSON, appends line to log file
- File operations use `O_APPEND | O_CREAT | O_WRONLY` for atomic appends (no locking needed on macOS for single-line appends under PIPE_BUF)
- Logging failures are non-fatal: write a warning to stderr but do not fail the session operation
- The `~/.keypo/` config directory is created if it does not exist (same pattern as `BackupStateManager`)

### 8.6 Log Rotation

Out of scope for this iteration. The log file grows unbounded. For reference, at ~300 bytes per entry, 100 execs/day for a year produces ~11 MB — manageable for a local CLI tool. Future work could add `session audit` commands to query, export, or rotate the log.

### 8.7 Privacy

- The audit log records `argv[0]` (the command name) of the child process, not the full argument list. This avoids logging sensitive arguments while still providing traceability.
- Secret *names* are logged; secret *values* are never logged.
- The log file is created with `0600` permissions (owner-only read/write).

## 9. Implementation Components

### 9.1 New Types (KeypoCore)

**SessionManager** — orchestrates session lifecycle:
- `createSession(secrets:ttl:maxUses:vaultStore:authContextProvider:) -> SessionMetadata`
- `loadSession(name:) -> SessionMetadata?`
- `listActiveSessions() -> [SessionMetadata]`
- `decryptSessionSecrets(session:) -> [String: String]`
- `decrementUsage(session:) -> SessionMetadata`
- `endSession(name:)`
- `endAllSessions()`
- `garbageCollect() -> Int`
- `isDuplicateSession(secrets:) -> Bool` — checks if an active session with the same secret set exists

**SessionKeychainStore** — Keychain CRUD for session data:
- `saveSession(_:)` — stores metadata + temp key ref
- `saveSessionSecret(sessionName:secretName:encrypted:)` — stores one re-wrapped secret
- `loadSession(name:) -> (SessionMetadata, Data)?` — metadata + temp key dataRep
- `loadSessionSecret(sessionName:secretName:) -> EncryptedSecret?`
- `loadAllSessionSecrets(sessionName:) -> [String: EncryptedSecret]`
- `deleteSession(name:)` — removes metadata + all secret items + SE key
- `listSessions() -> [(SessionMetadata, Data)]`

**SessionAuditLog** — append-only JSONL log writer:
- `log(_ entry: AuditEntry)`
- `init(configDir: URL)` — defaults to `~/.keypo/`

**AuditEntry** — Codable struct (see section 8.4)

**SessionMetadata** — Codable struct (see section 5.2)

Session naming uses the existing `PassphraseGenerator.generatePassphrase(wordCount: 2)` and `Wordlist.english` — no new wordlist type is needed.

### 9.2 Modified Types

**VaultExecCommand** — add `--session` option; when provided, `--allow` and `--env` are rejected; decrypt from session instead of vault

**VaultCommand** — add `session` as a subcommand group

### 9.3 New Commands (keypo-signer target)

- `SessionCommand` — parent command with subcommands: start, end, list, status, refresh
- `SessionStartCommand` — spawns child process for secret handling (process isolation)
- `SessionEndCommand`
- `SessionListCommand`
- `SessionStatusCommand`
- `SessionRefreshCommand`

### 9.4 ECIES Scheme for Sessions

Re-wrapping uses the same ECIES construction as `VaultManager` with two differences:

1. **HKDF salt**: the session name (UTF-8 encoded) is used as the HKDF salt, binding the ciphertext to the specific session. This means re-wrapped secrets from one session cannot be decrypted in the context of another session, even if both use the same temp SE key (which they don't — each session has its own).
2. **HKDF info prefix**: `keypo-session-v1` (instead of `keypo-vault-v1`) for domain separation.

Full construction:
1. Generate ephemeral P256 key pair
2. ECDH with the session's temp SE KeyAgreement key
3. HKDF-SHA256 with salt = session name (UTF-8), info = `keypo-session-v1` + secretName
4. AES-256-GCM encryption
5. Store: ephemeralPublicKey, nonce, ciphertext, authTag

## 10. Duplicate Session Prevention

Sessions must be explicitly scoped. To prevent redundant sessions that would create confusion about which session an agent should use, creating a session with an **identical set of secrets** as an existing active session is rejected.

### 10.1 Rules

- Secret sets are compared **order-independently** (sorted before comparison)
- Only **active** sessions are considered (expired/exhausted sessions are ignored)
- **Overlapping** sets are allowed: session {A, B} and session {B, C} can coexist
- **Identical** sets are rejected: session {A, B} blocks another session {A, B}
- **Subsets/supersets** are allowed: session {A, B} and session {A, B, C} can coexist

### 10.2 Implementation

During `session start`, before creating the temp SE key:
1. Load all active sessions via `listSessions()`
2. For each active session, sort its `secrets` array and compare to the sorted requested secrets
3. If any match, fail with exit 126: `a session with identical secrets already exists: '<name>'`

## 11. Testing Strategy

All code is assumed incorrect until proven otherwise by tests. Tests are organized so that **all automated tests using open-policy keys run first** (Categories S1-S8), allowing maximum issue detection without human interaction. Manual tests requiring biometric/passcode prompts come last (Category S9).

### Category S1: Session Naming (Automated, Open Policy)

Tests that the naming system produces valid, collision-resistant names. Uses the existing `PassphraseGenerator` and `Wordlist.english`.

| ID | Test | Proves |
|----|------|--------|
| S1.1 | Generate 100 session names via `PassphraseGenerator.generatePassphrase(wordCount: 2)`; all match `^[a-z]+-[a-z]+$` when joined with hyphen | Name format is correct |
| S1.2 | Generate 100 session names; all are unique | Collision resistance at small scale |
| S1.3 | Both words in every generated name exist in `Wordlist.english` | Names are drawn from the correct source |
| S1.4 | Name generation with existing sessions avoids collisions (mock a store with pre-existing names) | Retry logic works |

### Category S2: Session Creation (Automated, Open Policy)

Tests that session start correctly re-wraps and stores. All tests use open-tier secrets only (no auth prompts).

| ID | Test | Proves |
|----|------|--------|
| S2.1 | Create session with 1 open-tier secret; session metadata is stored in Keychain with correct fields | Basic creation works |
| S2.2 | Create session with 3 open-tier secrets; all secrets are re-wrapped and individually stored | Multi-secret storage works |
| S2.3 | Create session with non-existent secret name; fails with exit 126 | Input validation rejects unknown secrets |
| S2.4 | Create session with `--secrets *`; fails with exit 126 | Wildcard is rejected (must be explicit) |
| S2.5 | Create session with TTL `0s`; fails with exit 126 | Zero TTL is rejected |
| S2.6 | Create session with TTL `25h`; succeeds but emits stderr warning | TTL above 24h warns but is accepted |
| S2.7 | Create session with `--max-uses 0`; fails with exit 126 | Zero uses is rejected |
| S2.8 | Create session with default TTL; `expiresAt` is ~30 minutes from `createdAt` | Default TTL is applied |
| S2.9 | Create session; verify temp SE key exists with application tag `com.keypo.session.<name>` | SE key is created with correct tag |
| S2.10 | Create session; decrypt a re-wrapped secret using the temp SE key with session name as HKDF salt; value matches original | Re-encryption round-trip integrity with session-bound salt |
| S2.11 | Create session; original vault secrets are unchanged (re-read and decrypt originals) | Session creation has no side effects on the vault |
| S2.12 | Create session with secrets {A, B}; create another with secrets {A, B}; second fails with exit 126 | Duplicate session prevention works |
| S2.13 | Create session with secrets {A, B}; create another with secrets {B, C}; both succeed | Overlapping (non-identical) sessions are allowed |
| S2.14 | Create session with secrets {A, B}; create another with secrets {B, A}; second fails with exit 126 | Duplicate detection is order-independent |
| S2.15 | Create session with secrets {A, B}; create another with secrets {A, B, C}; both succeed | Superset sessions are allowed |
| S2.16 | Create session with secrets {A, B}; end it; create another with secrets {A, B}; succeeds | Ended sessions do not block new sessions with same secrets |

### Category S3: Session Exec (Automated, Open Policy)

Tests that `vault exec --session` correctly decrypts, enforces scope, and manages usage. All sessions created with open-tier secrets.

| ID | Test | Proves |
|----|------|--------|
| S3.1 | `vault exec --session <name> -- printenv SECRET_1`; outputs the correct value | Basic session exec works |
| S3.2 | `vault exec --session <name> -- printenv`; all session-scoped secrets appear, no extra secrets | Session injects exactly the scoped set |
| S3.3 | `vault exec --session <name> --allow SECRET_1 -- printenv`; fails with exit 126 | --allow is rejected when --session is present |
| S3.4 | `vault exec --session <name> --env .env -- printenv`; fails with exit 126 | --env is rejected when --session is present |
| S3.5 | After exec, `usesRemaining` in Keychain metadata is decremented by 1 | Usage tracking works |
| S3.6 | Session with `maxUses: 1`; first exec succeeds, second exec fails with exit 5 | Usage exhaustion is enforced |
| S3.7 | Session with `maxUses: 1`; after exhaustion, session metadata and SE key are cleaned up | Exhausted sessions are garbage-collected |
| S3.8 | Session with expired TTL; exec fails with exit 5 | TTL expiry is enforced |
| S3.9 | Session with expired TTL; after failed exec, session metadata and SE key are cleaned up | Expired sessions are garbage-collected |
| S3.10 | `vault exec --session nonexistent -- printenv`; fails with exit 5 | Non-existent session is handled |
| S3.11 | Session exec with child process that exits non-zero; exit code is forwarded | Child exit code forwarding works through session path |
| S3.12 | Two overlapping sessions with different secrets; exec each independently | Overlapping sessions are isolated |
| S3.13 | Two overlapping sessions sharing a secret; exec each independently, both work | Shared secrets across sessions work (independent re-wrappings) |
| S3.14 | `vault exec --allow SECRET_1 -- printenv` (no --session); works as before | Non-session path is unaffected |
| S3.15 | Session exec where child command reads from stdin (e.g., `cat`); stdin is forwarded | TTY/stdin forwarding works through session path |

### Category S4: Session Lifecycle Management (Automated, Open Policy)

Tests for list, status, end, refresh, and garbage collection. All sessions use open-tier secrets.

| ID | Test | Proves |
|----|------|--------|
| S4.1 | `session list` with no sessions returns empty array | List handles empty state |
| S4.2 | Create 3 sessions (with different secret sets); `session list` returns all 3 with correct metadata | List returns all active sessions |
| S4.3 | Create session, let it expire; `session list` omits it and returns `cleaned: 1` | List garbage-collects expired sessions |
| S4.4 | `session status <name>` returns full metadata including `originalTiers` | Status shows correct detail |
| S4.5 | `session status nonexistent`; fails with exit 126 | Status rejects unknown sessions |
| S4.6 | `session end <name>`; session is removed from list, temp SE key is deleted | End cleans up completely |
| S4.7 | `session end <name>` for already-ended session; succeeds (idempotent) | End is idempotent |
| S4.8 | Create 3 sessions; `session end --all`; all are removed | End-all works |
| S4.9 | `session refresh <name> --ttl 1h`; expiresAt is updated, secrets are unchanged | Refresh updates TTL (open tier — no auth prompt needed) |
| S4.10 | `session refresh <name> --max-uses 100`; usesRemaining is updated | Refresh updates usage limit |
| S4.11 | `session refresh <name>` on expired session; fails with exit 5 | Cannot refresh an expired session |
| S4.12 | During `session start`, 2 expired sessions exist; both are garbage-collected | Start triggers GC |
| S4.13 | After `session end`, verify SE key with application tag `com.keypo.session.<name>` no longer exists in Keychain | SE key cleanup is thorough |

### Category S5: Security Properties (Automated, Open Policy)

Tests that enforce the security model. Uses open-tier secrets for automation.

| ID | Test | Proves |
|----|------|--------|
| S5.1 | `vault get SECRET` where SECRET is in an active session; still works normally via vault (session does not affect `get`) | Sessions do not interfere with `get` |
| S5.2 | Session re-wrapped secrets use HKDF salt = session name (UTF-8) and info prefix `keypo-session-v1` | Domain separation and session binding |
| S5.3 | Decrypt a re-wrapped secret with the correct temp SE key but wrong session name as salt; decryption fails | Session name salt is enforced (ciphertext is bound to the session) |
| S5.4 | Create session; delete the original vault secret; session exec still works (session is self-contained) | Session is independent of vault state after creation |
| S5.5 | Create session; update the original vault secret's value; session exec returns the OLD value | Session is a snapshot, not a live reference |
| S5.6 | Session metadata in Keychain has access group `FWJKHZ4TZD.com.keypo.signer` | Keychain items are access-group scoped |
| S5.7 | Manually corrupt `usesRemaining` in Keychain to a negative value; next exec fails | Usage counter manipulation is handled |
| S5.8 | Manually corrupt `expiresAt` in Keychain to a past date; next exec fails with exit 5 | Expiry is checked at exec time, not trusted from creation only |
| S5.9 | Create session; verify temp key `dataRepresentation` is stored in `kSecAttrGeneric`, not `kSecValueData` (which holds the metadata JSON) | Storage layout matches design |
| S5.10 | `session start` output (stdout) does not contain any secret values; only session name and metadata | Process isolation: parent never sees plaintext |

### Category S6: SessionKeychainStore (Automated, Open Policy)

Unit tests for the Keychain persistence layer in isolation.

| ID | Test | Proves |
|----|------|--------|
| S6.1 | Save and load session metadata round-trip | Serialization is correct |
| S6.2 | Save and load session secret round-trip | Secret storage is correct |
| S6.3 | Delete session removes metadata item | Metadata cleanup works |
| S6.4 | Delete session removes all associated secret items | Secret cleanup works |
| S6.5 | List sessions returns only `com.keypo.session` items, not vault or key items | Service filtering is correct |
| S6.6 | Save two sessions with different names; both are independently loadable | Multiple sessions coexist |
| S6.7 | Save session, save again with same name; update overwrites (no duplicate) | Upsert semantics work |

### Category S7: Audit Logging (Automated, Open Policy)

Unit tests for the audit log system.

| ID | Test | Proves |
|----|------|--------|
| S7.1 | `SessionAuditLog.log()` creates log file if it doesn't exist | File creation works |
| S7.2 | Log entry is valid JSON when parsed back | Serialization is correct |
| S7.3 | Multiple log entries are each on their own line (JSONL format) | Append semantics work |
| S7.4 | Log file is created with `0600` permissions | File permissions are restrictive |
| S7.5 | `session.start` event contains session name, secrets, tiers, TTL, maxUses, expiresAt | Start event has all required fields |
| S7.6 | `session.exec` event contains session name, command (argv[0] only), usesRemaining, childPid | Exec event has all required fields |
| S7.7 | `session.exec` event does NOT contain full command arguments | Privacy: arguments are not logged |
| S7.8 | `session.exec_denied` event contains session name, reason, command | Denied event has all required fields |
| S7.9 | `session.end` event contains session name, trigger, usesConsumed | End event has all required fields |
| S7.10 | `session.refresh` event contains old and new TTL/maxUses values | Refresh event has all required fields |
| S7.11 | Audit log entry never contains secret values (search log content for known test secret values) | Secret values are never logged |
| S7.12 | Logging failure (e.g., read-only filesystem) does not cause session operation to fail | Logging is non-fatal |
| S7.13 | Create session + exec + end; read log file; all 3 events present in order | End-to-end audit trail works |

### Category S8: BIP39 Wordlist (Automated)

Unit tests for the existing embedded wordlist (already partially covered by PassphraseGenerator tests, but verified here for session naming).

| ID | Test | Proves |
|----|------|--------|
| S8.1 | `Wordlist.english` contains exactly 2048 entries | Wordlist is complete |
| S8.2 | All entries are lowercase ASCII alphabetic | No formatting issues |
| S8.3 | No duplicate entries | Wordlist is a proper set |

### Category S9: Multi-Tier Sessions (Manual — Passcode/Biometric)

Tests requiring human interaction (Touch ID / passcode prompts). Run manually after all automated tests pass.

| ID | Test | Proves |
|----|------|--------|
| S9.1 | Create session scoping a biometric-tier secret; Touch ID prompt appears once | Auth is required at session creation |
| S9.2 | After S9.1, run `vault exec --session <name>` 5 times; no Touch ID prompts | Session eliminates repeated auth |
| S9.3 | Create session scoping secrets from both biometric and passcode tiers; two auth prompts appear (one per tier) | Multi-tier auth works correctly |
| S9.4 | Create session, wait for TTL to expire, run exec; get exit 5, then create new session; new auth prompt appears | Full lifecycle with real auth |
| S9.5 | `session refresh` on active biometric session; Touch ID prompt appears | Refresh requires re-authentication |
| S9.6 | Run `vault exec --allow SECRET -- printenv` (no --session) on a biometric secret; Touch ID prompt appears as normal | Non-session path is unaffected by session feature existence |
| S9.7 | Create session with biometric secret; run `vault get` on same secret; Touch ID prompt still appears | Sessions do not leak into `get` for protected tiers |
| S9.8 | Create session; check `~/.keypo/session-audit.log`; `session.start` entry present with correct tiers | Audit log captures tier information for protected secrets |
| S9.9 | `session start` stdout contains only session name/metadata, never secret values; verify by capturing stdout | Process isolation holds with real biometric auth |

## 12. Output Formats

All session commands respect the existing `--format` flag (json/pretty/raw). JSON is the default. Pretty format shows human-readable summaries. Raw is not applicable to session commands (falls back to JSON).

## 13. Error Messages

| Condition | Stderr Message | Exit Code |
|-----------|---------------|-----------|
| Secret not found in vault | `secret '<name>' not found in any vault` | 126 |
| Wildcard `*` used with --secrets | `wildcard not permitted for sessions; list secrets explicitly` | 126 |
| TTL exceeds 24h | `warning: sessions longer than 24h are not recommended` (stderr, non-fatal) | 0 |
| TTL is zero or negative | `TTL must be a positive duration` | 126 |
| max-uses is zero | `max-uses must be at least 1` | 126 |
| --session with --allow or --env | `--session is mutually exclusive with --allow and --env` | 126 |
| Duplicate session (same secret set) | `a session with identical secrets already exists: '<name>'` | 126 |
| Auth failed/cancelled | `authentication failed` / `authentication cancelled` | 1 |
| Session expired or exhausted | `session '<name>' has expired` / `session '<name>' has no remaining uses` | 5 |
| Session not found | `session '<name>' not found` | 5 |
| Keychain error | `keychain error: <detail>` | 126 |

## 14. Future Considerations

These are explicitly **out of scope** for this iteration but noted for future reference:

- **Session delegation**: passing a session token to a remote process (would require a different trust model)
- **Notification on session creation**: macOS notification when a session is created (visible confirmation for the human)
- **vault get --session**: intentionally omitted; if a use case emerges, it would require a separate security review
- **Per-secret usage limits**: currently limits are per-session; per-secret limits add complexity without clear need
- **Audit log querying**: `session audit` commands to search, filter, export, or rotate the log file
- **Audit log rotation**: automatic size-based or time-based rotation
