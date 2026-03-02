# keypo-signer: Technical Specification v2

## Product Overview

keypo-signer is a macOS CLI tool that generates and manages P-256 signing keys inside the Apple Secure Enclave. It exposes key creation, signing, rotation, and deletion through a simple command-line interface.

The tool does one thing: it manages hardware-backed signing keys and signs data with them on demand. It does not interpret what it signs, construct transactions, interact with any network, or enforce policies. It accepts bytes, signs them, and returns signatures.

Any process that can shell out to a CLI binary can use keypo-signer — AI agent frameworks, shell scripts, cron jobs, or other tools.

---

## Architecture

### Secure Enclave Fundamentals

All private keys are generated inside and never leave the Apple Secure Enclave. The Secure Enclave is a hardware-isolated coprocessor with its own encrypted memory, present in all Apple Silicon Macs. Keys stored in it cannot be extracted even by a process with root access or with physical access to the device.

keypo-signer accesses the Secure Enclave through Apple's Security framework and CryptoKit, not through the WebAuthn/passkey stack. This distinction matters: WebAuthn requires a browser-mediated user gesture per operation. The Security framework's lower-level API allows creating Secure Enclave keys with configurable access control policies — from fully autonomous signing to biometric-gated signing — depending on the use case.

Key properties of all Secure Enclave keys created by this tool:

- Curve: P-256 (secp256r1) — the only elliptic curve the Secure Enclave supports
- Extractability: private key material cannot be exported, copied, backed up, or synced
- Persistence: keys survive app deletion and reboots; destroyed only by explicit deletion or Secure Enclave reset
- Device-bound: keys are tied to the specific hardware device they were created on

### Access Control Policies

Each Secure Enclave key is created with an immutable access control policy. Once set at creation time, the policy cannot be changed — it is enforced by the Secure Enclave hardware for the lifetime of the key. keypo-signer supports three policies:

**`open`** — The key is available for signing whenever the device is unlocked. No per-operation authentication. This is the appropriate policy for autonomous processes (AI agents, cron jobs, daemons) that need to sign without human intervention. The Secure Enclave still protects the key from extraction — the guarantee is that the private key material cannot be read, even though signing operations are unrestricted.

