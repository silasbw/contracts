//SPDX-License-Identifier: MIT
pragma solidity >=0.5.0 <0.9.0;

import "hardhat/console.sol";

import "./ubeswap-farming/contracts/StakingRewards.sol";
import "./ubeswap/contracts/uniswapv2/interfaces/IUniswapV2Router02.sol";
import "./ubeswap/contracts/uniswapv2/interfaces/IUniswapV2Pair.sol";
import "./ubeswap-farming/contracts/Owned.sol";
import "./FarmbotERC20.sol";
import "./IRevoBounty.sol";

contract FarmBot is Owned, FarmbotERC20 {
    uint256 public lpTotalBalance; // total number of LP tokens owned by Farm Bot

    StakingRewards public stakingRewards;

    IERC20 public rewardsToken;

    IUniswapV2Pair public stakingToken; // LP that's being staked
    IERC20 public stakingToken0; // LP token0
    IERC20 public stakingToken1; // LP token1

    IUniswapV2Router02 public router; // Router address

    // Paths for swapping; can be updated by owner
    address[] public path0; // Path to use when swapping rewardsToken to token0. If len < 2, we assume rewardsToken == token0
    address[] public path1; // Path to use when swapping rewardsToken to token1. If len < 2, we assume rewardsToken == token1

    // Acceptable slippage when swapping/minting LP; can be updated by owner
    uint256 public slippageNumerator = 99;
    uint256 public slippageDenominator = 100;

    // Configurable bounty contract. Determines the bounty for calling claimRewards on behalf of farm investors.
    //      May issue external reward (e.g. a governance token), plus a small fee on interest earned by FP holders.
    //      Fees should be 0.1% and are guaranteed to be < 4%, the current standard for other protocols.
    IRevoBounty public revoBounty;
    uint256 public maxFeeNumerator = 40;
    uint256 public maxFeeDenominator = 1000;

    modifier ensure(uint deadline) {
        require(deadline >= block.timestamp, 'FarmBot: EXPIRED');
        _;
    }

    constructor(
        address _owner,
        address _stakingRewards,
        address _revoBounty,
        address _router,
        address[] memory _path0,
        address[] memory _path1,
        string memory _symbol
    ) Owned(_owner) {
        stakingRewards = StakingRewards(_stakingRewards);
        rewardsToken = stakingRewards.rewardsToken();
        revoBounty = IRevoBounty(_revoBounty);

        stakingToken = IUniswapV2Pair(address(stakingRewards.stakingToken()));
        stakingToken0 = IERC20(stakingToken.token0());
        stakingToken1 = IERC20(stakingToken.token1());

        path0 = _path0;
        path1 = _path1;
        symbol = _symbol;

        router = IUniswapV2Router02(_router);
    }

    function updateBounty(address _revoBounty) external onlyOwner {
        revoBounty = IRevoBounty(_revoBounty);
    }

    function updatePaths(address[] calldata _path0, address[] calldata _path1) external onlyOwner {
        path0 = _path0;
        path1 = _path1;
    }

    function updateSlippage(uint256 _slippageNumerator, uint256 _slippageDenominator) external onlyOwner {
        slippageNumerator = _slippageNumerator;
        slippageDenominator = _slippageDenominator;
    }

    function getFpAmount(uint256 _lpAmount) public view returns (uint256) {
        if (lpTotalBalance == 0) {
            return _lpAmount;
        } else {
            return _lpAmount * totalSupply / lpTotalBalance;
        }
    }

    function getLpAmount(uint256 _fpAmount) public view returns (uint256) {
        if (totalSupply == 0) {
            return 0;
        } else {
            return _fpAmount * lpTotalBalance / totalSupply;
        }
    }

    function deposit(uint256 _lpAmount) public {
        bool transferSuccess = stakingToken.transferFrom(msg.sender, address(this), _lpAmount);
        require(transferSuccess, "Transfer failed, aborting deposit");

        uint256 _fpAmount = this.getFpAmount(_lpAmount);
        _mint(msg.sender, _fpAmount);
        lpTotalBalance += _lpAmount;
        investInFarm();
    }

    function withdrawAll() public {
        require(balanceOf[msg.sender] > 0, "Cannot withdraw zero balance");
        uint256 _lpAmount = getLpAmount(balanceOf[msg.sender]);
        withdraw(_lpAmount);
    }

    function withdraw(uint256 _lpAmount) public {
        // todo might need a lock on this
        uint256 _fpAmount = this.getFpAmount(_lpAmount);
        require(balanceOf[msg.sender] >= _fpAmount, "Cannot withdraw more than the total balance of the owner");

        uint256 tokenBalance = stakingToken.balanceOf(address(this));
        if (_lpAmount > tokenBalance) {
            stakingRewards.withdraw(_lpAmount - tokenBalance);
        }

        bool transferSuccess = stakingToken.transfer(msg.sender, _lpAmount);
        require(transferSuccess, "Transfer failed, aborting withdrawal");
        _burn(msg.sender, _fpAmount);
        lpTotalBalance -= _lpAmount;
    }

    function investInFarm() private {
        uint256 tokenBalance = stakingToken.balanceOf(address(this));
        require(tokenBalance > 0, "Cannot invest in farm because tokenBalance is 0");
        stakingToken.approve(address(stakingRewards), tokenBalance);
        stakingRewards.stake(tokenBalance);
    }

    // convenience method for anyone considering calling claimRewards (who may want to compare bounty to gas cost)
    function previewBounty() public view returns (TokenAmount[]) {
        uint _leftoverBalance = rewardsToken.balanceOf(address(this));
        uint _interestEarned = stakingRewards.earned(address(this));
        return revoBounty.calculateFeeBounty([TokenAmount(address(rewardsToken), _interestEarned + _leftoverBalance)]);
    }

    function claimRewards(uint deadline) public ensure(deadline) {
        stakingRewards.getReward();
        uint256 tokenBalance = rewardsToken.balanceOf(address(this));

        if (tokenBalance == 0) {
            return;
        }

        TokenAmount feeAmounts = revoBounty.calculateFeeBounty([TokenAmount(address(rewardsToken), tokenBalance)]);
        assert(feeAmounts.length == 1, "Invalid fee amounts, should have size 1 for farm with 1 reward token");
        uint256 feeAmount = feeAmounts[0].amount;
        assert(feeAmount <= maxFeeNumerator * tokenBalance / maxFeeDenominator, "Fees exceed maximum allowed");
        uint256 halfTokens = (tokenBalance - feeAmount) / 2;

        uint256 amountToken0;
        // Figure out best-case scenario amount of token0 we can get and swap
        if (path0.length >= 2) {
            uint[] memory amountsOut = router.getAmountsOut(halfTokens, path0);
            uint amountOut = amountsOut[amountsOut.length - 1];
            rewardsToken.approve(address(router), halfTokens);
            uint[] memory amountsSwapped = router.swapExactTokensForTokens(
                halfTokens,
                amountOut * slippageNumerator / slippageDenominator,
                path0,
                address(this),
                deadline
            );
            amountToken0 = amountsSwapped[amountsSwapped.length - 1];
        } else {
            amountToken0 = halfTokens;
        }

        uint256 amountToken1;
        // Figure out best-case scenario amount of token1 we can get and swap
        if (path1.length >= 2) {
            uint[] memory amountsOut = router.getAmountsOut(halfTokens, path1);
            uint amountOut = amountsOut[amountsOut.length - 1];
            rewardsToken.approve(address(router), halfTokens);
            uint[] memory amountsSwapped = router.swapExactTokensForTokens(
                halfTokens,
                amountOut * slippageNumerator / slippageDenominator,
                path1,
                address(this),
                deadline
            );
            amountToken1 = amountsSwapped[amountsSwapped.length - 1];
        } else {
            amountToken1 = halfTokens;
        }

        // Approve the router to spend the bot's token0/token1
        stakingToken0.approve(address(router), amountToken0);
        stakingToken1.approve(address(router), amountToken1);
        // Actually add liquidity
        router.addLiquidity(
            address(stakingToken0),
            address(stakingToken1),
            amountToken0,
            amountToken1,
            amountToken0 * slippageNumerator / slippageDenominator,
            amountToken1 * slippageNumerator / slippageDenominator,
            address(this),
            deadline
        );

        // How much LP we have to re-invest
        uint256 lpBalance = stakingToken.balanceOf(address(this));
        stakingToken.approve(address(stakingRewards), lpBalance);

        // Actually reinvest and adjust FP weight
        stakingRewards.stake(lpBalance);
        lpTotalBalance += lpBalance;

        // Send incentive fee to sender
        rewardsToken.transfer(msg.sender, feeAmount);
        revoBounty.issueAdditionalBounty(msg.sender);
    }
}
