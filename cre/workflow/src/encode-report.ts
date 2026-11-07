/**
 * encode-report.ts
 * ABI-encodes the PolicyReport struct using viem's encodeAbiParameters.
 *
 * CRITICAL: field order and types MUST match the Solidity struct in
 * ICREPolicyConsumer.PolicyReport exactly:
 *
 *   struct PolicyReport {
 *     uint256 schemaVersion;
 *     bytes32 strategyId;
 *     uint24  proposedFee;
 *     uint64  observedAt;
 *     uint64  validUntil;
 *     uint64  policyVersion;
 *   }
 *
 * Any deviation causes a silent decode failure or wrong value onchain.
 */

import { encodeAbiParameters, parseAbiParameters } from "viem";
import { CONFIG } from "./config.js";

export interface PolicyReportInput {
  strategyId:    `0x${string}`;
  proposedFee:   bigint;
  observedAt:    bigint;
  validUntil:    bigint;
  policyVersion: bigint;
}

export interface EncodedReport {
  encoded:    `0x${string}`;
  reportData: PolicyReportInput & { schemaVersion: bigint };
}

/**
 * ABI-encode a PolicyReport for delivery via CRE writeReport.
 *
 * The ABI parameter string matches the Solidity struct field-for-field.
 * Uses abi.encode (not encodePacked) to match Solidity's abi.decode.
 */
export function encodeReport(input: PolicyReportInput): EncodedReport {
  const reportData = {
    schemaVersion: CONFIG.SCHEMA_VERSION,
    strategyId:    input.strategyId,
    proposedFee:   input.proposedFee,
    observedAt:    input.observedAt,
    validUntil:    input.validUntil,
    policyVersion: input.policyVersion,
  };

  // Field order must match Solidity struct exactly
  const encoded = encodeAbiParameters(
    parseAbiParameters("uint256, bytes32, uint24, uint64, uint64, uint64"),
    [
      reportData.schemaVersion,
      reportData.strategyId,
      Number(reportData.proposedFee), // uint24 maps to number in viem
      reportData.observedAt,
      reportData.validUntil,
      reportData.policyVersion,
    ]
  );

  console.log("[encode-report] Encoded PolicyReport:");
  console.log(`  schemaVersion: ${reportData.schemaVersion}`);
  console.log(`  strategyId:    ${reportData.strategyId}`);
  console.log(`  proposedFee:   ${reportData.proposedFee}`);
  console.log(`  observedAt:    ${reportData.observedAt}`);
  console.log(`  validUntil:    ${reportData.validUntil}`);
  console.log(`  policyVersion: ${reportData.policyVersion}`);
  console.log(`  encoded:       ${encoded.slice(0, 66)}...`);

  return { encoded, reportData };
}
