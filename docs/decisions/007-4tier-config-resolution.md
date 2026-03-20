---
title: 4-Tier Config Resolution
owner: "@davidblumenfeld"
last_verified: 2026-03-05
status: current
---

# ADR-007: 4-Tier Config Resolution

## Status

Accepted

## Context

The CLI needs to resolve several configuration values (RPC URL, bundler URL, paymaster URL, paymaster policy ID) from multiple sources. Different contexts have different needs:

- **CI/scripts** prefer environment variables.
- **Interactive use** prefers a config file (`~/.keypo/config.toml`).
- **One-off overrides** use CLI flags.
- **Missing values** should produce clear errors with actionable hints.

## Decision

Resolve each configuration value using a strict 4-tier precedence:

1. **CLI flag** (`--rpc`, `--bundler`, `--paymaster`, `--paymaster-policy`) -- highest priority
2. **Environment variable** (`KEYPO_RPC_URL`, `KEYPO_BUNDLER_URL`, `KEYPO_PAYMASTER_URL`, `KEYPO_PAYMASTER_POLICY_ID`)
3. **Config file** (`~/.keypo/config.toml`, under `[network]`)
4. **Error** with `ConfigMissing` variant and hint to use `init` or the relevant flag

```rust
// In config.rs
pub fn resolve(cli_flag: Option<&str>, env_var: &str, config_value: Option<&str>) -> Result<String> {
    if let Some(v) = cli_flag { return Ok(v.to_string()); }
    if let Ok(v) = std::env::var(env_var) { return Ok(v); }
    if let Some(v) = config_value { return Ok(v.to_string()); }
    Err(Error::ConfigMissing { key: env_var.to_string() })
}
```

### Config File Format

```toml
[network]
rpc_url = "https://sepolia.base.org"
bundler_url = "https://api.pimlico.io/v2/84532/rpc?apikey=..."
paymaster_url = "https://api.pimlico.io/v2/84532/rpc?apikey=..."
paymaster_policy_id = "sp_clever_unus"
```

Created by `keypo-wallet init` (interactive or non-interactive mode).

### Debug Logging

With `--verbose`, each resolved value logs its source:

```
DEBUG keypo_wallet: KEYPO_RPC_URL resolved from CLI flag
DEBUG keypo_wallet: KEYPO_BUNDLER_URL resolved from config file
```

## Consequences

- CLI flags always win. This enables one-off overrides without modifying config or env.
- Environment variables override the config file. This supports CI and scripting.
- Unknown config keys produce warnings (non-fatal) on stderr.
- Invalid URLs in any tier produce `ConfigParse` errors with `config edit` hint.
- The `config show` command displays the effective value and its source when env vars are active.

## References

- `keypo-wallet/src/config.rs` -- config resolution implementation
- `keypo-wallet/src/bin/main.rs` -- CLI flag definitions
- Root README.md "Resolution precedence" section
