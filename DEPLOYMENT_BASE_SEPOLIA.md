# SteadyStake Deployment - Base Sepolia

## Deployment Date
Deployed on: $(date)

## Network Information
- **Network**: Base Sepolia Testnet
- **Chain ID**: 84532
- **RPC URL**: https://sepolia.base.org
- **Block Explorer**: https://sepolia.basescan.org

## Deployed Contracts

### Core Contracts

#### DCAVault
- **Address**: `0xe9e2F8F23CAfbF517B6Ca077fa88E12458b670E5`
- **Explorer**: https://sepolia.basescan.org/address/0xe9e2F8F23CAfbF517B6Ca077fa88E12458b670E5
- **Status**: ✅ Verified

#### DCAResolver
- **Address**: `0xA24259726659A19F13Ff8b07A756D74C1c658404`
- **Explorer**: https://sepolia.basescan.org/address/0xA24259726659A19F13Ff8b07A756D74C1c658404
- **Status**: ✅ Verified

### Mock Contracts (For Testing)

#### MockSwapRouter
- **Address**: `0x037Abdb1904CC2894a2Ca1d54b3E267A4B6f0d67`
- **Explorer**: https://sepolia.basescan.org/address/0x037Abdb1904CC2894a2Ca1d54b3E267A4B6f0d67
- **Status**: ✅ Verified

#### MockUSDC
- **Address**: `0x74C0cdB54B5bEB5fCf1073B8f1f6c583381c44D6`
- **Explorer**: https://sepolia.basescan.org/address/0x74C0cdB54B5bEB5fCf1073B8f1f6c583381c44D6
- **Status**: ✅ Verified

#### MockAERO
- **Address**: `0x3AF7Fc5E3305aaada45833a1C4dF6201222C489B`
- **Explorer**: https://sepolia.basescan.org/address/0x3AF7Fc5E3305aaada45833a1C4dF6201222C489B
- **Status**: ✅ Verified

#### MockDEGEN
- **Address**: `0x6D5c158E55339365C5456a49804973cB260076bA`
- **Explorer**: https://sepolia.basescan.org/address/0x6D5c158E55339365C5456a49804973cB260076bA
- **Status**: ✅ Verified

#### MockCBETH
- **Address**: `0x49DF0bb77d8F92e69A823AE1d53521306deB97ea`
- **Explorer**: https://sepolia.basescan.org/address/0x49DF0bb77d8F92e69A823AE1d53521306deB97ea
- **Status**: ✅ Verified

## Configuration

### DCAVault Configuration
- **Swap Router**: `0x037Abdb1904CC2894a2Ca1d54b3E267A4B6f0d67`
- **USDC Token**: `0x74C0cdB54B5bEB5fCf1073B8f1f6c583381c44D6`
- **Fee Percentage**: 0.25% (25 basis points)
- **Max Fee**: 5% (500 basis points)
- **Early Cancel Fee**: 3% (300 basis points)

### DCAResolver Configuration
- **Vault Address**: `0xe9e2F8F23CAfbF517B6Ca077fa88E12458b670E5`

## Test Tokens Minted
The deployer address has been minted the following test tokens:
- 10,000 USDC (MockUSDC)
- 10,000 AERO (MockAERO)
- 10,000 DEGEN (MockDEGEN)
- 100 CBETH (MockCBETH)

## Next Steps

1. **Update Frontend Configuration**
   - Update `frontend/config/contracts.ts` with the new contract addresses
   - Update `frontend/config/abis.ts` if ABIs have changed

2. **Test the Deployment**
   ```bash
   # Create a test DCA schedule
   cast send 0xe9e2F8F23CAfbF517B6Ca077fa88E12458b670E5 \
     "createSchedule(address,uint8,uint256,uint256)" \
     0x3AF7Fc5E3305aaada45833a1C4dF6201222C489B 1 1000000 10000000 \
     --rpc-url https://sepolia.base.org \
     --private-key $PRIVATE_KEY
   ```

3. **Setup Gelato Automation**
   - Create a Gelato task pointing to the DCAResolver
   - Configure the task to check schedules periodically

4. **Monitor Contracts**
   - Watch for events on the DCAVault contract
   - Monitor gas usage and execution costs

## Important Notes

⚠️ **Security Reminders**:
- These are testnet contracts for development and testing only
- Do not use real funds on testnet
- The private key in `.env.local` should be for testnet only
- Never commit private keys to version control

## Verification Status

All contracts have been successfully verified on Basescan and are ready for interaction through the block explorer or programmatically.

## Contract Interactions

You can interact with the contracts using:
- **Basescan UI**: Visit the contract addresses above
- **Cast CLI**: Use Foundry's cast tool
- **Frontend**: Use the Next.js frontend application
- **Ethers.js/Web3.js**: Direct contract interaction

## Support

For issues or questions:
- Check the contract code in `contracts/src/`
- Review the deployment script in `contracts/script/Deploy.s.sol`
- See documentation in `contracts/README.md`
