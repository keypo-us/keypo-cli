#!/bin/bash
# Install keypo-approvald as a system service running as _keypo user.
# Must be run with sudo.
# Usage: sudo ./install-daemon.sh
set -euo pipefail

INSTALL_DIR="/usr/local/libexec/keypo"
SOCKET_DIR="/var/run/keypo"
PLIST_PATH="/Library/LaunchDaemons/io.keypo.approvald.plist"
DAVE_USER="${KEYPO_VAULT_USER:-dave}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (use sudo)"
    exit 1
fi

echo "=== Installing keypo-approvald ==="

# Step 1: Create _keypo system user
if ! id _keypo &>/dev/null; then
    echo "Creating _keypo system user..."
    # Find an unused UID in the system range
    NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | awk 'BEGIN{n=400} $1==n{n++} END{print n}')
    dscl . -create /Users/_keypo
    dscl . -create /Users/_keypo UserShell /usr/bin/false
    dscl . -create /Users/_keypo UniqueID "$NEXT_UID"
    dscl . -create /Users/_keypo PrimaryGroupID 20
    dscl . -create /Users/_keypo RealName "Keypo Daemon"
    dscl . -create /Users/_keypo NFSHomeDirectory /var/empty
    echo "  ✓ _keypo user created (UID $NEXT_UID)"
else
    echo "  ✓ _keypo user already exists"
fi

# Step 2: Create install directory
mkdir -p "$INSTALL_DIR"
chown _keypo:staff "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"
echo "  ✓ $INSTALL_DIR created"

# Step 3: Build and copy binaries
echo "Building keypo-approvald..."
cd "$REPO_ROOT/demo/hermes-checkout/approvald"
swift build -c release 2>&1 | tail -3
cp .build/release/keypo-approvald "$INSTALL_DIR/"
chown _keypo:staff "$INSTALL_DIR/keypo-approvald"
chmod 755 "$INSTALL_DIR/keypo-approvald"
echo "  ✓ keypo-approvald installed"

# Step 4: Copy checkout.js
cp "$REPO_ROOT/demo/hermes-checkout/checkout/checkout.js" "$INSTALL_DIR/"
chown _keypo:staff "$INSTALL_DIR/checkout.js"
chmod 644 "$INSTALL_DIR/checkout.js"
echo "  ✓ checkout.js installed"

# Step 5: Create checkout wrapper script
cat > "$INSTALL_DIR/checkout-wrapper.sh" << 'WRAPPER'
#!/bin/bash
# Wrapper for sudoers-constrained checkout execution.
# Accepts bio_reason as argument, hardcodes everything else.
set -euo pipefail
BIO_REASON="${1:-Keypo Vault Access}"
exec keypo-signer vault exec \
    --label biometric \
    --reason "$BIO_REASON" \
    --allow '*' \
    -- node /usr/local/libexec/keypo/checkout.js
WRAPPER
chown _keypo:staff "$INSTALL_DIR/checkout-wrapper.sh"
chmod 755 "$INSTALL_DIR/checkout-wrapper.sh"
echo "  ✓ checkout-wrapper.sh installed"

# Step 6: Create socket directory
mkdir -p "$SOCKET_DIR"
chown _keypo:staff "$SOCKET_DIR"
chmod 770 "$SOCKET_DIR"
echo "  ✓ $SOCKET_DIR created"

# Step 7: Configure sudoers
SUDOERS_FILE="/etc/sudoers.d/keypo-approvald"
cat > "$SUDOERS_FILE" << EOF
# Allow _keypo to run the checkout wrapper as $DAVE_USER
_keypo ALL=($DAVE_USER) NOPASSWD: $INSTALL_DIR/checkout-wrapper.sh *
EOF
chmod 440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE"
echo "  ✓ sudoers configured"

# Step 8: Create launchd plist
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.keypo.approvald</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/keypo-approvald</string>
        <string>--socket</string>
        <string>$SOCKET_DIR/keypo-approvald.sock</string>
        <string>--checkout-script</string>
        <string>$INSTALL_DIR/checkout.js</string>
        <string>--vault-user</string>
        <string>$DAVE_USER</string>
    </array>
    <key>UserName</key>
    <string>_keypo</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardErrorPath</key>
    <string>/var/log/keypo-approvald.log</string>
</dict>
</plist>
EOF
chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"
echo "  ✓ launchd plist installed"

# Step 9: Load the daemon
launchctl load "$PLIST_PATH" 2>/dev/null || true
echo "  ✓ daemon loaded"

echo ""
echo "=== Installation complete ==="
echo "Socket: $SOCKET_DIR/keypo-approvald.sock"
echo "Logs: /var/log/keypo-approvald.log"
echo ""
echo "Run the T-C-sec tests to verify UID isolation."
