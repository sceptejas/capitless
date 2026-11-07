// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IStrategyPolicy
/// @notice Interface for the CAPITLESS strategy permission and fee-policy store
interface IStrategyPolicy {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    struct StrategyConfig {
        address maker;          // Strategy owner; implicitly authorised signer
        bool active;            // Strategy is accepting orders
        uint256 maxOrderSize;   // Maximum quoteAmountIn per order (tokenIn units)
        uint256 maxSlippageBps; // Maximum slippage the strategy permits (basis points)
        uint24 minDynamicFee;   // Minimum LP fee (v4 units: hundredths of a bip)
        uint24 maxDynamicFee;   // Maximum LP fee
        uint24 currentDynamicFee; // Current fee; updated by CRE consumer
        uint64 policyVersion;   // Incremented on every CRE update
        uint64 validUntil;      // CRE-set expiry; hook reverts if exceeded
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event StrategyCreated(bytes32 indexed strategyId, address indexed maker);
    event StrategyStatusChanged(bytes32 indexed strategyId, bool active);
    event SignerUpdated(bytes32 indexed strategyId, address indexed signer, bool authorised);
    event TokenApprovalUpdated(bytes32 indexed strategyId, address indexed token, bool approved);
    event AdapterApprovalUpdated(bytes32 indexed strategyId, address indexed adapter, bool approved);
    event PoolApprovalUpdated(bytes32 indexed strategyId, bytes32 indexed poolKeyHash, bool approved);
    event ExecutionLimitsUpdated(bytes32 indexed strategyId, uint256 maxOrderSize, uint256 maxSlippageBps);
    event FeeBoundsUpdated(bytes32 indexed strategyId, uint24 minFee, uint24 maxFee);
    event CREPolicyApplied(bytes32 indexed strategyId, uint24 newFee, uint64 policyVersion, uint64 validUntil);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error StrategyAlreadyExists(bytes32 strategyId);
    error StrategyNotFound(bytes32 strategyId);
    error NotStrategyOwner(bytes32 strategyId, address caller);
    error FeeOutOfBounds(uint24 fee, uint24 min, uint24 max);
    error InvalidFeeRange(uint24 min, uint24 max);
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Functions
    // -------------------------------------------------------------------------

    function createStrategy(
        bytes32 strategyId,
        uint24 minDynamicFee,
        uint24 maxDynamicFee,
        uint256 maxOrderSize,
        uint256 maxSlippageBps
    ) external;

    function setStrategyActive(bytes32 strategyId, bool active) external;

    function setSigner(bytes32 strategyId, address signer, bool authorised) external;

    function setTokenApproval(bytes32 strategyId, address token, bool approved) external;

    function setAdapterApproval(bytes32 strategyId, address adapter, bool approved) external;

    function setPoolApproval(bytes32 strategyId, bytes32 poolKeyHash, bool approved) external;

    function setExecutionLimits(bytes32 strategyId, uint256 maxOrderSize, uint256 maxSlippageBps) external;

    function setFeeBounds(bytes32 strategyId, uint24 minFee, uint24 maxFee) external;

    function applyCREPolicyUpdate(
        bytes32 strategyId,
        uint24 newFee,
        uint64 policyVersion,
        uint64 validUntil
    ) external;

    function getStrategy(bytes32 strategyId) external view returns (StrategyConfig memory);

    function isSignerAuthorised(bytes32 strategyId, address signer) external view returns (bool);

    function isTokenApproved(bytes32 strategyId, address token) external view returns (bool);

    function isAdapterApproved(bytes32 strategyId, address adapter) external view returns (bool);

    function isPoolKeyApproved(bytes32 strategyId, bytes32 poolKeyHash) external view returns (bool);
}
