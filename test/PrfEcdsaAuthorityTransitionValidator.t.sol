// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IPrfAuthorityTransitionValidator} from "../src/interfaces/IPrfAuthorityTransitionValidator.sol";
import {PrfEcdsaAuthorityTransitionValidator} from "../src/core/PrfEcdsaAuthorityTransitionValidator.sol";

contract PrfEcdsaAuthorityTransitionValidatorTest is Test {
    bytes32 private constant POLICY_ROOT = keccak256("local-authority-policy-v3");
    uint256 private constant VALIDATOR_KEY = 0xA11CE;
    address private validatorAddress;
    PrfEcdsaAuthorityTransitionValidator private validator;

    function setUp() public {
        validatorAddress = vm.addr(VALIDATOR_KEY);
        validator = new PrfEcdsaAuthorityTransitionValidator(POLICY_ROOT, validatorAddress);
    }

    function _signature(uint256 key, bytes32 commitment) private returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(commitment);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function testPolicyRootAndConfiguredKeyAreImmutableAndBound() public view {
        assertEq(validator.localAuthorityPolicyRoot(), POLICY_ROOT);
        assertEq(validator.transitionValidatorAddress(), validatorAddress);
        assertTrue(IPrfAuthorityTransitionValidator(address(validator)).localAuthorityPolicyRoot() == POLICY_ROOT);
    }

    function testAcceptsOnlySignatureFromPolicyPinnedValidator() public {
        bytes32 commitment = keccak256("validated authority transition execution commitment");
        assertTrue(validator.isValidTransition(commitment, _signature(VALIDATOR_KEY, commitment)));
        assertFalse(validator.isValidTransition(commitment, _signature(VALIDATOR_KEY + 1, commitment)));
        assertFalse(validator.isValidTransition(bytes32(uint256(commitment) ^ 1), _signature(VALIDATOR_KEY, commitment)));
        assertFalse(validator.isValidTransition(commitment, hex"010203"));
    }

    function testPinnedPrfEip191Fixture() public {
        bytes32 commitment = 0x0d31ec18d0dfe6638c889024bab69d5dfa4412cbc3e489352d7d35601530ec2e;
        bytes memory signature = hex"9aca4cdffbbf9a41e73080a605a05b40457121c91193955b0ded23863592684e20ea1ce247c3bea3d90abdd279dcfa0bdd1d5bf7d59f28b610d13763aafb5ef41b";
        PrfEcdsaAuthorityTransitionValidator fixtureValidator = new PrfEcdsaAuthorityTransitionValidator(
            0x0ed7744a299c20e55cbc55bd30020bc44f6e521932c829df9fed647bb38258f1,
            0xe05fcC23807536bEe418f142D19fa0d21BB0cfF7
        );
        assertTrue(fixtureValidator.isValidTransition(commitment, signature));
    }

    function testRejectsZeroConstructorBindings() public {
        vm.expectRevert(PrfEcdsaAuthorityTransitionValidator.ZeroPolicyRoot.selector);
        new PrfEcdsaAuthorityTransitionValidator(bytes32(0), validatorAddress);
        vm.expectRevert(PrfEcdsaAuthorityTransitionValidator.ZeroValidatorAddress.selector);
        new PrfEcdsaAuthorityTransitionValidator(POLICY_ROOT, address(0));
    }
}
