// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.33;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OnchainShortfallReserveV1} from "./applications/shortfall/OnchainShortfallReserveV1.sol";
import {ProductionProRataAllocatorV1} from "./applications/pro-rata/ProductionProRataAllocatorV1.sol";
import {IPrfStatementAdmission} from "./interfaces/IPrfStatementAdmission.sol";

contract LocalSnapshotToken is IERC20 {
    string public constant name = "Local Snapshot Token";
    string public constant symbol = "LST";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(address recipient) { _mint(recipient, 1000); }
    function transfer(address to, uint256 amount) external returns (bool) { _move(msg.sender, to, amount); return true; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; emit Approval(msg.sender, spender, amount); return true; }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender]; require(a >= amount, "allowance"); allowance[from][msg.sender] = a - amount; _move(from, to, amount); return true;
    }
    function _mint(address to, uint256 amount) internal { balanceOf[to] += amount; totalSupply += amount; emit Transfer(address(0), to, amount); }
    function _move(address from, address to, uint256 amount) internal { require(balanceOf[from] >= amount, "balance"); balanceOf[from] -= amount; balanceOf[to] += amount; emit Transfer(from, to, amount); }
}

contract LocalShortfallSnapshot is Script {
    bytes32 internal constant OPERATION_ID = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
    bytes32 internal constant ORDINARY_ID = keccak256("local-ordinary-reservation");
    function run() external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(key);
        address authority = vm.addr(key);
        LocalSnapshotToken token = new LocalSnapshotToken(authority);
        OnchainShortfallReserveV1 reserve = new OnchainShortfallReserveV1(IERC20(address(token)), authority, 10, 1 days);
        ProductionProRataAllocatorV1 allocator = new ProductionProRataAllocatorV1(IPrfStatementAdmission(address(1)), address(reserve));
        reserve.bindAllocator(allocator);
        token.approve(address(reserve), 100);
        reserve.deposit(100);
        reserve.reserveForOtherObligation(ORDINARY_ID, 20);
        uint64 snapshotId = reserve.lockAvailableFor(OPERATION_ID);
        (bytes32 snapshotOperation, address snapshotAllocator, uint256 gross, uint256 reservedBefore,
            uint256 protectedAmount, uint256 available, uint256 createdAtBlock, bytes32 snapshotHash) =
            reserve.availabilitySnapshots(snapshotId);
        console2.log("CHAIN_ID", block.chainid);
        console2.log("TOKEN", address(token));
        console2.log("RESERVE", address(reserve));
        console2.log("ALLOCATOR", address(allocator));
        console2.log("SNAPSHOT_ID", snapshotId);
        console2.log("CREATED_AT_BLOCK", createdAtBlock);
        console2.log("GROSS", gross);
        console2.log("RESERVED_BEFORE", reservedBefore);
        console2.log("PROTECTED", protectedAmount);
        console2.log("AVAILABLE", available);
        console2.logBytes32(snapshotHash);
        snapshotOperation; snapshotAllocator;
        vm.stopBroadcast();
    }
}
