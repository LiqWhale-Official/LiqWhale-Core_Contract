// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// --- CUSTOM ERRORS (GAS OPTIMIZATION) ---
// Custom errors are used instead of long revert strings to reduce contract bytecode size.
error TradingDisabled();
error InvalidAddress();
error AlreadyInitialized();
error PairNotCreated();
error SequencerDown();
error GracePeriodNotOver();
error InvalidIndex();
error AssetInactive();
error NoOracle();
error MaxTxExceeded();
error MaxWalletExceeded();
error NotKeeper();
error AaveWithdrawFailed();
error StakingWithdrawFailed();


/**
 * @title LiqWhale Protocol ($LWL) - V24 Ultra-Light
 * @notice ARCHITECTURE: V20 Logic + V22 Modularity + Custom Errors for Bytecode Optimization.
 * @dev DEPLOYMENT FLOW: 1. Deploy -> 2. initializePortfolio -> 3. createLiquidityPool -> 4. enableTrading
 * @dev PHILOSOPHY: "Liquidity is the Whale." This protocol manages an automated treasury that rebalances 
 * into Yield-bearing assets and Real World Assets (RWA) via decentralized oracles.
 */


// --- INTERFACES ---
interface AggregatorV3Interface {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

interface IAerodromeRouter {
    struct Route { address from; address to; bool stable; address factory; }
    function defaultFactory() external view returns (address);
    function weth() external view returns (address);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline) external;
    function addLiquidity(address tokenA, address tokenB, bool stable, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint amountA, uint amountB, uint liquidity);
    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts);
}

interface IAerodromeFactory {
    function getPool(address tokenA, address tokenB, bool stable) external view returns (address);
    function createPool(address tokenA, address tokenB, bool stable) external returns (address);
}

interface IPoolAddressesProvider { function getPool() external view returns (address); }
interface IAavePool { 
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external; 
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
interface IVirtualsStaking { 
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external; 
}

contract LiqWhale is ERC20Burnable, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- ROLES ---
    mapping(address => bool) public keepers; // Authorized automated bots/addresses for maintenance

    // --- PROTOCOL ADDRESSES (Base Mainnet) ---
    address public constant FOUNDER_ADDRESS = 0xa61e3A6077602a59aBcd032898b1b3a933D31c36;
    address public constant MARKETING_ADDRESS = 0x7c85c432e4E0e6164DcA4A25213f092882D45397;
    address public constant WETH = 0x4200000000000000000000000000000000000006;   
    address public constant AERO_ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43; 
    address public constant AERO_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address public constant AAVE_PROVIDER = 0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D;
    address public constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433; // L2 Sequencer Uptime Feed
    
    uint256 private constant GRACE_PERIOD_TIME = 3600; // 1 hour safety window after sequencer reboot
    uint256 public constant TARGET_SUPPLY = 100_000_000_000 * 10**18; // The threshold where "Endgame" (zero-tax) triggers

    enum YieldType { NATIVE_HOLD, AAVE_SUPPLY, STAKING }
    
    struct Asset { 
        string name; 
        address tokenAddress; 
        address oracle; 
        uint8 decimals;      
        uint256 targetWeight; // Target percentage in portfolio (basis points)
        uint256 slippageBps; 
        YieldType yieldStrategy; 
        bool stablePool; 
        bool needsWethHop; // True if the asset must be swapped via WETH
        bool isActive; 
    }
    
    Asset[] public portfolio;
    uint256 public totalTargetWeight; 
    bool public isInitialized;

    // --- PROTOCOL CONFIGURATION ---
    uint256 public yieldFee = 100;      // 1% Treasury Investment
    uint256 public lpFee = 100;         // 1% Auto-Liquidity
    uint256 public burnFee = 100;       // 1% Hyper-deflation
    uint256 public marketingFee = 50;   // 0.5% Marketing
    uint256 public constant MAX_FEE_CAP = 5000; // Hard cap on total fees (50%)

    uint256 public maxTxBps = 50;       // Max 0.5% per transaction
    uint256 public maxWalletBps = 50;   // Max 0.5% per wallet
    uint256 public maxSwapAmount;       // Maximum tokens contract swaps at once
    
