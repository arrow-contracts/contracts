# Arrow — smart contracts

Arrow is a bonding-curve memecoin launchpad. This repo is the full Solidity
source for every contract Arrow deploys, published so anyone — a wallet, an
aggregator, a curious holder — can read the code directly instead of taking
our word for it.

## What's fixed, forever, at launch

Every token Arrow launches is deployed with these rules baked into the
bytecode. None of them can be changed after deployment — not by the creator,
not by us.

- **1,000,000,000 fixed supply.** No `mint` function exists anywhere in the
  token contract.
- **2% transfer tax, permanently.** 1% to the token's creator, 1% to the
  platform, on every transfer — including trades on Uniswap after migration.
  Both cuts are claimable by their recipients, never auto-swept anywhere.
- **3% max wallet cap, forever.** Cumulative across transactions, enforced in
  `_update` on every transfer, including post-migration DEX trades.
- **30-second sniper shield.** The buy fee starts at 99% and decays linearly
  to the permanent 2% floor over 30 seconds. The surcharge isn't collected by
  anyone — it stays in the bonding curve as extra backing.
- **Automatic migration.** Once the curve collects its target amount, it
  pairs the token against the quote asset on Uniswap V2 in the same
  transaction and burns the LP token to `0x…dEaD`. No one can pull that
  liquidity back out.
- **Creator-fee reassignment.** The creator can hand off their 1% cut to a
  new address at any time. The platform owner can do the same for a single
  token (a "CTO" override for abandoned projects) — this never touches the
  2% rate itself, only who receives the creator's half.

## Contracts

| File | What it is |
|---|---|
| `src/ArrowToken.sol` | The ERC20 token — tax, cap, and shield logic (native-quote chains). |
| `src/ArrowBondingCurve.sol` | Constant-product bonding curve, quoted in the chain's native ETH. |
| `src/ArrowFactory.sol` | Launches a token + curve pair in one transaction. |
| `src/deployers/` | Tiny helper contracts that split up `new` calls to stay under the EIP-170 24576-byte contract size limit. |
| `src/interfaces/` | External interfaces (Uniswap V2, the factory). |
| `src/ArrowBondingCurveStable.sol`, `ArrowFactoryStable.sol` | Same rules, for chains that quote in an ERC20 stablecoin instead of native ETH. |
| `src/tempo/` | Clone-based variant (`ArrowTokenClone`, `ArrowBondingCurveCloneStable`, `ArrowFactoryStableClone`) built for Tempo specifically — see the docs in that folder for why. |
| `src/hyperevm/` | Clone-based variant for HyperEVM (`ArrowBondingCurveClone`, `ArrowFactoryClone`) — reuses `tempo/ArrowTokenClone` as-is. Different reason than Tempo's: HyperEVM's real block gas limit is only 3,000,000 gas, and a from-scratch `createTokenAndBuy` measured at 3,029,241 gas, just over it, so no launch could ever be mined. Cloning both contracts instead of deploying their full bytecode brings it to ~695k–861k gas. |
| `test/` | Foundry test suites, run against live mainnet forks of each chain — not mocks of Uniswap or the RPC. |
| `script/` | Deploy scripts for every chain variant. |

## Deployments

Every address below is verifiable on-chain: `factory.owner()`, `router.factory()`,
`token.totalSupply()`, etc. all read directly against these addresses.

### Robinhood Chain (chain ID 4663)
- Factory: `0xC134185838620B7965a8980222Fe0562482a9ce6`
- Uniswap V2 Router: `0x89e5DB8B5aA49aA85AC63f691524311AEB649eba`

### Arbitrum One (chain ID 42161)
- Factory: `0xf4F149383c5099A2D3d42F729700A4Eb479606c7`
- Uniswap V2 Router: `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24`

### Tempo (chain ID 4217)
- Factory: `0x5bDbc5bAfe4Fd5fe0cd3AA8701fCb4E60465B93c`
- Token implementation (cloned per launch): `0x1cB3CbE683edB46027f55D88f3401e3275f88262`
- Curve implementation (cloned per launch): `0x7b5F870592aF11cB57456Cb0093895d0F8fdD048`
- Uniswap V2 Router: `0x0FBac3c46F6F83B44C7fb4EA986d7309C701D73E`
- Quote asset (pathUSD): `0x20C0000000000000000000000000000000000000`

### HyperEVM (chain ID 999)
- Factory: `0xC134185838620B7965a8980222Fe0562482a9ce6`
- Token implementation (cloned per launch): `0xADA3421EE6378501edCaf03Fb33a51ACD48282b4`
- Curve implementation (cloned per launch): `0xC326AB4542C05FDa4ce7D021DCfe42dd25C59C37`
- Uniswap V2 Router: `0xb4a9C4e6Ea8E2191d2FA5B380452a634Fb21240A`
- Quote asset: native HYPE
- Note: an earlier, non-clone factory was deployed at `0xf4F149383c5099A2D3d42F729700A4Eb479606c7`.
  It was never usable — `createTokenAndBuy` needed 3,029,241 gas against a real
  3,000,000 block gas limit, so every launch attempt reverted before ever
  reaching a block (`allTokensLength() == 0`). Replaced by the clone factory
  above; the old address is dead and should be ignored.

### Base (chain ID 8453)
- Factory: `0xC134185838620B7965a8980222Fe0562482a9ce6`
- Uniswap V2 Router: `0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24`

### BNB Chain (chain ID 56)
- Factory: `0xf4F149383c5099A2D3d42F729700A4Eb479606c7`
- Router: `0x10ED43C718714eb63d5aA57B78B54704E256024E` (PancakeSwap V2 — the
  dominant V2-compatible AMM on BNB Chain; same `IUniswapV2Router02`
  interface as everywhere else)
- Quote asset: native BNB

## Building and testing

Dependencies (OpenZeppelin, forge-std) aren't vendored in this repo — install
them with Foundry:

```bash
forge install foundry-rs/forge-std
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.7.0
forge build
forge test
```

The test suites fork each chain's real mainnet RPC and exercise the actual
deployed Uniswap V2 router — not a mock — including the full migration and
LP-burn path.

## License

MIT