Implementation: `SecAccessControlCreateWithFlags` with `.privateKeyUsage` flag only, protection level `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

**`passcode`** — The key requires the macOS device passcode (login password) before each signing operation. The system presents a standard macOS authentication dialog (SecurityAgent). The passcode must be entered through the system GUI — there is no API to supply it programmatically, even with root access. This policy is appropriate for keys that require human approval per operation, not for autonomous agents.

Implementation: `SecAccessControlCreateWithFlags` with `[.privateKeyUsage, .devicePasscode]` flags.

**`biometric`** — The key requires Touch ID (or Face ID on supported hardware) before each signing operation. The system presents the biometric authentication dialog. If biometric fails repeatedly, falls back to device passcode. Like passcode policy, this requires physical human presence and cannot be automated.

Implementation: `SecAccessControlCreateWithFlags` with `[.privateKeyUsage, .biometryCurrentSet]` flags. Note: `.biometryCurrentSet` ties the key to the currently enrolled biometric data. If the user re-enrolls fingerprints or face, the key becomes permanently inaccessible (by design — it prevents someone from adding their own fingerprint to access existing keys).

### Policy Enforcement Scope

The access control policy is enforced by the Secure Enclave hardware for signing operations. This is the only enforcement layer — the CLI does not add additional software gates on top.

- **Signing**: hardware-enforced. The Secure Enclave checks the policy before every signing operation.
- **Creating keys**: no policy required. Any process that can call the CLI can create a new key.
- **Listing / info**: no policy required. Public keys and metadata are not secret.
- **Deleting**: no policy required beyond the `--confirm` safety flag. Deletion is a destructive metadata + Keychain operation, not a private key operation.
- **Rotating**: no policy required beyond the key existing. Rotation creates a new key, updates metadata, and deletes the old key.

### Key Metadata Storage

The Secure Enclave stores only the private key material. All metadata — labels, creation timestamps, public keys, policies, signing counters — is stored in a local JSON file at `~/.keypo/keys.json`. This file contains no secret material; it is an index of key references.

Each key entry in the metadata file stores:

- `keyId`: human-readable label (the primary identifier used in all CLI commands)
- `applicationTag`: the Keychain application tag used to look up the Secure Enclave key via SecItemCopyMatching
- `publicKey`: uncompressed P-256 public key in hex (0x04 prefix + 32 bytes X + 32 bytes Y = 65 bytes total = 130 hex chars)
- `policy`: one of `open`, `passcode`, `biometric`
- `createdAt`: ISO 8601 timestamp
- `signingCount`: number of signing operations performed
- `lastUsedAt`: ISO 8601 timestamp of most recent signing operation (null if never used)
- `previousPublicKeys`: array of public keys from prior rotations (empty initially)

The config directory `~/.keypo` is created on first use with 700 permissions (owner only). The `keys.json` file is created with 600 permissions (owner read/write only).

### Signing: Pre-hashed Input and CryptoKit

keypo-signer uses CryptoKit's `SecureEnclave.P256.Signing.PrivateKey` API rather than the lower-level `SecKeyCreateSignature`. The reason: `SecKeyCreateSignature` with the `ecdsaSignatureMessageX962SHA256` algorithm SHA-256 hashes the input before signing. Callers who pass already-hashed data would get a double-hash, producing signatures that won't verify against the original data.

CryptoKit's `signature(for:)` method accepts a pre-computed `SHA256Digest` or arbitrary data via `signature(for: rawRepresentation)`, giving the caller control over what exactly is signed. The CLI accepts data as input and signs it directly — no additional hashing is applied.

The Secure Enclave produces DER-encoded ECDSA signatures. The CLI outputs both the DER encoding and the decomposed r, s values (as separate 32-byte big-endian integers), since different consumers expect different formats.

### Low-S Normalization

Some signature verification implementations reject signatures where the s value is greater than half the curve order (following a convention originating from BIP-62). The Secure Enclave does not guarantee low-S output. After every signing operation, keypo-signer checks if s > curve_order/2 and, if so, replaces s with curve_order - s. This normalization is always applied to maximize compatibility with downstream verifiers.

The P-256 curve order is: `0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551`.

---

## CLI Interface

### Global Flags

| Flag | Description |
|------|-------------|
| `--format json` | Output as JSON (default) |
| `--format raw` | Output only the essential value with no wrapper |
| `--format pretty` | Human-readable formatted output |
| `--quiet` | Suppress all output except the result |
| `--config <path>` | Path to config directory (default: `~/.keypo`) |
| `--version` | Print version and exit |

### Commands

---

#### `keypo-signer create`

Generate a new P-256 signing key in the Secure Enclave.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `--label <n>` | Yes | Human-readable key identifier. Must be unique. Allowed characters: lowercase alphanumeric and hyphens. Must start with a letter. Length: 1-64 characters. |
| `--policy <policy>` | Yes | Access control policy: `open`, `passcode`, or `biometric` |

**Behavior:**

1. Validate the label format and uniqueness (check metadata file)
2. Create the config directory if it doesn't exist
3. Construct a `SecAccessControl` with the appropriate flags based on the chosen policy
4. Generate a key pair in the Secure Enclave (P-256, 256-bit, `kSecAttrTokenIDSecureEnclave`)
5. Extract and format the public key as uncompressed hex
6. Write the metadata entry to keys.json
7. Output the key information

**JSON output:**

```json
{
  "keyId": "my-signing-key",
  "publicKey": "0x04abc...def",
  "curve": "P-256",
  "policy": "open",
  "createdAt": "2026-02-28T12:00:00Z",
  "storage": "secure-enclave"
}
```

**Raw output:** The public key hex string only.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Label already exists or invalid format |
| 2 | Secure Enclave not available |
| 3 | Key generation failed |

**Notes:**

- If policy is `biometric`, the system will prompt for Touch ID during key creation to confirm the biometric enrollment
- The application tag stored in the Keychain uses a namespaced format: `com.keypo.signer.<label>`

---

#### `keypo-signer list`

List all managed keys and their status.

**Arguments:** None required.

**Behavior:**

1. Read the metadata file (if it doesn't exist, return empty list)
2. For each key, verify the Secure Enclave key still exists by attempting a `SecItemCopyMatching` lookup (keys can be deleted outside this tool via system Keychain operations or SE reset)
3. Report each key's status as `active` or `missing`

**JSON output:**

```json
{
  "keys": [
    {
      "keyId": "my-signing-key",
      "publicKey": "0x04abc...def",
      "policy": "open",
      "status": "active",
      "createdAt": "2026-02-28T12:00:00Z",
      "signingCount": 142,
      "lastUsedAt": "2026-02-28T15:30:00Z"
    },
    {
      "keyId": "admin-key",
      "publicKey": "0x04123...789",
      "policy": "biometric",
      "status": "active",
      "createdAt": "2026-02-28T12:05:00Z",
      "signingCount": 3,
      "lastUsedAt": "2026-02-28T14:00:00Z"
    }
  ]
}
```

**Exit codes:** 0 always (empty list is not an error).

**Notes:** This command does not require any authentication. Public keys and metadata are not secret.

---

#### `keypo-signer info <keyId>`

Get detailed information about a specific key.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<keyId>` | Yes | The key label (positional argument) |

**Behavior:**

1. Look up the key in metadata
2. Verify the SE key still exists
3. Return full details

**JSON output:**

```json
{
  "keyId": "my-signing-key",
  "publicKey": "0x04abc...def",
  "curve": "P-256",
  "policy": "open",
  "status": "active",
  "createdAt": "2026-02-28T12:00:00Z",
  "signingCount": 142,
  "lastUsedAt": "2026-02-28T15:30:00Z",
  "previousPublicKeys": []
}
```

