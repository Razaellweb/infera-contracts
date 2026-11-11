# INFERA contracts

The INFERA token and its INFERA/ETH Uniswap v4 pool on **Ethereum Mainnet**, launched through
Programmable (programmable.market) as a Custom Launch:

- `src/InferaToken.sol`: the INFERA ERC-20, fixed supply, no owner.
- `src/InferaEthHook.sol`: the pool's hook: fees in ETH and same-block price enforcement.
- `src/InferaLaunchInitializer.sol`: opens the pool in the launch transaction and locks its liquidity.

The pool is native ETH (`currency0`) against INFERA (`currency1`), 0.30% static LP fee, tick spacing 60.

## Fees

Every buy and sell pays a fixed fee **in ETH**, charged on the swap's gross ETH leg: the ETH a buyer
pays in, or the ETH the pool pays out to a seller.

| Bucket | Rate | Recipient |
| --- | --- | --- |
| Team | 1% | `0xBB4dEA1A372EBCA201c1cD140Cd21bC42E33095A` |
| Buybacks | 0.5% | `0x3835872Ea6EbE568769BabB3ba77147C4789A3FD` |
| Compute | 0.5% | `0x4db6dF81fd2aDC898BF3af1D01E518E8ce23F83f` |
| Programmable platform share | 0.3% | `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` (fixed) |

Infera's 2% is split 1 / 0.5 / 0.5 and rounded down; compute takes the rounding dust. Programmable's
0.3% is required on every Ethereum pool buy and sell, rounded up, and comes in addition to Infera's 2%,
so traders pay **2.3% plus the pool's 0.30% LP fee**. INFERA is never taken as a fee.

Example, an exact-input buy of 1 ETH: team 0.01 ETH, buybacks 0.005 ETH, compute 0.005 ETH,
Programmable 0.003 ETH; the remaining 0.977 ETH is swapped for INFERA.

All four swap shapes are charged on the same gross leg:

| Swap | ETH is | Charged in | Trader |
| --- | --- | --- | --- |
| Buy, exact ETH in | specified | `beforeSwap` | pays exactly the ETH given; fees come out of it |
| Sell, exact INFERA in | unspecified | `afterSwap` | receives the ETH paid out minus the fees |
| Buy, exact INFERA out | unspecified | `afterSwap` | pays the swap cost plus fees on top |
| Sell, exact ETH out | specified | `beforeSwap` | receives exactly the ETH asked for; the pool pays the fees on top |

## Payouts

Fees accrue in the hook per bucket (`accrued`). Lifetime totals are kept separately: `collected`
(trading fees), `released` (paid out) and `withheldEth` / `withheldInfera` (same-block price
enforcement, below). For every bucket, `collected + withheld == accrued + released`, where only the
buybacks bucket receives withheld ETH. Anyone can call
`release(bucket)` or `releaseAll()`; ETH only ever goes to the bucket's recipient. A recipient that
rejects ETH keeps its bucket accrued and does not hold up the others or block swaps. The hook only
accepts ETH from the PoolManager, so its balance always equals the sum of `accrued`.

## Owner controls

- `setRecipient(bucket, address)` changes the team, buybacks or compute recipient. Programmable's
  recipient and every rate are constants and cannot be changed.
- `transferOwnership` / `acceptOwnership`: two-step transfer.

The owner is a constructor argument, not `msg.sender`, because CREATE2 deployers and Programmable's
Launch Stamp Router deploy on the owner's behalf. The owner cannot change rates, pause swaps or touch
Programmable's share. Changing a recipient also redirects that bucket's unreleased ETH.

## Same-block price enforcement (anti-sandwich)

Within a block, no swap executes at a better price than the pool had when the block opened. The hook
records the price on the block's first swap (`blockStart()`); nothing else in a block moves it.
Whatever a later swap in the same block would have gained beyond that price is withheld and goes to
buybacks: ETH accrues to the buybacks bucket, INFERA is sent to the buybacks recipient. Each case
emits `BlockStartPriceEnforced`.

The withheld value deliberately does **not** go to liquidity providers. An earlier version donated it
to in-range LPs, and an audit showed the flaw: a sandwicher can add a large just-in-time position
before the back-run and remove it after, recapturing the withheld value and profiting again (about
+12 ETH in `test_jitLiquidityCannotRecaptureWhatTheGuardWithholds` before the fix). A fixed recipient
cannot be positioned into, so the round trip loses.

A same-block sandwich's front-run pays more than the opening price (price impact), and its back-run
can exit at the opening price at best, so the round trip always loses. The tests show a sandwich
around a 100 ETH buy that clears the 2.3% fees and profits when the back-run is in a later block, and
loses in the same block, with or without JIT liquidity; likewise around a sell.

This is same-block price enforcement, not complete MEV protection:

- The block's first swap sets the anchor and is never constrained. Price impact and the LP fee
  already put it below the opening price, and an attacker who takes that slot is held to the price
  before their own trade for the rest of the block.
- A later swap in the same block is held to the opening price when earlier swaps in that block moved
  the price in its favour, so it can get a slightly worse fill than an unguarded pool would give.
  The difference goes to buybacks.
