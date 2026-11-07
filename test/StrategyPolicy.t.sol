// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StrategyPolicy} from "../contracts/StrategyPolicy.sol";
import {IStrategyPolicy} from "../contracts/interfaces/IStrategyPolicy.sol";

contract StrategyPolicyTest is Test {
    StrategyPolicy internal policy;

    address internal admin   = makeAddr("admin");
    address internal maker   = makeAddr("maker");
    address internal maker2  = makeAddr("maker2");
    address internal signer1 = makeAddr("signer1");
    address internal stranger = makeAddr("stranger");
    address internal creConsumer = makeAddr("creConsumer");
    address internal tokenUsdc = address(0x036CbD53842c5426634e7929541eC2318f3dCF7e);
    address internal tokenWeth = address(0x4200000000000000000000000000000000000006);
    address internal adapter   = makeAddr("adapter");

    bytes32 internal constant STRATEGY_A = keccak256("STRATEGY_A");
    bytes32 internal constant STRATEGY_B = keccak256("STRATEGY_B");

    uint24 internal constant MIN_FEE = 500;   // 0.05%
    uint24 internal constant MAX_FEE = 10000; // 1%
    uint24 internal constant INIT_FEE = 500;

    function setUp() public {
        policy = new StrategyPolicy(admin);
        // Grant CRE_CONSUMER_ROLE to the mock consumer.
        // Read the role constant first (view call), then prank for the state-changing grantRole.
        bytes32 creRole = policy.CRE_CONSUMER_ROLE();
        vm.prank(admin);
        policy.grantRole(creRole, creConsumer);
    }

    // -------------------------------------------------------------------------
    // createStrategy
    // -------------------------------------------------------------------------

    function test_createStrategy_succeeds() public {
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 100);

        IStrategyPolicy.StrategyConfig memory cfg = policy.getStrategy(STRATEGY_A);
        assertEq(cfg.maker, maker);
        assertFalse(cfg.active);
        assertEq(cfg.minDynamicFee, MIN_FEE);
        assertEq(cfg.maxDynamicFee, MAX_FEE);
        assertEq(cfg.currentDynamicFee, MIN_FEE);
        assertEq(cfg.policyVersion, 0);
    }

    function test_createStrategy_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit IStrategyPolicy.StrategyCreated(STRATEGY_A, maker);
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 100);
    }

    function test_createStrategy_duplicateReverts() public {
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 100);

        vm.prank(maker2);
        vm.expectRevert(abi.encodeWithSelector(IStrategyPolicy.StrategyAlreadyExists.selector, STRATEGY_A));
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 100);
    }

    function test_createStrategy_invalidFeeRangeReverts() public {
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(IStrategyPolicy.InvalidFeeRange.selector, MAX_FEE, MIN_FEE));
        policy.createStrategy(STRATEGY_A, MAX_FEE, MIN_FEE, 1e18, 100); // min > max
    }

    // -------------------------------------------------------------------------
    // setStrategyActive
    // -------------------------------------------------------------------------

    function test_setStrategyActive_makerCanActivate() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setStrategyActive(STRATEGY_A, true);
        assertTrue(policy.getStrategy(STRATEGY_A).active);
    }

    function test_setStrategyActive_strangerReverts() public {
        _createStrategyA();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.NotStrategyOwner.selector, STRATEGY_A, stranger)
        );
        policy.setStrategyActive(STRATEGY_A, true);
    }

    function test_setStrategyActive_nonexistentReverts() public {
        vm.prank(maker);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.StrategyNotFound.selector, STRATEGY_A)
        );
        policy.setStrategyActive(STRATEGY_A, true);
    }

    // -------------------------------------------------------------------------
    // setSigner (D-3)
    // -------------------------------------------------------------------------

    function test_setSigner_makerGrantsSigner() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setSigner(STRATEGY_A, signer1, true);
        assertTrue(policy.isSignerAuthorised(STRATEGY_A, signer1));
    }

    function test_setSigner_makerIsAlwaysAuthorised() public {
        _createStrategyA();
        assertTrue(policy.isSignerAuthorised(STRATEGY_A, maker));
    }

    function test_setSigner_makerRevokesGrantedSigner() public {
        _createStrategyA();
        vm.startPrank(maker);
        policy.setSigner(STRATEGY_A, signer1, true);
        assertTrue(policy.isSignerAuthorised(STRATEGY_A, signer1));
        policy.setSigner(STRATEGY_A, signer1, false);
        vm.stopPrank();
        assertFalse(policy.isSignerAuthorised(STRATEGY_A, signer1));
    }

    function test_setSigner_revokedSignerReturnsFalse() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setSigner(STRATEGY_A, signer1, false);
        assertFalse(policy.isSignerAuthorised(STRATEGY_A, signer1));
    }

    function test_setSigner_strangerReverts() public {
        _createStrategyA();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.NotStrategyOwner.selector, STRATEGY_A, stranger)
        );
        policy.setSigner(STRATEGY_A, signer1, true);
    }

    function test_setSigner_zeroAddressReverts() public {
        _createStrategyA();
        vm.prank(maker);
        vm.expectRevert(IStrategyPolicy.ZeroAddress.selector);
        policy.setSigner(STRATEGY_A, address(0), true);
    }

    // -------------------------------------------------------------------------
    // Token approval
    // -------------------------------------------------------------------------

    function test_setTokenApproval_makerApprovesToken() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setTokenApproval(STRATEGY_A, tokenUsdc, true);
        assertTrue(policy.isTokenApproved(STRATEGY_A, tokenUsdc));
    }

    function test_setTokenApproval_unapprovedTokenReturnsFalse() public {
        _createStrategyA();
        assertFalse(policy.isTokenApproved(STRATEGY_A, tokenUsdc));
    }

    function test_setTokenApproval_strangerReverts() public {
        _createStrategyA();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.NotStrategyOwner.selector, STRATEGY_A, stranger)
        );
        policy.setTokenApproval(STRATEGY_A, tokenUsdc, true);
    }

    // -------------------------------------------------------------------------
    // Adapter approval
    // -------------------------------------------------------------------------

    function test_setAdapterApproval_makerApprovesAdapter() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setAdapterApproval(STRATEGY_A, adapter, true);
        assertTrue(policy.isAdapterApproved(STRATEGY_A, adapter));
    }

    function test_setAdapterApproval_unapprovedAdapterReturnsFalse() public {
        _createStrategyA();
        assertFalse(policy.isAdapterApproved(STRATEGY_A, adapter));
    }

    function test_setAdapterApproval_strangerReverts() public {
        _createStrategyA();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.NotStrategyOwner.selector, STRATEGY_A, stranger)
        );
        policy.setAdapterApproval(STRATEGY_A, adapter, true);
    }

    // -------------------------------------------------------------------------
    // Pool key approval (D-5)
    // -------------------------------------------------------------------------

    function test_setPoolApproval_makerApprovesPool() public {
        _createStrategyA();
        bytes32 poolHash = keccak256(abi.encode("some-pool-key"));
        vm.prank(maker);
        policy.setPoolApproval(STRATEGY_A, poolHash, true);
        assertTrue(policy.isPoolKeyApproved(STRATEGY_A, poolHash));
    }

    function test_setPoolApproval_unapprovedPoolReturnsFalse() public {
        _createStrategyA();
        bytes32 poolHash = keccak256(abi.encode("some-pool-key"));
        assertFalse(policy.isPoolKeyApproved(STRATEGY_A, poolHash));
    }

    // -------------------------------------------------------------------------
    // Execution limits
    // -------------------------------------------------------------------------

    function test_setExecutionLimits_makerUpdates() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setExecutionLimits(STRATEGY_A, 5e18, 200);
        IStrategyPolicy.StrategyConfig memory cfg = policy.getStrategy(STRATEGY_A);
        assertEq(cfg.maxOrderSize, 5e18);
        assertEq(cfg.maxSlippageBps, 200);
    }

    function test_setExecutionLimits_strangerReverts() public {
        _createStrategyA();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.NotStrategyOwner.selector, STRATEGY_A, stranger)
        );
        policy.setExecutionLimits(STRATEGY_A, 5e18, 200);
    }

    // -------------------------------------------------------------------------
    // Fee bounds
    // -------------------------------------------------------------------------

    function test_setFeeBounds_makerUpdates() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setFeeBounds(STRATEGY_A, 1000, 5000);
        IStrategyPolicy.StrategyConfig memory cfg = policy.getStrategy(STRATEGY_A);
        assertEq(cfg.minDynamicFee, 1000);
        assertEq(cfg.maxDynamicFee, 5000);
    }

    function test_setFeeBounds_clampsCurrentFeeDown() public {
        _createStrategyA();
        // First push current fee up via CRE
        vm.prank(creConsumer);
        policy.applyCREPolicyUpdate(STRATEGY_A, 8000, 1, uint64(block.timestamp + 1 days));
        // Now tighten bounds below current fee
        vm.prank(maker);
        policy.setFeeBounds(STRATEGY_A, 500, 3000);
        assertEq(policy.getStrategy(STRATEGY_A).currentDynamicFee, 3000); // clamped to max
    }

    function test_setFeeBounds_invalidRangeReverts() public {
        _createStrategyA();
        vm.prank(maker);
        vm.expectRevert(abi.encodeWithSelector(IStrategyPolicy.InvalidFeeRange.selector, 5000, 1000));
        policy.setFeeBounds(STRATEGY_A, 5000, 1000);
    }

    // -------------------------------------------------------------------------
    // CRE policy update
    // -------------------------------------------------------------------------

    function test_applyCREPolicyUpdate_succeeds() public {
        _createStrategyA();
        uint24 newFee = 3000;
        uint64 version = 1;
        uint64 validUntil = uint64(block.timestamp + 1 days);

        vm.prank(creConsumer);
        policy.applyCREPolicyUpdate(STRATEGY_A, newFee, version, validUntil);

        IStrategyPolicy.StrategyConfig memory cfg = policy.getStrategy(STRATEGY_A);
        assertEq(cfg.currentDynamicFee, newFee);
        assertEq(cfg.policyVersion, version);
        assertEq(cfg.validUntil, validUntil);
    }

    function test_applyCREPolicyUpdate_emitsEvent() public {
        _createStrategyA();
        uint24 newFee = 3000;
        uint64 version = 1;
        uint64 validUntil = uint64(block.timestamp + 1 days);

        vm.expectEmit(true, false, false, true);
        emit IStrategyPolicy.CREPolicyApplied(STRATEGY_A, newFee, version, validUntil);
        vm.prank(creConsumer);
        policy.applyCREPolicyUpdate(STRATEGY_A, newFee, version, validUntil);
    }

    function test_applyCREPolicyUpdate_strangerReverts() public {
        _createStrategyA();
        vm.prank(stranger);
        vm.expectRevert(); // AccessControl revert
        policy.applyCREPolicyUpdate(STRATEGY_A, 3000, 1, uint64(block.timestamp + 1 days));
    }

    function test_applyCREPolicyUpdate_makerReverts() public {
        _createStrategyA();
        // Maker does NOT have CRE_CONSUMER_ROLE
        vm.prank(maker);
        vm.expectRevert();
        policy.applyCREPolicyUpdate(STRATEGY_A, 3000, 1, uint64(block.timestamp + 1 days));
    }

    function test_applyCREPolicyUpdate_feeBelowMinReverts() public {
        _createStrategyA();
        vm.prank(creConsumer);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.FeeOutOfBounds.selector, MIN_FEE - 1, MIN_FEE, MAX_FEE)
        );
        policy.applyCREPolicyUpdate(STRATEGY_A, MIN_FEE - 1, 1, uint64(block.timestamp + 1 days));
    }

    function test_applyCREPolicyUpdate_feeAboveMaxReverts() public {
        _createStrategyA();
        vm.prank(creConsumer);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.FeeOutOfBounds.selector, MAX_FEE + 1, MIN_FEE, MAX_FEE)
        );
        policy.applyCREPolicyUpdate(STRATEGY_A, MAX_FEE + 1, 1, uint64(block.timestamp + 1 days));
    }

    function test_applyCREPolicyUpdate_cannotChangeMaker() public {
        _createStrategyA();
        // CRE consumer has no function to change the maker — verify the field is unchanged
        vm.prank(creConsumer);
        policy.applyCREPolicyUpdate(STRATEGY_A, 3000, 1, uint64(block.timestamp + 1 days));
        assertEq(policy.getStrategy(STRATEGY_A).maker, maker); // unchanged
    }

    function test_applyCREPolicyUpdate_cannotChangeSigners() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setSigner(STRATEGY_A, signer1, true);

        vm.prank(creConsumer);
        policy.applyCREPolicyUpdate(STRATEGY_A, 3000, 1, uint64(block.timestamp + 1 days));

        // signer1 still authorised — CRE didn't touch it
        assertTrue(policy.isSignerAuthorised(STRATEGY_A, signer1));
    }

    function test_applyCREPolicyUpdate_cannotChangeAdapters() public {
        _createStrategyA();
        vm.prank(maker);
        policy.setAdapterApproval(STRATEGY_A, adapter, true);

        vm.prank(creConsumer);
        policy.applyCREPolicyUpdate(STRATEGY_A, 3000, 1, uint64(block.timestamp + 1 days));

        // adapter still approved — CRE didn't touch it
        assertTrue(policy.isAdapterApproved(STRATEGY_A, adapter));
    }

    // -------------------------------------------------------------------------
    // Strategy isolation
    // -------------------------------------------------------------------------

    function test_twoStrategiesAreIndependent() public {
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 100);
        vm.prank(maker2);
        policy.createStrategy(STRATEGY_B, MIN_FEE, MAX_FEE, 1e18, 100);

        vm.prank(maker);
        policy.setTokenApproval(STRATEGY_A, tokenUsdc, true);

        // Token approved for A but not for B
        assertTrue(policy.isTokenApproved(STRATEGY_A, tokenUsdc));
        assertFalse(policy.isTokenApproved(STRATEGY_B, tokenUsdc));
    }

    function test_maker2_cannotModifyStrategyA() public {
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 100);

        vm.prank(maker2);
        vm.expectRevert(
            abi.encodeWithSelector(IStrategyPolicy.NotStrategyOwner.selector, STRATEGY_A, maker2)
        );
        policy.setStrategyActive(STRATEGY_A, true);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _createStrategyA() internal {
        vm.prank(maker);
        policy.createStrategy(STRATEGY_A, MIN_FEE, MAX_FEE, 1e18, 100);
    }
}
