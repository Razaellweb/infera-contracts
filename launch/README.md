# Programmable launch package

`build.py` turns this repository into a Programmable Custom Launch request for Ethereum Mainnet
(profile 3.6.0): it compiles the token, hook and initializer with exactly
`solc 0.8.26+commit.8a97fa7a` and writes `programmable-launch.config.json`. Every launch
parameter is a constant at the top of `build.py`.

Run from a clean checkout of the public commit being submitted:

```bash
mkdir -p launch/build/evidence
forge test > launch/build/evidence/forge-test.txt
forge test --match-path test/InferaEthHook.fork.t.sol --fork-url <ethereum-mainnet-rpc> \
  > launch/build/evidence/fork-test.txt
ETH_USD=$(cast call 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 \
  "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url <ethereum-mainnet-rpc> | sed -n 2p | cut -d' ' -f1)
python3 launch/build.py --solc <path-to-solc-0.8.26> --eth-usd-8dp $ETH_USD
programmable-launch pack --config programmable-launch.config.json --output launch.json
programmable-launch validate launch.json --config programmable-launch.config.json
```

The opening tick is set for `OPENING_FDV_USD` (USD 17,000) at the ETH price passed in, so the launch
still clears Programmable's USD 15,000 floor if ETH falls up to about 11.7% before it happens. After `pack`,
`forge test --match-path test/InferaLaunchPackage.fork.t.sol --fork-url <rpc>` deploys the exact packed
targets at their predicted addresses on a Mainnet fork and runs the packed launch call.

The permit window in the config lasts one hour, so pack right after building. `launch/build/`,
the config and `launch.json` are generated and not committed. No step needs a private key; the
Programmable API key is read only by `programmable-launch` from the `PROGRAMMABLE_API_KEY`
environment variable, and the launch wallet signs the final transaction itself.