- **Attacks spread over several blocks are not covered** (pinned by
  `test_crossBlockSandwichIsNotPrevented_knownLimitation`).
- Fees are charged on the price-enforced ETH leg, so Programmable's 0.3% and Infera's 2% are paid on
  what actually leaves or enters the pool.

## Other behaviour to know

- **Rounding.** Programmable's 0.3% rounds up per trade, so on trades of a few hundred wei or less its
  effective rate is above 0.3%. The total never exceeds the trade's ETH leg.
- **Price-limited partial fills.** An exact-input buy that stops early at the trader's own price limit
  still pays fees on the full amount specified: v4 lets a hook take ETH from an exact-input buy only
  before the swap, when the fill size is unknown. Standard routers set no binding limit.
- **Largest single buy.** An exact-input buy's fee is taken from the PoolManager's ETH before the buyer
  settles, so it can be at most the native ETH the PoolManager holds (about 55,000 ETH on Mainnet on
  11 Nov 2026, i.e. buys up to roughly 2.4 million ETH). A larger buy reverts whole.
- **PoolManager.** On Ethereum Mainnet the constructor accepts only the canonical PoolManager
  `0x000000000004444c5dc75cB358380D2e3dE08A90`.
- **Token.** INFERA must be a plain ERC-20. A token with a transfer tax makes payments into the pool
  revert (tested), so it cannot corrupt the hook's accounting, but the pool would not work.

## Launch

Programmable's Launch Stamp Router deploys the token, the hook and `InferaLaunchInitializer` in one
transaction, then its graph factory (the initializer's only allowed caller) calls `initialize` once,
with the launch wallet's first-buy ETH:

1. The pool is initialized at the starting tick: 187,320, about 136.4 million INFERA per ETH, a
   USD 15,087 fully diluted valuation at USD 2,057.77/ETH (11 Nov 2026).
2. The whole supply goes into one position from the lowest usable price up to the starting price, so
   the pool opens holding only INFERA and buyers' ETH builds the other side.
3. The launch wallet's first buy (USD 10 of ETH) runs through the hook and pays its fees like any
   other buy. It reverts the whole launch if it returns less than its reviewed minimum.

The position is **locked permanently**: the initializer owns it and has no function that removes
liquidity. Its earnings (the pool's 0.30% LP fee, in ETH from buys and INFERA from sells) can be
collected by anyone with `collectPoolFees()`, and only go to the hook's current buybacks recipient.

## Layout

| Path | Purpose |
| --- | --- |
| `src/InferaEthHook.sol` | The hook |
| `src/InferaToken.sol` | The INFERA ERC-20: fixed 1,000,000,000 supply minted once to the initializer; no owner, minting, tax, pause or blocklist |
| `src/InferaLaunchInitializer.sol` | Opens the pool in the launch transaction (see Launch) |
| `src/InferaEthConfig.sol` | Ethereum Mainnet values: PoolManager, pool parameters, recipients, permission bits |
| `src/utils/HookMiner.sol` | Finds a CREATE2 salt for an address carrying exactly the hook's permission bits (`0xCC`) |
| `script/DeployInferaEthHook.s.sol` | Deploys the hook at a mined address (Mainnet, testnet or local node) |
| `script/MineHookSalt.s.sol` | Prints a salt, the hook address and the init code for a given CREATE2 deployer |
| `test/InferaEthHook.t.sol` | Tests against a real v4 PoolManager from v4-core, including the audit's adversarial cases |
| `test/InferaLaunch.t.sol` | The full launch: seeding, locking, first buy, trading and pool-fee collection |
| `test/InferaEthHook.invariant.t.sol` | Stateful fuzzing: random swaps, blocks, JIT liquidity, payouts and recipient changes, with the accounting invariants checked after every step |
| `test/InferaEthHook.fork.t.sol` | Deploy script and swaps on the live Mainnet PoolManager; skipped without a fork |

Dependencies are pinned git submodules: `lib/forge-std` (v1.9.4) and `lib/v4-core` (`d153b048`).

## Build and test

Requires [Foundry](https://getfoundry.sh). Solidity `0.8.26+commit.8a97fa7a`, EVM `cancun`,
optimizer 10,000 runs, no via-IR, no CBOR metadata. Compiler and lint warnings in `src/` fail the build.

```bash
git clone --recurse-submodules https://github.com/Razaellweb/infera-contracts
cd infera-contracts
forge build
forge test
forge test --match-path test/InferaEthHook.fork.t.sol --fork-url <ethereum-mainnet-rpc>
```

## Launch on Programmable

The token, hook and initializer are submitted together as a Programmable Custom Launch on Ethereum
Mainnet. `launch/` holds the packaging: it compiles the three contracts with the exact compiler and
writes the Programmable launch config. Nothing in this repository holds a private key or an API key;
the launch wallet signs the final transaction itself.

## Deploying without Programmable (testnets)

The scripts read no environment variables or key files. Pass the signer with Foundry's wallet options
(`--account <keystore>`, `--ledger`, ...):

```bash
forge script script/DeployInferaEthHook.s.sol \
  --sig "run(address,address,address)" <POOL_MANAGER> <INFERA_TOKEN> <OWNER> \
  --rpc-url <rpc> --account <keystore> --broadcast
```