**Raw output:** The public key hex string only.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Key not found in metadata |

---

#### `keypo-signer sign <data>`

Sign data with a Secure Enclave key.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<data>` | Yes (unless --stdin) | Hex-encoded data to sign (with or without 0x prefix) |
| `--key <keyId>` | No | Key to sign with. Required if multiple keys exist. If omitted and exactly one key exists, uses that key. |
| `--stdin` | No | Read hex data from stdin instead of positional argument |

**Behavior:**

1. Resolve which key to use (explicit `--key`, or the only available key, or error if ambiguous)
2. Validate the input is valid hex and decode to bytes
3. Look up the private key reference from the Secure Enclave
4. The Secure Enclave enforces the key's access control policy at this point:
   - `open`: proceeds immediately
   - `passcode`: macOS presents a password dialog; signing blocks until the user enters it or cancels
   - `biometric`: macOS presents a Touch ID dialog; signing blocks until the user authenticates or cancels
5. Sign the data using CryptoKit's SecureEnclave P256 signing (the input is treated as pre-hashed data)
6. Decode the DER signature into r and s components
7. Apply low-S normalization if needed
8. Increment signing counter and update lastUsedAt in metadata
9. Output the result

**JSON output:**

```json
{
  "signature": "0x3045022100...",
  "r": "0xabc...def",
  "s": "0x123...456",
  "publicKey": "0x04abc...def",
  "keyId": "my-signing-key",
  "algorithm": "ES256"
}
```

**Raw output:** The DER signature hex string only.

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Key not found |
| 2 | Secure Enclave key missing (metadata exists but SE key was deleted) |
| 3 | Invalid hex input |
| 4 | Signing failed (including user cancelled biometric/passcode) |
| 5 | Ambiguous key (multiple keys exist, --key not specified) |

---

#### `keypo-signer delete <keyId>`

Permanently and irreversibly destroy a Secure Enclave key.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<keyId>` | Yes | The key to destroy (positional argument) |
| `--confirm` | Yes | Safety flag to prevent accidental deletion. Command refuses to run without it. |

**Behavior:**

1. Look up the key in metadata
2. Verify the SE key exists
3. Delete the Secure Enclave key via `SecItemDelete`
4. Remove the entry from the metadata file
5. Output confirmation

This operation is permanent. Once the Secure Enclave key is deleted, the private key material is destroyed and cannot be recovered by any means. Any signatures that depended on this key will no longer be producible.

**JSON output:**

```json
{
  "keyId": "my-signing-key",
  "deleted": true,
  "deletedAt": "2026-02-28T16:00:00Z"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Key not found |
| 2 | --confirm flag not provided |
| 3 | Deletion failed |

**Notes:**

- Without `--confirm`, the command prints a warning message showing which key would be deleted and its public key, then exits with code 2 without deleting anything.

---

#### `keypo-signer rotate <keyId>`

Replace a key with a new one, keeping the same label and policy. The old key is permanently destroyed.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<keyId>` | Yes | The key to rotate (positional argument) |

**Behavior:**

1. Look up the existing key in metadata, record its policy and public key
2. Generate a new Secure Enclave key with the same policy as the original
3. Delete the old Secure Enclave key via `SecItemDelete`
4. Update metadata: replace `applicationTag` and `publicKey`, append the old public key to `previousPublicKeys`, reset `signingCount` to 0
5. Output the new key info and the old public key

**JSON output:**

```json
{
  "keyId": "my-signing-key",
  "publicKey": "0x04new...key",
  "previousPublicKey": "0x04old...key",
  "policy": "open",
  "rotatedAt": "2026-02-28T16:00:00Z"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Key not found |
| 2 | New key generation failed |
| 3 | Old key deletion failed (new key is still usable — metadata has been updated) |

**Notes:**

- The caller receives both the old and new public keys in the output. This is useful if the caller needs to update any external system that references the public key.
- If old key deletion fails (exit code 3), the rotation is still considered successful — the new key is active and the metadata is updated. The old SE key remains as an orphan that can be cleaned up manually.

---

#### `keypo-signer verify <data> <signature>`

Verify a signature against a public key. This is a convenience command for testing. The verification happens in software using the public key — not in the Secure Enclave.

**Arguments:**

| Argument | Required | Description |
|----------|----------|-------------|
| `<data>` | Yes | Hex-encoded data that was signed |
| `<signature>` | Yes | Hex-encoded DER signature |
| `--key <keyId>` | No | Verify against this key's public key |
| `--public-key <hex>` | No | Verify against an explicit public key (for verifying without having the key in the local store) |

One of `--key` or `--public-key` is required.

**JSON output:**

```json
{
  "valid": true,
  "publicKey": "0x04abc...def",
  "algorithm": "ES256"
}
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| 0 | Signature is valid |
| 1 | Signature is invalid |
| 2 | Invalid input (bad hex, missing arguments) |

