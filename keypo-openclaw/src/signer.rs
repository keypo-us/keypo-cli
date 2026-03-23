use crate::error::{Error, Result};
use serde::Deserialize;
use std::process::{Command, Stdio};

/// Wrapper for the `keypo-signer vault list` JSON output.
#[derive(Debug, Deserialize)]
struct VaultListOutput {
    vaults: Vec<VaultTier>,
}

#[derive(Debug, Deserialize)]
struct VaultTier {
    policy: String,
    secrets: Vec<VaultSecret>,
}

#[derive(Debug, Deserialize)]
struct VaultSecret {
    name: String,
}

/// A flattened vault entry (secret name + policy tier).
#[derive(Debug, Clone)]
pub struct VaultEntry {
    pub name: String,
    pub vault: String, // "open", "passcode", "biometric"
}

/// Subprocess wrapper for keypo-signer vault operations.
pub struct VaultSigner {
    binary: String,
}

impl VaultSigner {
    pub fn new() -> Self {
        Self {
            binary: "keypo-signer".to_string(),
        }
    }

    #[cfg(test)]
    #[allow(dead_code)]
    pub fn with_binary(binary: impl Into<String>) -> Self {
        Self {
            binary: binary.into(),
        }
    }

    /// Returns true if keypo-signer is on PATH.
    pub fn is_available(&self) -> bool {
        Command::new(&self.binary)
            .arg("--version")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok()
    }

    /// Returns the version string from keypo-signer, if available.
    pub fn version(&self) -> Result<String> {
        let output = self.run_capture(&["--version"])?;
        Ok(output.trim().to_string())
    }

    /// Returns true if the vault is already initialized.
    pub fn is_vault_initialized(&self) -> bool {
        Command::new(&self.binary)
            .args(["vault", "list"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|s| s.success())
    }

    /// Initialize the vault (creates encryption keys for all three policy tiers).
    pub fn vault_init(&self) -> Result<()> {
        self.run_raw(&["vault", "init"])
    }

    /// List all vault entries (names and their policy tiers).
    pub fn vault_list(&self) -> Result<Vec<VaultEntry>> {
        let output = self.run_capture(&["vault", "list"])?;
        let parsed: VaultListOutput = serde_json::from_str(&output)
            .map_err(|e| Error::SignerOutput(format!("failed to parse vault list: {e}")))?;

        let mut entries = Vec::new();
        for tier in parsed.vaults {
            for secret in tier.secrets {
                entries.push(VaultEntry {
                    name: secret.name,
                    vault: tier.policy.clone(),
                });
            }
        }
        Ok(entries)
    }

    /// Store a new secret in the vault. Value is piped via stdin (--stdin flag).
    pub fn vault_set(&self, name: &str, value: &str, policy: &str) -> Result<()> {
        self.run_stdin(
            &["vault", "set", name, "--vault", policy, "--stdin"],
            value,
        )
    }

    /// Update an existing secret. Value is piped via stdin (--stdin flag).
    /// The secret stays in its original policy tier.
    pub fn vault_update(&self, name: &str, value: &str) -> Result<()> {
        self.run_stdin(&["vault", "update", name, "--stdin"], value)
    }

    /// Retrieve the raw (bare) value of a secret.
    pub fn vault_get_raw(&self, name: &str) -> Result<String> {
        self.run_capture(&["vault", "get", name, "--format", "raw"])
    }

    /// Delete a secret from the vault.
    pub fn vault_delete(&self, name: &str) -> Result<()> {
        self.run_raw(&["vault", "delete", name, "--confirm"])
    }

    /// Create or update an encrypted backup in iCloud Drive.
    /// Runs with inherited I/O for interactive passphrase display.
    pub fn vault_backup(&self) -> Result<()> {
        self.run_raw(&["vault", "backup"])
    }

    /// Show backup status (last date, secret count, device).
    pub fn vault_backup_info(&self) -> Result<()> {
        self.run_raw(&["vault", "backup", "info"])
    }

    /// Reset the backup encryption key and passphrase.
    pub fn vault_backup_reset(&self) -> Result<()> {
        self.run_raw(&["vault", "backup", "reset"])
    }

    /// Restore vault secrets from iCloud Drive backup.
    /// Runs with inherited I/O for interactive merge and passphrase prompt.
    pub fn vault_restore(&self) -> Result<()> {
        self.run_raw(&["vault", "restore"])
    }

    // --- Private helpers ---

    /// Run a command with inherited stdio (passthrough to terminal).
    fn run_raw(&self, args: &[&str]) -> Result<()> {
        let status = Command::new(&self.binary)
            .args(args)
            .status()
            .map_err(|e| self.map_spawn_error(e))?;

        if !status.success() {
            return Err(Error::SignerCommand(format!(
                "{} {} exited with {}",
                self.binary,
                args.first().unwrap_or(&""),
                status
            )));
        }
        Ok(())
    }

    /// Run a command and capture stdout.
    fn run_capture(&self, args: &[&str]) -> Result<String> {
        let output = Command::new(&self.binary)
            .args(args)
            .output()
            .map_err(|e| self.map_spawn_error(e))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(Error::SignerCommand(format!(
                "{} {} exited with {}: {}",
                self.binary,
                args.first().unwrap_or(&""),
                output.status,
                stderr.trim()
            )));
        }

        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }

    /// Run a command with value piped to stdin.
    fn run_stdin(&self, args: &[&str], input: &str) -> Result<()> {
        let mut child = Command::new(&self.binary)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| self.map_spawn_error(e))?;

        if let Some(mut stdin) = child.stdin.take() {
            use std::io::Write;
            stdin.write_all(input.as_bytes()).map_err(|e| {
                Error::SignerCommand(format!("failed to write to {} stdin: {e}", self.binary))
            })?;
            // stdin is dropped here, closing the pipe
        }

        let output = child.wait_with_output().map_err(|e| {
            Error::SignerCommand(format!("failed to wait for {}: {e}", self.binary))
        })?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(Error::SignerCommand(format!(
                "{} {} exited with {}: {}",
                self.binary,
                args.first().unwrap_or(&""),
                output.status,
                stderr.trim()
            )));
        }
        Ok(())
    }

    fn map_spawn_error(&self, e: std::io::Error) -> Error {
        if e.kind() == std::io::ErrorKind::NotFound {
            Error::SignerNotFound(self.binary.clone())
        } else {
            Error::SignerCommand(format!("failed to run {}: {e}", self.binary))
        }
    }
}
