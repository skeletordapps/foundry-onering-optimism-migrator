// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {Test, console2} from "forge-std/Test.sol";
import {DeployMigratorScript} from "../script/DeployMigrator.sol";
import {Migrator} from "../src/Migrator.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MigratorTest is Test {
    DeployMigratorScript public deployer;
    Migrator public migrator;

    uint256 fork;
    string public rpcUrl;

    address public ring;
    address public ringV2;
    address public receiver;

    address internal bob;
    address internal alice;
    address internal john;

    uint256 oneEther = 1 ether;

    event migrated(uint256 amount);
    event feededRingV2(uint256 amount);
    event withdrawal(uint256 amount);

    function setUp() public {
        rpcUrl = vm.envString("OPTIMISM_RPC_URL");
        fork = vm.createFork(rpcUrl);
        vm.selectFork(fork);

        deployer = new DeployMigratorScript();
        (migrator, ring, ringV2, receiver) = deployer.run();

        bob = vm.addr(3);
        vm.label(bob, "bob");

        alice = vm.addr(5);
        vm.label(alice, "alice");

        john = vm.addr(6);
        vm.label(john, "john");
    }

    function test_Deployment() public view {
        assert(migrator.ring() != address(0));
        assert(migrator.ringV2() != address(0));
        assert(migrator.receiver() != address(0));
        assert(migrator.paused() == true);
    }

    modifier unpaused() {
        vm.startPrank(migrator.owner());
        migrator.unpause();
        vm.stopPrank();
        _;
    }

    function test__OnlyOnwerCanUnpause() public {
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.unpause();

        vm.startPrank(migrator.owner());
        migrator.unpause();
        vm.stopPrank();

        assertEq(migrator.paused(), false);
    }

    function test__OnlyOnwerCanPause() public unpaused {
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.pause();

        vm.startPrank(migrator.owner());
        migrator.pause();
        vm.stopPrank();

        assertEq(migrator.paused(), true);
    }

    function test__CannotFeedRingV2WithZeroAsAmount() public unpaused {
        vm.expectRevert(Migrator.Migrator__Amount_Cannot_Be_Zero.selector);
        migrator.feedRingV2(0);
    }

    function test__CannotFeedRingV2WithoutBalance() public unpaused {
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.feedRingV2(oneEther);
    }

    modifier dealFundsToActor(address actor, address token) {
        vm.startPrank(actor);
        ERC20(token).approve(address(migrator), oneEther);
        deal(token, actor, oneEther);
        vm.stopPrank();
        _;
    }

    function test__CanFeedRingV2() public unpaused dealFundsToActor(john, ringV2) {
        vm.startPrank(john);
        vm.expectEmit();
        emit feededRingV2(oneEther);
        migrator.feedRingV2(oneEther);
        vm.stopPrank();

        assertEq(ERC20(ringV2).balanceOf(address(migrator)), oneEther);
    }

    function test__RevertWithdrawWhenIsNotOwner() public {
        vm.startPrank(john);
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.withdraw();
        vm.stopPrank();
    }

    function test__RevertWithdrawWhenHasNoBalance() public {
        vm.startPrank(migrator.owner());
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.withdraw();
        vm.stopPrank();
    }

    function test__WithdrawRing() public {
        deal(ring, address(migrator), oneEther);
        assertEq(ERC20(ring).balanceOf(address(migrator)), oneEther);

        uint256 receiverBalanceBefore = ERC20(ring).balanceOf(receiver);

        vm.startPrank(migrator.owner());
        vm.expectEmit();
        emit withdrawal(oneEther);
        migrator.withdraw();
        vm.stopPrank();

        uint256 receiverBalanceAfter = ERC20(ring).balanceOf(receiver);

        assertEq(ERC20(ring).balanceOf(address(migrator)), 0);
        assertEq(receiverBalanceAfter - receiverBalanceBefore, oneEther);
    }

    function test__RevertsMigrationWhenPaused() public {
        vm.expectRevert("Pausable: paused");
        migrator.migrate(oneEther);
    }

    function test__RevertsMigrationWithZeroAmount() public unpaused {
        vm.expectRevert(Migrator.Migrator__Amount_Cannot_Be_Zero.selector);
        migrator.migrate(0);
    }

    function test__RevertsMigrationWhenBalanceIsLowerThanAmount() public unpaused {
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.migrate(oneEther);
    }

    function test__MigratesRingToRingV2() public unpaused dealFundsToActor(john, ring) {
        deal(ringV2, address(migrator), oneEther);

        uint256 balanceOfRingBefore = ERC20(ring).balanceOf(john);
        uint256 balanceOfRingV2Before = ERC20(ringV2).balanceOf(john);

        vm.startPrank(john);
        vm.expectEmit();
        emit migrated(oneEther);
        migrator.migrate(oneEther);
        vm.stopPrank();

        uint256 balanceOfRingAfter = ERC20(ring).balanceOf(john);
        uint256 balanceOfRingV2After = ERC20(ringV2).balanceOf(john);

        assertEq(balanceOfRingBefore, oneEther);
        assertEq(balanceOfRingV2Before, 0);

        assertEq(balanceOfRingAfter, 0);
        assertEq(balanceOfRingV2After, oneEther);
    }

    function test__RevertsMigratingAllWhenPaused() public {
        vm.expectRevert("Pausable: paused");
        migrator.migrateAll();
    }

    function test__RevertsMigratingllWhenHasNoBalance() public unpaused {
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.migrateAll();
    }

    function test__RevertsMigratingAllWhenUserBalanceIsHigherThanContractBalance()
        public
        unpaused
        dealFundsToActor(john, ring)
    {
        deal(ringV2, address(migrator), oneEther / 2);
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.migrateAll();
    }

    function test__MigratesAllRingFundsToRingV2() public unpaused dealFundsToActor(john, ring) {
        deal(ringV2, address(migrator), oneEther);

        uint256 balanceOfRingBefore = ERC20(ring).balanceOf(john);
        uint256 balanceOfRingV2Before = ERC20(ringV2).balanceOf(john);

        vm.startPrank(john);
        emit migrated(oneEther);
        migrator.migrateAll();
        vm.stopPrank();

        uint256 balanceOfRingAfter = ERC20(ring).balanceOf(john);
        uint256 balanceOfRingV2After = ERC20(ringV2).balanceOf(john);

        assertEq(balanceOfRingBefore, oneEther);
        assertEq(balanceOfRingV2Before, 0);

        assertEq(balanceOfRingAfter, 0);
        assertEq(balanceOfRingV2After, oneEther);
    }
}
