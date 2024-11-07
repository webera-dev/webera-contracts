## Webera contracts

This repo contains the Smart Contracts of [Webera Finance](https://www.webera.finance/)

Docs: https://docs.webera.finance/

`Vault.sol`

```
The vault contract that users can deposit/withdraw assets.
It has functions for owner the manage the deposited assets to the strategy.
```

`HoneyBeraBendStrategy.sol`

```
The strategy contract that is responsible for received funds from `Vault` then depositing to yield source (in this case is Bera Bend)
It is derived from `BaseStrategy.sol` and using `TokenizedStrategy.sol` as the main implementation
```

[Deployed contracts of Bera Bend](https://docs.bend.berachain.com/developers/deployed-contracts)

## Installation

Requirements

- forge 0.2.0 (58bf161 2024-11-07T00:20:40.732513260Z)

```shell
# Install dependencies, select foundry.toml
# https://book.getfoundry.sh/projects/soldeer
$ forge soldeer install
# build contracts
$ forge build
```

## Add new libs, solidity contracts, dependencies using Soldeer, a package manager of Foundry

```shell
$ forge soldeer install [URL]
```
