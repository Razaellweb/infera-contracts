#!/usr/bin/env python3
"""Builds the Programmable Custom Launch package for INFERA on Ethereum Mainnet.

Compiles the token, hook and initializer with the exact compiler Programmable admits
(solc 0.8.26+commit.8a97fa7a), writes the Standard JSON input and artifacts, and writes
`programmable-launch.config.json` for `programmable-launch pack`. The config pins no profile
version: `pack` then reads Programmable's live capabilities and binds the active profile (3.6.0)
and its live platform fee policy (0.3% to 0xD885...79da).

Run it from a clean checkout of the public commit being submitted, right before packing:
the permit window it writes is valid for one hour.

    python3 launch/build.py --solc /path/to/solc-0.8.26

Reads no private keys and no API keys. Everything below is public launch input.
"""

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "launch" / "build"
PUBLIC_REPO = "https://github.com/Razaellweb/infera-contracts"

# ---- Ethereum Mainnet bindings
POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90"
GRAPH_FACTORY = "0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887"  # Programmable: deploys the graph, calls initialize
NATIVE_ETH = "0x0000000000000000000000000000000000000000"
PROGRAMMABLE_RECIPIENT = "0xD88539d3c4C460136a733A3Fd60cf6BF269079da"

# ---- Owner-approved launch parameters
LAUNCH_WALLET = "0x1F9c16370fAdd58A05D87C685488Ef556d2DE7be"  # signs the launch; also the hook owner
TEAM = "0xBB4dEA1A372EBCA201c1cD140Cd21bC42E33095A"
BUYBACKS = "0x3835872Ea6EbE568769BabB3ba77147C4789A3FD"
COMPUTE = "0x4db6dF81fd2aDC898BF3af1D01E518E8ce23F83f"
NAME, SYMBOL = "Infera", "INFERA"
SUPPLY = str(1_000_000_000 * 10**18)
LP_FEE, TICK_SPACING = 3000, 60
START_TICK = 187_320  # ~136.4M INFERA per ETH: USD 15,087 FDV at USD 2,057.77/ETH (Chainlink, 2026-11-11)
FIRST_BUY_WEI = str(4_859_637_193_736_836)  # USD 10 at USD 2,057.77/ETH
FIRST_BUY_MIN_OUT = str(638_772_128_058_338_499_105_724)  # 99% of the 645,224.37 INFERA it returns
INFERA_FEE_HUNDREDTHS_OF_BIP = "20000"  # 2% on buys and sells, on top of Programmable's 0.3%

DESCRIPTION = "Inference infrastructure to power agents at scale."
IMAGE_PATH = "assets/infera-logo.jpg"
LINKS = [
    {"kind": "website", "uri": "https://inferacompute.xyz"},
    {"kind": "x", "uri": "https://x.com/inferaHQ_"},
]

ENTRYPOINTS = ["src/InferaToken.sol", "src/InferaEthHook.sol", "src/InferaLaunchInitializer.sol"]
REMAP = {"@uniswap/v4-core/": "lib/v4-core/"}
SETTINGS = {
    "optimizer": {"enabled": True, "runs": 10_000},
    "evmVersion": "cancun",
    "viaIR": False,
    "metadata": {"bytecodeHash": "none", "appendCBOR": False},
    "outputSelection": {
        "*": {"*": ["abi", "evm.bytecode", "evm.deployedBytecode", "metadata"], "": ["ast"]},
    },
}


def fail(message):
    sys.exit(f"build.py: {message}")


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True, text=True).stdout.strip()


def source_file(unit):
    for prefix, path in REMAP.items():
        if unit.startswith(prefix):
            return ROOT / (path + unit[len(prefix):])
    return ROOT / unit


def collect_sources():
    """The entrypoints and everything they import, keyed by import path."""
    sources, pending = {}, list(ENTRYPOINTS)
    pattern = re.compile(r'^\s*import\s+(?:[^;]*?\sfrom\s+)?["\']([^"\']+)["\']\s*;', re.M)
    while pending:
        unit = pending.pop()
        if unit in sources:
            continue
        content = source_file(unit).read_text()
        sources[unit] = {"content": content}
        for spec in pattern.findall(content):
            imported = os.path.normpath(os.path.join(os.path.dirname(unit), spec)) if spec.startswith(".") else spec
            if imported not in sources:
                pending.append(imported)
    return dict(sorted(sources.items()))