---

#### `keypo-signer info --system`

Print system information about Secure Enclave availability and tool configuration.

**JSON output:**

```json
{
  "secureEnclaveAvailable": true,
  "chip": "Apple M2",
  "macosVersion": "15.3",
  "keypoVersion": "0.1.0",
  "configDir": "/Users/dave/.keypo",
  "keyCount": 2
}
```

**Notes:** This works on all hardware, including machines without a Secure Enclave (it reports `secureEnclaveAvailable: false`). Useful for Homebrew formula tests and diagnostic scripts.

---

## Security Model

### Hardware-Enforced Guarantees

These hold even if an attacker has root access on the machine:

- Private key material never leaves the Secure Enclave. It cannot be read, copied, exported, or transmitted.
- The access control policy on each key (open/passcode/biometric) is immutable and enforced by the Secure Enclave hardware for every signing operation.
- Keys are bound to the specific physical device. There is no mechanism to migrate a Secure Enclave key to another machine.
- For passcode and biometric policies: authentication must occur through the macOS system GUI (SecurityAgent). There is no API to supply the device passcode programmatically, even with root access. A headless process cannot bypass this.

### Software-Enforced Guarantees

These depend on the CLI being the interface to the keys. A process that bypasses the CLI and calls Security framework APIs directly could circumvent these:

- Key label uniqueness and metadata integrity. The mapping between human-readable labels and Keychain application tags is maintained in a JSON file.
- Signing counters and timestamps. These are metadata that the CLI updates — a direct SE call would bypass the counter.
- File permissions on the config directory and metadata file.

### Threat Analysis

**Threat: Rogue process tries to sign with a key**

- If the key policy is `open`: the rogue process can sign, either through the CLI or by calling Security framework directly. The Secure Enclave provides extraction-resistance but not use-resistance for open-policy keys.
- If the key policy is `passcode`: the system presents a password dialog via the macOS GUI. Without the password entered through the dialog, signing fails. Hardware-enforced, and not bypassable programmatically.
- If the key policy is `biometric`: the system presents a Touch ID dialog. Without the enrolled fingerprint, signing fails. Hardware-enforced.

**Threat: Rogue process tries to delete a key (denial of service)**

- `SecItemDelete` does not require the key's signing access control policy. A rogue process that knows the application tag can delete the key. The attacker gains nothing — they can't extract the key and can only destroy it. Mitigation: Keychain access groups tied to the binary's code signing identity can prevent other processes from accessing keypo-signer's Keychain items.

**Threat: Metadata file is corrupted or tampered**

- Corruption: the CLI handles invalid JSON gracefully — reports an error and refuses to operate. Keys in the SE still exist and can be recovered by scanning the Keychain for the `com.keypo.signer.*` application tag prefix.
- Tampering (e.g., swapping public keys between entries): this could cause confusion but cannot cause key material leakage. The SE keys themselves are unaffected.

---

## Swift Package Structure

The project is organized as a Swift Package Manager project:

- **`keypo-signer`** (executable target): CLI entry point, argument parsing, output formatting. Depends on KeypoCore.
- **`KeypoCore`** (library target): all Secure Enclave operations, key management, metadata storage, signature format conversion. This is the shared logic that could be reused by a future GUI app or server mode.
- **`KeypoCoreTests`** (test target): unit and integration tests.

### Dependencies

Minimize external dependencies:

- **swift-argument-parser** (Apple): CLI argument parsing and help generation
- **CryptoKit** (system framework): SecureEnclave P256 signing operations
- **Security** (system framework): Keychain operations, SecAccessControl, key lookup/deletion
- **LocalAuthentication** (system framework): LAContext for policy evaluation context

JSON encoding/decoding uses Foundation's built-in `JSONEncoder`/`JSONDecoder`. No external JSON library is needed.

---

## Distribution

### Homebrew

Distributed via a custom Homebrew tap: `keypo/homebrew-tap`.

**Installation:**

```bash
brew tap keypo/tap
brew install keypo-signer
```

**Formula type:** Cask or binary formula that downloads a pre-built arm64 macOS binary from GitHub Releases. Building from source in Homebrew is not practical because the build requires Xcode and macOS-specific frameworks.

**Build pipeline (GitHub Actions):**

1. Build the Swift package on a macOS Apple Silicon runner
2. Build for arm64 target only (Apple Silicon is required for Secure Enclave)
3. Code-sign the binary with a Developer ID certificate
4. Notarize with Apple (required for Gatekeeper)
5. Create a tar.gz archive and compute SHA256 hash
6. Upload to GitHub Releases
7. Update the Homebrew formula with new URL and SHA256

**Formula test block:**

The Homebrew test runs `keypo-signer info --system` and verifies the output contains version information. This works without Secure Enclave key operations and confirms the binary is executable.

