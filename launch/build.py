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
import math
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
ETH_USD_FEED = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"  # Chainlink ETH/USD
ETH_USD_FEED_CODE_HASH = "0x4b79b5c8aee6da0f7b393e8b53e6265ef7320a1d16184c65bd3841b5aa3d700d"
ETH_USD_FEED_DECIMALS, MAX_FEED_AGE = 8, 3600  # what the initializer reads and sets on Mainnet
UNIVERSAL_ROUTER = "0xd92A36B0000531EF3063dEd4De20A0783308446C"  # identifies buyers during protection
UNIVERSAL_ROUTER_CODE_HASH = "0x41ccd905c8e4de29ce9536ff49233b79e3085a0987d490664e703ee1e7b1dc49"
ZERO = "0x0000000000000000000000000000000000000000"

# ---- Owner-approved launch parameters
LAUNCH_WALLET = "0x1F9c16370fAdd58A05D87C685488Ef556d2DE7be"  # signs the launch; also the hook owner
TEAM = "0xBB4dEA1A372EBCA201c1cD140Cd21bC42E33095A"
BUYBACKS = "0x3835872Ea6EbE568769BabB3ba77147C4789A3FD"
COMPUTE = "0x4db6dF81fd2aDC898BF3af1D01E518E8ce23F83f"
NAME, SYMBOL = "Infera", "INFERA"
SUPPLY = str(1_000_000_000 * 10**18)
LP_FEE, TICK_SPACING = 3000, 60
WALLET_TOKEN_LIMIT = str(1_000_000_000 * 10**18 * 200 // 10_000)  # 2% of supply
# The opening price is set for this valuation at the ETH/USD price given to --eth-usd-8dp. Programmable's
# floor is USD 15,000 at the moment of launch, checked against the live feed; the margin above it
# absorbs ETH falling between packing and the launch (review plus the 24-hour signing window).
OPENING_FDV_USD = 20_000
FIRST_BUY_USD = 10
FIRST_BUY_MIN_OUT_BPS = 9_800  # the first buy may return no less than 98% of its estimate
INFERA_FEE_HUNDREDTHS_OF_BIP = "20000"  # 2% on buys and sells, on top of Programmable's 0.3%

DESCRIPTION = "Inference infrastructure to power agents at scale."
IMAGE_PATH = "assets/infera-logo.jpg"
LINKS = [
    {"kind": "website", "uri": "https://inferacompute.xyz/"},
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


Q96 = 1 << 96


def sqrt_price_at_tick(tick):
    """Uniswap's TickMath.getSqrtPriceAtTick, exactly."""
    abs_tick = abs(tick)
    ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if abs_tick & 0x1 else 0x100000000000000000000000000000000
    for bit, mul in [
        (0x2, 0xfff97272373d413259a46990580e213a), (0x4, 0xfff2e50f5f656932ef12357cf3c7fdcc),
        (0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0), (0x10, 0xffcb9843d60f6159c9db58835c926644),
        (0x20, 0xff973b41fa98c081472e6896dfb254c0), (0x40, 0xff2ea16466c96a3843ec78b326b52861),
        (0x80, 0xfe5dee046a99a2a811c461f1969c3053), (0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4),
        (0x200, 0xf987a7253ac413176f2b074cf7815e54), (0x400, 0xf3392b0822b70005940c7a398e4b70f3),
        (0x800, 0xe7159475a2c29b7443b29c7fa6e889d9), (0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825),
        (0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5), (0x4000, 0x70d869a156d2a1b890bb3df62baf32f7),
        (0x8000, 0x31be135f97d08fd981231505542fcfa6), (0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9),
        (0x20000, 0x5d6af8dedb81196699c329225ee604), (0x40000, 0x2216e584f5fa1ea926041bedfe98),
        (0x80000, 0x48a170391f7dc42444e8fa2),
    ]:
        if abs_tick & bit:
            ratio = (ratio * mul) >> 128
    if tick > 0:
        ratio = ((1 << 256) - 1) // ratio
    return (ratio >> 32) + (0 if ratio % (1 << 32) == 0 else 1)


def opening(eth_usd_8dp):
    """Opening tick, first-buy ETH, its minimum INFERA out, and the INFERA it is expected to return."""
    supply = 1_000_000_000 * 10**18
    # INFERA per ETH = supply * (USD per ETH) / FDV. The tick is rounded down to a multiple of 60,
    # which means fewer INFERA per ETH: the valuation lands at or just above the target.
    price = 1_000_000_000 * eth_usd_8dp / (OPENING_FDV_USD * 10**8)
    tick = int(math.floor(math.log(price) / math.log(1.0001)))
    tick -= tick % TICK_SPACING
    while sqrt_price_at_tick(tick) ** 2 * 10**8 * OPENING_FDV_USD > 1_000_000_000 * eth_usd_8dp * (1 << 192):
        tick -= TICK_SPACING
    first_buy = FIRST_BUY_USD * 10**18 * 10**8 // eth_usd_8dp
    # The first buy (the developer's: no opening tax) pays 2% to Infera (rounded down) and 0.3% to
    # Programmable (rounded up), then the pool's 0.3% LP fee, against the single-sided position.
    fees = first_buy * 200 // 10_000 + -(-first_buy * 30 // 10_000)
    amount_in = (first_buy - fees) * (1_000_000 - LP_FEE) // 1_000_000
    sqrt_upper, sqrt_lower = sqrt_price_at_tick(tick), sqrt_price_at_tick(-887_220)
    liquidity = supply * Q96 // (sqrt_upper - sqrt_lower)
    sqrt_next = liquidity * Q96 * sqrt_upper // (liquidity * Q96 + amount_in * sqrt_upper)
    expected = liquidity * (sqrt_upper - sqrt_next) // Q96
    return tick, first_buy, expected * FIRST_BUY_MIN_OUT_BPS // 10_000, expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--solc", required=True, help="path to solc 0.8.26+commit.8a97fa7a")
    parser.add_argument(
        "--eth-usd-8dp", type=int, required=True, help="Chainlink ETH/USD latestRoundData answer (8 decimals)"
    )
    parser.add_argument("--allow-dirty", action="store_true", help="local rehearsal only; never for submission")
    args = parser.parse_args()
    start_tick, first_buy_wei, first_buy_min_out, expected_out = opening(args.eth_usd_8dp)

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
                "constructorArguments": [POOL_MANAGER, GRAPH_FACTORY, ETH_USD_FEED, ETH_USD_FEED_CODE_HASH],
                "initializer": {
                    "function": "initialize",
                    "arguments": [
                        {"target": "hook"},
                        {"target": "token"},
                        start_tick,
                        LAUNCH_WALLET,
                        str(first_buy_min_out),
                    ],
                },
                "initializerValueWei": str(first_buy_wei),
                "declaredHookPermissions": None,
                "runtimeImmutables": immutables(
                    output,
                    contracts["initializer"],
                    {
                        "poolManager": lit("address", POOL_MANAGER),
                        "launcher": lit("address", GRAPH_FACTORY),
                        "ethUsdFeed": lit("address", ETH_USD_FEED),
                        "feedCodeHash": lit("bytes32", ETH_USD_FEED_CODE_HASH),
                        "feedDecimals": lit("uint8", str(ETH_USD_FEED_DECIMALS)),
                        "maxFeedAge": lit("uint256", str(MAX_FEED_AGE)),
                    },
                ),
            },
            {
                **target_common("token", "0x" + "02" * 32, "token"),
                "constructorArguments": [NAME, SYMBOL, SUPPLY, {"target": "initializer"}, POOL_MANAGER],
                "initializer": None,
                "initializerValueWei": "0",
                "declaredHookPermissions": None,
                "runtimeImmutables": immutables(
                    output,
                    contracts["token"],
                    {
                        "totalSupply": lit("uint256", SUPPLY),
                        "initializer": {"abiType": "address", "target": "initializer"},
                        "poolManager": lit("address", POOL_MANAGER),
                        "walletTokenLimit": lit("uint256", WALLET_TOKEN_LIMIT),
                    },
                ),
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
                    [LAUNCH_WALLET, TEAM, BUYBACKS, COMPUTE],  # Recipients: owner, team, buybacks, compute
                    # Protection: initializer, developer, router, router code hash, no extra tax-exempt wallets
                    [{"target": "initializer"}, LAUNCH_WALLET, UNIVERSAL_ROUTER, UNIVERSAL_ROUTER_CODE_HASH, [ZERO] * 6],
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
                        "initializer": {"abiType": "address", "target": "initializer"},
                        "developer": lit("address", LAUNCH_WALLET),
                        "router": lit("address", UNIVERSAL_ROUTER),
                        "routerCodeHash": lit("bytes32", UNIVERSAL_ROUTER_CODE_HASH),
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
            "checkedAt": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(now)),
            "checks": [
                {"checkId": "foundry-test-suite", "evidence": "launch/build/evidence/forge-test.txt"},
                {"checkId": "mainnet-fork-launch", "evidence": "launch/build/evidence/fork-test.txt"},
            ],
        },
    }
    (ROOT / "programmable-launch.config.json").write_text(json.dumps(config, indent=2) + "\n")
    print(
        json.dumps(
            {
                "revision": revision,
                "config": "programmable-launch.config.json",
                "targets": 3,
                "startTick": start_tick,
                "openingFdvUsdTarget": OPENING_FDV_USD,
                "firstBuyWei": str(first_buy_wei),
                "firstBuyExpectedInfera": str(expected_out),
                "firstBuyMinOut": str(first_buy_min_out),
            }
        )
    )


if __name__ == "__main__":
    main()
