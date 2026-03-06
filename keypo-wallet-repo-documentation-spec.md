# Repo Documentation Harness Spec

> **Purpose:** General guidance for organizing in-repo documentation so that AI coding agents (Claude Code, Codex, etc.) can reliably navigate, understand, and contribute to the codebase. Hand this spec to Claude Code and ask it to generate an implementation plan specific to your repo.

---

## Core Principle

From the agent's perspective, anything it can't access in-context doesn't exist. Knowledge that lives in Google Docs, Slack threads, or people's heads is invisible to the system. **The repository must be the single source of truth.**

---

## 1. CLAUDE.md as Table of Contents, Not Encyclopedia

The root `CLAUDE.md` (or `AGENTS.md`) file should be short — roughly 100 lines — and serve as a **map with pointers**, not an exhaustive reference. It gets injected into context on every session, so it must be concise enough to leave room for actual work.

### What belongs in CLAUDE.md

- Project identity: one-sentence description, primary language/framework, target platform
- Repo structure: brief directory map (one line per top-level dir)
- Pointers to deeper docs: relative paths into `docs/` for architecture, design decisions, conventions, etc.
- Build/test/deploy cheat sheet: the 3–5 commands an agent needs to get oriented (build, test, lint, deploy)
- Active conventions: naming patterns, import ordering, error handling style — only the rules that apply repo-wide
- Current focus areas or known constraints (e.g., "EIP-7702 support is in progress, do not refactor delegation logic")

### What does NOT belong in CLAUDE.md

- Exhaustive API references (point to generated docs or a dedicated file)
- Historical decision logs (put these in `docs/decisions/`)
- Task lists or sprint plans
- Anything longer than ~5 lines on a single topic — extract it to `docs/` and link

---

## 2. Structured `docs/` Directory

All deeper documentation lives in a `docs/` directory at the repo root, organized by purpose. The structure below is a starting template — adapt subdirectories to match your repo's actual domains.

```
docs/
├── architecture.md          # Top-level system map: domains, packages, data flow
├── conventions.md           # Coding standards, naming, file organization rules
├── quality.md               # Quality grades per domain/layer, known gaps, tech debt
├── setup.md                 # Dev environment setup, dependencies, toolchain
├── deployment.md            # Deploy process, environments, secrets management
├── decisions/               # Architecture Decision Records (ADRs)
│   ├── 001-framework-choice.md
│   ├── 002-auth-approach.md
│   └── ...
├── designs/                 # Feature/component design specs
│   ├── feature-x.md
│   └── ...
└── runbooks/                # Operational procedures, incident response
    ├── rollback.md
    └── ...
```

### Key properties of each doc

Every document in `docs/` should include a small metadata header:

```markdown
---
title: Architecture Overview
owner: @handle-or-team
last_verified: 2025-06-01
status: current | draft | stale
---
```

- **owner**: who is responsible for keeping this doc accurate
- **last_verified**: date someone (human or agent) confirmed the doc matches reality
- **status**: `current` means it reflects the code; `stale` means it needs review

---

## 3. Architecture Decision Records (ADRs)

Design decisions that affect how an agent should write code belong in `docs/decisions/` as lightweight ADRs. Each ADR answers:

1. **What** was decided
2. **Why** (context, constraints, alternatives considered)
3. **Consequences** (what the agent should or should not do as a result)

Use a simple numbered naming convention (`NNN-short-title.md`). ADRs are append-only — if a decision is superseded, add a new ADR that references the old one rather than editing it. This prevents an agent from accidentally acting on outdated reasoning.

---

## 4. Cross-Linking and Discoverability

Documentation only works if the agent can find it. Follow these rules:

- **CLAUDE.md links to every top-level doc in `docs/`.** If a doc exists but isn't linked from CLAUDE.md, the agent may never discover it.
- **Docs reference each other with relative paths.** Use `[see Architecture](./architecture.md)` style links so agents can follow the chain.
- **Code references docs where relevant.** A comment like `// See docs/decisions/002-auth-approach.md` in a tricky module helps the agent understand why the code is shaped that way.
- **No orphan docs.** Every file in `docs/` should be reachable by following links from CLAUDE.md within two hops.

