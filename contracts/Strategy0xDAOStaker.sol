// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
//gary's fork
// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/Math.sol";

interface ICurveFi {
    function exchange(
        int128 from,
        int128 to,
        uint256 _from_amount,
        uint256 _min_to_amount
    ) external;

    function exchange_underlying(
        int128 from,
        int128 to,
        uint256 _from_amount,
        uint256 _min_to_amount
    ) external;
}

interface IUniswapV2Router02 {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface ChefLike {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external; // use amount = 0 for harvesting rewards

    function emergencyWithdraw(uint256 _pid) external;

    function poolInfo(uint256 _pid)
        external
        view
        returns (
            address lpToken,
            uint256 allocPoint,
            uint256 lastRewardTime,
            uint256 accOXDPerShare
        );

    function userInfo(uint256 _pid, address user)
        external
        view
        returns (uint256 amount, uint256 rewardDebt);
}

contract Strategy0xDAOStaker is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    ChefLike public constant masterchef =
        ChefLike(0xa7821C3e9fC1bF961e280510c471031120716c3d);
    IERC20 public constant emissionToken =
        IERC20(0xc165d941481e68696f43EE6E99BFB2B23E0E3114); // the token we receive for staking, 0XD

    // swap stuff
    address internal constant spookyRouter =
        0xF491e7B69E4244ad4002BC14e878a34207E38c29;
    ICurveFi internal constant mimPool =
        ICurveFi(0x2dd7C9371965472E5A5fD28fbE165007c61439E1); // Curve's MIM-USDC-USDT pool
    ICurveFi internal constant daiPool =
        ICurveFi(0x27E611FD27b276ACbd5Ffd632E5eAEBEC9761E40); // Curve's USDC-DAI pool

    // tokens
    IERC20 internal constant wftm =
        IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    IERC20 internal constant weth =
        IERC20(0x74b23882a30290451A17c44f4F05243b6b58C76d);
    IERC20 internal constant wbtc =
        IERC20(0x321162Cd933E2Be498Cd2267a90534A804051b11);
    IERC20 internal constant dai =
        IERC20(0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E);
    IERC20 internal constant usdc =
        IERC20(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75);
    IERC20 internal constant mim =
        IERC20(0x82f0B8B456c1A451378467398982d4834b6829c1);

    uint256 public pid; // the pool ID we are staking for

