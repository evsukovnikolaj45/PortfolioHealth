// deploy/universal-deploy.ts
// Universal Hardhat-Deploy script that figures out which contract to deploy
// based on your contracts folder. You don't need to edit the script when
// you rename the .sol file — just keep one main contract per project or
// set ENV vars to disambiguate.
//
// Usage:
//   - Put this file under `deploy/` directory.
//   - Configure `hardhat-deploy` and named accounts (deployer) in hardhat.config.
//   - Optionally set env vars:
//       CONTRACT_NAME       = Explicit contract name to deploy (e.g. PrivateRoadFineCheck)
//       CONTRACT_FILE       = Relative path under contracts/ (e.g. road/PrivateRoadFineCheck.sol)
//       CONSTRUCTOR_ARGS    = JSON array of args (e.g. '["0xOwner..."]')
//       WAIT_CONFIRMS       = number of confirmations to wait (default 1)
//   - Run: `npx hardhat deploy --network sepolia`
//
// Notes:
//   - If CONTRACT_NAME/CONTRACT_FILE are not set, the script will pick the most
//     recently modified .sol file under `contracts/` and deploy a contract whose
//     name matches the file basename (fallback to first contract found in that file).
//   - Designed for Zama FHEVM projects but works for any Solidity contract.

import path from "node:path";
import fs from "node:fs/promises";
import { DeployFunction } from "hardhat-deploy/types";
import { HardhatRuntimeEnvironment } from "hardhat/types";

async function listSolFiles(root: string): Promise<string[]> {
  const out: string[] = [];
  async function walk(dir: string) {
    const items = await fs.readdir(dir, { withFileTypes: true });
    for (const it of items) {
      const p = path.join(dir, it.name);
      if (it.isDirectory()) await walk(p);
      else if (it.isFile() && p.endsWith(".sol")) out.push(p);
    }
  }
  await walk(root);
  return out;
}

async function pickLatestFile(files: string[]): Promise<string | null> {
  if (files.length === 0) return null;
  let best = files[0];
  let bestMtime = (await fs.stat(files[0])).mtimeMs;
  for (let i = 1; i < files.length; i++) {
    const m = (await fs.stat(files[i])).mtimeMs;
    if (m > bestMtime) {
      bestMtime = m;
      best = files[i];
    }
  }
  return best;
}

async function resolveTarget(hre: HardhatRuntimeEnvironment): Promise<{ contractName: string; fqn: string }> {
  const artifacts = hre.artifacts;
  const fqns = await artifacts.getAllFullyQualifiedNames();
  const contractsFqns = fqns.filter((fqn) => fqn.startsWith("contracts/"));

  // Build index: sourceName -> contractNames[]
  const bySource = new Map<string, string[]>();
  for (const fqn of contractsFqns) {
    const [sourceName, contractName] = fqn.split(":");
    if (!bySource.has(sourceName)) bySource.set(sourceName, []);
    bySource.get(sourceName)!.push(contractName);
  }

  const envName = process.env.CONTRACT_NAME?.trim();
  const envFile = process.env.CONTRACT_FILE?.replace(/\\/g, "/").replace(/^\/*/, "");

  // 1) Explicit name
  if (envName) {
    const matchFqn = contractsFqns.find((f) => f.endsWith(`:${envName}`));
    if (!matchFqn)
      throw new Error(`CONTRACT_NAME='${envName}' not found in artifacts. Candidates: \n` + contractsFqns.join("\n"));
    return { contractName: envName, fqn: matchFqn };
  }

  // 2) Explicit file
  if (envFile) {
    const sourceName = path.posix.join("contracts", envFile);
    const names = bySource.get(sourceName);
    if (!names || names.length === 0) throw new Error(`CONTRACT_FILE '${envFile}' not found in artifacts.`);
    const base = path.posix.basename(sourceName, ".sol");
    const preferred = names.includes(base) ? base : names[0];
    return { contractName: preferred, fqn: `${sourceName}:${preferred}` };
  }

  // 3) Only one contract total
  const uniqueNames = new Set(contractsFqns.map((f) => f.split(":")[1]));
  if (uniqueNames.size === 1) {
    const only = [...uniqueNames][0];
    const match = contractsFqns.find((f) => f.endsWith(`:${only}`))!;
    return { contractName: only, fqn: match };
  }

  // 4) Pick most recently modified .sol file and prefer contract with same basename
  const srcRoot = hre.config.paths.sources.replace(/\\/g, "/");
  const files = await listSolFiles(srcRoot);
  const latest = await pickLatestFile(files);
  if (!latest) throw new Error("No .sol files under contracts/");
  const sourceNamePosix = latest.replace(/\\/g, "/");
  const rel = path.posix.relative(process.cwd().replace(/\\/g, "/"), sourceNamePosix);
  const sourceKey = rel.startsWith("contracts/") ? rel : path.posix.join("contracts", path.posix.basename(rel));
  const names = bySource.get(sourceKey);
  if (!names || names.length === 0) {
    // Try fallback: find any fqn whose sourceName ends with the file basename
    const base = path.posix.basename(sourceKey);
    const found = contractsFqns.find((f) => f.split(":")[0].endsWith(`/${base}`));
    if (!found) throw new Error(`Could not resolve target contract for latest file ${sourceKey}`);
    return { contractName: found.split(":")[1], fqn: found };
  }
  const base = path.posix.basename(sourceKey, ".sol");
  const preferred = names.includes(base) ? base : names[0];
  return { contractName: preferred, fqn: `${sourceKey}:${preferred}` };
}

const func: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts } = hre;
  const { deploy, log } = deployments;
  const { deployer } = await getNamedAccounts();

  const { contractName, fqn } = await resolveTarget(hre);

  const WAIT = parseInt(process.env.WAIT_CONFIRMS ?? "1");
  let args: any[] = [];
  if (process.env.CONSTRUCTOR_ARGS) {
    try {
      args = JSON.parse(process.env.CONSTRUCTOR_ARGS);
    } catch (e) {
      throw new Error(`Failed to parse CONSTRUCTOR_ARGS JSON: ${e}`);
    }
  }

  log("\n====================================================");
  log(`Deploying ${contractName}`);
  log(`Resolved FQN: ${fqn}`);
  log(`From: ${deployer}`);
  log(`Args: ${JSON.stringify(args)}`);
  log("====================================================\n");

  const result = await deploy(contractName, {
    from: deployer,
    args,
    log: true,
    waitConfirmations: WAIT,
  });

  log(`Deployed at: ${result.address}`);
};

export default func;
func.tags = ["auto"];