---

## 5. Documentation Freshness Enforcement

Stale documentation is worse than no documentation — it actively misleads the agent. Build in mechanical checks:

### Automated checks (implement in CI or as a pre-commit hook)

- **Link validation**: all relative links in `docs/` resolve to existing files
- **Metadata presence**: every doc has the required frontmatter (`owner`, `last_verified`, `status`)
- **Staleness detection**: flag docs where `last_verified` is older than a configurable threshold (e.g., 90 days)
- **Orphan detection**: flag docs in `docs/` not reachable from CLAUDE.md

### Agent-driven doc gardening

Periodically (or as a CI job), run a "doc gardening" pass:

1. Scan all docs for `status: stale` or expired `last_verified` dates
2. Cross-reference doc claims against actual code structure (e.g., does `architecture.md` reference directories that still exist?)
3. Open fix-up PRs for anything that's drifted

---

## 6. Writing Style for Agent Consumption

Docs written for agents should prioritize precision and parsability over narrative flow.

- **Be declarative, not conversational.** "All API handlers return `Result<T, AppError>`" beats "We generally try to use Result types."
- **Use concrete examples.** Show the exact import path, the exact command, the exact file name.
- **Prefer structured formats.** Tables, bullet lists, and code blocks are easier for agents to extract facts from than prose paragraphs.
- **State constraints as rules.** "NEVER import from `ui/` in a `service/` module" is enforceable. "Try to keep layers separate" is not.
- **Mark things that are in flux.** If a convention is actively being migrated, say so explicitly: "MIGRATING: handlers are moving from callbacks to async/await. New code MUST use async/await. Legacy callbacks exist in `src/legacy/`."

---

## 7. Scoped Documentation for Subdirectories

For larger repos (monorepos, multi-package), place a lightweight `README.md` or `CLAUDE.md` in each major subdirectory. These should:

- Describe the purpose and scope of that directory
- State local conventions that differ from the repo-wide defaults
- List key files and their roles
- Link back up to the root `CLAUDE.md` or relevant `docs/` files

This gives the agent local context when it's working deep in a subtree without needing to load the entire repo's documentation.

---

## 8. What NOT to Document in the Repo

Some things should stay out of `docs/` to avoid noise:

- **Auto-generated API docs** — generate on demand, don't commit (or put in a clearly separate `docs/generated/` dir that's gitignored or clearly labeled)
- **Meeting notes or discussion logs** — these belong in your project management tool, not the repo
- **Personal preferences** — if it's not a team-wide convention, it doesn't belong
- **Duplicated information** — if the source of truth is a config file (e.g., `tsconfig.json`), don't repeat its contents in a doc; point to the file

---

## Implementation Instructions for Claude Code

When you receive this spec along with access to a specific codebase, do the following:

1. **Audit the current state.** List all existing documentation files, their locations, and their apparent purpose. Note what's missing relative to this spec.
2. **Propose a `docs/` structure.** Based on the repo's actual domains, packages, and architecture, propose a directory layout. Adapt the template above — don't copy it blindly.
3. **Draft a CLAUDE.md.** Write a concise root-level CLAUDE.md that serves as a map. Keep it under 100 lines.
4. **Identify ADR candidates.** Scan the codebase for design decisions that are currently implicit (e.g., "why is auth done this way?") and list them as ADR candidates.
5. **Propose freshness checks.** Recommend specific CI checks or scripts for link validation, metadata enforcement, and staleness detection appropriate to the repo's toolchain.
6. **Flag existing docs that need migration.** If docs exist but are in the wrong place, suggest moves. If critical docs are missing, draft them.
7. **Output an implementation plan** as a prioritized checklist, ordered by impact (what unblocks the agent most).