// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.21;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * ██████╗ ██╗███╗   ██╗ ██████╗     ███╗   ███╗██╗ ██████╗ ██████╗  █████╗ ████████╗ ██████╗ ██████╗
 * ██╔══██╗██║████╗  ██║██╔════╝     ████╗ ████║██║██╔════╝ ██╔══██╗██╔══██╗╚══██╔══╝██╔═══██╗██╔══██╗
 * ██████╔╝██║██╔██╗ ██║██║  ███╗    ██╔████╔██║██║██║  ███╗██████╔╝███████║   ██║   ██║   ██║██████╔╝
 * ██╔══██╗██║██║╚██╗██║██║   ██║    ██║╚██╔╝██║██║██║   ██║██╔══██╗██╔══██║   ██║   ██║   ██║██╔══██╗
 * ██║  ██║██║██║ ╚████║╚██████╔╝    ██║ ╚═╝ ██║██║╚██████╔╝██║  ██║██║  ██║   ██║   ╚██████╔╝██║  ██║
 * ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝     ╚═╝     ╚═╝╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝   ╚═╝    ╚═════╝ ╚═╝  ╚═╝
 *
 *     __            _____   _                _
 *    /  \   __ __  |_   _| | |_      ___    | |
 *   | () |  \ \ /    | |   | ' \    / -_)   | |__
 *   _\__/   /_\_\   _|_|_  |_||_|   \___|   |____|
 * _|"""""|_|"""""|_|"""""|_|"""""|_|"""""|_|"""""|
 * "`-0-0-'"`-0-0-'"`-0-0-'"`-0-0-'"`-0-0-'"`-0-0-'                                                                                                                                                                                 |___/
 *
 * @title Ring Migrator Contract
 * @author 0xTheL
 * @notice This contract allows users to migrate Ring v1 to the new Ring v2.
 */

contract Migrator is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_RING_PER_MIGRATION = 1000000 ether;

    address public immutable ring;
    address public immutable ringV2;
    address public immutable receiver;

    struct UserMigration {
        uint256 totalMigrated;
        uint256 lastMigrationAmount;
        uint256 lastTimestamp;
    }

    mapping(address userAddress => UserMigration userMigration) migrations;

    error Migrator__Insufficient_Balance();
    error Migrator__Invalid_Token_Address();
    error Migrator__Amount_Cannot_Be_Zero();
    error Migrator__Exceeds_Max_Migration_Limit();
    error Migrator__Not_Allowed_For_One_Day();

    event migrated(address indexed account, uint256 amount);
    event feededRingV2(address indexed account, uint256 amount);
    event withdrawal(uint256 amount);

    constructor(address _ring, address _ringV2, address _receiver) {
        ring = _ring;
        ringV2 = _ringV2;
        receiver = _receiver;

        _pause();
    }

    modifier canMigrate() {
        UserMigration memory userMigration = migrations[msg.sender];
        if (
            userMigration.lastMigrationAmount == MAX_RING_PER_MIGRATION
                && block.timestamp - userMigration.lastTimestamp < 1 days
        ) revert Migrator__Not_Allowed_For_One_Day();
        _;
    }

    modifier senderHasBalance(address token, uint256 amount) {
        if (token != ring && token != ringV2) revert Migrator__Invalid_Token_Address();
        if (amount == 0) revert Migrator__Amount_Cannot_Be_Zero();
        if (amount > MAX_RING_PER_MIGRATION) revert Migrator__Exceeds_Max_Migration_Limit();

        uint256 userBalance = ERC20(token).balanceOf(msg.sender);
        if (userBalance < amount) revert Migrator__Insufficient_Balance();
        _;
    }

    modifier contractHasBalance(uint256 amount) {
        if (ERC20(ringV2).balanceOf(address(this)) < amount) revert Migrator__Insufficient_Balance();
        _;
    }

    //////////////////////////////////////
    // EXTERNAL FUNCTIONS
    //////////////////////////////////////

    /**
     * @dev Migrates all RING tokens owned by the caller to RING V2 tokens.
     *
     * Requirements:
     * - The contract must not be paused.
     * - The caller must have a sufficient balance of RING tokens.
     *
     * Emits a {migrated} event.
     */
    function migrateAll() external whenNotPaused canMigrate nonReentrant {
        uint256 userBalance = ERC20(ring).balanceOf(msg.sender);
        if (userBalance == 0) revert Migrator__Insufficient_Balance();

        uint256 balance = ERC20(ringV2).balanceOf(address(this));
        if (userBalance > balance) revert Migrator__Insufficient_Balance();

        _migrate(userBalance);
    }

    /**
     * @dev Feeds RING V2 tokens to the contract.
     *
     * Requirements:
     * - The caller must have a sufficient balance of RING V2 tokens.
     *
     * Emits a {feededRingV2} event.
     */
    function feedRingV2(uint256 amount) external senderHasBalance(ringV2, amount) {
        IERC20(ringV2).safeTransferFrom(msg.sender, address(this), amount);
        emit feededRingV2(msg.sender, amount);
    }

    /**
     * @dev Withdraws RING tokens from the contract.
     *
     * Requirements:
     * - The caller must be the owner of the contract.
     * - The contract must have a sufficient balance of RING tokens.
     *
     * Emits a {withdrawal} event.
     */
    function withdraw() external onlyOwner nonReentrant {
        uint256 balance = ERC20(ring).balanceOf(address(this));
        if (balance == 0) revert Migrator__Insufficient_Balance();

        IERC20(ring).safeTransfer(receiver, balance);

        emit withdrawal(balance);
    }

    /**
     * @dev Pauses the contract.
     *
     * Requirements:
     * - The caller must be the owner of the contract.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses the contract.
     *
     * Requirements:
     * - The caller must be the owner of the contract.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    //////////////////////////////////////
    // PUBLIC FUNCTIONS
    //////////////////////////////////////

    /**
     * @notice Migrates the specified amount of RING tokens owned by the caller to RING V2 tokens.
     * @param amount: amount of ring to be migrated
     * Requirements:
     * The contract must not be paused.
     * The caller must have a sufficient balance of RING tokens.
     * The amount of RING tokens to migrate must be greater than zero.
     * Emits a {migrated} event.
     */

    function migrate(uint256 amount)
        public
        whenNotPaused
        canMigrate
        contractHasBalance(amount)
        senderHasBalance(ring, amount)
        nonReentrant
    {
        _migrate(amount);
    }

    //////////////////////////////////////
    // INTERNAL FUNCTIONS
    //////////////////////////////////////

    /**
     * @dev Internal function that migrates the specified amount of RING tokens from the caller to RING V2 tokens.
     * @param amount: amount of ring to be migrated
     * Requirements:
     * The amount of RING tokens to migrate must be greater than zero.
     * Emits a {migrated} event.
     */
    function _migrate(uint256 amount) internal {
        IERC20(ring).safeTransferFrom(msg.sender, address(this), amount);

        UserMigration memory migration = migrations[msg.sender];
        migration.totalMigrated += amount;
        migration.lastMigrationAmount = amount;
        migration.lastTimestamp = block.timestamp;
        migrations[msg.sender] = migration;

        emit migrated(msg.sender, amount);

        IERC20(ringV2).safeTransfer(msg.sender, amount);
    }
}
