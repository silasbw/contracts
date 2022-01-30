import { DeployerFn } from '@ubeswap/hardhat-celo';
import {ContractFactory} from "ethers";
// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// When running the script with `npx hardhat run <script>` you'll find the Hardhat
// Runtime Environment's members available in the global scope.
// import { ethers } from "hardhat";

const ALFAJORES_ADDRESS = "0x642abB1237009956BB67d0B174337D76F0455EDd" // Owner
const STAKING_REWARDS_ADDRESS = "0x734913751D7390c32410eD2c71Bb1d8210d7570B" // StakingRewards
const ROUTER_ADDRESS = "0xE3D8bd6Aed4F159bc8000a9cD47CffDb95F96121" // Ubeswap Router
const path0: string[] = [] // path0 should be empty since token0 == rewardsToken == cUSD
const path1 = [
  "0x874069fa1eb16d44d622f2e0ca25eea172369bc1", // cUSD
  "0xf194afdf50b03e69bd7d057c1aa9e10c9954e4c9"  // CELO
]

export const main: DeployerFn<{}> = async ({
  deployCreate2,
  deployer,
  provider
}) => {
  provider
  const args = [
    ALFAJORES_ADDRESS, STAKING_REWARDS_ADDRESS, ROUTER_ADDRESS, path0, path1, 'cUSD_CELO_FP'
  ]
  const farmBot = await deployCreate2('FarmBot_2', {
    //@ts-ignore -- we could use a typechain-generated type here, but that introduces a circular dependency (need to compile contracts before typechain's types exist/update, but types must exist/update before this will compile properly...). Particularly hard to fix here because this module is imported by hardhat config, which is always loaded first (so a post-install step wont help here)
    factory: ContractFactory,
    signer: deployer,
    //@ts-ignore -- see above
    args,
  })

  return {
    FarmBot: farmBot.address
  }
}
