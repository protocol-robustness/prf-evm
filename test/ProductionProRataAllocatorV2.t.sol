// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProductionProRataAllocatorV2} from "../src/applications/pro-rata/ProductionProRataAllocatorV2.sol";
import {MockEntitlementProofModeSource} from "./mocks/MockEntitlementProofModeSource.sol";
import {IShortfallAllocatorV2} from "../src/interfaces/IShortfallAllocatorV2.sol";

contract ProductionV2AllocatorToken is ERC20 {
    constructor() ERC20("Allocator V2", "AV2") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ProductionProRataAllocatorV2Test is Test {
    ProductionV2AllocatorToken token;
    ProductionProRataAllocatorV2 allocator;
    address authority = address(0xA11CE);
    address reserve = address(0xBEEF);
    bytes32 constant OPERATION = keccak256("allocator-v2-operation");
    bytes32 constant ALLOCATION = keccak256("allocator-v2-allocation");
    bytes32 constant REALIZED = keccak256("allocator-v2-realized");

    function setUp() public {
        token = new ProductionV2AllocatorToken();
        allocator = new ProductionProRataAllocatorV2(authority, new MockEntitlementProofModeSource());
    }

    function test_BindsReserveOnceAndFundsExactOperation() public {
        vm.prank(authority);
        allocator.bindFundingAuthority(reserve);
        assertTrue(allocator.fundingAuthorityBound());
        assertEq(allocator.fundingAuthority(), reserve);

        vm.prank(reserve);
        allocator.create(OPERATION, ALLOCATION, REALIZED, token, 70, address(0x2222));
        token.mint(reserve, 70);
        vm.prank(reserve);
        token.approve(address(allocator), 70);
        vm.prank(reserve);
        allocator.fund(OPERATION);

        IShortfallAllocatorV2.Operation memory operation = allocator.operation(OPERATION);
        assertEq(uint8(operation.state), uint8(IShortfallAllocatorV2.State.Funded));
        assertEq(operation.amount, 70);
        assertEq(token.balanceOf(address(allocator)), 70);
        assertEq(token.allowance(reserve, address(allocator)), 0);
    }

    function test_WrongAuthorityAndRebindingAreRejected() public {
        vm.prank(address(0xCAFE));
        vm.expectRevert();
        allocator.bindFundingAuthority(reserve);

        vm.prank(authority);
        allocator.bindFundingAuthority(reserve);
        vm.prank(authority);
        vm.expectRevert();
        allocator.bindFundingAuthority(address(0xCAFE));

        vm.prank(address(0xCAFE));
        vm.expectRevert();
        allocator.create(OPERATION, ALLOCATION, REALIZED, token, 70, address(0x2222));
    }

    function test_DuplicateCreateAndFundAreRejected() public {
        vm.prank(authority);
        allocator.bindFundingAuthority(reserve);
        vm.prank(reserve);
        allocator.create(OPERATION, ALLOCATION, REALIZED, token, 70, address(0x2222));
        vm.prank(reserve);
        vm.expectRevert();
        allocator.create(OPERATION, ALLOCATION, REALIZED, token, 70, address(0x2222));

        vm.prank(reserve);
        token.mint(reserve, 70);
        vm.prank(reserve);
        token.approve(address(allocator), 70);
        vm.prank(reserve);
        allocator.fund(OPERATION);
        vm.prank(reserve);
        vm.expectRevert();
        allocator.fund(OPERATION);
    }
}
