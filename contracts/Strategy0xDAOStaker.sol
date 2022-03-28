// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

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

interface IRewardPool {
    function stake(uint256 _amount) public; // WHAT IS "SUPER"???

    function withdraw(uint256 _amount) public; // use amount = 0 for harvesting rewards CANNOT WITHDRAW 0

    function exit() external; // withdraws balanceOf msg.sender and calls getReward

    // function userInfo(uint256 _pid, address user)
    //     external
    //     view
    //     returns (uint256 amount, uint256 rewardDebt);
}

interface IZapbeFTM {
    function depositNative() external payable;
}

interface IWrappedNative is IERC20 {
    function deposit() external payable;
    function withdraw(uint wad) external;
}

contract Strategy0xDAOStaker is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    IRewardPool public constant rewardPool =
        IRewardPool(0xE00D25938671525C2542A689e42D1cfA56De5888);
    IZapbeFTM public beftmMinter =
        IZapbeFTM(0x34753f36d69d00e2112Eb99B3F7f0FE76cC35090);

    // // swap stuff
    // address internal constant spookyRouter =
    //     0xF491e7B69E4244ad4002BC14e878a34207E38c29;
    // ICurveFi internal constant mimPool =
    //     ICurveFi(0x2dd7C9371965472E5A5fD28fbE165007c61439E1); // Curve's MIM-USDC-USDT pool
    // ICurveFi internal constant daiPool =
    //     ICurveFi(0x27E611FD27b276ACbd5Ffd632E5eAEBEC9761E40); // Curve's USDC-DAI pool

    // tokens
    IERC20 internal constant wftm =
        IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    IERC20 internal constant beftm =
        IERC20(0x7381eD41F6dE418DdE5e84B55590422a57917886);


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

    // want = beftm
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // taked = beftm
    function balanceOfStaked() public view returns (uint256) {
        return rewardPool.balanceOf(address(this))
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
        rewardPool.getReward();

        // if we have wftm to sell, then sell some of it
        uint256 wftmBalance = wftm.balanceOf(address(this));
        if (wftmBalance > 0) {
            // sell our emissionToken
            _sell(wftmBalance);
        }

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = balanceOfWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 amountToFree;

        // this would only happen if the rewardPool somehow lost funds or was drained
        uint256 rewardPoolHoldings = want.balanceOf(address(rewardPool));
        uint256 stakedBalance = balanceOfStaked();
        if (rewardPoolHoldings < stakedBalance) {
            amountToFree = rewardPoolHoldings;
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
            rewardPool.stake(toInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        // if we have loose wftm. liquidate it
        uint256 wftmBalance = wftm.balanceOf(address(this));
        if (wftmBalance > 0) {
            // sell our wftm
            _sell(wftmBalance);
        }

        uint256 beftmBalance = want.balanceOf(address(this));

        // if we need more beftm than is already loose in the contract
        if (beftmBalance < _amountNeeded) {
            uint256 amountToFree = _amountNeeded.sub(beftmBalance);

            uint256 deposited = IRewardPool(rewardPool).balanceOf(address(this));
            if (deposited < amountToFree) {
                amountToFree = deposited;
            }
            if (deposited > 0) {
                IRewardPool(rewardPool).withdraw(amountToFree);
            }

            _liquidatedAmount = want.balanceOf(address(this));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        rewardPool.exit();

        _sell(wftm.balanceOf(address(this)));

        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        uint256 stakedBalance = balanceOfStaked();
        if (stakedBalance > 0) {
            rewardPool.withdraw(stakedBalance);
        }

        // send our claimed wftm to the new strategy
        wftm.safeTransfer(
            _newStrategy,
            wftm.balanceOf(address(this))
        );
    }
    
    // FUNCTION EXIT() INSTEAD??? STILL CALLS GETREWARD
    // @notice Only do this if absolutely necessary; as assets will be withdrawn but rewards won't be claimed.
    function emergencyWithdraw() external onlyEmergencyAuthorized {
        rewardPool.exit();
    }

    function manualWithdraw(uint256 amount) external onlyEmergencyAuthorized {
        rewardPool.withdraw(amount);
    }

    function manualSell(uint256 _amount) external onlyEmergencyAuthorized {
        _sell(_amount);
    }

    // sell from reward token (wftm) to want
    function _sell(uint256 _amount) internal {
        // unwrap our wftm
        wftm.withdraw(_amount);
        // swap ftm for beftm
        beftmMinter.depositNative(_amount);
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