    uint256 public swapThreshold;      // Tokens needed in contract to trigger swap
    uint256 public investThreshold;    // Minimum WETH accumulated before treasury investment
    uint256 public globalSlippageTolerance = 500; // 5% default
    uint256 public rebalanceThreshold = 1000;     // 10% deviation triggers rebalance
    
    address public marketingWallet;
    address public lpPair; 
    address public virtualsStakingContract; 
    
    bool public tradingEnabled;
    bool private swapping;
    bool public endgameActive;         // Active when supply drops below TARGET_SUPPLY
    uint256 public launchBlock;
    uint256 public constant TRAP_DURATION = 300; // Blocks duration for anti-snipe logic
    bool public trapForceDisabled;

    mapping(address => bool) public isExcludedFromFees;
    mapping(address => bool) public isExcludedFromLimits;
    mapping(address => bool) public isPair;

    // --- EVENTS ---
    event SmartTreasuryBuy(string asset, uint256 baseSpent, uint256 assetReceived);
    event RebalanceExecuted(string asset, string action, uint256 amountSold, uint256 lwlBurned);
    event YieldAction(string asset, string strategy, uint256 amount, string status);
    event SniperCaught(address indexed sniper, uint256 amountSeized, string direction);
    event FeesUpdated(uint256 yield, uint256 lp, uint256 burn, uint256 market);
    event LpPairInitialized(address pair);
    event InitializedLaunch(bool success);
    event FailSafe(string module, string reason);
    event TrapModeActive(uint256 startBlock, uint256 endBlock);
    event AssetStatusChanged(string name, bool status);
    event PositionUnwound(string protocol, uint256 amount);
    event DustSwept(address token, uint256 amount);
    event AutoLPExecuted(uint256 tokenAmt, uint256 baseAmt);
    event KeeperUpdated(address keeper, bool status);

    modifier onlyKeeper() {
        if (!keepers[msg.sender] && msg.sender != owner()) revert NotKeeper();
        _;
    }

