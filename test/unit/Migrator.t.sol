// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {console2, Test} from "forge-std/Test.sol";
import {DeployMigratorScript} from "../../script/DeployMigrator.sol";
import {Migrator} from "../../src/Migrator.sol";
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

    event migration(address indexed account, Migrator.UserMigration userMigration);
    event ringV2Deposit(address indexed account, uint256 amount);
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

    //////////////////////////////////////
    // PAUSABLE TESTS
    //////////////////////////////////////

    modifier unpaused() {
        vm.startPrank(migrator.owner());
        migrator.unpause();
        vm.stopPrank();
        _;
    }

    function test_OnlyOnwerCanUnpause() public {
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.unpause();

        vm.startPrank(migrator.owner());
        migrator.unpause();
        vm.stopPrank();

        assertEq(migrator.paused(), false);
    }

    function test_OnlyOnwerCanPause() public unpaused {
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.pause();

        vm.startPrank(migrator.owner());
        migrator.pause();
        vm.stopPrank();

        assertEq(migrator.paused(), true);
    }

    //////////////////////////////////////
    // FEED RING V2 TESTS
    //////////////////////////////////////

    function test_CannotFeedRingV2WithZeroAsAmount() public unpaused {
        vm.expectRevert(Migrator.Migrator__Amount_Cannot_Be_Zero.selector);
        migrator.feedRingV2(0);
    }

    function test_CannotFeedRingV2WithoutBalance() public unpaused {
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.feedRingV2(oneEther);
    }

    modifier dealFundsToActor(address actor, address token, uint256 amount) {
        vm.startPrank(actor);
        ERC20(token).approve(address(migrator), amount);
        deal(token, actor, amount);
        vm.stopPrank();
        _;
    }

    function test_CanFeedRingV2()
        public
        unpaused
        dealFundsToActor(john, ringV2, oneEther)
        dealFundsToActor(bob, ringV2, migrator.MAX_RING_PER_MIGRATION() * 2)
    {
        vm.startPrank(john);
        vm.expectEmit();
        emit ringV2Deposit(john, oneEther);
        migrator.feedRingV2(oneEther);
        vm.stopPrank();

        assertEq(ERC20(ringV2).balanceOf(address(migrator)), oneEther);

        uint256 bigAmount = migrator.MAX_RING_PER_MIGRATION() * 2;
        vm.startPrank(bob);
        migrator.feedRingV2(bigAmount);
        vm.stopPrank();

        assertEq(ERC20(ringV2).balanceOf(address(migrator)), bigAmount + oneEther);
    }

    //////////////////////////////////////
    // WITHDRAW RING V1 TESTS
    //////////////////////////////////////

    function test_RevertWithdrawWhenIsNotOwner() public {
        vm.startPrank(john);
        vm.expectRevert("Ownable: caller is not the owner");
        migrator.withdraw();
        vm.stopPrank();
    }

    function test_RevertWithdrawWhenHasNoBalance() public {
        vm.startPrank(migrator.owner());
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.withdraw();
        vm.stopPrank();
    }

    function test_WithdrawRing() public {
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

    //////////////////////////////////////
    // MIGRATION TESTS
    //////////////////////////////////////

    function test_RevertsMigrationWhenPaused() public {
        vm.expectRevert("Pausable: paused");
        migrator.migrate(oneEther);
    }

    function test_RevertsMigrationWithZeroAmount() public unpaused {
        vm.expectRevert(Migrator.Migrator__Amount_Cannot_Be_Zero.selector);
        migrator.migrate(0);
    }

    modifier contractHasRingV2(uint256 amount) {
        deal(ringV2, address(migrator), amount);
        _;
    }

    function test_RevertsMigrationWhenBalanceIsLowerThanAmount()
        public
        unpaused
        contractHasRingV2(migrator.MAX_RING_PER_MIGRATION())
    {
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.migrate(oneEther);
    }

    function test_RevertsWhenContractHasNoBalanceToMigrate() public unpaused dealFundsToActor(bob, ring, oneEther) {
        vm.startPrank(bob);
        vm.expectRevert(Migrator.Migrator__Insufficient_Ring_V2_Available.selector);
        migrator.migrate(oneEther);
        vm.stopPrank();
    }

    function test_RevertsMigrationWhenExceedsLimit()
        public
        unpaused
        contractHasRingV2(migrator.MAX_RING_PER_MIGRATION() * 2)
    {
        uint256 amount = migrator.MAX_RING_PER_MIGRATION() + oneEther;

        vm.expectRevert(Migrator.Migrator__Exceeds_Max_Migration_Limit.selector);
        migrator.migrate(amount);
    }

    modifier migrateLimit(address actor) {
        deal(ringV2, address(migrator), migrator.MAX_RING_PER_MIGRATION());
        uint256 amount = migrator.MAX_RING_PER_MIGRATION();
        vm.startPrank(actor);
        migrator.migrate(amount);
        vm.stopPrank();
        _;
    }

    function test_RevertsWhenAlreadyMigratedMaxLimit()
        public
        unpaused
        dealFundsToActor(bob, ring, migrator.MAX_RING_PER_MIGRATION() * 2)
        migrateLimit(bob)
    {
        vm.startPrank(bob);
        vm.expectRevert(Migrator.Migrator__Not_Allowed_For_One_Day.selector);
        migrator.migrate(oneEther);
        vm.stopPrank();
    }

    function test_MigratesRingToRingV2()
        public
        unpaused
        contractHasRingV2(oneEther)
        dealFundsToActor(john, ring, oneEther)
    {
        uint256 balanceOfRingBefore = ERC20(ring).balanceOf(john);
        uint256 balanceOfRingV2Before = ERC20(ringV2).balanceOf(john);

        Migrator.UserMigration memory userMigration = Migrator.UserMigration(oneEther, oneEther, block.timestamp);

        vm.startPrank(john);
        vm.expectEmit();
        emit migration(john, userMigration);
        migrator.migrate(oneEther);
        vm.stopPrank();

        uint256 balanceOfRingAfter = ERC20(ring).balanceOf(john);
        uint256 balanceOfRingV2After = ERC20(ringV2).balanceOf(john);

        assertEq(balanceOfRingBefore, oneEther);
        assertEq(balanceOfRingV2Before, 0);

        assertEq(balanceOfRingAfter, 0);
        assertEq(balanceOfRingV2After, oneEther);
    }

    function test_CanMigrateAgainWhenReachLimitAndWaitOneDay()
        public
        unpaused
        dealFundsToActor(bob, ring, migrator.MAX_RING_PER_MIGRATION() * 2)
        migrateLimit(bob)
        contractHasRingV2(oneEther)
    {
        vm.warp(block.timestamp + 1 days);

        Migrator.UserMigration memory userMigration =
            Migrator.UserMigration(migrator.MAX_RING_PER_MIGRATION() + oneEther, oneEther, block.timestamp);

        vm.startPrank(bob);
        vm.expectEmit();
        emit migration(bob, userMigration);
        migrator.migrate(oneEther);
        vm.stopPrank();
    }

    //////////////////////////////////////
    // MIGRATING ALL TESTS
    //////////////////////////////////////

    function test_RevertsMigratingAllWhenPaused() public {
        vm.expectRevert("Pausable: paused");
        migrator.migrateAll();
    }

    function test_RevertsMigratingllWhenHasNoBalance() public unpaused {
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.migrateAll();
    }

    function test_RevertsMigratingAllWhenUserBalanceIsHigherThanContractBalance()
        public
        unpaused
        contractHasRingV2(oneEther / 2)
        dealFundsToActor(john, ring, oneEther)
    {
        vm.startPrank(john);
        vm.expectRevert(Migrator.Migrator__Insufficient_Balance.selector);
        migrator.migrateAll();
        vm.stopPrank();
    }

    function test_MigratesAllRingFundsToRingV2()
        public
        unpaused
        contractHasRingV2(oneEther)
        dealFundsToActor(john, ring, oneEther)
    {
        uint256 balanceOfRingBefore = ERC20(ring).balanceOf(john);
        uint256 balanceOfRingV2Before = ERC20(ringV2).balanceOf(john);
        Migrator.UserMigration memory userMigration = Migrator.UserMigration(oneEther, oneEther, block.timestamp);

        vm.startPrank(john);
        emit migration(john, userMigration);
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