**Caveats:**

The formula should include a caveats section noting:
- Requires Apple Silicon (M1 or later)
- macOS 14 (Sonoma) or later is recommended
- Touch ID requires a Magic Keyboard with Touch ID (for Mac Mini/Mac Studio) or built-in (MacBook)

---

## Verification Tests

All tests must pass on an Apple Silicon Mac with macOS 14 or later. Tests are designed to be run sequentially within each category but categories are independent of each other (each category manages its own setup and teardown).

Tests are organized so that all automated tests (using `open` policy keys) come first. Tests that require human interaction (passcode and biometric policies) are grouped at the end of the spec so the tester can run all automated tests unattended, then step through the interactive tests manually.

### Test Environment Setup

Before running tests:
- Use a dedicated config directory to avoid interfering with real keys: `--config /tmp/keypo-test-$$`
- Each test category should create its config dir at the start and remove it at the end
- All key labels used in tests should be prefixed with `test-` to make cleanup easy

---

### Category 1: Key Lifecycle

**T1.1 — Create a key with open policy**

Run: `keypo-signer create --label test-open --policy open`

Assert:
- Exit code is 0
- JSON output field `keyId` equals `"test-open"`
- JSON field `publicKey` starts with `"0x04"` and is exactly 130 hex characters (65 bytes)
- JSON field `curve` equals `"P-256"`
- JSON field `policy` equals `"open"`
- JSON field `createdAt` is a valid ISO 8601 timestamp within the last 10 seconds
- JSON field `storage` equals `"secure-enclave"`
- The metadata file exists and contains an entry for `"test-open"`

**T1.2 — Reject duplicate label**

Precondition: key `test-open` exists from T1.1

Run: `keypo-signer create --label test-open --policy open`

Assert:
- Exit code is 1
- stderr contains a message indicating the label already exists
- No new key is created in the Secure Enclave

**T1.3 — Reject invalid label formats**

Run each of the following and assert exit code is 1 with an error about invalid format:
- `keypo-signer create --label "" --policy open` (empty)
- `keypo-signer create --label "has spaces" --policy open` (spaces)
- `keypo-signer create --label "HAS-CAPS" --policy open` (uppercase)
- `keypo-signer create --label "123-starts-number" --policy open` (starts with number)
- `keypo-signer create --label "-starts-hyphen" --policy open` (starts with hyphen)
- A label that is 65 characters long (exceeds max length)

**T1.4 — Reject invalid policy**

Run: `keypo-signer create --label test-bad --policy nuclear`

Assert:
- Exit code is non-zero
- Error message lists valid policy options

**T1.5 — List shows all created keys**

Precondition: key `test-open` exists, plus `test-extra-a` and `test-extra-b` created with `--policy open`

Run: `keypo-signer list`

Assert:
- Exit code is 0
- JSON field `keys` is an array with 3 entries
- Each entry has `status` equal to `"active"`
- Each entry has a unique `publicKey`

**T1.6 — List on empty state returns empty array**

Precondition: clean config directory with no keys

Run: `keypo-signer list`

Assert:
- Exit code is 0
- JSON field `keys` is an empty array `[]`

**T1.7 — Info for existing key**

Precondition: key `test-open` exists

Run: `keypo-signer info test-open`

Assert:
- Exit code is 0
- JSON field `keyId` equals `"test-open"`
- JSON field `status` equals `"active"`
- JSON field `publicKey` matches the value from T1.1
- JSON field `previousPublicKeys` is an empty array
- JSON field `signingCount` is 0

**T1.8 — Info for nonexistent key**

Run: `keypo-signer info ghost-key`

Assert:
- Exit code is 1
- stderr contains error message

**T1.9 — Create multiple keys and verify unique public keys**

Run:
- `keypo-signer create --label test-multi-a --policy open`
- `keypo-signer create --label test-multi-b --policy open`
- `keypo-signer create --label test-multi-c --policy open`

Assert:
- All three succeed
- All three have different `publicKey` values

---

### Category 2: Signing (Open Policy)

**T2.1 — Sign a hash with an open-policy key**

Precondition: key `test-sign` created with `--policy open`

Run: `keypo-signer sign 0x$(openssl rand -hex 32) --key test-sign`

Assert:
- Exit code is 0
- JSON field `signature` is a hex string starting with `"0x"`
- JSON field `r` is a hex string (up to 64 hex chars, 32 bytes)
- JSON field `s` is a hex string (up to 64 hex chars, 32 bytes)
- JSON field `keyId` equals `"test-sign"`
- JSON field `publicKey` matches the key's known public key
- JSON field `algorithm` equals `"ES256"`

**T2.2 — Signature verifies with external tooling (CRITICAL)**

This is the most critical test. It confirms end-to-end correctness and standards compatibility.

Precondition: key `test-sign` created with `--policy open`, public key known