    string internal stratName; // we use this for our strategy's name on cloning
    bool internal isOriginal = true;

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us
    uint256 public minHarvestCredit; // if we hit this amount of credit, harvest the strategy

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        uint256 _pid,
        string memory _name
    ) public BaseStrategy(_vault) {
        _initializeStrat(_pid, _name);
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // we use this to clone our original strategy to other vaults
    function clone0xDAOStaker(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _pid,
        string memory _name
    ) external returns (address newStrategy) {
        require(isOriginal);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy0xDAOStaker(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _pid,
            _name
        );

        emit Cloned(newStrategy);
    }

    // this will only be called by the clone function above
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        uint256 _pid,
        string memory _name
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_pid, _name);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(uint256 _pid, string memory _name) internal {
        // initialize variables
        maxReportDelay = 43200; // 1/2 day in seconds, if we hit this then harvestTrigger = True
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0); // Fantom common health check

        // set our strategy's name
        stratName = _name;

        // make sure that we used the correct pid
        pid = _pid;
        (address poolToken, , , ) = masterchef.poolInfo(pid);
        require(poolToken == address(want), "wrong pid");

        // turn off our credit harvest trigger to start with
        minHarvestCredit = type(uint256).max;

        // add approvals on all tokens
        usdc.approve(spookyRouter, type(uint256).max);
        usdc.approve(address(mimPool), type(uint256).max);
        usdc.approve(address(daiPool), type(uint256).max);
        want.approve(address(masterchef), type(uint256).max);
        emissionToken.approve(spookyRouter, type(uint256).max);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfStaked() public view returns (uint256) {
        (uint256 stakedInMasterchef, ) =
            masterchef.userInfo(pid, address(this));
        return stakedInMasterchef;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // look at our staked tokens and any free tokens sitting in the strategy
        return balanceOfStaked().add(balanceOfWant());
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // claim our rewards
        masterchef.withdraw(pid, 0);

        // if we have emissionToken to sell, then sell some of it
        uint256 emissionTokenBalance = emissionToken.balanceOf(address(this));
        if (emissionTokenBalance > 0) {
            // sell our emissionToken
            _sell(emissionTokenBalance);
        }

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = balanceOfWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 amountToFree;

        // this would only happen if the masterchef somehow lost funds or was drained
        uint256 masterchefHoldings = want.balanceOf(address(masterchef));
        uint256 stakedBalance = balanceOfStaked();
        if (masterchefHoldings < stakedBalance) {
            amountToFree = masterchefHoldings;
            liquidatePosition(amountToFree);
            _debtPayment = balanceOfWant();
            _loss = stakedBalance.sub(_debtPayment);
            return (_profit, _loss, _debtPayment);
        }

        if (assets > debt) {
            _debtPayment = _debtOutstanding;
            _profit = assets - debt;

            amountToFree = _profit.add(_debtPayment);

            if (amountToFree > 0 && wantBal < amountToFree) {
                liquidatePosition(amountToFree);

                uint256 newLoose = want.balanceOf(address(this));

                //if we dont have enough money adjust _debtOutstanding and only change profit if needed
                if (newLoose < amountToFree) {
                    if (_profit > newLoose) {
                        _profit = newLoose;
                        _debtPayment = 0;
                    } else {
                        _debtPayment = Math.min(
                            newLoose - _profit,
                            _debtPayment
                        );
                    }
                }
            }
        } else {
            //serious loss should never happen but if it does lets record it accurately
            _loss = debt - assets;
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // send all of our want tokens to be deposited
        uint256 toInvest = balanceOfWant();
        // stake only if we have something to stake
        if (toInvest > 0) {
            masterchef.deposit(pid, toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            uint256 amountToFree = _amountNeeded.sub(totalAssets);

            (uint256 deposited, ) =
                ChefLike(masterchef).userInfo(pid, address(this));
            if (deposited < amountToFree) {
                amountToFree = deposited;
            }
            if (deposited > 0) {
                ChefLike(masterchef).withdraw(pid, amountToFree);
            }

            _liquidatedAmount = want.balanceOf(address(this));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 stakedBalance = balanceOfStaked();
        if (stakedBalance > 0) {
            masterchef.withdraw(pid, stakedBalance);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 stakedBalance = balanceOfStaked();
        if (stakedBalance > 0) {
            masterchef.withdraw(pid, stakedBalance);
        }

        // send our claimed emissionToken to the new strategy
        emissionToken.safeTransfer(
            _newStrategy,
            emissionToken.balanceOf(address(this))
        );
    }

    ///@notice Only do this if absolutely necessary; as assets will be withdrawn but rewards won't be claimed.
    function emergencyWithdraw() external onlyEmergencyAuthorized {
        masterchef.emergencyWithdraw(pid);
    }

    // sell from reward token to want
    function _sell(uint256 _amount) internal {
        // sell our emission token for usdc
        address[] memory emissionTokenPath = new address[](2);
        emissionTokenPath[0] = address(emissionToken);
        emissionTokenPath[1] = address(usdc);

        IUniswapV2Router02(spookyRouter).swapExactTokensForTokens(
            _amount,
            uint256(0),
            emissionTokenPath,
            address(this),
            block.timestamp
        );

        if (address(want) == address(usdc)) {
            return;
        }

        // sell our USDC for want
        uint256 usdcBalance = usdc.balanceOf(address(this));
        if (address(want) == address(wftm)) {
            // sell our usdc for want with spooky
            address[] memory usdcSwapPath = new address[](2);
            usdcSwapPath[0] = address(usdc);
            usdcSwapPath[1] = address(want);

            IUniswapV2Router02(spookyRouter).swapExactTokensForTokens(
                usdcBalance,
                uint256(0),
                usdcSwapPath,
                address(this),
                block.timestamp
            );
        } else if (address(want) == address(weth)) {
            // sell our usdc for want with spooky
            address[] memory usdcSwapPath = new address[](3);
            usdcSwapPath[0] = address(usdc);
            usdcSwapPath[1] = address(wftm);
            usdcSwapPath[2] = address(weth);

            IUniswapV2Router02(spookyRouter).swapExactTokensForTokens(
                usdcBalance,
                uint256(0),
                usdcSwapPath,
                address(this),
                block.timestamp
            );
        } else if (address(want) == address(dai)) {
            // sell our usdc for want with curve
            daiPool.exchange_underlying(1, 0, usdcBalance, 0);
        } else if (address(want) == address(mim)) {
            // sell our usdc for want with curve
            mimPool.exchange(2, 0, usdcBalance, 0);
        } else if (address(want) == address(wbtc)) {
            // sell our usdc for want with spooky
            address[] memory usdcSwapPath = new address[](3);
            usdcSwapPath[0] = address(usdc);
            usdcSwapPath[1] = address(wftm);
            usdcSwapPath[2] = address(wbtc);

            IUniswapV2Router02(spookyRouter).swapExactTokensForTokens(
                usdcBalance,
                uint256(0),
                usdcSwapPath,
                address(this),
                block.timestamp
            );
        }
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    // our main trigger is regarding our DCA since there is low liquidity for our emissionToken
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        StrategyParams memory params = vault.strategies(address(this));

        // harvest no matter what once we reach our maxDelay
        if (block.timestamp.sub(params.lastReport) > maxReportDelay) {
            return true;
        }

        // trigger if we want to manually harvest
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // trigger if we have enough credit
        if (vault.creditAvailable() >= minHarvestCredit) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {}

    /* ========== SETTERS ========== */

    ///@notice This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }

    ///@notice When our strategy has this much credit, harvestTrigger will be true.
    function setMinHarvestCredit(uint256 _minHarvestCredit)
        external
        onlyAuthorized
    {
        minHarvestCredit = _minHarvestCredit;
    }
}
