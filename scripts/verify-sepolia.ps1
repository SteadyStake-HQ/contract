# Verify all Sepolia contracts on Etherscan (chain 11155111).
# From contracts/: .\scripts\verify-sepolia.ps1
# Requires: $env:ETHERSCAN_API_KEY set (https://etherscan.io/apis)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if (-not $env:ETHERSCAN_API_KEY) {
    Write-Error "Set ETHERSCAN_API_KEY (e.g. `$env:ETHERSCAN_API_KEY='YourKey')"
}

$env:KAVASCAN_API_KEY = "dummy"
$env:POLYGONSCAN_API_KEY = "dummy"
$env:BASE_ETHERSCAN_KEY = "dummy"
$env:BSCSCAN_API_KEY = "dummy"

$z = cast abi-encode "constructor(address,address)" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 0xDef1C0ded9bec7F1a1670819833240f027b25EfF
$d = cast abi-encode "constructor(address,address)" 0x8A7DcD7975e44Ad7a6e21a577A573F77C6656742 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238
$r = cast abi-encode "constructor(address)" 0x55a3812b36a4d9F3dc7ce6204A5ae81c3b714f3a
$g = cast abi-encode "constructor(address)" 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

Write-Host "Verifying ZeroExAdapter..."
forge verify-contract 0x8A7DcD7975e44Ad7a6e21a577A573F77C6656742 src/SwapHelper.sol:ZeroExAdapter --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $z --watch
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Verifying DCAVault..."
forge verify-contract 0x55a3812b36a4d9F3dc7ce6204A5ae81c3b714f3a src/DCAVault.sol:DCAVault --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $d --watch
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Verifying DCAResolver..."
forge verify-contract 0x088bC79F8dE6D7BA90EDc96665B5D7917C56cd84 src/DCAResolver.sol:DCAResolver --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $r --watch
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Verifying GasTank..."
forge verify-contract 0x9Ec79EE879b2945e87446Aba08F93Bc50b200461 src/GasTank.sol:GasTank --chain-id 11155111 --compiler-version 0.8.33 --constructor-args $g --watch
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "All four contracts verified on Sepolia."
