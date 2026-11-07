// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ICREPolicyConsumer} from "./interfaces/ICREPolicyConsumer.sol";
import {IStrategyPolicy} from "./interfaces/IStrategyPolicy.sol";

/// @title IReceiver
/// @notice Minimal Chainlink CRE IReceiver interface.
///         The KeystoneForwarder calls onReport(metadata, report) after signature verification.
interface IReceiver is IERC165 {
    function onReport(bytes calldata metadata, bytes calldata report) external;
}

/// @title CREPolicyConsumer
/// @notice Receives authenticated CRE workflow reports and applies bounded
///         dynamic-fee updates to StrategyPolicy.
///
/// Security model:
///   - Only the configured KeystoneForwarder can call onReport (msg.sender check).
///   - For simulation: use MockKeystoneForwarder 0x82300bd7c3958625581cc2f77bc6464dcecdf3e5
///   - For production: use production forwarder 0xF8344CFd5c43616a4366C34E3EEE75af79a74482
///   - The forwarder is set at construction and cannot be address(0).
///   - policyVersion must strictly increase (replay protection).
///   - validUntil in the report must be in the future.
///   - proposedFee is bounded onchain by StrategyPolicy (not trusted from the report).
///
/// What CRE can change:  currentDynamicFee, policyVersion, validUntil
/// What CRE cannot change: maker, active, signers, tokens, adapters, pools
contract CREPolicyConsumer is IReceiver, ICREPolicyConsumer, Ownable {
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant SCHEMA_VERSION = 1;

    /// @notice Maximum acceptable age of the observedAt timestamp (1 hour).
    ///         Prevents very stale off-chain data from being written onchain.
    uint64 public constant MAX_DATA_AGE = 1 hours;

    // -------------------------------------------------------------------------
    // Immutables
    // -------------------------------------------------------------------------

    /// @notice The KeystoneForwarder whose calls we accept.
    ///         Immutable — set once at construction, never address(0).
    address public immutable keystoneForwarder;

    IStrategyPolicy public immutable strategyPolicy;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(address _keystoneForwarder, address _strategyPolicy)
        Ownable(msg.sender)
    {
        require(_keystoneForwarder != address(0), "CRE: zero forwarder");
        require(_strategyPolicy    != address(0), "CRE: zero policy");
        keystoneForwarder = _keystoneForwarder;
        strategyPolicy    = IStrategyPolicy(_strategyPolicy);
    }

    // -------------------------------------------------------------------------
    // IReceiver
    // -------------------------------------------------------------------------

    /// @notice Called by KeystoneForwarder after DON signature verification.
    ///         `metadata` carries workflow identity fields (not used for fee policy logic).
    ///         `report`   carries the ABI-encoded PolicyReport.
    function onReport(bytes calldata metadata, bytes calldata report) external override {
        // Authenticate: only the configured forwarder
        require(msg.sender == keystoneForwarder, "CRE: unauthorized forwarder");

        // Suppress unused variable warning — metadata not needed for our logic
        // (workflow identity validation can be added post-hackathon via setExpectedWorkflowId)
        metadata;

        _processReport(report);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    function _processReport(bytes calldata report) internal {
        // Decode PolicyReport — field order must match TypeScript encodeAbiParameters exactly
        PolicyReport memory pr = abi.decode(report, (PolicyReport));

        // 1. Schema version check
        if (pr.schemaVersion != SCHEMA_VERSION) {
            revert UnknownSchemaVersion(pr.schemaVersion, SCHEMA_VERSION);
        }

        // 2. Report must not have expired
        if (block.timestamp > pr.validUntil) {
            revert ReportExpired(pr.validUntil, block.timestamp);
        }

        // 3. Data freshness — observedAt must not be too stale
        if (block.timestamp > pr.observedAt + MAX_DATA_AGE) {
            revert StaleReport(pr.observedAt, MAX_DATA_AGE);
        }

        // 4. Strategy must exist (getStrategy returns zero maker for unknown IDs)
        IStrategyPolicy.StrategyConfig memory cfg = strategyPolicy.getStrategy(pr.strategyId);
        if (cfg.maker == address(0)) {
            revert StrategyNotFound(pr.strategyId);
        }

        // 5. Replay protection — policyVersion must strictly increase
        if (pr.policyVersion <= cfg.policyVersion) {
            revert ReplayDetected(pr.policyVersion, cfg.policyVersion);
        }

        // 6. Apply the update — StrategyPolicy enforces fee bounds internally
        strategyPolicy.applyCREPolicyUpdate(
            pr.strategyId,
            pr.proposedFee,
            pr.policyVersion,
            pr.validUntil
        );

        emit PolicyUpdated(pr.strategyId, pr.proposedFee, pr.policyVersion, pr.validUntil);
    }

    // -------------------------------------------------------------------------
    // ERC165
    // -------------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IReceiver).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }
}
