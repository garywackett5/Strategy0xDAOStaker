// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;
// Gary's xBOO Fork
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

// boo:xboo ratios, enter = "Locks Boo and mints xBoo", leave = "Unlocks the staked + gained Boo, and burns xBoo"
interface IXboo is IERC20 {
    function xBOOForBOO(uint256) external view returns (uint256);
    function BOOForxBOO(uint256) external view returns (uint256);
    function enter(uint256) external;
    function leave(uint256) external;
}

interface IUniswapV2Pair {
    function swap(
        uint256,
        uint256,
        address to,
        bytes calldata
    ) external ;

    function getReserves() external view returns (uint reserve0, uint reserve1, uint256 timestamp);
}

interface IFactory {
    function getPair(
        address, address
    ) external view returns(address);

    function getReserves() external view returns (uint reserve0, uint reserve1, uint256 timestamp);
}

interface ChefLike {
    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external; // use amount = 0 for harvesting rewards

    function emergencyWithdraw(uint256 _pid) external;

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

    ChefLike public masterchef;
    IERC20 public emissionToken;
    IERC20 public swapFirstStep;

    // swap stuff
    // swap stuff
    //address internal constant spookyRouter =
    //    0xF491e7B69E4244ad4002BC14e878a34207E38c29;
    address internal constant spookyFactory = 0x152eE697f2E276fA89E96742e9bB9aB1F2E61bE3;
    //address internal constant spiritRouter =
    //    0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52;
    address internal constant spiritFactory = 0xEF45d134b73241eDa7703fa787148D9C9F4950b0;
    ICurveFi internal constant mimPool =
        ICurveFi(0x2dd7C9371965472E5A5fD28fbE165007c61439E1); // Curve's MIM-USDC-USDT pool
    ICurveFi internal constant daiPool =
        ICurveFi(0x27E611FD27b276ACbd5Ffd632E5eAEBEC9761E40); // Curve's USDC-DAI pool

    // tokens
    IERC20 internal constant wftm =
        IERC20(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);
    IERC20 internal constant usdc =
        IERC20(0x04068DA6C83AFCFA0e13ba15A6696662335D5B75); 
    IERC20 internal constant boo =
        IERC20(0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE);    
    IXboo internal constant xboo =
        IXboo(0xa48d959AE2E88f1dAA7D5F611E01908106dE7598);

        bool public autoSell;
        uint256 public maxSell; //set to zero for unlimited

        bool public useSpiritPartOne;
        bool public useSpiritPartTwo;

    uint256 public pid; // the pool ID we are staking for

    string internal stratName; // we use this for our strategy's name on cloning
    bool internal isOriginal = true;

