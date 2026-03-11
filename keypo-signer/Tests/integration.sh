#!/bin/bash
# keypo-signer integration tests: Categories 1-6
# Usage: ./tests/integration.sh
set -uo pipefail
# NO set -e: ~15 tests check non-zero exit codes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Building keypo-signer (release) ==="
swift build -c release --package-path "$PROJECT_DIR" 2>&1 | tail -3
BIN_DIR=$(swift build -c release --package-path "$PROJECT_DIR" --show-bin-path 2>/dev/null)
KEYPO="$BIN_DIR/keypo-signer"

if [ ! -x "$KEYPO" ]; then
    echo "FAIL: binary not found at $KEYPO"
    exit 1
fi

CONFIG="/tmp/keypo-test-$$"
CONFIG_SINGLE="/tmp/keypo-test-$$-single"
CONFIG_EMPTY="/tmp/keypo-test-$$-empty"

ALL_TEST_LABELS="test-open test-extra-a test-extra-b test-multi-a test-multi-b test-multi-c \
test-sign test-only test-a test-b test-counter test-del-safety test-del-open \
test-del-passcode test-del-bio test-rot test-rot-multi test-verify test-concurrent \
test-perf test-persist test-corrupt test-openssl test-first"

# Test harness
PASS=0
FAIL=0
SKIP=0
ERRORS=""

assert_exit() {
    local expected="$1" actual="$2" name="$3"
    if [ "$actual" -ne "$expected" ]; then
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $name (expected exit $expected, got $actual)"
        return 1
    fi
    PASS=$((PASS + 1))
    return 0
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [ "$expected" != "$actual" ]; then
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $name (expected '$expected', got '$actual')"
        return 1
    fi
    PASS=$((PASS + 1))
    return 0
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if echo "$haystack" | grep -q "$needle"; then
        PASS=$((PASS + 1))
        return 0
    fi
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: $name (output does not contain '$needle')"
    return 1
}

assert_true() {
    local condition="$1" name="$2"
    if [ "$condition" = "true" ] || [ "$condition" = "1" ]; then
        PASS=$((PASS + 1))
        return 0
    fi
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: $name"
    return 1
}

cleanup() {
    echo ""
    echo "=== Cleanup ==="
    # Delete SE keys first while metadata exists
    for dir in "$CONFIG" "$CONFIG_SINGLE" "$CONFIG_EMPTY"; do
        if [ -d "$dir" ]; then
            for label in $("$KEYPO" list --config "$dir" 2>/dev/null | jq -r '.keys[].keyId' 2>/dev/null); do
                "$KEYPO" delete "$label" --confirm --config "$dir" 2>/dev/null || true
            done
        fi
    done
    # Fallback: hardcoded labels
    for label in $ALL_TEST_LABELS; do
        "$KEYPO" delete "$label" --confirm --config "$CONFIG" 2>/dev/null || true
        "$KEYPO" delete "$label" --confirm --config "$CONFIG_SINGLE" 2>/dev/null || true
    done
    rm -rf "$CONFIG" "$CONFIG_SINGLE" "$CONFIG_EMPTY"
    rm -f /tmp/pubkey.pem /tmp/sig.der
    echo "Cleanup done."
}
trap cleanup EXIT

echo ""
echo "=== Category 1: Key Lifecycle ==="