def immutables(output, contract, mapping):
    """Maps every immutable in `contract`'s runtime code to a literal or a graph target."""
    names = {}

    def walk(node):
        if isinstance(node, dict):
            if node.get("nodeType") == "VariableDeclaration" and node.get("mutability") == "immutable":
                names[str(node["id"])] = node["name"]
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    for source in output["sources"].values():
        walk(source["ast"])
    refs = contract["evm"]["deployedBytecode"].get("immutableReferences", {})
    result = []
    for immutable_id in sorted(refs, key=int):
        name = names[immutable_id]
        if name not in mapping:
            fail(f"unmapped immutable {name}; refusing to guess its runtime value")
        result.append({"immutableId": immutable_id, **mapping[name]})
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--solc", required=True, help="path to solc 0.8.26+commit.8a97fa7a")
    parser.add_argument("--allow-dirty", action="store_true", help="local rehearsal only; never for submission")
    args = parser.parse_args()

    version = subprocess.run([args.solc, "--version"], check=True, capture_output=True, text=True).stdout
    if "0.8.26+commit.8a97fa7a" not in version:
        fail("solc must be exactly 0.8.26+commit.8a97fa7a")
    revision = git("rev-parse", "HEAD")
    if git("status", "--porcelain", "--untracked-files=no") and not args.allow_dirty:
        fail("commit everything first: the package must match a public commit")

    standard_json = {"language": "Solidity", "sources": collect_sources(), "settings": SETTINGS}
    compiled = subprocess.run(
        [args.solc, "--standard-json"], input=json.dumps(standard_json), check=True, capture_output=True, text=True
    )
    output = json.loads(compiled.stdout)
    errors = [e for e in output.get("errors", []) if e["severity"] == "error"]
    if errors:
        fail("\n".join(e["formattedMessage"] for e in errors))
    warnings = [e for e in output.get("errors", []) if e["severity"] == "warning"]
    if warnings:
        fail("compiler warnings:\n" + "\n".join(e["formattedMessage"] for e in warnings))

    (BUILD / "standard-json").mkdir(parents=True, exist_ok=True)
    (BUILD / "artifacts").mkdir(parents=True, exist_ok=True)
    (BUILD / "standard-json" / "infera.json").write_text(json.dumps(standard_json, indent=2) + "\n")

    contracts = {
        "token": output["contracts"]["src/InferaToken.sol"]["InferaToken"],
        "hook": output["contracts"]["src/InferaEthHook.sol"]["InferaEthHook"],
        "initializer": output["contracts"]["src/InferaLaunchInitializer.sol"]["InferaLaunchInitializer"],
    }
    for target_id, contract in contracts.items():
        artifact = {k: contract[k] for k in ("abi", "metadata")}
        artifact["bytecode"] = contract["evm"]["bytecode"]
        artifact["deployedBytecode"] = contract["evm"]["deployedBytecode"]
        (BUILD / "artifacts" / f"{target_id}.json").write_text(json.dumps(artifact, indent=2) + "\n")

    def lit(abi_type, value):
        return {"abiType": abi_type, "literal": value}

    def target_common(target_id, salt, kind):
        return {
            "targetId": target_id,
            "compilationUnitId": "infera-solc-0.8.26",
            "artifact": f"launch/build/artifacts/{target_id}.json",
            "applicantSalt": salt,
            "deploymentValueWei": "0",
            "componentKind": kind,
        }

    for evidence in ("forge-test.txt", "fork-test.txt"):
        if not (BUILD / "evidence" / evidence).is_file():
            fail(f"missing launch/build/evidence/{evidence}: run the test suites first (see launch/README.md)")

    now = int(time.time())
    config = {
        "schemaVersion": "programmable.launch-pack-config.v3",
        "launchWallet": LAUNCH_WALLET,
        "chainId": "1",
        "nonce": "0x" + secrets.token_hex(32),
        "source": {
            "root": ".",
            "paths": ["assets", "foundry.toml", "launch/build.py", "remappings.txt", "src"],
            "sourceLineageNonce": "1",
            "publicOrigin": {"url": PUBLIC_REPO, "revision": revision},
        },
        "compilationUnits": [
            {"compilationUnitId": "infera-solc-0.8.26", "standardJson": "launch/build/standard-json/infera.json"}
        ],
        "targets": [
            {
                **target_common("initializer", "0x" + "01" * 32, "other"),
                "constructorArguments": [POOL_MANAGER, GRAPH_FACTORY],
                "initializer": {
                    "function": "initialize",
                    "arguments": [
                        {"target": "hook"},
                        {"target": "token"},
                        START_TICK,
                        LAUNCH_WALLET,
                        FIRST_BUY_MIN_OUT,
                    ],
                },
                "initializerValueWei": FIRST_BUY_WEI,
                "declaredHookPermissions": None,
                "runtimeImmutables": immutables(
                    output,
                    contracts["initializer"],
                    {"poolManager": lit("address", POOL_MANAGER), "launcher": lit("address", GRAPH_FACTORY)},
                ),
            },
            {
                **target_common("token", "0x" + "02" * 32, "token"),
                "constructorArguments": [NAME, SYMBOL, SUPPLY, {"target": "initializer"}],
                "initializer": None,
                "initializerValueWei": "0",
                "declaredHookPermissions": None,
                "runtimeImmutables": immutables(output, contracts["token"], {"totalSupply": lit("uint256", SUPPLY)}),
            },
            {
                **target_common(
                    "hook", {"mode": "deterministic-hook-permission-grind-v1", "start": "0", "maxAttempts": "262144"}, "hook"
                ),
                "constructorArguments": [
                    POOL_MANAGER,
                    {"target": "token"},
                    LP_FEE,
                    TICK_SPACING,
                    LAUNCH_WALLET,
                    TEAM,
                    BUYBACKS,
                    COMPUTE,
                ],
                "initializer": None,
                "initializerValueWei": "0",
                "declaredHookPermissions": ["beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"],
                "runtimeImmutables": immutables(
                    output,
                    contracts["hook"],
                    {
                        "poolManager": lit("address", POOL_MANAGER),
                        "infera": {"abiType": "address", "target": "token"},
                        "lpFee": lit("uint24", str(LP_FEE)),
                        "tickSpacing": lit("int24", str(TICK_SPACING)),
                    },
                ),
            },
        ],
        "pool": {
            "tokenTargetId": "token",
            "hookTargetId": "hook",
            "fee": LP_FEE,
            "tickSpacing": TICK_SPACING,
            "quoteCurrency": NATIVE_ETH,
        },
        "projectMetadata": {
            "schemaVersion": "programmable.project-metadata-input.v1",
            "token": {"name": NAME, "symbol": SYMBOL},
            "presentation": {
                "description": DESCRIPTION,
                "image": {
                    "sourcePath": IMAGE_PATH,
                    "uri": f"https://raw.githubusercontent.com/Razaellweb/infera-contracts/{revision}/{IMAGE_PATH}",
                },
                "links": LINKS,
            },
        },
        "launchProfile": {
            "schemaVersion": "programmable.direct-native-hook-graph-profile-selection.v3",
            "profileId": "programmable.direct-native-hook-graph.v1",
            "profileRevision": 3,
            "targetRoles": {
                "tokenTargetId": "token",
                "hookTargetId": "hook",
                "initializerTargetId": "initializer",
                "platformFeeBindingTargetId": "hook",
            },
            "liquidityModel": {
                "schemaVersion": "programmable.direct-native-liquidity-model-intent.v1",
                "model": "launch-seeded-concentrated-liquidity",
                "declaredLaunchState": "assessment_required",
                "liquidityTargetId": "initializer",
                "assessment": {
                    "schemaVersion": "programmable.direct-native-liquidity-model-assessment.v1",
                    "status": "required",
                    "requestClaimsExecution": False,
                    "requiredVectorIds": [
                        "liquidity.seeded.pool-active-liquidity",
                        "liquidity.seeded.position-custody-and-withdrawal",
                        "liquidity.seeded.buy-and-sell",
                    ],
                },
            },
            "fundingMode": "wallet-transaction-value",
            "accountingMode": "additive-platform-share",
            "assessmentBase": "executed-gross-declared-quote",
            "feeCurrency": "declared-quote-currency",
            "claimMode": "immutable-payout-recipient",
            "payoutRecipient": PROGRAMMABLE_RECIPIENT,
            "applicantSelectedBuyHundredthsOfBip": INFERA_FEE_HUNDREDTHS_OF_BIP,
            "applicantSelectedSellHundredthsOfBip": INFERA_FEE_HUNDREDTHS_OF_BIP,
        },
        "permitWindow": {"validAfter": str(now - 60), "deadline": str(now + 3_540)},
        "agentAttestation": {
            "agentId": "infera-launch-build",
            "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
            "checks": [
                {"checkId": "foundry-test-suite", "evidence": "launch/build/evidence/forge-test.txt"},
                {"checkId": "mainnet-fork-launch", "evidence": "launch/build/evidence/fork-test.txt"},
            ],
        },
    }
    (ROOT / "programmable-launch.config.json").write_text(json.dumps(config, indent=2) + "\n")
    print(json.dumps({"revision": revision, "config": "programmable-launch.config.json", "targets": 3}))


if __name__ == "__main__":
    main()