Steps:
1. Generate a known 32-byte hash: `HASH=0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef`
2. Sign it: `keypo-signer sign $HASH --key test-sign`, capture r and s
3. Using an independent P-256 verification tool (Python `ecdsa` library, Node.js `crypto` module, or `openssl`), verify that the signature (r, s) is valid for the given hash and the key's public key

Assert:
- External verification succeeds
- This proves the signature format is standards-compliant

**T2.3 — Same hash produces different signatures (ECDSA non-determinism)**

Precondition: key `test-sign` exists

Run: Sign the same hash twice:
- `SIG1=$(keypo-signer sign 0xdeadbeef... --key test-sign --format json)`
- `SIG2=$(keypo-signer sign 0xdeadbeef... --key test-sign --format json)`

Assert:
- Both succeed
- `SIG1.signature` does not equal `SIG2.signature` (ECDSA with random k produces different signatures)
- Both have the same `publicKey`
- Both verify independently (using the verify command or external tooling)

**T2.4 — Default key resolution with single key**

Precondition: exactly one key `test-only` exists

Run: `keypo-signer sign 0xdeadbeef` (no --key flag)

Assert:
- Exit code is 0
- JSON field `keyId` equals `"test-only"`

**T2.5 — Ambiguous key resolution with multiple keys**

Precondition: keys `test-a` and `test-b` exist

Run: `keypo-signer sign 0xdeadbeef` (no --key flag)

Assert:
- Exit code is 5
- stderr message indicates ambiguity and lists available key names

**T2.6 — Sign with nonexistent key**

Run: `keypo-signer sign 0xdeadbeef --key ghost-key`

Assert:
- Exit code is 1

**T2.7 — Invalid hex input rejected**

Run: `keypo-signer sign not-hex-at-all --key test-sign`

Assert:
- Exit code is 3
- stderr mentions invalid hex

**T2.8 — Empty input rejected**

Run: `keypo-signer sign "" --key test-sign`

Assert:
- Exit code is 3

**T2.9 — Signing counter increments**

Precondition: key `test-counter` created, initial `signingCount` is 0

Run:
1. `keypo-signer sign 0xaaaa... --key test-counter`
2. `keypo-signer sign 0xbbbb... --key test-counter`
3. `keypo-signer sign 0xcccc... --key test-counter`
4. `keypo-signer info test-counter`

Assert:
- `signingCount` is 3
- `lastUsedAt` is a recent timestamp

**T2.10 — Raw format outputs only signature**

Run: `keypo-signer sign 0xdeadbeef... --key test-sign --format raw`

Assert:
- stdout is exactly one line
- The line is a hex string (the DER signature) with no JSON wrapper
- No additional whitespace, labels, or formatting

**T2.11 — Stdin input works**

Precondition: key `test-sign` exists

Run: `echo -n "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" | keypo-signer sign --stdin --key test-sign`

Assert:
- Exit code is 0
- Produces a valid signature

**T2.12 — Low-S normalization**

Run: Sign 200 random hashes with the same key, capture all s values.

Assert:
- Every s value, parsed as a big-endian unsigned integer, is less than or equal to P-256 curve_order / 2
- curve_order / 2 = `0x7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8`

---

### Category 3: Deletion

**T3.1 — Delete requires --confirm flag**

Precondition: key `test-del-safety` created with `--policy open`

Run: `keypo-signer delete test-del-safety` (no --confirm)

Assert:
- Exit code is 2
- stderr contains a warning showing the key name and public key
- Key still exists: `keypo-signer info test-del-safety` returns status `"active"`
- Key can still sign

**T3.2 — Delete an open-policy key with --confirm**

Precondition: key `test-del-open` created with `--policy open`

Run: `keypo-signer delete test-del-open --confirm`

Assert:
- Exit code is 0
- JSON field `deleted` is true
- `keypo-signer info test-del-open` returns exit code 1 (not found)
- `keypo-signer sign 0xdeadbeef --key test-del-open` returns exit code 1

**T3.3 — Delete a passcode-policy key (no authentication required)**

Precondition: key `test-del-passcode` created with `--policy passcode`

Run: `keypo-signer delete test-del-passcode --confirm`

Assert:
- Exit code is 0
- JSON field `deleted` is true
- No authentication dialog appears (delete does not use the private key)
- `keypo-signer info test-del-passcode` returns exit code 1 (not found)

**T3.4 — Delete a biometric-policy key (no authentication required)**

Precondition: key `test-del-bio` created with `--policy biometric`

Run: `keypo-signer delete test-del-bio --confirm`

Assert:
- Exit code is 0
- JSON field `deleted` is true
- No Touch ID dialog appears (delete does not use the private key)
- `keypo-signer info test-del-bio` returns exit code 1 (not found)

**T3.5 — Delete nonexistent key**

Run: `keypo-signer delete ghost-key --confirm`

Assert:
- Exit code is 1

---

### Category 4: Rotation

**T4.1 — Rotate produces new key with same policy**

