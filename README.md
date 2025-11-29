````markdown
# PortfolioHealth 🧮

**Private portfolio risk & health scoring on top of Zama FHEVM**

`PortfolioHealth` is a smart contract that computes risk and health metrics for portfolios using **encrypted position sizes**.  
All sensitive portfolio amounts are provided as encrypted `euint64` values; the contract never sees them in plaintext.

The result is:

- `riskBP`  – portfolio risk in **basis points** (0–10,000, encrypted)  
- `healthBP` – derived health score in **basis points** (0–10,000, encrypted)

Both scores are stored on-chain in encrypted form and can be selectively decrypted by authorized addresses.

---

## 1. High-level idea

The contract lets you:

1. Configure **per-asset risk parameters** (weights & caps).
2. Associate a **portfolio identifier** with an owner.
3. Submit a **set of encrypted positions** for that portfolio.
4. Let the contract compute a private risk score:
   - Higher risk → higher `riskBP`, lower `healthBP`
   - Lower risk → lower `riskBP`, higher `healthBP`
5. Read only **encrypted handles** on-chain and decrypt off-chain via the FHEVM Relayer SDK.

Nothing about position sizes is revealed on-chain – not per asset, not total, not even relative proportions.

---

## 2. Used FHEVM primitives

The contract uses only official Zama FHEVM Solidity types and functions:

```solidity
import { FHE, euint64, externalEuint64, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
````

Encrypted types:

* `euint64` – encrypted 64-bit unsigned integer
* `externalEuint64` – attested external ciphertext used as function input
* `ebool` – encrypted boolean (used internally while computing)

Access control primitives:

* `FHE.allow(...)`
* `FHE.allowThis(...)`
* `FHE.makePubliclyDecryptable(...)`
* `FHE.toBytes32(...)` (for handles)

No deprecated or third-party FHE libraries are used.

---

## 3. Risk model definition

For a given portfolio and list of assets:

* `assetIds[i]` – identifier for asset *i* (e.g. hash of symbol/ISIN)
* `amount[i]` – encrypted position size in USD cents (`euint64`)
* Each asset has admin-configured parameters:

  * `capUSDc[i]` (maximum amount per asset, in cents, public)
  * `weightBP[i]` (risk weight in basis points, public)

The contract computes:

1. **Capped amount** per asset (still encrypted):

   ```text
   capped[i] = min(amount[i], capUSDc[i])
   ```

2. **Weighted contribution** (encrypted):

   ```text
   contrib[i] = capped[i] * weightBP[i]
   ```

3. **Numerator** (encrypted sum):

   ```text
   numerator = Σ contrib[i]
   ```

4. **Denominator** (public sum of caps):

   ```text
   denom = Σ capUSDc[i]
   ```

5. **Risk score** (encrypted division by public value):

   ```text
   riskBP = numerator / denom      // result in basis points
   riskBP = min(riskBP, 10000)
   ```

6. **Health score** (encrypted subtraction):

   ```text
   healthBP = 10000 - riskBP       // also clamped to [0, 10000] via min above
   ```

Both `riskBP` and `healthBP` are stored as `euint64`.

---

## 4. Data structures and storage

### 4.1 Asset risk parameters

```solidity
struct AssetParam {
    uint16  weightBP;  // 0..10000 bps
    uint64  capUSDc;   // cents
    bool    set;
}
mapping(bytes32 => AssetParam) public assetParams;
```

* `weightBP` – per-asset risk weight
* `capUSDc` – maximum amount considered per asset
* These are configured by the protocol `owner`.

### 4.2 Portfolio ownership

```solidity
mapping(bytes32 => address) public portfolioOwner;
```

* `portfolioId` is any `bytes32` identifier (e.g. keccak of some portfolio key).
* The owner can be changed by the current owner (or set initially by any caller when empty).

### 4.3 Computation results

```solidity
struct Result {
    address sender;
    uint64  ts;
    euint64 riskBP;
    euint64 healthBP;
    bool    set;
}

