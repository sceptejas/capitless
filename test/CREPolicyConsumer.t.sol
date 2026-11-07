// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CREPolicyConsumer} from "../contracts/CREPolicyConsumer.sol";
import {ICREPolicyConsumer} from "../contracts/interfaces/ICREPolicyConsumer.sol";
import {StrategyPolicy} from "../contracts/StrategyPolicy.sol";
import {IStrategyPolicy} from "../contracts/interfaces/IStrategyPolicy.sol";

contract CREPolicyConsumerTest is Test {
    CREPolicyConsumer internal consumer;
    StrategyPolicy    internal policy;

    address internal admin     = makeAddr("admin");
    address internal maker     = makeAddr("maker");
    address internal stranger  = makeAddr("stranger");
    address internal mockForwarder = address(0x82300bd7c3958625581cc2F77bC6464dcEcDF3e5);

    bytes32 internal constant STRATEGY_A = keccak256("STRATEGY_A");

    uint24 internal constant MIN_FEE  = 500;
    uint24 internal constant MAX_FEE  = 10_000;

    function setUp() public {
        // Warp to a realistic timestamp so block.timestamp - hours doesn't underflow
        vm.warp(1_700_000_000);

        policy = new StrategyPolicy(admin);

        consumer = new CREPolicyConsumer(mockForwarder, address(policy));

        // Grant CRE_CONSUMER_ROLE to the consumer contract
        bytes32 creRole = policy.CRE_CONSUMER_ROLE();
        vm.prank(admin);
        policy.grantRole(creRole, address(consumer));

        // Create and activate demo strategy
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 200);

        vm.prank(maker);
        policy.setStrategyActive(STRATEGY_A, true);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _buildReport(
        uint256 schemaVersion,
        bytes32 strategyId,
        uint24  proposedFee,
        uint64  observedAt,
        uint64  validUntil,
        uint64  policyVersion
    ) internal pure returns (bytes memory) {
        return abi.encode(ICREPolicyConsumer.PolicyReport({
            schemaVersion: schemaVersion,
            strategyId:    strategyId,
            proposedFee:   proposedFee,
            observedAt:    observedAt,
            validUntil:    validUntil,
            policyVersion: policyVersion
        }));
    }

    function _validReport(uint64 version) internal view returns (bytes memory) {
        return _buildReport(
            1,
            STRATEGY_A,
            3_000,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            version
        );
    }

    function _callOnReport(bytes memory report) internal {
        vm.prank(mockForwarder);
        consumer.onReport("", report);
    }

    // -------------------------------------------------------------------------
    // 1. Forwarder authentication
    // -------------------------------------------------------------------------

    function test_onReport_validForwarderSucceeds() public {
        _callOnReport(_validReport(1));
        assertEq(policy.getStrategy(STRATEGY_A).currentDynamicFee, 3_000);
    }

    function test_onReport_wrongForwarderReverts() public {
        vm.prank(stranger);
        vm.expectRevert("CRE: unauthorized forwarder");
        consumer.onReport("", _validReport(1));
    }

    function test_onReport_makerCannotCallDirectly() public {
        vm.prank(maker);
        vm.expectRevert("CRE: unauthorized forwarder");
        consumer.onReport("", _validReport(1));
    }

    // -------------------------------------------------------------------------
    // 2. Schema version
    // -------------------------------------------------------------------------

    function test_onReport_wrongSchemaVersionReverts() public {
        bytes memory report = _buildReport(2, STRATEGY_A, 3_000,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), 1);
        vm.prank(mockForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(ICREPolicyConsumer.UnknownSchemaVersion.selector, 2, 1)
        );
        consumer.onReport("", report);
    }

    // -------------------------------------------------------------------------
    // 3. Report expiry
    // -------------------------------------------------------------------------

    function test_onReport_expiredReportReverts() public {
        uint64 validUntil = uint64(block.timestamp + 1);
        bytes memory report = _buildReport(1, STRATEGY_A, 3_000,
            uint64(block.timestamp), validUntil, 1);
        vm.warp(block.timestamp + 2); // expire it
        vm.prank(mockForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(ICREPolicyConsumer.ReportExpired.selector, validUntil, block.timestamp)
        );
        consumer.onReport("", report);
    }

    // -------------------------------------------------------------------------
    // 4. Data staleness
    // -------------------------------------------------------------------------

    function test_onReport_staleObservedAtReverts() public {
        uint64 staleObservedAt = uint64(block.timestamp - 2 hours);
        bytes memory report = _buildReport(1, STRATEGY_A, 3_000,
            staleObservedAt, uint64(block.timestamp + 1 days), 1);
        uint64 maxAge = consumer.MAX_DATA_AGE(); // read before setting prank
        vm.prank(mockForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(ICREPolicyConsumer.StaleReport.selector, staleObservedAt, maxAge)
        );
        consumer.onReport("", report);
    }

    function test_onReport_freshObservedAtSucceeds() public {
        // observedAt = now - 30 min (within 1 hour MAX_DATA_AGE)
        uint64 recentObs = uint64(block.timestamp - 30 minutes);
        bytes memory report = _buildReport(1, STRATEGY_A, 3_000,
            recentObs, uint64(block.timestamp + 1 days), 1);
        vm.prank(mockForwarder);
        consumer.onReport("", report); // should not revert
    }

    // -------------------------------------------------------------------------
    // 5. Unknown strategy
    // -------------------------------------------------------------------------

    function test_onReport_unknownStrategyReverts() public {
        bytes32 unknownId = keccak256("UNKNOWN");
        bytes memory report = _buildReport(1, unknownId, 3_000,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), 1);
        vm.prank(mockForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(ICREPolicyConsumer.StrategyNotFound.selector, unknownId)
        );
        consumer.onReport("", report);
    }

    // -------------------------------------------------------------------------
    // 6. Replay protection
    // -------------------------------------------------------------------------

    function test_onReport_replayedVersionReverts() public {
        // First report: version 1
        _callOnReport(_validReport(1));
        assertEq(policy.getStrategy(STRATEGY_A).policyVersion, 1);

        // Replay same version
        vm.prank(mockForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(ICREPolicyConsumer.ReplayDetected.selector, uint64(1), uint64(1))
        );
        consumer.onReport("", _validReport(1));
    }

    function test_onReport_olderVersionReverts() public {
        _callOnReport(_validReport(5)); // jump to version 5

        bytes memory oldReport = _buildReport(1, STRATEGY_A, 3_000,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), 3); // version 3 < 5
        vm.prank(mockForwarder);
        vm.expectRevert(
            abi.encodeWithSelector(ICREPolicyConsumer.ReplayDetected.selector, uint64(3), uint64(5))
        );
        consumer.onReport("", oldReport);
    }

    function test_onReport_strictlyIncreasingVersionSucceeds() public {
        _callOnReport(_validReport(1));
        _callOnReport(_validReport(2));
        _callOnReport(_validReport(10));
        assertEq(policy.getStrategy(STRATEGY_A).policyVersion, 10);
    }

    // -------------------------------------------------------------------------
    // 7. Fee bounds enforced by StrategyPolicy
    // -------------------------------------------------------------------------

    function test_onReport_feeBelowMinReverts() public {
        bytes memory report = _buildReport(1, STRATEGY_A, MIN_FEE - 1,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), 1);
        vm.prank(mockForwarder);
        vm.expectRevert(); // StrategyPolicy.FeeOutOfBounds
        consumer.onReport("", report);
    }

    function test_onReport_feeAboveMaxReverts() public {
        bytes memory report = _buildReport(1, STRATEGY_A, MAX_FEE + 1,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), 1);
        vm.prank(mockForwarder);
        vm.expectRevert(); // StrategyPolicy.FeeOutOfBounds
        consumer.onReport("", report);
    }

    function test_onReport_feeAtMinSucceeds() public {
        bytes memory report = _buildReport(1, STRATEGY_A, MIN_FEE,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), 1);
        _callOnReport(report);
        assertEq(policy.getStrategy(STRATEGY_A).currentDynamicFee, MIN_FEE);
    }

    function test_onReport_feeAtMaxSucceeds() public {
        bytes memory report = _buildReport(1, STRATEGY_A, MAX_FEE,
            uint64(block.timestamp), uint64(block.timestamp + 1 days), 1);
        _callOnReport(report);
        assertEq(policy.getStrategy(STRATEGY_A).currentDynamicFee, MAX_FEE);
    }

    // -------------------------------------------------------------------------
    // 8. State changes
    // -------------------------------------------------------------------------

    function test_onReport_updatesAllPolicyFields() public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        bytes memory report = _buildReport(1, STRATEGY_A, 7_500,
            uint64(block.timestamp), validUntil, 3);
        _callOnReport(report);

        IStrategyPolicy.StrategyConfig memory cfg = policy.getStrategy(STRATEGY_A);
        assertEq(cfg.currentDynamicFee, 7_500, "fee updated");
        assertEq(cfg.policyVersion,     3,     "version updated");
        assertEq(cfg.validUntil,        validUntil, "validUntil updated");
    }

    function test_onReport_doesNotChangeMaker() public {
        address makerBefore = policy.getStrategy(STRATEGY_A).maker;
        _callOnReport(_validReport(1));
        assertEq(policy.getStrategy(STRATEGY_A).maker, makerBefore, "maker unchanged");
    }

    function test_onReport_doesNotChangeActiveStatus() public {
        bool activeBefore = policy.getStrategy(STRATEGY_A).active;
        _callOnReport(_validReport(1));
        assertEq(policy.getStrategy(STRATEGY_A).active, activeBefore, "active unchanged");
    }

    function test_onReport_emitsEvent() public {
        uint64 validUntil = uint64(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, true);
        emit ICREPolicyConsumer.PolicyUpdated(STRATEGY_A, 3_000, 1, validUntil);
        bytes memory report = _buildReport(1, STRATEGY_A, 3_000,
            uint64(block.timestamp), validUntil, 1);
        _callOnReport(report);
    }

    // -------------------------------------------------------------------------
    // 9. ERC165
    // -------------------------------------------------------------------------

    function test_supportsInterface_IERC165() public view {
        bytes4 erc165Id = 0x01ffc9a7; // ERC165 interfaceId constant
        assertTrue(consumer.supportsInterface(erc165Id), "supports IERC165");
    }

    function test_supportsInterface_unknownReturnsFalse() public view {
        assertFalse(consumer.supportsInterface(0xdeadbeef), "unknown interface returns false");
    }
}
