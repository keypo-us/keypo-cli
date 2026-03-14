---
name: keypo-vault
description: "Background context on Keypo's hardware-secured vault system. Explains vault tiers (open, passcode, biometric), Secure Enclave properties, and why the agent never sees card data."
version: 1.0.1
author: Keypo
metadata:
  hermes:
    tags: [security, vault, encryption, biometric, keypo, secure-enclave]
    category: keypo
    requires_toolsets: [keypo]
---

# Keypo Vault — Background Context

## When to Use

Activate this skill when the user asks about:
- Stored credentials, payment cards, or personal information in the vault
- Vault security, encryption, or how secrets are protected
- How the Secure Enclave works or what biometric protection means

## Concepts

### Vault Tiers (Policy Levels)

Keypo stores encrypted secrets in three tiers, each with increasing authentication requirements:

| Tier | Authentication | Use Case |
|------|---------------|----------|
| `open` | None (device unlocked) | Non-sensitive config |
| `passcode` | Device passcode | Moderate sensitivity |
| `biometric` | Touch ID / Apple Watch | Payment cards, PII |

### How Secrets Are Injected

- Secrets are encrypted at rest using Secure Enclave P-256 keys
- `vault exec` decrypts secrets and injects them as **environment variables** into a child process
- The child process (e.g., checkout.js) reads secrets from its environment
- After the child exits, the environment variables are gone — they are never written to disk

### Secure Enclave Properties

- Private keys **never leave** the Secure Enclave hardware
- Biometric authentication is enforced by hardware, not software
- Even root access cannot extract SE private keys or bypass biometric requirements
- Each `vault exec` invocation gets its own biometric prompt — authentication doesn't leak across processes

## Pitfalls — CRITICAL

- **NEVER** ask the user to reveal their card number, CVV, or other vault secrets
- **NEVER** attempt shell commands to read vault contents (e.g., `vault get`, `cat`, `printenv`)
- **NEVER** include card data, shipping addresses, or other vault secrets in tool calls or messages
- **NEVER** log or display secret values — you don't have access to them and should never try
- If the user asks "what card is in the vault?" — explain that vault secrets are never exposed to the agent
- The agent process does NOT have vault environment variables — only the checkout.js child process does