    /**
     * @dev Ensures the L2 Sequencer is up before executing oracle-dependent logic.
     * Prevents stale price attacks during L2 downtime.
     */
    modifier validateSequencer() {
        (, int256 answer, uint256 startedAt, ,) = AggregatorV3Interface(SEQUENCER_FEED).latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= GRACE_PERIOD_TIME) revert GracePeriodNotOver();
        _;
    }

 
    constructor() ERC20("LiqWhale", "LWL") Ownable(msg.sender) {
        marketingWallet = MARKETING_ADDRESS;
        
        keepers[FOUNDER_ADDRESS] = true;
        keepers[msg.sender] = true;

        isExcludedFromFees[FOUNDER_ADDRESS] = true;
        isExcludedFromFees[MARKETING_ADDRESS] = true;
        isExcludedFromFees[address(this)] = true;
        isExcludedFromFees[AERO_ROUTER] = true; 
        isExcludedFromFees[msg.sender] = true;
        isExcludedFromLimits[FOUNDER_ADDRESS] = true;
        isExcludedFromLimits[MARKETING_ADDRESS] = true;
        isExcludedFromLimits[address(this)] = true;
        isExcludedFromLimits[AERO_ROUTER] = true;
        isExcludedFromLimits[msg.sender] = true;

        
        uint256 totalSupply = 1_000_000_000_000_000 * 10**18;
        _mint(FOUNDER_ADDRESS, totalSupply);

        swapThreshold = 50_000_000_000 * 10**18; 
        investThreshold = 5 * 10**16; 
        maxSwapAmount = 50_000_000_000 * 10**18;
    }

    // --- STEP 1: PORTFOLIO INITIALIZATION ---
    /**
     * @notice Configures the Treasury Asset Basket (RWA & Blue Chips)
     */
    function initializePortfolio() external onlyOwner {
        if (isInitialized) revert AlreadyInitialized();
        
        _addAsset("cbBTC", 0xcbD06E5A2B0C65597161de254AA074E489dEb510, 0x64c911D33190820848f0940D36E9D7FbE25618e9, 8, 2000, 50, YieldType.AAVE_SUPPLY, false, false);
        _addAsset("SolvBTC", 0x3B86Ad95859b6AB773f55f8d94B4b9d443EE931f, 0x64c911D33190820848f0940D36E9D7FbE25618e9, 18, 1500, 100, YieldType.NATIVE_HOLD, false, false);
        _addAsset("USDC", 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 0x7E8648AB70801F9d4072F37E075F37B23D75Bc6B, 6, 1500, 50, YieldType.AAVE_SUPPLY, true, false);
        _addAsset("AERO", 0x940181a94A35A4569E4529A3CDfB74e38FD98631, address(0), 18, 2000, 100, YieldType.NATIVE_HOLD, false, false);
        _addAsset("VIRTUAL", 0x0b3e328455c4059EEb9e3f84b5543F74E24e7E1b, address(0), 18, 1000, 200, YieldType.STAKING, false, false);
        _addAsset("AAVE", 0x63706e401c06ac8513145b7687A14804d17f814b, address(0), 18, 1000, 100, YieldType.NATIVE_HOLD, false, false); 
        _addAsset("LINK", 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196, 0xB888384A9777414C02e785d8b84F722D81d04E0A, 18, 1000, 100, YieldType.AAVE_SUPPLY, false, false);
        
        isInitialized = true;
        emit InitializedLaunch(true);
    }

    // --- STEP 2: POOL CREATION ---
    /**
     * @notice Synchronizes with Aerodrome Factory to link the LWL/WETH pair
     */
    function createLiquidityPool() external onlyOwner {
        if (lpPair != address(0)) revert AlreadyInitialized();
        address existingPair = IAerodromeFactory(AERO_FACTORY).getPool(address(this), WETH, false);
        if (existingPair == address(0)) {
            lpPair = IAerodromeFactory(AERO_FACTORY).createPool(address(this), WETH, false);
        } else {
            lpPair = existingPair;
        }
        isExcludedFromLimits[lpPair] = true;
        isPair[lpPair] = true;
        emit LpPairInitialized(lpPair);
    }

    // --- STEP 3: ENABLE TRADING ---
    /**
     * @notice Officially opens the protocol for public trading and activates Trap Mode
     */
    function enableTrading() external onlyOwner { 
        if (tradingEnabled) revert("Already Enabled");
        if (lpPair == address(0)) revert PairNotCreated();
        tradingEnabled = true; 
        launchBlock = block.number; 
        emit TrapModeActive(block.number, block.number + TRAP_DURATION);
    }

    function _addAsset(string memory name, address token, address oracle, uint8 decimals, uint256 weight, uint256 slip, YieldType yield, bool stable, bool hop) internal {
        portfolio.push(Asset(name, token, oracle, decimals, weight, slip, yield, stable, hop, true));
        totalTargetWeight += weight;
    }

    function addPortfolioAsset(string memory name, address token, address oracle, uint8 decimals, uint256 weight, uint256 slip, YieldType yield, bool stable, bool hop) external onlyOwner {
        _addAsset(name, token, oracle, decimals, weight, slip, yield, stable, hop);
    }

    // --- HELPER: DECIMAL NORMALIZATION ---
    function _normalizeTo18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10**(18 - decimals));
        return amount / (10**(decimals - 18));
    }

    function _denormalizeFrom18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount / (10**(18 - decimals));
        return amount * (10**(decimals - 18));
    }

    // --- V20 SHANNON'S ENGINE (Oracle-based Rebalancing) ---
    /**
     * @notice Rebalances a specific asset in the treasury if it exceeds its target weight.
     * Calculated excess is sold for WETH, which is then used to market-buy and BURN $LWL.
     */
    function rebalanceAsset(uint256 index) external onlyKeeper nonReentrant validateSequencer {
        if (index >= portfolio.length) revert InvalidIndex();
        Asset storage asset = portfolio[index];
        if (!asset.isActive || asset.oracle == address(0)) revert AssetInactive();

        uint256 rawBalance = IERC20(asset.tokenAddress).balanceOf(address(this));
        if (rawBalance == 0) return;
        
        uint256 balance18 = _normalizeTo18(rawBalance, asset.decimals);
        uint256 assetPrice = getAssetPrice(asset.oracle); 
        uint256 currentValUSD = (balance18 * assetPrice * 1e10) / 1e18; // Price feed normalization
        uint256 totalTreasuryVal = calculateTotalTreasuryValue();
        if (totalTreasuryVal == 0) return;

        uint256 targetVal = (totalTreasuryVal * asset.targetWeight) / 10000;
        uint256 thresholdVal = (targetVal * rebalanceThreshold) / 10000;

        // If current value exceeds target by more than threshold, sell excess and burn LWL
        if (currentValUSD > targetVal + thresholdVal) {
            uint256 excessValUSD = currentValUSD - targetVal;
            uint256 tokensToSellNorm = (excessValUSD * 1e18 * 1e18) / (assetPrice * 1e10 * 1e18); 
            uint256 tokensToSell = _denormalizeFrom18(tokensToSellNorm, asset.decimals);
            
            if (tokensToSell > rawBalance / 2) tokensToSell = rawBalance / 2; // Safety cap

            _prepareAssetForSale(asset, tokensToSell);
            _sellAssetAndBurnLWL(asset, tokensToSell);
        }
    }

    function calculateTotalTreasuryValue() public view returns (uint256 totalVal) {
        for(uint i=0; i<portfolio.length; i++) {
            if(portfolio[i].isActive && portfolio[i].oracle != address(0)) {
                uint256 rawBal = IERC20(portfolio[i].tokenAddress).balanceOf(address(this));
                uint256 normBal = _normalizeTo18(rawBal, portfolio[i].decimals);
                uint256 price = getAssetPrice(portfolio[i].oracle);
                totalVal += (normBal * price * 1e10) / 1e18;
            }
        }
    }

    function getAssetPrice(address oracle) internal view returns (uint256) {
        if (oracle == address(0)) return 0;
        (, int256 price, , , ) = AggregatorV3Interface(oracle).latestRoundData();
        return price > 0 ? uint256(price) : 0;
    }

    function _sellAssetAndBurnLWL(Asset memory asset, uint256 tokenAmount) internal {
        uint256 wethBefore = IERC20(WETH).balanceOf(address(this));
        _swapAssetForBase(asset, tokenAmount);
        uint256 wethGained = IERC20(WETH).balanceOf(address(this)) - wethBefore;

        if (wethGained > 0) {
            IAerodromeRouter.Route[] memory routes = _getRoutes(WETH, address(this), false);
            IERC20(WETH).approve(AERO_ROUTER, wethGained);
            try IAerodromeRouter(AERO_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wethGained, 0, routes, address(0xdead), block.timestamp
            ) {
                emit RebalanceExecuted(asset.name, "BURN", tokenAmount, wethGained); 
            } catch {}
        }
    }

    // --- CORE ERC20 OVERRIDE (Taxes & Limits) ---
    function _update(address from, address to, uint256 amount) internal override {
        if (!tradingEnabled) {
             if (!isExcludedFromFees[from] && !isExcludedFromFees[to]) revert TradingDisabled();
        }
        
        bool isEndgame = totalSupply() <= TARGET_SUPPLY;
        if (isEndgame && !endgameActive) endgameActive = true;
        bool trapActive = (launchBlock > 0 && block.number <= launchBlock + TRAP_DURATION) && !trapForceDisabled;

        // Apply Max TX and Max Wallet limits unless in Endgame or Trap active
        if (!endgameActive && !trapActive && !swapping && !isExcludedFromLimits[from] && !isExcludedFromLimits[to]) {
            uint256 dynMaxTx = (totalSupply() * maxTxBps) / 10000;
            uint256 dynMaxWallet = (totalSupply() * maxWalletBps) / 10000;
            if (from == lpPair && amount > dynMaxTx) revert MaxTxExceeded();
            if (to != lpPair && to != address(0xdead) && balanceOf(to) + amount > dynMaxWallet) revert MaxWalletExceeded();
        }

        uint256 contractBal = balanceOf(address(this));
        bool canSwap = contractBal >= swapThreshold;
        
        // IPO: Initial Protocol Operation (Fee Processing)
        if (isInitialized && lpPair != address(0) && !trapActive && !endgameActive && canSwap && !swapping && to == lpPair && !isExcludedFromFees[from]) {
            swapping = true;
            uint256 amountToSwap = contractBal > maxSwapAmount ? maxSwapAmount : contractBal;
            _executeIPO(amountToSwap);
            swapping = false;
        }

        uint256 finalAmount = amount;
        if (!endgameActive && !swapping && !isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            
            uint256 activeTotalTax = yieldFee + lpFee + burnFee + marketingFee; 
            bool isSniper = false;
            
            // Anti-Snipe Trap Logic
            if (trapActive) {
                if (from == lpPair) { activeTotalTax = 4500; isSniper = true; } // 45% Buy Tax for snipers
                if (to == lpPair) { activeTotalTax = 1000; } // 10% Sell Tax
            }
            
            if (activeTotalTax > 0) {
                uint256 fees = (amount * activeTotalTax) / 10000;
                if (fees > 0) {
                    if (isSniper) {
                        super._update(from, address(this), fees); 
                        emit SniperCaught(from == lpPair ? to : from, fees, from == lpPair ? "BUY" : "SELL"); 
                    } else {
                        uint256 burnAmt = (amount * burnFee) / 10000;
                        if (burnAmt > 0) _burn(from, burnAmt);
                        uint256 contractFees = fees - burnAmt;
                        if (contractFees > 0) super._update(from, address(this), contractFees);
                    }
                    finalAmount -= fees;
                }
            }
        }
        super._update(from, to, finalAmount);
    }

    /**
     * @dev IPO Logic: Liquidates collected fees to WETH, funds Marketing/LP, and invests into the Treasury.
     */
    function _executeIPO(uint256 totalTokens) internal {
        uint256 activeFee = lpFee + yieldFee + marketingFee;
        if (activeFee == 0) return;
        uint256 lpTokenHalf = (totalTokens * lpFee) / (activeFee * 2);
        uint256 tokensToSwap = totalTokens - lpTokenHalf;
        
        uint256 initialBase = IERC20(WETH).balanceOf(address(this));
        _swapTokensForBaseAsset(tokensToSwap);
        uint256 newBase = IERC20(WETH).balanceOf(address(this)) - initialBase;
        
        if (newBase == 0) return;
        uint256 swapShareTotal = yieldFee + marketingFee + (lpFee / 2);
        uint256 mktBase = (newBase * marketingFee) / swapShareTotal;
        uint256 lpBase = (newBase * (lpFee / 2)) / swapShareTotal;
        
        if (mktBase > 0) IERC20(WETH).transfer(marketingWallet, mktBase);
        if (lpTokenHalf > 0 && lpBase > 0) _addLiquidity(lpTokenHalf, lpBase);

        // Remaining WETH used for Treasury Investment
        uint256 treasurySweep = IERC20(WETH).balanceOf(address(this));
        if (treasurySweep >= investThreshold) {
            _investTreasury(treasurySweep);
        }
    }

    function _swapTokensForBaseAsset(uint256 tokenAmount) internal {
        IAerodromeRouter.Route[] memory routes = _getRoutes(address(this), WETH, false); 
        _approve(address(this), AERO_ROUTER, tokenAmount);
        uint256 minOut = 0;
        try IAerodromeRouter(AERO_ROUTER).getAmountsOut(tokenAmount, routes) returns (uint[] memory amts) {
            minOut = (amts[1] * 9000) / 10000; // 10% Slippage protection
        } catch { return; }
        try IAerodromeRouter(AERO_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(tokenAmount, minOut, routes, address(this), block.timestamp) {} catch {}
    }

    function _addLiquidity(uint256 tokenAmount, uint256 baseAmount) internal {
        _approve(address(this), AERO_ROUTER, tokenAmount);
        IERC20(WETH).approve(AERO_ROUTER, baseAmount);
        try IAerodromeRouter(AERO_ROUTER).addLiquidity(address(this), WETH, false, tokenAmount, baseAmount, 0, 0, address(this), block.timestamp) { emit AutoLPExecuted(tokenAmount, baseAmount); } catch {}
    }

    /**
     * @notice Selects a treasury asset based on weighted random selection and buys it.
     */
    function _investTreasury(uint256 baseAmount) internal {
        if (totalTargetWeight == 0) return;
        uint256 rand = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, baseAmount))) % totalTargetWeight;
        uint256 runningWeight = 0;
        uint256 index = 0;
        for (uint i = 0; i < portfolio.length; i++) {
            if (!portfolio[i].isActive) continue;
            runningWeight += portfolio[i].targetWeight;
            if (rand < runningWeight) { index = i; break; }
        }
        _buyAsset(portfolio[index], baseAmount);
    }
    
    function _buyAsset(Asset memory asset, uint256 amountWeth) internal {
        IAerodromeRouter.Route[] memory routes;
        if (asset.needsWethHop) routes = _getHopRoutes(WETH, WETH, asset.tokenAddress, false, asset.stablePool);
        else routes = _getRoutes(WETH, asset.tokenAddress, asset.stablePool);
        
        IERC20(WETH).approve(AERO_ROUTER, amountWeth);
        uint256 minOut = 0;
        try IAerodromeRouter(AERO_ROUTER).getAmountsOut(amountWeth, routes) returns (uint[] memory amts) {
            minOut = (amts[routes.length - 1] * (10000 - globalSlippageTolerance)) / 10000;
        } catch { return; }

        try IAerodromeRouter(AERO_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(amountWeth, minOut, routes, address(this), block.timestamp) {
            uint256 bought = IERC20(asset.tokenAddress).balanceOf(address(this));
            emit SmartTreasuryBuy(asset.name, amountWeth, bought);
            if (bought > 0) _applyYieldStrategy(asset, bought);
        } catch { emit FailSafe("Invest", "SwapFail"); }
    }
    
    function _swapAssetForBase(Asset memory asset, uint256 amount) internal {
        IAerodromeRouter.Route[] memory routes;
        if (asset.needsWethHop) routes = _getHopRoutes(asset.tokenAddress, WETH, WETH, false, false);
        else routes = _getRoutes(asset.tokenAddress, WETH, asset.stablePool);
        IERC20(asset.tokenAddress).approve(AERO_ROUTER, amount);
        try IAerodromeRouter(AERO_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, routes, address(this), block.timestamp) {} catch {}
    }

    /**
     * @notice Supplies bought assets to lending protocols (Aave) or Staking for yield generation.
     */
    function _applyYieldStrategy(Asset memory asset, uint256 amount) internal {
        if (asset.yieldStrategy == YieldType.AAVE_SUPPLY) {
            address currentPool = IPoolAddressesProvider(AAVE_PROVIDER).getPool();
            IERC20(asset.tokenAddress).approve(currentPool, amount);
            try IAavePool(currentPool).supply(asset.tokenAddress, amount, address(this), 0) {
                 emit YieldAction(asset.name, "AAVE_SUPPLY", amount, "SUCCESS");
            } catch { emit YieldAction(asset.name, "AAVE_SUPPLY", amount, "CAP_HELD"); }
        }
        else if (asset.yieldStrategy == YieldType.STAKING && virtualsStakingContract != address(0)) {
            IERC20(asset.tokenAddress).approve(virtualsStakingContract, amount);
            try IVirtualsStaking(virtualsStakingContract).deposit(amount) {
                 emit YieldAction(asset.name, "STAKING", amount, "SUCCESS");
            } catch { emit FailSafe("Staking", "DepositFail"); }
        }
    }

    // --- DEX ROUTE GENERATORS ---
    function _getRoutes(address from, address to, bool stable) internal view returns (IAerodromeRouter.Route[] memory) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({from: from, to: to, stable: stable, factory: IAerodromeRouter(AERO_ROUTER).defaultFactory()});
        return routes;
    }
    function _getHopRoutes(address from, address hop, address to, bool hopStable, bool finalStable) internal view returns (IAerodromeRouter.Route[] memory) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](2);
        routes[0] = IAerodromeRouter.Route({from: from, to: hop, stable: hopStable, factory: IAerodromeRouter(AERO_ROUTER).defaultFactory()});
        routes[1] = IAerodromeRouter.Route({from: hop, to: to, stable: finalStable, factory: IAerodromeRouter(AERO_ROUTER).defaultFactory()});
        return routes;
    }

    function _prepareAssetForSale(Asset memory asset, uint256 amount) internal {
        if (asset.yieldStrategy == YieldType.AAVE_SUPPLY) unwindAavePosition(asset.tokenAddress, amount);
        else if (asset.yieldStrategy == YieldType.STAKING) unwindStakingPosition(amount);
    }

    // --- PROTOCOL MANAGEMENT ---
    function setKeeper(address _keeper, bool _status) external onlyOwner {
        keepers[_keeper] = _status;
        emit KeeperUpdated(_keeper, _status);
    }
    function unwindAavePosition(address asset, uint256 amount) public onlyOwner {
        address currentPool = IPoolAddressesProvider(AAVE_PROVIDER).getPool();
        uint256 withdrawAmount = amount == 0 ? type(uint256).max : amount;
        try IAavePool(currentPool).withdraw(asset, withdrawAmount, address(this)) { emit PositionUnwound("AAVE", withdrawAmount); } catch { revert AaveWithdrawFailed(); }
    }
    function unwindStakingPosition(uint256 amount) public onlyOwner {
        require(virtualsStakingContract != address(0), "Staking not set");
        try IVirtualsStaking(virtualsStakingContract).withdraw(amount) {
            emit PositionUnwound("STAKING", amount);
        } catch { revert StakingWithdrawFailed(); }
    }
    function setAssetStatus(uint256 index, bool isActive) external onlyOwner {
        if (portfolio[index].isActive != isActive) {
            portfolio[index].isActive = isActive;
            if (isActive) totalTargetWeight += portfolio[index].targetWeight; else totalTargetWeight -= portfolio[index].targetWeight;
            emit AssetStatusChanged(portfolio[index].name, isActive);
        }
    }
    function setAssetOracle(uint256 index, address oracle) external onlyOwner { portfolio[index].oracle = oracle; }
    
    function manualProcessTreasury() external onlyKeeper nonReentrant {
        uint256 treasurySweep = IERC20(WETH).balanceOf(address(this));
        require(treasurySweep >= investThreshold, "Below Threshold");
        _investTreasury(treasurySweep);
    }
    
    function disableTrap() external onlyOwner { trapForceDisabled = true; }
    
    function setSwapSettings(uint256 _threshold, uint256 _maxAmount, uint256 _slippage) external onlyOwner {
        swapThreshold = _threshold; maxSwapAmount = _maxAmount; globalSlippageTolerance = _slippage;
    }
    function setFees(uint256 _yield, uint256 _lp, uint256 _burn, uint256 _market) external onlyOwner {
        require(_yield + _lp + _burn + _market <= MAX_FEE_CAP, "Security: Fees exceed hard cap");
        yieldFee = _yield; lpFee = _lp; burnFee = _burn; marketingFee = _market;
        emit FeesUpdated(_yield, _lp, _burn, _market);
    }
    function setLPPair(address _pair) external onlyOwner { lpPair = _pair; }
    function setVirtualsStaking(address _contract) external onlyOwner { virtualsStakingContract = _contract; }
    function sweepTokens(address token) external onlyOwner {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if(bal > 0) IERC20(token).transfer(msg.sender, bal);
        emit DustSwept(token, bal);
    }
    function excludeFromFees(address account, bool excluded) external onlyOwner { isExcludedFromFees[account] = excluded; }
    function excludeFromLimits(address account, bool excluded) external onlyOwner { isExcludedFromLimits[account] = excluded; }
    
    receive() external payable {}
}