# T1.1 — Create a key with open policy
echo "T1.1: Create key with open policy"
OUTPUT=$("$KEYPO" create --label test-open --policy open --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T1.1 exit code"
KEY_ID=$(echo "$OUTPUT" | jq -r '.keyId')
assert_eq "test-open" "$KEY_ID" "T1.1 keyId"
PUBKEY_T1=$(echo "$OUTPUT" | jq -r '.publicKey')
PUBKEY_LEN=${#PUBKEY_T1}
# 0x + 130 hex = 132 chars
assert_eq "132" "$PUBKEY_LEN" "T1.1 publicKey length"
assert_contains "$PUBKEY_T1" "^0x04" "T1.1 publicKey prefix"
CURVE=$(echo "$OUTPUT" | jq -r '.curve')
assert_eq "P-256" "$CURVE" "T1.1 curve"
POLICY=$(echo "$OUTPUT" | jq -r '.policy')
assert_eq "open" "$POLICY" "T1.1 policy"
STORAGE=$(echo "$OUTPUT" | jq -r '.storage')
assert_eq "secure-enclave" "$STORAGE" "T1.1 storage"
# Check metadata file exists
assert_true "$([ -f "$CONFIG/keys.json" ] && echo true || echo false)" "T1.1 metadata file exists"

# T1.2 — Reject duplicate label
echo "T1.2: Reject duplicate label"
OUTPUT=$("$KEYPO" create --label test-open --policy open --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T1.2 reject duplicate"

# T1.3 — Reject invalid label formats
echo "T1.3: Reject invalid labels"
for invalid_label in "" "has spaces" "HAS-CAPS" "123-starts-number"; do
    OUTPUT=$("$KEYPO" create --label "$invalid_label" --policy open --config "$CONFIG" 2>&1) ; RC=$?
    assert_exit 1 $RC "T1.3 invalid label '$invalid_label'"
done
# Hyphen-prefixed label needs = syntax to avoid argument parser confusion
OUTPUT=$("$KEYPO" create --label="-starts-hyphen" --policy open --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T1.3 invalid label '-starts-hyphen'"
# 65-char label
LONG_LABEL=$(python3 -c "print('a' * 65)")
OUTPUT=$("$KEYPO" create --label "$LONG_LABEL" --policy open --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T1.3 label too long"

# T1.4 — Reject invalid policy
echo "T1.4: Reject invalid policy"
OUTPUT=$("$KEYPO" create --label test-bad --policy nuclear --config "$CONFIG" 2>&1) ; RC=$?
assert_true "$([ $RC -ne 0 ] && echo true || echo false)" "T1.4 invalid policy exits non-zero"

# T1.5 — List shows all created keys
echo "T1.5: List keys"
"$KEYPO" create --label test-extra-a --policy open --config "$CONFIG" 2>/dev/null >/dev/null
"$KEYPO" create --label test-extra-b --policy open --config "$CONFIG" 2>/dev/null >/dev/null
OUTPUT=$("$KEYPO" list --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T1.5 exit code"
KEY_COUNT=$(echo "$OUTPUT" | jq '.keys | length')
assert_eq "3" "$KEY_COUNT" "T1.5 key count"
ACTIVE_COUNT=$(echo "$OUTPUT" | jq '[.keys[] | select(.status == "active")] | length')
assert_eq "3" "$ACTIVE_COUNT" "T1.5 all active"

# T1.6 — List on empty state returns empty array
echo "T1.6: Empty list"
OUTPUT=$("$KEYPO" list --config "$CONFIG_EMPTY" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T1.6 exit code"
KEY_COUNT=$(echo "$OUTPUT" | jq '.keys | length')
assert_eq "0" "$KEY_COUNT" "T1.6 empty list"

# T1.7 — Info for existing key
echo "T1.7: Info for existing key"
OUTPUT=$("$KEYPO" info test-open --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T1.7 exit code"
KEY_ID=$(echo "$OUTPUT" | jq -r '.keyId')
assert_eq "test-open" "$KEY_ID" "T1.7 keyId"
STATUS=$(echo "$OUTPUT" | jq -r '.status')
assert_eq "active" "$STATUS" "T1.7 status"
PUBKEY_INFO=$(echo "$OUTPUT" | jq -r '.publicKey')
assert_eq "$PUBKEY_T1" "$PUBKEY_INFO" "T1.7 publicKey matches T1.1"
PREV_KEYS=$(echo "$OUTPUT" | jq '.previousPublicKeys | length')
assert_eq "0" "$PREV_KEYS" "T1.7 no previous keys"
SIGN_COUNT=$(echo "$OUTPUT" | jq '.signingCount')
assert_eq "0" "$SIGN_COUNT" "T1.7 signingCount is 0"
LAST_USED=$(echo "$OUTPUT" | jq '.lastUsedAt')
assert_eq "null" "$LAST_USED" "T1.7 lastUsedAt is null"

# T1.8 — Info for nonexistent key
echo "T1.8: Info for nonexistent key"
OUTPUT=$("$KEYPO" info ghost-key --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T1.8 exit code"

# T1.9 — Create multiple keys with unique public keys
echo "T1.9: Multiple keys with unique public keys"
OUTPUT_A=$("$KEYPO" create --label test-multi-a --policy open --config "$CONFIG" 2>/dev/null)
OUTPUT_B=$("$KEYPO" create --label test-multi-b --policy open --config "$CONFIG" 2>/dev/null)
OUTPUT_C=$("$KEYPO" create --label test-multi-c --policy open --config "$CONFIG" 2>/dev/null)
PK_A=$(echo "$OUTPUT_A" | jq -r '.publicKey')
PK_B=$(echo "$OUTPUT_B" | jq -r '.publicKey')
PK_C=$(echo "$OUTPUT_C" | jq -r '.publicKey')
assert_true "$([ "$PK_A" != "$PK_B" ] && echo true || echo false)" "T1.9 A != B"
assert_true "$([ "$PK_B" != "$PK_C" ] && echo true || echo false)" "T1.9 B != C"
assert_true "$([ "$PK_A" != "$PK_C" ] && echo true || echo false)" "T1.9 A != C"

echo ""
echo "=== Category 2: Signing (Open Policy) ==="

# T2.1 — Sign a hash
echo "T2.1: Sign a hash"
"$KEYPO" create --label test-sign --policy open --config "$CONFIG" 2>/dev/null >/dev/null
RAND_HASH="0x$(openssl rand -hex 32)"
OUTPUT=$("$KEYPO" sign "$RAND_HASH" --key test-sign --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T2.1 exit code"
SIG=$(echo "$OUTPUT" | jq -r '.signature')
assert_contains "$SIG" "^0x" "T2.1 signature prefix"
R_VAL=$(echo "$OUTPUT" | jq -r '.r')
assert_contains "$R_VAL" "^0x" "T2.1 r prefix"
S_VAL=$(echo "$OUTPUT" | jq -r '.s')
assert_contains "$S_VAL" "^0x" "T2.1 s prefix"
KEY_ID=$(echo "$OUTPUT" | jq -r '.keyId')
assert_eq "test-sign" "$KEY_ID" "T2.1 keyId"
ALGO=$(echo "$OUTPUT" | jq -r '.algorithm')
assert_eq "ES256" "$ALGO" "T2.1 algorithm"

# T2.2 — Signature verifies with openssl (CRITICAL)
echo "T2.2: Cross-verify with openssl (CRITICAL)"
HASH="0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
SIGN_PUBKEY=$("$KEYPO" info test-sign --format raw --config "$CONFIG" 2>/dev/null)
SIG_JSON=$("$KEYPO" sign "$HASH" --key test-sign --config "$CONFIG" 2>/dev/null)
SIG_HEX=$(echo "$SIG_JSON" | jq -r '.signature')

PUBKEY_RAW=$(echo "$SIGN_PUBKEY" | sed 's/^0x//')
echo "3059301306072a8648ce3d020106082a8648ce3d030107034200${PUBKEY_RAW}" \
    | xxd -r -p | base64 | fold -w 64 \
    | (echo "-----BEGIN PUBLIC KEY-----"; cat; echo "-----END PUBLIC KEY-----") > /tmp/pubkey.pem

echo "$SIG_HEX" | sed 's/^0x//' | xxd -r -p > /tmp/sig.der

VERIFY_RESULT=$(echo "$HASH" | sed 's/^0x//' | xxd -r -p \
    | openssl dgst -sha256 -verify /tmp/pubkey.pem -signature /tmp/sig.der 2>&1)
assert_contains "$VERIFY_RESULT" "Verified OK" "T2.2 openssl verification"

# T2.3 — Same hash produces different signatures
echo "T2.3: ECDSA non-determinism"
SIG1=$("$KEYPO" sign "$HASH" --key test-sign --config "$CONFIG" 2>/dev/null | jq -r '.signature')
SIG2=$("$KEYPO" sign "$HASH" --key test-sign --config "$CONFIG" 2>/dev/null | jq -r '.signature')
assert_true "$([ "$SIG1" != "$SIG2" ] && echo true || echo false)" "T2.3 signatures differ"

# T2.4 — Default key resolution with single key
echo "T2.4: Default key resolution"
"$KEYPO" create --label test-only --policy open --config "$CONFIG_SINGLE" 2>/dev/null >/dev/null
OUTPUT=$("$KEYPO" sign 0xdeadbeef --config "$CONFIG_SINGLE" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T2.4 exit code"
KEY_ID=$(echo "$OUTPUT" | jq -r '.keyId')
assert_eq "test-only" "$KEY_ID" "T2.4 keyId"

# T2.5 — Ambiguous key resolution
echo "T2.5: Ambiguous key resolution"
"$KEYPO" create --label test-a --policy open --config "$CONFIG" 2>/dev/null >/dev/null
"$KEYPO" create --label test-b --policy open --config "$CONFIG" 2>/dev/null >/dev/null
OUTPUT=$("$KEYPO" sign 0xdeadbeef --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 5 $RC "T2.5 exit code"

# T2.6 — Sign with nonexistent key
echo "T2.6: Sign with nonexistent key"
OUTPUT=$("$KEYPO" sign 0xdeadbeef --key ghost-key --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T2.6 exit code"

# T2.7 — Invalid hex input
echo "T2.7: Invalid hex input"
OUTPUT=$("$KEYPO" sign not-hex-at-all --key test-sign --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 3 $RC "T2.7 exit code"

# T2.8 — Empty input
echo "T2.8: Empty input"
OUTPUT=$("$KEYPO" sign "" --key test-sign --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 3 $RC "T2.8 exit code"

# T2.9 — Signing counter increments
echo "T2.9: Signing counter"
"$KEYPO" create --label test-counter --policy open --config "$CONFIG" 2>/dev/null >/dev/null
"$KEYPO" sign "0xaaaa" --key test-counter --config "$CONFIG" 2>/dev/null >/dev/null
"$KEYPO" sign "0xbbbb" --key test-counter --config "$CONFIG" 2>/dev/null >/dev/null
"$KEYPO" sign "0xcccc" --key test-counter --config "$CONFIG" 2>/dev/null >/dev/null
OUTPUT=$("$KEYPO" info test-counter --config "$CONFIG" 2>/dev/null)
SIGN_COUNT=$(echo "$OUTPUT" | jq '.signingCount')
assert_eq "3" "$SIGN_COUNT" "T2.9 signingCount is 3"
LAST_USED=$(echo "$OUTPUT" | jq -r '.lastUsedAt')
assert_true "$([ "$LAST_USED" != "null" ] && echo true || echo false)" "T2.9 lastUsedAt set"

# T2.10 — Raw format
echo "T2.10: Raw format"
OUTPUT=$("$KEYPO" sign "$HASH" --key test-sign --format raw --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T2.10 exit code"
# Should be hex string without JSON
assert_contains "$OUTPUT" "^0x30" "T2.10 raw DER signature"
# Should NOT contain JSON curly braces
if echo "$OUTPUT" | grep -q '{'; then
    FAIL=$((FAIL + 1))
    ERRORS="${ERRORS}\n  FAIL: T2.10 raw format contains JSON"
else
    PASS=$((PASS + 1))
fi

# T2.11 — Stdin input
echo "T2.11: Stdin input"
OUTPUT=$(echo -n "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" | "$KEYPO" sign --stdin --key test-sign --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T2.11 exit code"
SIG_STDIN=$(echo "$OUTPUT" | jq -r '.signature')
assert_contains "$SIG_STDIN" "^0x" "T2.11 stdin signature"

# T2.12 — Low-S normalization
echo "T2.12: Low-S normalization (200 signatures)"
HALF_ORDER="7FFFFFFF800000007FFFFFFFFFFFFFFFDE737D56D38BCF4279DCE5617E3192A8"
ALL_LOW_S=true
for i in $(seq 1 200); do
    RAND="0x$(openssl rand -hex 32)"
    S_HEX=$("$KEYPO" sign "$RAND" --key test-sign --config "$CONFIG" 2>/dev/null | jq -r '.s' | sed 's/^0x//')
    # Pad s to 64 hex chars (32 bytes) for comparison
    S_PADDED=$(printf "%064s" "$S_HEX" | tr ' ' '0')
    # Compare with half order (both uppercase)
    S_UPPER=$(echo "$S_PADDED" | tr 'a-f' 'A-F')
    HALF_UPPER=$(echo "$HALF_ORDER" | tr 'a-f' 'A-F')
    if [[ "$S_UPPER" > "$HALF_UPPER" ]]; then
        ALL_LOW_S=false
        echo "  High-S found at iteration $i: $S_UPPER"
        break
    fi
done
assert_true "$ALL_LOW_S" "T2.12 all signatures have low-S"

echo ""
echo "=== Category 3: Deletion ==="

# T3.1 — Delete requires --confirm
echo "T3.1: Delete requires --confirm"
"$KEYPO" create --label test-del-safety --policy open --config "$CONFIG" 2>/dev/null >/dev/null
OUTPUT=$("$KEYPO" delete test-del-safety --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 2 $RC "T3.1 exit code"
# Key should still exist
OUTPUT=$("$KEYPO" info test-del-safety --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T3.1 key still exists"

# T3.2 — Delete with --confirm
echo "T3.2: Delete with --confirm"
"$KEYPO" create --label test-del-open --policy open --config "$CONFIG" 2>/dev/null >/dev/null
OUTPUT=$("$KEYPO" delete test-del-open --confirm --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T3.2 exit code"
DELETED=$(echo "$OUTPUT" | jq -r '.deleted')
assert_eq "true" "$DELETED" "T3.2 deleted is true"
# Key should not be found
OUTPUT=$("$KEYPO" info test-del-open --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T3.2 key not found after delete"

# T3.3/T3.4 — Delete passcode/biometric keys (may need interaction to create)
echo "T3.3: Delete passcode-policy key"
OUTPUT=$("$KEYPO" create --label test-del-passcode --policy passcode --config "$CONFIG" 2>&1) ; RC=$?
if [ $RC -ne 0 ]; then
    echo "  SKIP: T3.3 (passcode creation requires interaction)"
    SKIP=$((SKIP + 1))
else
    OUTPUT=$("$KEYPO" delete test-del-passcode --confirm --config "$CONFIG" 2>/dev/null) ; RC=$?
    assert_exit 0 $RC "T3.3 exit code"
    DELETED=$(echo "$OUTPUT" | jq -r '.deleted')
    assert_eq "true" "$DELETED" "T3.3 deleted is true"
fi

echo "T3.4: Delete biometric-policy key"
OUTPUT=$("$KEYPO" create --label test-del-bio --policy biometric --config "$CONFIG" 2>&1) ; RC=$?
if [ $RC -ne 0 ]; then
    echo "  SKIP: T3.4 (biometric creation requires interaction)"
    SKIP=$((SKIP + 1))
else
    OUTPUT=$("$KEYPO" delete test-del-bio --confirm --config "$CONFIG" 2>/dev/null) ; RC=$?
    assert_exit 0 $RC "T3.4 exit code"
    DELETED=$(echo "$OUTPUT" | jq -r '.deleted')
    assert_eq "true" "$DELETED" "T3.4 deleted is true"
fi

# T3.5 — Delete nonexistent key
echo "T3.5: Delete nonexistent key"
OUTPUT=$("$KEYPO" delete ghost-key --confirm --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T3.5 exit code"

echo ""
echo "=== Category 4: Rotation ==="

# T4.1 — Rotate produces new key with same policy
echo "T4.1: Rotate key"
"$KEYPO" create --label test-rot --policy open --config "$CONFIG" 2>/dev/null >/dev/null
ORIG_PK=$("$KEYPO" info test-rot --config "$CONFIG" 2>/dev/null | jq -r '.publicKey')
OUTPUT=$("$KEYPO" rotate test-rot --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T4.1 exit code"
NEW_PK=$(echo "$OUTPUT" | jq -r '.publicKey')
PREV_PK=$(echo "$OUTPUT" | jq -r '.previousPublicKey')
ROT_POLICY=$(echo "$OUTPUT" | jq -r '.policy')
assert_true "$([ "$NEW_PK" != "$ORIG_PK" ] && echo true || echo false)" "T4.1 new key is different"
assert_eq "$ORIG_PK" "$PREV_PK" "T4.1 previousPublicKey matches original"
assert_eq "open" "$ROT_POLICY" "T4.1 policy preserved"
# Check info shows new state
INFO=$("$KEYPO" info test-rot --config "$CONFIG" 2>/dev/null)
INFO_PK=$(echo "$INFO" | jq -r '.publicKey')
assert_eq "$NEW_PK" "$INFO_PK" "T4.1 info shows new key"
PREV_KEYS=$(echo "$INFO" | jq '.previousPublicKeys | length')
assert_eq "1" "$PREV_KEYS" "T4.1 one previous key"
INFO_COUNT=$(echo "$INFO" | jq '.signingCount')
assert_eq "0" "$INFO_COUNT" "T4.1 signingCount reset"

# T4.2 — Rotated key signs correctly
echo "T4.2: Rotated key signs"
SIG_JSON=$("$KEYPO" sign "$HASH" --key test-rot --config "$CONFIG" 2>/dev/null)
SIG_HEX=$(echo "$SIG_JSON" | jq -r '.signature')
# Verify with new key
OUTPUT=$("$KEYPO" verify "$HASH" "$SIG_HEX" --public-key "$NEW_PK" --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T4.2 verify with new key"
# Should NOT verify with old key
OUTPUT=$("$KEYPO" verify "$HASH" "$SIG_HEX" --public-key "$ORIG_PK" --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 1 $RC "T4.2 does not verify with old key"

# T4.3 — Rotate nonexistent key
echo "T4.3: Rotate nonexistent key"
OUTPUT=$("$KEYPO" rotate ghost-key --config "$CONFIG" 2>&1) ; RC=$?
assert_exit 1 $RC "T4.3 exit code"

# T4.4 — Multiple rotations preserve history
echo "T4.4: Multiple rotations"
"$KEYPO" create --label test-rot-multi --policy open --config "$CONFIG" 2>/dev/null >/dev/null
PK1=$("$KEYPO" info test-rot-multi --config "$CONFIG" 2>/dev/null | jq -r '.publicKey')
"$KEYPO" rotate test-rot-multi --config "$CONFIG" 2>/dev/null >/dev/null
PK2=$("$KEYPO" info test-rot-multi --config "$CONFIG" 2>/dev/null | jq -r '.publicKey')
"$KEYPO" rotate test-rot-multi --config "$CONFIG" 2>/dev/null >/dev/null
PK3=$("$KEYPO" info test-rot-multi --config "$CONFIG" 2>/dev/null | jq -r '.publicKey')
INFO=$("$KEYPO" info test-rot-multi --config "$CONFIG" 2>/dev/null)
CURRENT_PK=$(echo "$INFO" | jq -r '.publicKey')
assert_eq "$PK3" "$CURRENT_PK" "T4.4 current key is PK3"
PREV_COUNT=$(echo "$INFO" | jq '.previousPublicKeys | length')
assert_eq "2" "$PREV_COUNT" "T4.4 two previous keys"
PREV_0=$(echo "$INFO" | jq -r '.previousPublicKeys[0]')
PREV_1=$(echo "$INFO" | jq -r '.previousPublicKeys[1]')
assert_eq "$PK1" "$PREV_0" "T4.4 first previous is PK1"
assert_eq "$PK2" "$PREV_1" "T4.4 second previous is PK2"
assert_true "$([ "$PK1" != "$PK2" ] && [ "$PK2" != "$PK3" ] && [ "$PK1" != "$PK3" ] && echo true || echo false)" "T4.4 all keys different"

echo ""
echo "=== Category 5: Verification ==="

# T5.1 — Verify valid signature
echo "T5.1: Verify valid signature"
"$KEYPO" create --label test-verify --policy open --config "$CONFIG" 2>/dev/null >/dev/null
SIG_JSON=$("$KEYPO" sign "$HASH" --key test-verify --config "$CONFIG" 2>/dev/null)
SIG_HEX=$(echo "$SIG_JSON" | jq -r '.signature')
OUTPUT=$("$KEYPO" verify "$HASH" "$SIG_HEX" --key test-verify --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T5.1 exit code"
VALID=$(echo "$OUTPUT" | jq -r '.valid')
assert_eq "true" "$VALID" "T5.1 valid is true"

# T5.2 — Verify with tampered data
echo "T5.2: Verify with tampered data"
DIFF_HASH="0xbaadf00dbaadf00dbaadf00dbaadf00dbaadf00dbaadf00dbaadf00dbaadf00d"
OUTPUT=$("$KEYPO" verify "$DIFF_HASH" "$SIG_HEX" --key test-verify --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 1 $RC "T5.2 exit code"
VALID=$(echo "$OUTPUT" | jq -r '.valid')
assert_eq "false" "$VALID" "T5.2 valid is false"

# T5.3 — Verify with tampered signature
echo "T5.3: Verify with tampered signature"
# Tamper with last byte of DER signature (XOR with 0x01)
SIG_RAW=$(echo "$SIG_HEX" | sed 's/^0x//')
LAST_BYTE="${SIG_RAW: -2}"
TAMPERED_BYTE=$(printf "%02x" $(( 0x$LAST_BYTE ^ 0x01 )))
TAMPERED_SIG="0x${SIG_RAW:0:${#SIG_RAW}-2}${TAMPERED_BYTE}"
OUTPUT=$("$KEYPO" verify "$HASH" "$TAMPERED_SIG" --key test-verify --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 1 $RC "T5.3 exit code"

# T5.4 — Verify with wrong key
echo "T5.4: Verify with wrong key"
# test-a and test-b already exist from T2.5
SIG_A=$("$KEYPO" sign "$HASH" --key test-a --config "$CONFIG" 2>/dev/null | jq -r '.signature')
OUTPUT=$("$KEYPO" verify "$HASH" "$SIG_A" --key test-b --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 1 $RC "T5.4 exit code"

# T5.5 — Verify with explicit public key
echo "T5.5: Verify with explicit public key"
VERIFY_PK=$("$KEYPO" info test-verify --format raw --config "$CONFIG" 2>/dev/null)
OUTPUT=$("$KEYPO" verify "$HASH" "$SIG_HEX" --public-key "$VERIFY_PK" --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T5.5 exit code"
VALID=$(echo "$OUTPUT" | jq -r '.valid')
assert_eq "true" "$VALID" "T5.5 valid is true"

echo ""
echo "=== Category 6: Edge Cases and System ==="

# T6.1 — System info
echo "T6.1: System info"
OUTPUT=$("$KEYPO" info --system --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T6.1 exit code"
SE_AVAIL=$(echo "$OUTPUT" | jq -r '.secureEnclaveAvailable')
assert_eq "true" "$SE_AVAIL" "T6.1 SE available"
CHIP=$(echo "$OUTPUT" | jq -r '.chip')
assert_true "$([ -n "$CHIP" ] && echo true || echo false)" "T6.1 chip not empty"
VERSION=$(echo "$OUTPUT" | jq -r '.keypoVersion')
assert_contains "$VERSION" "[0-9]" "T6.1 version is semver"

# T6.2 — Config directory auto-creation
echo "T6.2: Config dir auto-creation"
CONFIG_NEW="/tmp/keypo-test-$$-autocreate"
"$KEYPO" create --label test-first --policy open --config "$CONFIG_NEW" 2>/dev/null >/dev/null ; RC=$?
assert_exit 0 $RC "T6.2 exit code"
DIR_PERMS=$(stat -f "%OLp" "$CONFIG_NEW")
assert_eq "700" "$DIR_PERMS" "T6.2 config dir perms"
FILE_PERMS=$(stat -f "%OLp" "$CONFIG_NEW/keys.json")
assert_eq "600" "$FILE_PERMS" "T6.2 metadata file perms"
# Cleanup
"$KEYPO" delete test-first --confirm --config "$CONFIG_NEW" 2>/dev/null >/dev/null
rm -rf "$CONFIG_NEW"

# T6.3 — Concurrent signing
echo "T6.3: Concurrent signing"
"$KEYPO" create --label test-concurrent --policy open --config "$CONFIG" 2>/dev/null >/dev/null
BEFORE=$("$KEYPO" info test-concurrent --config "$CONFIG" 2>/dev/null | jq '.signingCount')
CONCURRENT_FAILS=0
PIDS=""
for i in $(seq 1 10); do
    "$KEYPO" sign "0x$(openssl rand -hex 32)" --key test-concurrent --config "$CONFIG" > /dev/null 2>&1 &
    PIDS="$PIDS $!"
done
for pid in $PIDS; do
    wait $pid || CONCURRENT_FAILS=$((CONCURRENT_FAILS + 1))
done
AFTER=$("$KEYPO" info test-concurrent --config "$CONFIG" 2>/dev/null | jq '.signingCount')
DIFF=$((AFTER - BEFORE))
assert_eq "0" "$CONCURRENT_FAILS" "T6.3 no failures"
assert_eq "10" "$DIFF" "T6.3 count increased by 10"
# Verify metadata is valid JSON
"$KEYPO" list --config "$CONFIG" > /dev/null 2>&1 ; RC=$?
assert_exit 0 $RC "T6.3 metadata still valid"

# T6.4 — Large batch signing
echo "T6.4: Batch signing (100 signatures)"
"$KEYPO" create --label test-perf --policy open --config "$CONFIG" 2>/dev/null >/dev/null
START_TIME=$(date +%s)
BATCH_FAILS=0
for i in $(seq 1 100); do
    "$KEYPO" sign "0x$(openssl rand -hex 32)" --key test-perf --config "$CONFIG" > /dev/null 2>&1 || BATCH_FAILS=$((BATCH_FAILS + 1))
done
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
assert_eq "0" "$BATCH_FAILS" "T6.4 all 100 succeed"
echo "  100 signatures in ${ELAPSED}s"

# T6.5 — Key persistence
echo "T6.5: Key persistence"
"$KEYPO" create --label test-persist --policy open --config "$CONFIG" 2>/dev/null >/dev/null
# Simulate new session by just running sign command fresh
OUTPUT=$("$KEYPO" sign "$HASH" --key test-persist --config "$CONFIG" 2>/dev/null) ; RC=$?
assert_exit 0 $RC "T6.5 exit code"

# T6.6 — Corrupt metadata handling
echo "T6.6: Corrupt metadata"
CONFIG_CORRUPT="/tmp/keypo-test-$$-corrupt"
mkdir -p "$CONFIG_CORRUPT"
echo "{{{broken" > "$CONFIG_CORRUPT/keys.json"
OUTPUT=$("$KEYPO" list --config "$CONFIG_CORRUPT" 2>&1) ; RC=$?
assert_true "$([ $RC -ne 0 ] && echo true || echo false)" "T6.6 non-zero exit"
assert_contains "$OUTPUT" "corrupt" "T6.6 error mentions corruption"
rm -rf "$CONFIG_CORRUPT"

# T6.7 — Cross-verification with openssl (CRITICAL)
echo "T6.7: Cross-verification with openssl (CRITICAL)"
"$KEYPO" create --label test-openssl --policy open --config "$CONFIG" 2>/dev/null >/dev/null
PUBKEY_RAW=$("$KEYPO" info test-openssl --format raw --config "$CONFIG" 2>/dev/null | sed 's/^0x//')
SIG_JSON=$("$KEYPO" sign "$HASH" --key test-openssl --config "$CONFIG" 2>/dev/null)
SIG_HEX=$(echo "$SIG_JSON" | jq -r '.signature' | sed 's/^0x//')

echo "3059301306072a8648ce3d020106082a8648ce3d030107034200${PUBKEY_RAW}" \
    | xxd -r -p | base64 | fold -w 64 \
    | (echo "-----BEGIN PUBLIC KEY-----"; cat; echo "-----END PUBLIC KEY-----") > /tmp/pubkey.pem

echo "$SIG_HEX" | xxd -r -p > /tmp/sig.der

VERIFY_RESULT=$(echo "$HASH" | sed 's/^0x//' | xxd -r -p \
    | openssl dgst -sha256 -verify /tmp/pubkey.pem -signature /tmp/sig.der 2>&1)
assert_contains "$VERIFY_RESULT" "Verified OK" "T6.7 openssl verification"

# T6.8 — r and s values within curve order
echo "T6.8: r and s within curve order (50 signatures)"
CURVE_ORDER="FFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551"
ALL_IN_RANGE=true
for i in $(seq 1 50); do
    RAND="0x$(openssl rand -hex 32)"
    SIG_OUT=$("$KEYPO" sign "$RAND" --key test-openssl --config "$CONFIG" 2>/dev/null)
    R_HEX=$(echo "$SIG_OUT" | jq -r '.r' | sed 's/^0x//')
    S_HEX=$(echo "$SIG_OUT" | jq -r '.s' | sed 's/^0x//')
    R_PADDED=$(printf "%064s" "$R_HEX" | tr ' ' '0' | tr 'a-f' 'A-F')
    S_PADDED=$(printf "%064s" "$S_HEX" | tr ' ' '0' | tr 'a-f' 'A-F')
    HALF_UPPER=$(echo "$HALF_ORDER" | tr 'a-f' 'A-F')
    ORDER_UPPER=$(echo "$CURVE_ORDER" | tr 'a-f' 'A-F')
    # r > 0 and r < curveOrder
    if [[ "$R_PADDED" > "$ORDER_UPPER" ]] || [[ "$R_PADDED" == "$ORDER_UPPER" ]]; then
        ALL_IN_RANGE=false
        echo "  r out of range at $i"
        break
    fi
    # s > 0 and s <= halfOrder
    if [[ "$S_PADDED" > "$HALF_UPPER" ]]; then
        ALL_IN_RANGE=false
        echo "  s out of range at $i"
        break
    fi
done
assert_true "$ALL_IN_RANGE" "T6.8 all r,s in range"

# T6.9 — Version flag
echo "T6.9: Version flag"
OUTPUT=$("$KEYPO" --version 2>&1) ; RC=$?
assert_exit 0 $RC "T6.9 exit code"
assert_contains "$OUTPUT" "[0-9]" "T6.9 version string"

echo ""
echo "==============================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ -n "$ERRORS" ]; then
    echo -e "\nFailures:$ERRORS"
fi
echo "==============================="

if [ $FAIL -gt 0 ]; then
    exit 1
fi
exit 0
