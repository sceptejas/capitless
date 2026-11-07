// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IStrategyPolicy} from "./interfaces/IStrategyPolicy.sol";

/// @title StrategyPolicy
/// @notice Central permission, configuration, and fee-policy store for CAPITLESS.
///         Each Maker registers a strategy here. The RFQExecutor, UniswapV4Adapter,
///         and CapitallessHook all read from this contract.
///
/// Access control:
///   DEFAULT_ADMIN_ROLE  – protocol deployer; emergency admin
///   CRE_CONSUMER_ROLE   – CREPolicyConsumer only; may call applyCREPolicyUpdate
///   Strategy ownership  – tracked per-strategy via strategies[id].maker
contract StrategyPolicy is IStrategyPolicy, AccessControl {
    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    bytes32 public constant CRE_CONSUMER_ROLE = keccak256("CRE_CONSUMER_ROLE");

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    /// @notice Core configuration per strategy
    mapping(bytes32 strategyId => StrategyConfig) private _strategies;

    /// @notice Ordered list of all registered strategy IDs (for enumeration)
    bytes32[] private _strategyIds;

    /// @notice Per-strategy authorised signers (D-3: mapping model, not single field)
    mapping(bytes32 strategyId => mapping(address signer => bool)) private _authorisedSigners;

    /// @notice Per-strategy approved tokenIn / tokenOut tokens
    mapping(bytes32 strategyId => mapping(address token => bool)) private _approvedTokens;

    /// @notice Per-strategy approved execution adapters
    mapping(bytes32 strategyId => mapping(address adapter => bool)) private _approvedAdapters;

    /// @notice Per-strategy approved pool keys (D-5: full PoolKey hash, not just token pair)
    mapping(bytes32 strategyId => mapping(bytes32 poolKeyHash => bool)) private _approvedPoolKeys;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyStrategyOwner(bytes32 strategyId) {
        if (_strategies[strategyId].maker != msg.sender) {
            revert NotStrategyOwner(strategyId, msg.sender);
        }
        _;
    }

    modifier strategyExists(bytes32 strategyId) {
        if (_strategies[strategyId].maker == address(0)) {
            revert StrategyNotFound(strategyId);
        }
        _;
    }

    // -------------------------------------------------------------------------
    // Strategy lifecycle
    // -------------------------------------------------------------------------

    /// @notice Register a new strategy. Caller becomes the strategy owner.
    function createStrategy(
        bytes32 strategyId,
        uint24 minDynamicFee,
        uint24 maxDynamicFee,
        uint256 maxOrderSize,
        uint256 maxSlippageBps
    ) external {
        if (_strategies[strategyId].maker != address(0)) {
            revert StrategyAlreadyExists(strategyId);
        }
        if (minDynamicFee > maxDynamicFee) revert InvalidFeeRange(minDynamicFee, maxDynamicFee);

        _strategies[strategyId] = StrategyConfig({
            maker: msg.sender,
            active: false,
            maxOrderSize: maxOrderSize,
            maxSlippageBps: maxSlippageBps,
            minDynamicFee: minDynamicFee,
            maxDynamicFee: maxDynamicFee,
            currentDynamicFee: minDynamicFee, // start at minimum
            policyVersion: 0,
            validUntil: 0
        });

        emit StrategyCreated(strategyId, msg.sender);
        _strategyIds.push(strategyId);
    }

    /// @notice Activate or deactivate a strategy.
    function setStrategyActive(bytes32 strategyId, bool active)
        external
        strategyExists(strategyId)
        onlyStrategyOwner(strategyId)
    {
        _strategies[strategyId].active = active;
        emit StrategyStatusChanged(strategyId, active);
    }

    // -------------------------------------------------------------------------
    // Signer management (D-3)
    // -------------------------------------------------------------------------

    /// @notice Grant or revoke an additional authorised signer for a strategy.
    ///         The strategy maker is always implicitly authorised.
    function setSigner(bytes32 strategyId, address signer, bool authorised)
        external
        strategyExists(strategyId)
        onlyStrategyOwner(strategyId)
    {
        if (signer == address(0)) revert ZeroAddress();
        _authorisedSigners[strategyId][signer] = authorised;
        emit SignerUpdated(strategyId, signer, authorised);
    }

    // -------------------------------------------------------------------------
    // Token / adapter / pool allowlists
    // -------------------------------------------------------------------------

    function setTokenApproval(bytes32 strategyId, address token, bool approved)
        external
        strategyExists(strategyId)
        onlyStrategyOwner(strategyId)
    {
        if (token == address(0)) revert ZeroAddress();
        _approvedTokens[strategyId][token] = approved;
        emit TokenApprovalUpdated(strategyId, token, approved);
    }

    function setAdapterApproval(bytes32 strategyId, address adapter, bool approved)
        external
        strategyExists(strategyId)
        onlyStrategyOwner(strategyId)
    {
        if (adapter == address(0)) revert ZeroAddress();
        _approvedAdapters[strategyId][adapter] = approved;
        emit AdapterApprovalUpdated(strategyId, adapter, approved);
    }

    /// @notice Approve or revoke a pool identified by its PoolKey hash.
    ///         poolKeyHash = keccak256(abi.encode(poolKey)) — full PoolKey, not just token pair.
    function setPoolApproval(bytes32 strategyId, bytes32 poolKeyHash, bool approved)
        external
        strategyExists(strategyId)
        onlyStrategyOwner(strategyId)
    {
        _approvedPoolKeys[strategyId][poolKeyHash] = approved;
        emit PoolApprovalUpdated(strategyId, poolKeyHash, approved);
    }

    // -------------------------------------------------------------------------
    // Execution limits
    // -------------------------------------------------------------------------

    function setExecutionLimits(bytes32 strategyId, uint256 maxOrderSize, uint256 maxSlippageBps)
        external
        strategyExists(strategyId)
        onlyStrategyOwner(strategyId)
    {
        _strategies[strategyId].maxOrderSize = maxOrderSize;
        _strategies[strategyId].maxSlippageBps = maxSlippageBps;
        emit ExecutionLimitsUpdated(strategyId, maxOrderSize, maxSlippageBps);
    }

    // -------------------------------------------------------------------------
    // Dynamic fee bounds
    // -------------------------------------------------------------------------

    function setFeeBounds(bytes32 strategyId, uint24 minFee, uint24 maxFee)
        external
        strategyExists(strategyId)
        onlyStrategyOwner(strategyId)
    {
        if (minFee > maxFee) revert InvalidFeeRange(minFee, maxFee);
        StrategyConfig storage cfg = _strategies[strategyId];
        cfg.minDynamicFee = minFee;
        cfg.maxDynamicFee = maxFee;
        // Clamp current fee into the new bounds
        if (cfg.currentDynamicFee < minFee) cfg.currentDynamicFee = minFee;
        if (cfg.currentDynamicFee > maxFee) cfg.currentDynamicFee = maxFee;
        emit FeeBoundsUpdated(strategyId, minFee, maxFee);
    }

    // -------------------------------------------------------------------------
    // CRE policy update (CRE_CONSUMER_ROLE only)
    // -------------------------------------------------------------------------

    /// @notice Apply a bounded fee update from the CRE consumer.
    ///         Only updates currentDynamicFee, policyVersion, validUntil.
    ///         Cannot modify maker, active, signers, tokens, adapters, or pools.
    function applyCREPolicyUpdate(
        bytes32 strategyId,
        uint24 newFee,
        uint64 policyVersion,
        uint64 validUntil
    ) external onlyRole(CRE_CONSUMER_ROLE) strategyExists(strategyId) {
        StrategyConfig storage cfg = _strategies[strategyId];

        if (newFee < cfg.minDynamicFee || newFee > cfg.maxDynamicFee) {
            revert FeeOutOfBounds(newFee, cfg.minDynamicFee, cfg.maxDynamicFee);
        }

        cfg.currentDynamicFee = newFee;
        cfg.policyVersion = policyVersion;
        cfg.validUntil = validUntil;

        emit CREPolicyApplied(strategyId, newFee, policyVersion, validUntil);
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getStrategy(bytes32 strategyId) external view returns (StrategyConfig memory) {
        return _strategies[strategyId];
    }

    /// @notice Returns true if signer is the strategy maker OR is in the authorised signer mapping.
    function isSignerAuthorised(bytes32 strategyId, address signer) external view returns (bool) {
        StrategyConfig storage cfg = _strategies[strategyId];
        return signer == cfg.maker || _authorisedSigners[strategyId][signer];
    }

    function isTokenApproved(bytes32 strategyId, address token) external view returns (bool) {
        return _approvedTokens[strategyId][token];
    }

    function isAdapterApproved(bytes32 strategyId, address adapter) external view returns (bool) {
        return _approvedAdapters[strategyId][adapter];
    }

    function isPoolKeyApproved(bytes32 strategyId, bytes32 poolKeyHash) external view returns (bool) {
        return _approvedPoolKeys[strategyId][poolKeyHash];
    }

    /// @notice Returns all registered strategy IDs in creation order.
    function getStrategyIds() external view returns (bytes32[] memory) {
        return _strategyIds;
    }

    /// @notice Returns the number of registered strategies.
    function strategyCount() external view returns (uint256) {
        return _strategyIds.length;
    }
}