Precondition: key `test-rot` created with `--policy open`, original public key captured

Run: `keypo-signer rotate test-rot`

Assert:
- Exit code is 0
- JSON field `publicKey` is different from the original
- JSON field `previousPublicKey` equals the original
- JSON field `policy` equals `"open"`
- `keypo-signer info test-rot` shows the new public key
- `keypo-signer info test-rot` JSON field `previousPublicKeys` contains the original public key
- `signingCount` is 0 (reset after rotation)

**T4.2 — Rotated key signs correctly, old key does not verify**

Precondition: key `test-rot` has been rotated from T4.1, new and old public keys known

Run: Sign a hash with the rotated key

Assert:
- Signature is valid against the new public key (via `keypo-signer verify` or external tool)
- Signature is NOT valid against the old public key

**T4.3 — Rotate nonexistent key**

Run: `keypo-signer rotate ghost-key`

Assert:
- Exit code is 1

**T4.4 — Multiple rotations preserve history**

Precondition: key `test-rot-multi` created with `--policy open`

Run:
1. Capture original public key as PK1
2. `keypo-signer rotate test-rot-multi` → capture new key as PK2
3. `keypo-signer rotate test-rot-multi` → capture new key as PK3
4. `keypo-signer info test-rot-multi`

Assert:
- Current `publicKey` is PK3
- `previousPublicKeys` array contains [PK1, PK2] in order
- PK1, PK2, PK3 are all different
- Signing with the current key produces signatures that verify against PK3

---

### Category 5: Verification

**T5.1 — Verify valid signature by key name**

Precondition: key `test-verify` created, hash signed and captured

Run: `keypo-signer verify <hash> <signature> --key test-verify`

Assert:
- Exit code is 0
- JSON field `valid` is true

**T5.2 — Verify with tampered data**

Run: `keypo-signer verify <different-hash> <signature> --key test-verify`

Assert:
- Exit code is 1
- JSON field `valid` is false

**T5.3 — Verify with tampered signature**

Run: Flip a byte in the signature hex, then verify

Assert:
- Exit code is 1
- JSON field `valid` is false

**T5.4 — Verify with wrong key**

Precondition: keys `test-a` and `test-b` exist, hash signed with `test-a`

Run: `keypo-signer verify <hash> <signature> --key test-b`

Assert:
- Exit code is 1
- JSON field `valid` is false

**T5.5 — Verify with explicit public key**

Precondition: know a public key and have a valid signature for it

Run: `keypo-signer verify <hash> <signature> --public-key 0x04...`

Assert:
- Exit code is 0
- JSON field `valid` is true
- Works without having the key in the local metadata store

---

### Category 6: Edge Cases and System

**T6.1 — System info on supported hardware**

Run: `keypo-signer info --system`

Assert:
- Exit code is 0
- JSON field `secureEnclaveAvailable` is true
- JSON field `chip` contains a string (e.g., "Apple M1", "Apple M2")
- JSON field `macosVersion` is a version string
- JSON field `keypoVersion` is a semver string

**T6.2 — Config directory auto-creation**

Precondition: config directory does not exist

Run: `keypo-signer create --label test-first --policy open`

Assert:
- Exit code is 0
- Config directory exists with 700 permissions
- Metadata file exists with 600 permissions

**T6.3 — Concurrent signing does not corrupt metadata**

Precondition: key `test-concurrent` exists with `--policy open`

Run: Launch 10 signing processes in parallel (e.g., using `xargs -P10` or background jobs)

Assert:
- All 10 return valid signatures (exit code 0)
- All 10 signatures are different
- `signingCount` in metadata has increased by exactly 10
- Metadata file is valid JSON (no corruption from concurrent writes)

**T6.4 — Large batch signing performance**

Precondition: key `test-perf` exists with `--policy open`

Run: Sign 100 sequential random hashes, measure total wall-clock time

Assert:
- All 100 succeed
- All 100 signatures are valid
- Record average time per operation (expected: under 50ms per sign for the SE operation itself; total including process startup will be higher for one-shot mode)

**T6.5 — Key persists across process restarts**

Precondition: key `test-persist` created in one terminal session

Run: In a completely new shell session, `keypo-signer sign 0xdeadbeef... --key test-persist`

Assert:
- Exit code is 0
- Signing succeeds with the same public key

**T6.6 — Corrupt metadata handling**

Precondition: key `test-corrupt` created, then manually overwrite `~/.keypo/keys.json` with invalid JSON (e.g., `{{{broken`)

Run: `keypo-signer list`

Assert:
- Does not crash (no unhandled exception / segfault)
- Exits with a non-zero code and a clear error message about corrupted metadata
- Suggests recovery steps (e.g., "The metadata file is corrupted. Keys may still exist in the Secure Enclave. Delete the metadata file and use `keypo-signer create` to re-register keys.")

**T6.7 — Cross-verification with openssl (CRITICAL)**

This test validates format compatibility with the most widely-used crypto toolkit.