    bool internal forceHarvestTriggerOnce; // only set this to true externally when we want to trigger our keepers to harvest for us
    uint256 public minHarvestCredit; // if we hit this amount of credit, harvest the strategy

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        uint256 _pid,
        string memory _name,
        address _masterchef,
        address _emissionToken,
        address _swapFirstStep,
        bool _autoSell
    ) public BaseStrategy(_vault) {
        _initializeStrat(_pid, _name, _masterchef, _emissionToken, _swapFirstStep, _autoSell);
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
        string memory _name,
        address _masterchef,
        address _emissionToken,
        address _swapFirstStep,
        bool _autoSell
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
            _name, _masterchef, _emissionToken, _swapFirstStep,  _autoSell
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
        string memory _name,
        address _masterchef,
        address _emissionToken,
        address _swapFirstStep,
        bool _autoSell
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(_pid, _name, _masterchef, _emissionToken, _swapFirstStep, _autoSell);
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(uint256 _pid, string memory _name, address _masterchef, address _emissionToken, address _swapFirstStep, bool _autoSell) internal {

        masterchef = ChefLike(_masterchef);
        emissionToken = IERC20(_emissionToken);
        swapFirstStep = IERC20(_swapFirstStep);
        // initialize variables
        maxReportDelay = 43200; // 1/2 day in seconds, if we hit this then harvestTrigger = True
        healthCheck = address(0xf13Cd6887C62B5beC145e30c38c4938c5E627fe0); // Fantom common health check

        // set our strategy's name
        stratName = _name;

        autoSell = _autoSell;

        // make sure that we used the correct pid
        pid = _pid;

        // turn off our credit harvest trigger to start with
        minHarvestCredit = type(uint256).max;

        // add approvals on all tokens
        want.approve(address(xboo), type(uint256).max);
        xboo.approve(address(masterchef), type(uint256).max);
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    // balance of boo in strat - should be zero most of the time
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    // balance of xboo in strat (in boo) - should be zero most of the time
    function balanceOfXbooInWant() public view returns (uint256) {
        return xboo.xBOOForBOO(xboo.balanceOf(address(this)));
    }

    // balance of xboo in masterchef (in boo)
    function balanceOfStaked() public view returns (uint256) {
        (uint256 stakedInMasterchef, ) =
            masterchef.userInfo(pid, address(this));
        stakedInMasterchef = xboo.xBOOForBOO(stakedInMasterchef);
        return stakedInMasterchef;
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        // look at our staked tokens and any free tokens sitting in the strategy
        return balanceOfStaked().add(balanceOfWant()).add(balanceOfXbooInWant());
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

        // if we have emissionToken (OXD) to sell, then sell all of it
        uint256 emissionTokenBalance = emissionToken.balanceOf(address(this));
        if (emissionTokenBalance > 0) {
            // sell our emissionToken
            _sell(emissionTokenBalance);
        }

        uint256 assets = estimatedTotalAssets();
        uint256 wantBal = balanceOfWant();

        uint256 debt = vault.strategies(address(this)).totalDebt;
        uint256 amountToFree;

        if (assets >= debt) {
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
            // deposit our boo into xboo
            xboo.enter(toInvest);
            // deposit xboo into masterchef
            masterchef.deposit(pid, xboo.balanceOf(address(this)));
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balanceOfBoo = want.balanceOf(address(this));
        // if we need more boo than is already loose in the contract
        if (balanceOfBoo < _amountNeeded) {
            // boo needed beyond any boo that is already loose in the contract
            uint256 amountToFree = _amountNeeded.sub(balanceOfBoo);
            // converts this amount into xboo
            uint256 amountToFreeInXboo = xboo.BOOForxBOO(amountToFree);
            //any xboo that is already loose in the contract
            uint256 balanceOfXboo = xboo.balanceOf(address(this));
            // if we need more xboo than is already loose in the contract
            if (balanceOfXboo < amountToFreeInXboo) {
                // new amount of xboo needed after subtracting any xboo that is already loose in the contract
                uint256 newAmountToFreeInXboo = amountToFreeInXboo.sub(balanceOfXboo);

                (uint256 deposited, ) =
                    ChefLike(masterchef).userInfo(pid, address(this));
                // if xboo deposited in masterchef is less than what we want, deposited becomes what we want (all)
                if (deposited < newAmountToFreeInXboo) {
                    newAmountToFreeInXboo = deposited;
                }
                // stops us trying to withdraw if xboo deposited is zero
                if (deposited > 0) {
                    ChefLike(masterchef).withdraw(pid, newAmountToFreeInXboo);
                    // updating balanceOfXboo in preparation for when we leave xboo
                    balanceOfXboo = xboo.balanceOf(address(this));
                }
            }
            // leave = "Unlocks the staked Boo + gained Boo (which should be zero?), and burns xBoo"
            // the lowest of these two options beause balanceOfXboo might be more than we need
            xboo.leave(Math.min(amountToFreeInXboo, balanceOfXboo));

            // this address' balance of boo
            _liquidatedAmount = want.balanceOf(address(this));
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        (uint256 stakedInMasterchef, ) =
            masterchef.userInfo(pid, address(this));
        if (stakedInMasterchef > 0) {
            masterchef.withdraw(pid, stakedInMasterchef);
        }
        uint256 balanceOfXboo = xboo.balanceOf(address(this));
        if (balanceOfXboo > 0) {
            xboo.leave(balanceOfXboo);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        (uint256 stakedInMasterchef, ) =
            masterchef.userInfo(pid, address(this));
        if (stakedInMasterchef > 0) {
            masterchef.withdraw(pid, stakedInMasterchef);
        }

        // send our total balance of claimed emissionToken (OXD) to the new strategy
        emissionToken.safeTransfer(
            _newStrategy,
            emissionToken.balanceOf(address(this))
        );
        // send our total balance of xboo to the new strategy
        xboo.transfer(
            _newStrategy,
            xboo.balanceOf(address(this))
        );
    }

    ///@notice Only do this if absolutely necessary; as assets will be withdrawn but rewards won't be claimed.
    function emergencyWithdraw() external onlyEmergencyAuthorized {
        masterchef.emergencyWithdraw(pid);
    }

    function manualSell(uint256 _amount) external onlyEmergencyAuthorized {
        _sell(_amount);
    }

    struct SellRoute{
        address pair; 
        address input; 
        address output; 
        address to;
    }
    // sell from reward token to want
    function _sell(uint256 _amount) internal {

        if(maxSell > 0){
            _amount = Math.min(maxSell, _amount);
        }        

        //we do all our sells in one go in a chain between pairs
        //inialise to 3 even if we use less to save on gas
        SellRoute[] memory sellRoute = new SellRoute[](3);

        // 1! sell our emission token for pool two second token
        address[] memory emissionTokenPath = new address[](2);
        emissionTokenPath[0] = address(emissionToken);
        emissionTokenPath[1] = address(swapFirstStep);
        uint256 id = 0;

        address factory = useSpiritPartOne? spiritFactory: spookyFactory;
        //we deal directly with the pairs
        address pair = IFactory(factory).getPair(emissionTokenPath[0], emissionTokenPath[1]);

        //start off by sending our emission token to the first pair. we only do this once
        emissionToken.safeTransfer(pair, _amount);

        //first
        sellRoute[id] =
                SellRoute(
                    pair,
                    emissionTokenPath[0], 
                    emissionTokenPath[1],
                    address(0)
                );

        if (address(want) == address(swapFirstStep)) {

            //end with only one step
            _uniswap_sell_with_fee(sellRoute, id);
            return;
        }

        //if the second token isnt ftm we need to do an etra step
        if(address(swapFirstStep) != address(wftm)){
            id = id+1;
            //! 2
            emissionTokenPath[0] = address(swapFirstStep);
            emissionTokenPath[1] = address(wftm);
            
            pair = IFactory(spookyFactory).getPair(emissionTokenPath[0], emissionTokenPath[1]);
            

            //we set the to of the last step to 
            sellRoute[id-1].to = pair;

            sellRoute[id] =
                SellRoute(
                    pair,
                    emissionTokenPath[0], 
                    emissionTokenPath[1],
                    address(0)
                );

            if (address(want) == address(wftm)) {
                //end. final to is always us. second array
                sellRoute[id].to = address(this);

                //end with only one step
                _uniswap_sell_with_fee(sellRoute, id);
                return;
            }
        }

        id = id+1;
        //final step is wftm to want
        emissionTokenPath[0] = address(wftm);
        emissionTokenPath[1] = address(want);
        factory = useSpiritPartTwo? spiritFactory: spookyFactory;
        pair = IFactory(factory).getPair(emissionTokenPath[0], emissionTokenPath[1]);
        

        sellRoute[id - 1].to = pair;


        sellRoute[id] =
                SellRoute(
                    pair,
                    emissionTokenPath[0], 
                    emissionTokenPath[1],
                    address(this)
                );


        //id will be 0-1-2
        _uniswap_sell_with_fee(sellRoute, id);
    }


    function _uniswap_sell_with_fee(SellRoute[] memory sell, uint256 id) internal{
        sell[id].to = address(this); //last one is always to us
        for (uint i; i < id+1; i++) {
            
            (address token0,) = _sortTokens(sell[i].input, sell[i].output);
            IUniswapV2Pair pair = IUniswapV2Pair(sell[i].pair);
            uint amountInput;
            uint amountOutput;
            { // scope to avoid stack too deep errors
            (uint reserve0, uint reserve1,) = pair.getReserves();
            (uint reserveInput, uint reserveOutput) = sell[i].input == token0 ? (reserve0, reserve1) : (reserve1, reserve0);
            amountInput = IERC20(sell[i].input).balanceOf(address(pair)).sub(reserveInput);
            amountOutput = _getAmountOut(amountInput, reserveInput, reserveOutput);
            }
            (uint amount0Out, uint amount1Out) = sell[i].input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
            require(sell[i].to != address(0), "burning tokens");
            pair.swap(amount0Out, amount1Out, sell[i].to, new bytes(0));
        }
    }


    //following two functions are taken from uniswap library
    //https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) internal pure returns (uint amountOut) {
        require(amountIn > 0, 'UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint amountInWithFee = amountIn.mul(997);
        uint numerator = amountInWithFee.mul(reserveOut);
        uint denominator = reserveIn.mul(1000).add(amountInWithFee);
        amountOut = numerator / denominator;
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

     ///@notice autosell if pools are liquid enough
    function setAutoSell(bool _autoSell)
        external
        onlyEmergencyAuthorized
    {
        autoSell = _autoSell;
    }

    ///@notice set a max sell for illiquid pools
    function setMaxSell(uint256 _maxSell)
        external
        onlyEmergencyAuthorized
    {
        maxSell = _maxSell;
    }

    function setUseSpiritOne(bool _useSpirit)
        external
        onlyEmergencyAuthorized
    {
        useSpiritPartOne = _useSpirit;
    }

    function setUseSpiritTwo(bool _useSpirit)
        external
        onlyEmergencyAuthorized
    {
        useSpiritPartTwo = _useSpirit;
    }
}
