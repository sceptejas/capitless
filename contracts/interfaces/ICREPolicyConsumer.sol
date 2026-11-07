// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ICREPolicyConsumer
/// @notice External interface for the CAPITLESS CRE Policy Consumer.
interface ICREPolicyConsumer {
    // -------------------------------------------------------------------------
    // Structs
    // -------------------------------------------------------------------------

    /// @notice ABI-encoded payload written by the CRE TypeScript workflow.
    ///         Field order and types must match the TypeScript encodeAbiParameters call exactly.
    struct PolicyReport {
        uint256 schemaVersion;    // Must equal SCHEMA_VERSION (currently 1)
        bytes32 strategyId;       // Must be a registered strategy in StrategyPolicy
        uint24  proposedFee;      // Must be within [minDynamicFee, maxDynamicFee]
        uint64  observedAt;       // Unix timestamp of data observation; staleness check
        uint64  validUntil;       // Report expiry; consumer reverts if block.timestamp > validUntil
        uint64  policyVersion;    // Must be strictly greater than current policyVersion (replay protection)
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event PolicyUpdated(
        bytes32 indexed strategyId,
        uint24  newFee,
        uint64  policyVersion,
        uint64  validUntil
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error UnknownSchemaVersion(uint256 received, uint256 expected);
    error ReportExpired(uint64 validUntil, uint256 blockTimestamp);
    error StaleReport(uint64 observedAt, uint256 maxAge);
    error ReplayDetected(uint64 receivedVersion, uint64 currentVersion);
    error StrategyNotFound(bytes32 strategyId);
}
