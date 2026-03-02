// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {KeypoAccount} from "../src/KeypoAccount.sol";
import {P256Helper} from "./helpers/P256Helper.sol";
import {P256} from "@openzeppelin/contracts/utils/cryptography/P256.sol";

contract KeypoAccountSetupTest is P256Helper {
    KeypoAccount internal impl;

    // EOA private keys for EIP-7702 delegation
    uint256 internal constant EOA_PK_1 = 0xA11CE;
    uint256 internal constant EOA_PK_2 = 0xB0B;

    function setUp() public {
        _deriveP256Keys();
        impl = new KeypoAccount();
    }

    function test_delegation_codePrefix() public {
        address payable eoa = payable(vm.addr(EOA_PK_1));
        vm.signAndAttachDelegation(address(impl), EOA_PK_1);
        bytes memory code = eoa.code;
        assertTrue(code.length >= 23, "delegation code too short");
        assertEq(uint8(code[0]), 0xef);
        assertEq(uint8(code[1]), 0x01);
        assertEq(uint8(code[2]), 0x00);
        address delegatee;
        assembly {
            delegatee := mload(add(code, 23))
        }
        assertEq(delegatee, address(impl));
    }

    function test_delegation_initialize() public {
        address payable eoa = payable(vm.addr(EOA_PK_1));
        vm.signAndAttachDelegation(address(impl), EOA_PK_1);
        KeypoAccount(eoa).initialize(qx1, qy1);
        (bytes32 qx, bytes32 qy) = KeypoAccount(eoa).signer();
        assertEq(qx, qx1);
        assertEq(qy, qy1);
    }

    function test_delegation_storageIsolation() public {
        address payable eoa1 = payable(vm.addr(EOA_PK_1));
        address payable eoa2 = payable(vm.addr(EOA_PK_2));
        vm.signAndAttachDelegation(address(impl), EOA_PK_1);
        vm.signAndAttachDelegation(address(impl), EOA_PK_2);
        KeypoAccount(eoa1).initialize(qx1, qy1);
        KeypoAccount(eoa2).initialize(qx2, qy2);
        (bytes32 qx_a, bytes32 qy_a) = KeypoAccount(eoa1).signer();
        (bytes32 qx_b, bytes32 qy_b) = KeypoAccount(eoa2).signer();
        assertEq(qx_a, qx1);
        assertEq(qy_a, qy1);
        assertEq(qx_b, qx2);
        assertEq(qy_b, qy2);
        assertTrue(qx_a != qx_b || qy_a != qy_b, "keys should differ");
    }

    function test_delegation_uninitializedRejectsSignature() public {
        address payable eoa = payable(vm.addr(EOA_PK_1));
        vm.signAndAttachDelegation(address(impl), EOA_PK_1);
        // Don't initialize — signer storage is (0, 0) for this EOA
        (bytes32 qx, bytes32 qy) = KeypoAccount(eoa).signer();
        assertEq(qx, bytes32(0));
        assertEq(qy, bytes32(0));
        // (0, 0) is not on the P-256 curve, so P256.verify always returns false
        bytes32 hash = keccak256("test");
        (bytes32 r, bytes32 s) = vm.signP256(PK1, hash);
        assertFalse(P256.verify(hash, r, s, bytes32(0), bytes32(0)));
    }
}
