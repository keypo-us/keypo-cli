// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Account} from "@openzeppelin/contracts/account/Account.sol";
import {SignerP256} from "@openzeppelin/contracts/utils/cryptography/signers/SignerP256.sol";
import {ERC7821} from "@openzeppelin/contracts/account/extensions/draft-ERC7821.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {WebAuthn} from "@openzeppelin/contracts/utils/cryptography/WebAuthn.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";
import {IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {AbstractSigner} from "@openzeppelin/contracts/utils/cryptography/signers/AbstractSigner.sol";

/// @title KeypoAccount — EIP-7702 delegation target for P-256 smart accounts
/// @notice Minimal smart account: P-256 signature validation (raw + WebAuthn)
///         via ERC-4337 UserOperations with ERC-7821 batch execution.
contract KeypoAccount is Account, SignerP256, ERC7821, Initializable {
    // Constructor uses P-256 generator point G = (GX, GY) as placeholder.
    // This corresponds to private key = 1. The implementation contract itself
    // should never be used directly — EOAs delegate via EIP-7702 and call
    // initialize() to set their real public key.
    constructor() SignerP256(bytes32(P256.GX), bytes32(P256.GY)) {
        _disableInitializers();
    }

    /// @notice Sets the P-256 public key for this account.
    /// @dev SECURITY: No access control. The EIP-7702 delegation and this call
    /// MUST be bundled in the same transaction to prevent frontrunning.
    /// The Phase 2 Rust wallet crate enforces atomic bundling.
    function initialize(bytes32 qx, bytes32 qy) public initializer {
        _setSigner(qx, qy);
    }

    /// @dev ENTRYPOINT_V08 compatible with eip7702
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return ERC4337Utils.ENTRYPOINT_V08;
    }

    /// @dev Validates signatures via two paths:
    /// - 64 bytes: raw P-256 (r, s) — used by keypo-signer
    /// - >64 bytes: WebAuthn assertion — used by browser passkeys
    /// WebAuthn UV (User Verification) is NOT required — device-level
    /// policy (Secure Enclave biometric/passcode) handles auth instead.
    function _rawSignatureValidation(
        bytes32 hash,
        bytes calldata signature
    ) internal view virtual override(AbstractSigner, SignerP256) returns (bool) {
        if (signature.length == 64) {
            return SignerP256._rawSignatureValidation(hash, signature);
        }
        if (signature.length > 64) {
            (bool success, WebAuthn.WebAuthnAuth calldata auth) = WebAuthn.tryDecodeAuth(signature);
            if (!success) return false;
            (bytes32 qx, bytes32 qy) = signer();
            return WebAuthn.verify(abi.encodePacked(hash), auth, qx, qy, false);
        }
        return false;
    }

    function _erc7821AuthorizedExecutor(
        address caller,
        bytes32 mode,
        bytes calldata executionData
    ) internal view virtual override returns (bool) {
        return caller == address(entryPoint())
            || super._erc7821AuthorizedExecutor(caller, mode, executionData);
    }
}