Precondition: key `test-openssl` created with `--policy open`

Steps:
1. Get public key via `keypo-signer info test-openssl --format raw`
2. Convert the uncompressed public key hex to PEM format (this requires constructing the ASN.1 DER header for an EC public key on the P-256 curve, then base64-encoding)
3. Sign a known hash with `keypo-signer sign <hash> --key test-openssl`
4. Extract the DER signature
5. Verify with `openssl dgst -verify pubkey.pem -signature sig.der`

Assert:
- openssl verification succeeds

**T6.8 — r and s values within curve order**

Run: Sign 50 random hashes, collect all r and s values

Assert:
- All r values, as big-endian unsigned integers, are > 0 and < P-256 curve order
- All s values, as big-endian unsigned integers, are > 0 and <= P-256 curve_order / 2 (low-S normalized)

**T6.9 — Version flag**

Run: `keypo-signer --version`

Assert:
- Outputs a semver version string
- Exit code is 0

---

### Category 7: Interactive Tests (Passcode and Biometric Policies)

These tests require human interaction and cannot be automated. They should be run after all automated tests (Categories 1-6) pass. The tester must be physically present at the machine with access to the device passcode and Touch ID hardware.

#### Passcode Policy Tests

**T7.1 — Create a key with passcode policy**

Run: `keypo-signer create --label test-passcode --policy passcode`

Assert:
- Exit code is 0
- JSON field `policy` equals `"passcode"`
- Note: The macOS system may present a passcode dialog during creation. This is expected.

**T7.2 — Sign with passcode-policy key prompts for password**

Precondition: key `test-passcode` exists from T7.1

Run: `keypo-signer sign 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef --key test-passcode`

Assert:
- The macOS system authentication dialog appears (requesting device passcode/password)
- After entering the correct password, exit code is 0 and a valid signature is returned

**T7.3 — Verify passcode-policy signature with the verify command**

Precondition: signature obtained from T7.2

Run: `keypo-signer verify <hash-from-T7.2> <signature-from-T7.2> --key test-passcode`

Assert:
- Exit code is 0
- JSON field `valid` is true

**T7.4 — Verify passcode-policy signature with external tooling**

Precondition: signature and public key from T7.1/T7.2

Steps:
1. Take the public key from `keypo-signer info test-passcode`
2. Take the hash and DER signature from T7.2
3. Verify with an independent tool (Python `ecdsa`, Node.js `crypto`, or `openssl`)

Assert:
- External verification succeeds
- Confirms that passcode-policy keys produce the same standards-compliant signature format as open-policy keys

**T7.5 — Cancel passcode dialog aborts signing**

Run: `keypo-signer sign 0xdeadbeef... --key test-passcode`

When the password dialog appears, click Cancel.

Assert:
- Exit code is 4
- stderr contains a message about authentication failure or cancellation

#### Biometric Policy Tests

**T7.6 — Create a key with biometric policy**

Run: `keypo-signer create --label test-bio --policy biometric`

Assert:
- Exit code is 0
- JSON field `policy` equals `"biometric"`
- Touch ID dialog will appear during creation. Tester must authenticate.

**T7.7 — Sign with biometric-policy key prompts for Touch ID**

Precondition: key `test-bio` exists from T7.6

Run: `keypo-signer sign 0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef --key test-bio`

Assert:
- The Touch ID dialog appears
- After successful authentication, exit code is 0 and a valid signature is returned

**T7.8 — Verify biometric-policy signature with the verify command**

Precondition: signature obtained from T7.7

Run: `keypo-signer verify <hash-from-T7.7> <signature-from-T7.7> --key test-bio`

Assert:
- Exit code is 0
- JSON field `valid` is true

**T7.9 — Verify biometric-policy signature with external tooling**

Precondition: signature and public key from T7.6/T7.7

Steps:
1. Take the public key from `keypo-signer info test-bio`
2. Take the hash and DER signature from T7.7
3. Verify with an independent tool (Python `ecdsa`, Node.js `crypto`, or `openssl`)

Assert:
- External verification succeeds
- Confirms that biometric-policy keys produce the same standards-compliant signature format as open-policy keys

**T7.10 — Cancel Touch ID dialog aborts signing**

Run: `keypo-signer sign 0xdeadbeef... --key test-bio`

When the Touch ID dialog appears, click Cancel.

Assert:
- Exit code is 4
- stderr contains a message about authentication failure or cancellation

---

## Appendix: Homebrew Formula Notes

The formula lives in `keypo/homebrew-tap`:

- Class name: `KeypoSigner`
- Formula name: `keypo-signer`
- Binary name: `keypo-signer`
- Downloads pre-built arm64 binary from GitHub Releases (Apple Silicon only)
- Test block runs `keypo-signer info --system` and checks for version info
- Caveats note Apple Silicon requirement (M1 or later), macOS 14+, and Touch ID hardware for biometric policy
