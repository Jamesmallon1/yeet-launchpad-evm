// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CurveMath} from "./libraries/CurveMath.sol";

/// @title YeetToken
/// @notice Plain ERC-20 (fixed 1B supply, no owner, no mint, no pause) with a USDC dividend ledger.
///         Dividends arrive in native USDC via `notifyDividend` from the launchpad (curve trades) and the
///         Uniswap v4 hook (pool trades) and accrue pro-rata to every non-excluded holder. Holders `claim()`.
/// @dev Synthetix-style accumulator: O(1) per transfer, no loops over holders, no rebasing.
contract YeetToken is ERC20, ERC20Permit, ReentrancyGuard {
    uint256 private constant MAGNITUDE = 2 ** 128;

    uint16 public immutable taxBps; // 0, 100 or 300
    uint16 public immutable burnShareBps; // share of every dividend used to buy this token back and burn it (0..10000)
    address public immutable launchpad;
    address public immutable hook;
    string public metadataURI;

    mapping(address => bool) public isExcluded;
    uint256 public eligibleSupply; // totalSupply - balances of excluded addresses
    uint256 public dividendPerShare; // MAGNITUDE-scaled
    uint256 public undistributed; // dividends received while eligibleSupply == 0
    uint256 public totalDividends;
    uint256 public totalClaimed;

    mapping(address => uint256) private _paidPerShare;
    mapping(address => uint256) private _owed;

    event DividendNotified(address indexed from, uint256 amount, uint256 dividendPerShare);
    event DividendClaimed(address indexed holder, uint256 amount);

    error NotDistributor();
    error NothingToClaim();
    error TransferFailed();
    error InvalidTax();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory metadataURI_,
        uint16 taxBps_,
        uint16 burnShareBps_,
        address launchpad_,
        address hook_,
        address[] memory excluded_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (!(taxBps_ == 0 || taxBps_ == 100 || taxBps_ == 300)) revert InvalidTax();
        if (burnShareBps_ > 10_000) revert InvalidTax();
        taxBps = taxBps_;
        burnShareBps = burnShareBps_;
        launchpad = launchpad_;
        hook = hook_;
        metadataURI = metadataURI_;

        isExcluded[launchpad_] = true;
        isExcluded[hook_] = true;
        isExcluded[address(this)] = true;
        isExcluded[0x000000000000000000000000000000000000dEaD] = true;
        for (uint256 i; i < excluded_.length; ++i) {
            isExcluded[excluded_[i]] = true;
        }

        _mint(launchpad_, CurveMath.SUPPLY); // launchpad is excluded, eligibleSupply stays 0
    }

    // ---------------------------------------------------------------- dividends

    /// @notice Deposit native USDC to be shared pro-rata by all eligible holders.
    function notifyDividend() external payable {
        if (msg.sender != launchpad && msg.sender != hook) revert NotDistributor();
        if (msg.value == 0) return;
        totalDividends += msg.value;
        uint256 amount = msg.value + undistributed;
        if (eligibleSupply == 0) {
            undistributed = amount;
        } else {
            undistributed = 0;
            dividendPerShare += amount * MAGNITUDE / eligibleSupply;
        }
        emit DividendNotified(msg.sender, msg.value, dividendPerShare);
    }

    /// @notice USDC currently claimable by `account`.
    function claimable(address account) public view returns (uint256) {
        if (isExcluded[account]) return _owed[account];
        return _owed[account] + balanceOf(account) * (dividendPerShare - _paidPerShare[account]) / MAGNITUDE;
    }

    /// @notice Send all accrued USDC to the caller.
    function claim() external nonReentrant returns (uint256 amount) {
        _settle(msg.sender);
        amount = _owed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        _owed[msg.sender] = 0;
        totalClaimed += amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit DividendClaimed(msg.sender, amount);
    }

    function _settle(address account) internal {
        if (isExcluded[account]) return;
        uint256 dps = dividendPerShare;
        uint256 paid = _paidPerShare[account];
        if (dps != paid) {
            _owed[account] += balanceOf(account) * (dps - paid) / MAGNITUDE;
            _paidPerShare[account] = dps;
        }
    }

    // ---------------------------------------------------------------- ERC20 hook

    function _update(address from, address to, uint256 value) internal override {
        if (taxBps == 0) {
            super._update(from, to, value);
            return;
        }
        bool fromEx = from == address(0) || isExcluded[from];
        bool toEx = to == address(0) || isExcluded[to];
        if (!fromEx) _settle(from);
        if (!toEx) _settle(to);
        super._update(from, to, value);
        if (fromEx && !toEx) eligibleSupply += value;
        else if (!fromEx && toEx) eligibleSupply -= value;
    }
}
