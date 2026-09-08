# yeet-launchpad-evm

Contracts for yeet.family on Arc (USDC-native L1). Foundry, Solidity 0.8.26, Uniswap v4.

| Contract | Role |
|---|---|
| `YeetLaunchpad` | singleton: create tokens, run every bonding curve in native USDC, 0.3% protocol fee + USDC dividend on every trade, atomic graduation |
| `YeetToken` | plain ERC-20 (1B fixed, no owner/mint/pause) + USDC dividend ledger (`claimable`, `claim`) |
| `YeetHook` | Uniswap v4 hook on every graduated pool: takes protocol fee + dividend from the USDC side of every swap, any router |
| `YeetGraduator` | initialises the v4 pool (native USDC / token, fee 0, hook) and seeds a permanently locked full-range position |
| `YeetRouter` | buy / sell / exact `quote` for the UI |
| `libraries/CurveMath` | pump.fun-shaped constant-product curve; params derived so the pool seeds at exactly the curve's final price |

Design and rationale: `yeet-plan/02-contracts.md`.

## Curve (production parameters)

`vUsdc0 = 3,500 USDC`, `target = 10,000 USDC` → 794.1M tokens on the curve, 205.9M into the pool, launch mcap ≈ $3.3k, graduation mcap ≈ $48.6k (14.9×). Parameters are constructor immutables so testnet can also run a **lite** stack (`3.5 / 10 USDC`) for end-to-end testing with the same shape.

## Deployments (Arc testnet, chain 5042002)

`deployments/5042002.json` (production params) and `deployments/5042002-lite.json` (10 USDC graduation). Shared self-deployed v4 `PoolManager`. Backend and frontend read these files.

Smoke-tested on chain (lite): token [`0xc665487F14a256591844EBC35f16a787bCBa5263`](https://testnet.arcscan.app/address/0xc665487F14a256591844EBC35f16a787bCBa5263) — created with 5% dev buy, sold, bought to completion, graduated atomically into v4 pool `0xc742aaf4…8fb1de`, swapped both ways through the router, dividends claimed.

## Develop

```bash
forge build
forge test                       # 31 tests: fuzz curve math, dividend ledger, full curve → graduation, hook fees on all 4 swap shapes
forge test --gas-report
source ../yeet-devops/secrets.env; export ARC_TESTNET_RPC=$TF_VAR_quicknode_http
forge script script/Deploy.s.sol --rpc-url $ARC_TESTNET_RPC --broadcast --slow --gas-estimate-multiplier 150
POOL_MANAGER=<pm> CURVE_V_USDC0=3500000000000000000 CURVE_TARGET=10000000000000000000 DEPLOYMENT_SUFFIX=-lite forge script script/Deploy.s.sol ...
DEPLOYMENTS=deployments/5042002-lite.json forge script script/Smoke.s.sol --rpc-url $ARC_TESTNET_RPC --broadcast --slow
```

Mainnet: `POOL_MANAGER=<official v4 PoolManager> OWNER=<hardware wallet> forge script script/Deploy.s.sol --rpc-url $ARC_MAINNET_RPC --broadcast --slow`; owner then calls `launchpad.initialize(...)` and `hook.acceptOwnership()`.

Arc notes: `eth_estimateGas` is unreliable → always `--gas-estimate-multiplier`; Anvil cannot emulate native USDC, use the testnet RPC for integration.
