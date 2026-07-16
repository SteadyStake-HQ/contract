#!/usr/bin/env bash
# Verify all Sepolia contracts on Etherscan (chain 11155111).
# From contracts/: ./scripts/verify-sepolia.sh
# Requires: ETHERSCAN_API_KEY set (https://etherscan.io/apis)

set -e
cd "$(dirname "$0")/.."

if [ -z "$ETHERSCAN_API_KEY" ]; then
  echo "Set ETHERSCAN_API_KEY (e.g. export ETHERSCAN_API_KEY=YourKey)"
  exit 1
fi

export KAVASCAN_API_KEY=dummy
export POLYGONSCAN_API_KEY=dummy
export BASE_ETHERSCAN_KEY=dummy
export BSCSCAN_API_KEY=dummy

echo "Verifying ZeroExAdapter..."
forge verify-contract 0x8A7DcD7975e44Ad7a6e21a577A573F77C6656742 src/SwapHelper.sol:ZeroExAdapter --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address,address)" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 0xDef1C0ded9bec7F1a1670819833240f027b25EfF) --watch

echo "Verifying DCAVault..."
forge verify-contract 0x55a3812b36a4d9F3dc7ce6204A5ae81c3b714f3a src/DCAVault.sol:DCAVault --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address,address)" 0x8A7DcD7975e44Ad7a6e21a577A573F77C6656742 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) --watch

echo "Verifying DCAResolver..."
forge verify-contract 0x088bC79F8dE6D7BA90EDc96665B5D7917C56cd84 src/DCAResolver.sol:DCAResolver --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address)" 0x55a3812b36a4d9F3dc7ce6204A5ae81c3b714f3a) --watch

echo "Verifying GasTank..."
forge verify-contract 0x9Ec79EE879b2945e87446Aba08F93Bc50b200461 src/GasTank.sol:GasTank --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $(cast abi-encode "constructor(address)" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238) --watch

echo "All four contracts verified on Sepolia."