mapping(bytes32 => uint256) public nextResultId;
mapping(bytes32 => mapping(uint256 => Result)) public results;
```

Each `portfolioId` can have multiple result entries (e.g., time series of recalculated risk).

---

## 5. Contract interface

### 5.1 Admin / owner functions

**Set contract owner**

```solidity
function setOwner(address newOwner) external onlyOwner;
```

**Configure asset parameters**

```solidity
function setAssetParam(bytes32 assetId, uint16 weightBP, uint64 capUSDc) external onlyOwner;
```

Constraints enforced:

* `weightBP <= 10_000`
* `0 < capUSDc <= 10_000_000_00` (max $10M in cents)

### 5.2 Portfolio ownership

```solidity
function setPortfolioOwner(bytes32 portfolioId, address newOwner) external;
```

Rules:

* If `portfolioOwner[portfolioId]` is unset, **anyone** can set it.
* If already set, only the current owner can change it.

### 5.3 Core computation entry point

```solidity
function computePortfolio(
    bytes32 portfolioId,
    bytes32[] calldata assetIds,
    externalEuint64[] calldata amounts,
    bytes calldata attestation
) external returns (uint256 resultId);
```

Behavior:

1. Verifies:

   * `assetIds.length > 0`
   * `assetIds.length == amounts.length`
   * each `assetId` is configured in `assetParams`
2. Imports encrypted amounts via `FHE.fromExternal(amounts[i], attestation)`
3. Executes the risk model (see section 3)
4. Stores `Result` in `results[portfolioId][resultId]`
5. Sets access control:

   * `FHE.allowThis(riskBP/healthBP)`
   * `FHE.allow(..., msg.sender)`
   * `FHE.allow(..., portfolioOwner[portfolioId])` if set
6. Emits:

```solidity
event PortfolioComputed(
    bytes32 indexed portfolioId,
    uint256 indexed resultId,
    address indexed by,
    bytes32 riskHandle,
    bytes32 healthHandle
);
```

Where:

* `riskHandle`  = `FHE.toBytes32(R.riskBP)`
* `healthHandle` = `FHE.toBytes32(R.healthBP)`

### 5.4 Access management

**Grant someone decryption rights to a specific result**

```solidity
function grantResultAccess(bytes32 portfolioId, uint256 resultId, address to) external;
```

Allowed callers:

* global `owner`
* `portfolioOwner[portfolioId]`
* `results[portfolioId][resultId].sender`

If valid, grants access with:

```solidity
FHE.allow(R.riskBP, to);
FHE.allow(R.healthBP, to);
```

**Mark result as publicly decryptable**

```solidity
function makeResultPublic(bytes32 portfolioId, uint256 resultId) external;
```

Allowed callers:

* global `owner`
* `portfolioOwner[portfolioId]`

Effect:

```solidity
FHE.makePubliclyDecryptable(R.riskBP);
FHE.makePubliclyDecryptable(R.healthBP);
```

### 5.5 Handle getters (read-only)

These functions return opaque `bytes32` handles you can pass to the Relayer SDK:

```solidity
function riskHandle(bytes32 portfolioId, uint256 resultId) external view returns (bytes32);

function healthHandle(bytes32 portfolioId, uint256 resultId) external view returns (bytes32);
```

They **do not** perform FHE math; they simply convert stored handles to `bytes32`.

### 5.6 Version

```solidity
function version() external pure returns (string memory);
```

Currently returns:

```text
"PortfolioHealth/1.0.0"
```

---

## 6. Access control model (FHE ACL)

The contract uses Zama’s ACL model explicitly:

* `FHE.allowThis(cipher)`
  → contract itself can use the encrypted value in later calls.
* `FHE.allow(cipher, addr)`
  → `addr` can later request decryption or use the ciphertext in further FHE operations.
* `FHE.makePubliclyDecryptable(cipher)`
  → anyone can request decryption of that particular ciphertext.

For each computed result:

* The **caller** (`msg.sender`) gains access.
* The **portfolio owner**, if set, gains access.
* The **contract** gets persistent access to both `riskBP` and `healthBP`.

Additional addresses can be granted or the result can be made public using the functions described above.

---

## 7. Off-chain integration sketch

Below is a conceptual flow using the official **Relayer SDK** (package name may vary by network, e.g. `@zama-fhe/relayer-sdk`):

1. Frontend gathers portfolio amounts in USD cents.
2. Frontend calls `createEncryptedInput(...)` to obtain:

   * A list of `externalEuint64`
   * An `attestation`
3. Frontend sends a transaction to `computePortfolio(...)`.
4. After confirmation, frontend calls:

   * `riskHandle(portfolioId, resultId)`
   * `healthHandle(portfolioId, resultId)`
5. Using `userDecrypt(handle, ...)` on the client or backend, the plaintext scores are recovered.

Example pseudo-TypeScript:

```ts
const sdk = await createInstance(SomeNetworkConfig);

// step 1: encrypt amounts
const enc = await sdk.createEncryptedInput({
  amounts: [100_000_00, 50_000_00], // example: cents per asset
});

// step 2: compute on-chain
const tx = await portfolioHealth.computePortfolio(
  portfolioId,
  [assetId1, assetId2],
  enc.external.amounts,
  enc.attestation
);
const receipt = await tx.wait();
const resultId = /* derive from event logs */;

// step 3: read handles
const riskHandle  = await portfolioHealth.riskHandle(portfolioId, resultId);
const healthHandle = await portfolioHealth.healthHandle(portfolioId, resultId);

// step 4: decrypt
const riskBP = await sdk.userDecrypt({
  handle: riskHandle,
  contractAddress: portfolioHealth.target,
});

const healthBP = await sdk.userDecrypt({
  handle: healthHandle,
  contractAddress: portfolioHealth.target,
});

console.log({ riskBP, healthBP });
```

---

## 8. Deployment & usage checklist

1. **Deploy** `PortfolioHealth` to an FHEVM-enabled network.
2. As `owner`:

   * Configure assets using `setAssetParam(assetId, weightBP, capUSDc)`.
3. Associate each portfolio with an owner via `setPortfolioOwner(portfolioId, ownerAddress)`.
4. From your app:

   * Encrypt per-asset amounts with Relayer SDK → `externalEuint64[]` + `attestation`.
   * Call `computePortfolio(portfolioId, assetIds, amounts, attestation)`.
   * Listen for `PortfolioComputed` events to get `resultId`.
5. Use `riskHandle` / `healthHandle` to get handles and decrypt off-chain.

---

## 9. License

This contract is released under the **MIT License**.

```
```
