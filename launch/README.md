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
python3 launch/build.py --solc <path-to-solc-0.8.26>
programmable-launch pack --config programmable-launch.config.json --output launch.json
programmable-launch validate launch.json --config programmable-launch.config.json
```

The permit window in the config lasts one hour, so pack right after building. `launch/build/`,
the config and `launch.json` are generated and not committed. No step needs a private key; the
Programmable API key is read only by `programmable-launch` from the `PROGRAMMABLE_API_KEY`
environment variable, and the launch wallet signs the final transaction itself.
