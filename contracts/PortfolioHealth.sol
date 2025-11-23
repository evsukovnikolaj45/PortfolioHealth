// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* Zama FHEVM */
import { FHE, euint64, externalEuint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/**
 * @title PortfolioHealth
 * @notice Private portfolio risk/health metric over encrypted positions.
 * @dev Design constraints:
 *  - Only Zama official libs (no deprecated packages).
 *  - Avoid FHE ops in view/pure; do computations in state-changing functions.
 *  - Division is done by a PUBLIC denominator only.
 *  - Uses FHE.allow / FHE.allowThis / FHE.makePubliclyDecryptable for ACL.
 */
contract PortfolioHealth is ZamaEthereumConfig {
    /* ─────────────────────────────
       Ownership & Admin
    ───────────────────────────── */
    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }

    constructor() {
        owner = msg.sender;
    }

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != address(0), "bad owner");
        owner = newOwner;
        emit OwnerSet(newOwner);
    }

    /* ─────────────────────────────
       Asset risk parameters
       - weightBP: risk weight in basis points (0..10000)
       - capUSDc: cap per asset (in USD * 100, i.e., cents)
    ───────────────────────────── */
    struct AssetParam {
        uint16  weightBP;  // 0..10000 bps
        uint64  capUSDc;   // cents
        bool    set;
    }

    // Admin-configured parameters per assetId
    mapping(bytes32 => AssetParam) public assetParams;

    // Domain guardrails (adjust to your product constraints)
    uint64  public constant MAX_CAP_USDC = 10_000_000_00; // $10,000,000.00 in cents
    uint16  public constant MAX_WEIGHT_BP = 10_000;       // 100%

    event AssetParamSet(bytes32 indexed assetId, uint16 weightBP, uint64 capUSDc);
    event OwnerSet(address indexed newOwner);

    function setAssetParam(bytes32 assetId, uint16 weightBP, uint64 capUSDc) external onlyOwner {
        require(weightBP <= MAX_WEIGHT_BP, "weight>100%");
        require(capUSDc > 0 && capUSDc <= MAX_CAP_USDC, "bad cap");
        assetParams[assetId] = AssetParam({
            weightBP: weightBP,
            capUSDc: capUSDc,
            set: true
        });
        emit AssetParamSet(assetId, weightBP, capUSDc);
    }

    /* ─────────────────────────────
       Portfolio ownership
       - lets teams map a portfolioId to an owner
    ───────────────────────────── */
    mapping(bytes32 => address) public portfolioOwner;
    event PortfolioOwnerSet(bytes32 indexed portfolioId, address indexed newOwner);

    function setPortfolioOwner(bytes32 portfolioId, address newOwner) external {
        address cur = portfolioOwner[portfolioId];
        if (cur != address(0)) require(msg.sender == cur, "not owner");
        portfolioOwner[portfolioId] = newOwner;
        emit PortfolioOwnerSet(portfolioId, newOwner);
    }

    /* ─────────────────────────────
       Results storage
    ───────────────────────────── */
    struct Result {
        address sender;
        uint64  ts;
        euint64 riskBP;    // 0..10000 (encrypted)
        euint64 healthBP;  // 0..10000 (encrypted)
        bool    set;
    }

    mapping(bytes32 => uint256) public nextResultId;                 // portfolioId => next id
    mapping(bytes32 => mapping(uint256 => Result)) public results;   // portfolioId => resultId => Result

    event PortfolioComputed(
        bytes32 indexed portfolioId,
        uint256 indexed resultId,
        address indexed by,
        bytes32 riskHandle,
        bytes32 healthHandle
    );
    event ResultAccessGranted(bytes32 indexed portfolioId, uint256 indexed resultId, address to);
    event ResultMadePublic(bytes32 indexed portfolioId, uint256 indexed resultId);

    /* ─────────────────────────────
       Core: compute private risk/health
       Inputs:
         - assetIds[i]: must be configured by admin
         - amounts[i]: encrypted amounts per asset in USD cents (uint64 domain)
         - attestation: shared attestation for all external values
       Formula:
         numerator = Σ_i ( min(amount[i], cap[i]) * weightBP[i] )
         denom     = Σ_i cap[i]                               // public
         riskBP    = numerator / denom                        // in basis points
         healthBP  = clamp(10000 - riskBP, 0..10000)
    ───────────────────────────── */
    function computePortfolio(
        bytes32 portfolioId,
        bytes32[] calldata assetIds,
        externalEuint64[] calldata amounts,
        bytes calldata attestation
    ) external returns (uint256 resultId) {
        uint256 n = assetIds.length;
        require(n > 0 && n == amounts.length, "bad input len");

        // Accumulators
        euint64 accNum = FHE.asEuint64(0); // Σ min(amount, cap) * weight
        uint64  accDen = 0;                // Σ cap (PUBLIC)

        // Iterate assets
        for (uint256 i = 0; i < n; i++) {
            AssetParam memory p = assetParams[assetIds[i]];
            require(p.set, "asset not configured");

            // Import encrypted amount with shared attestation
            euint64 amt = FHE.fromExternal(amounts[i], attestation);

            // Clamp to cap: min(amt, cap)
            euint64 capped = FHE.min(amt, FHE.asEuint64(p.capUSDc));

            // Weighted contribution = capped * weightBP
            euint64 w = FHE.mul(capped, FHE.asEuint64(uint64(p.weightBP)));

            // Accumulate numerator
            accNum = FHE.add(accNum, w);

            // Accumulate PUBLIC denominator
            accDen += p.capUSDc;
        }

        require(accDen > 0, "zero denominator");

        // riskBP = accNum / accDen  (division by PUBLIC uint64 is supported)
        euint64 riskBP = FHE.div(accNum, accDen);

        // Clamp to [0, 10000]
        riskBP = FHE.min(riskBP, FHE.asEuint64(uint64(MAX_WEIGHT_BP)));

        // healthBP = 10000 - riskBP
        euint64 healthBP = FHE.sub(FHE.asEuint64(uint64(MAX_WEIGHT_BP)), riskBP);

        // Persist result
        resultId = nextResultId[portfolioId]++;
        Result storage R = results[portfolioId][resultId];
        R.sender   = msg.sender;
        R.ts       = uint64(block.timestamp);
        R.riskBP   = riskBP;
        R.healthBP = healthBP;
        R.set      = true;

        // Access control: contract needs persistent access; sender & portfolio owner need access
        FHE.allowThis(R.riskBP);
        FHE.allowThis(R.healthBP);

        FHE.allow(R.riskBP, msg.sender);
        FHE.allow(R.healthBP, msg.sender);

        address pOwner = portfolioOwner[portfolioId];
        if (pOwner != address(0)) {
            FHE.allow(R.riskBP, pOwner);
            FHE.allow(R.healthBP, pOwner);
        }

        emit PortfolioComputed(
            portfolioId,
            resultId,
            msg.sender,
            FHE.toBytes32(R.riskBP),
            FHE.toBytes32(R.healthBP)
        );
    }

    /* ─────────────────────────────
       Access control helpers
    ───────────────────────────── */
    function grantResultAccess(bytes32 portfolioId, uint256 resultId, address to) external {
        require(to != address(0), "bad addr");
        Result storage R = results[portfolioId][resultId];
        require(R.set, "no result");
        address pOwner = portfolioOwner[portfolioId];
        require(msg.sender == pOwner || msg.sender == R.sender || msg.sender == owner, "not allowed");
        FHE.allow(R.riskBP, to);
        FHE.allow(R.healthBP, to);
        emit ResultAccessGranted(portfolioId, resultId, to);
    }

    function makeResultPublic(bytes32 portfolioId, uint256 resultId) external {
        address pOwner = portfolioOwner[portfolioId];
        require(msg.sender == pOwner || msg.sender == owner, "not owner");
        Result storage R = results[portfolioId][resultId];
        require(R.set, "no result");
        FHE.makePubliclyDecryptable(R.riskBP);
        FHE.makePubliclyDecryptable(R.healthBP);
        emit ResultMadePublic(portfolioId, resultId);
    }

    /* ─────────────────────────────
       Getters (handles only; no FHE math here)
    ───────────────────────────── */
    function riskHandle(bytes32 portfolioId, uint256 resultId) external view returns (bytes32) {
        require(results[portfolioId][resultId].set, "no result");
        return FHE.toBytes32(results[portfolioId][resultId].riskBP);
    }

    function healthHandle(bytes32 portfolioId, uint256 resultId) external view returns (bytes32) {
        require(results[portfolioId][resultId].set, "no result");
        return FHE.toBytes32(results[portfolioId][resultId].healthBP);
    }

    /* ─────────────────────────────
       Version
    ───────────────────────────── */
    function version() external pure returns (string memory) {
        return "PortfolioHealth/1.0.0";
    }
}
