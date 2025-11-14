// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IPairFactory.sol";
import "./interfaces/IPair.sol";
import "./interfaces/IAlgebraCLFactory.sol";

import "@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "./libraries/Math.sol";

interface ICustomPoolDeployer {
    function createCustomPool(
        address creator,
        address tokenA,
        address tokenB,
        bytes calldata data,
        uint160 initialPrice
    ) external returns (address customPool);

    function tickSpacing() external view returns (int24);
}

contract PairBootstrapper is Ownable {
    using SafeERC20 for IERC20;
    struct CreateBasicParams {
        address tokenA;
        address tokenB;
        bool stable;
        uint amountADesired;
        uint amountBDesired;
        address to;
    }

    struct CreateCLParams {
        address token0;
        address token1;
        address deployer; // CustomPoolDeployer address for chosen tick spacing
        uint160 initialSqrtPriceX96; // initial price for pool
        uint256 amount0Desired;
        uint256 amount1Desired;
        address recipient; // receiver of the NFT
        uint256 deadline;
    }

    struct DepositAmounts {
        uint256 amount0Desired;
        uint256 amount1Desired;
    }
    struct MintOutput {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
    }
    struct TickRange {
        int24 spacing;
        int24 tickLower;
        int24 tickUpper;
    }

    IPairFactory public immutable pairFactory;
    INonfungiblePositionManager public immutable nfpm;
    IAlgebraCLFactory public immutable algebraFactory;

    uint internal constant MINIMUM_LIQUIDITY = 10**3;
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    mapping(address => bool) public authorizedAccounts;

    event BasicPairCreatedAndSeeded(address indexed pair, address indexed tokenA, address indexed tokenB, bool stable, uint liquidity, uint amountAUsed, uint amountBUsed, address to);
    event CLPoolCreatedAndSeeded(address indexed pool, address deployer, int24 spacing, address indexed token0, address indexed token1, uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used, address recipient);
    event AuthorizedAccountAdded(address indexed account);
    event AuthorizedAccountRemoved(address indexed account);

    modifier onlyAuthorized() {
        require(authorizedAccounts[msg.sender] || msg.sender == owner(), "NA"); // Not Authorized
        _;
    }

    constructor(address _pairFactory, address _nfpm, address _algebraFactory) {
        require(_pairFactory != address(0) && _nfpm != address(0) && _algebraFactory != address(0), "ZA");
        pairFactory = IPairFactory(_pairFactory);
        nfpm = INonfungiblePositionManager(_nfpm);
        algebraFactory = IAlgebraCLFactory(_algebraFactory);
    }

    function sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        require(tokenA != address(0) && tokenB != address(0), "ZA");
        require(tokenA != tokenB, "IA");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }


    // -------- BASIC (V2-style) --------
    function _getMinimumLiquidity(uint amount0, uint amount1, uint decimals0, uint decimals1) internal pure returns (uint) {
        uint totalLiquidity = Math.sqrt(amount0 * amount1);
        // We need minimum reserves to satisfy:
        // _x >= 1e14 where _x = minReserve0 * 1e18 / decimals0
        // _y >= 1e14 where _y = minReserve1 * 1e18 / decimals1

        // This means:
        // minReserve0 >= 1e14 * decimals0 / 1e18
        // minReserve1 >= 1e14 * decimals1 / 1e18
        // minReserve0 >= decimals0 / 1e4
        // minReserve1 >= decimals1 / 1e4

        // Since minReserve0 = (amount0 * minimumLiquidity) / totalLiquidity
        // We can solve for minimumLiquidity:
        // minimumLiquidity >= (decimals0 / 1e4) * totalLiquidity / amount0
        // minimumLiquidity >= (decimals1 / 1e4) * totalLiquidity / amount1
        uint minLiquidity0 = (decimals0 * totalLiquidity) / (1e4 * amount0);
        uint minLiquidity1 = (decimals1 * totalLiquidity) / (1e4 * amount1);
        return Math.max(minLiquidity0, minLiquidity1);
    }

    function createBasicPairAndAddLiquidity(CreateBasicParams calldata p) external onlyAuthorized returns (address pair, uint amountA, uint amountB, uint liquidity) {
        // Check if pair already exists - revert if it does
        (address t0, address t1) = sortTokens(p.tokenA, p.tokenB);

        // Since this is a new pair, reserves are always 0
        // Sort amounts to match sorted token order
        bool tokensSwapped = p.tokenA > p.tokenB;
        amountA = tokensSwapped ? p.amountBDesired : p.amountADesired;
        amountB = tokensSwapped ? p.amountADesired : p.amountBDesired;
        require(amountA > 0 && amountB > 0, "SLP");
        pair = pairFactory.getPair(t0, t1, p.stable);
        require(pair == address(0), "PE"); // Pair Exists


        // Create the pair
        pair = pairFactory.createPair(t0, t1, p.stable);


        {
            // Read token decimals from pair metadata (for min liquidity calc)
            (uint dec0, uint dec1, , , , , ) = IPair(pair).metadata();
            // Transfer tokens directly from user to pair
            IERC20(t0).safeTransferFrom(msg.sender, pair, amountA);
            IERC20(t1).safeTransferFrom(msg.sender, pair, amountB);
            // Mint LP to this contract, then enforce minimum burn and forward remainder to user
            liquidity = IPair(pair).mint(address(this));

            // Determine minimum liquidity required
            uint minimumLiquidity = p.stable
                ? _getMinimumLiquidity(amountA, amountB, dec0, dec1)
                : MINIMUM_LIQUIDITY;
            uint burned = IERC20(pair).balanceOf(address(0));
            if (burned < minimumLiquidity) {
                uint shortfall = minimumLiquidity - burned;
                require(shortfall <= liquidity, "IL"); // Insufficient Liquidity to meet minimum burn
                // Burn the shortfall to meet minimum liquidity requirement
                IERC20(pair).transfer(address(0), shortfall);
                liquidity = liquidity - shortfall;
            }
            // Forward remaining LP to recipient
            if (liquidity > 0) {
                IERC20(pair).transfer(p.to, liquidity);
            }
        }

        emit BasicPairCreatedAndSeeded(pair, t0, t1, p.stable, liquidity, amountA, amountB, p.to);
    }

    // -------- CONCENTRATED LIQUIDITY (Algebra) --------

    function _clAmounts(CreateCLParams memory p) private pure returns (DepositAmounts memory depositAmts) {
        bool tokensSwapped = p.token0 > p.token1;
        depositAmts.amount0Desired = tokensSwapped ? p.amount1Desired : p.amount0Desired;
        depositAmts.amount1Desired = tokensSwapped ? p.amount0Desired : p.amount1Desired;
    }

    function _tickRange(address deployer) private view returns (TickRange memory t) {
        t.spacing = ICustomPoolDeployer(deployer).tickSpacing();
        t.tickLower = int24((MIN_TICK / t.spacing) * t.spacing);
        t.tickUpper = int24((MAX_TICK / t.spacing) * t.spacing);
    }

    function _mintCLFull(
        address token0,
        address token1,
        address deployer,
        DepositAmounts memory amounts,
        address recipient,
        uint256 deadline
    ) private returns (MintOutput memory mo, TickRange memory t) {
        IERC20(token0).safeTransferFrom(msg.sender, address(this), amounts.amount0Desired);
        IERC20(token0).forceApprove(address(nfpm), amounts.amount0Desired);
        IERC20(token1).safeTransferFrom(msg.sender, address(this), amounts.amount1Desired);
        IERC20(token1).forceApprove(address(nfpm), amounts.amount1Desired);
        amounts.amount0Desired = IERC20(token0).balanceOf(address(this));
        amounts.amount1Desired = IERC20(token1).balanceOf(address(this));

        t = _tickRange(deployer);
        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            deployer: deployer,
            tickLower: t.tickLower,
            tickUpper: t.tickUpper,
            amount0Desired: amounts.amount0Desired,
            amount1Desired: amounts.amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: recipient,
            deadline: deadline
        });
        (mo.tokenId, mo.liquidity, mo.amount0, mo.amount1) = nfpm.mint(mp);
    }


    function createCLPoolAndAddFullRange(CreateCLParams calldata p_) external onlyAuthorized returns (address pool, uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        require(p_.deadline >= block.timestamp, "EXP");
        CreateCLParams memory p = p_;
        (address token0, address token1) = sortTokens(p.token0, p.token1);
        pool = algebraFactory.customPoolByPair(p.deployer, token0, token1);
        require(pool == address(0), "PE");
        pool = ICustomPoolDeployer(p.deployer).createCustomPool(
            msg.sender, token0, token1, new bytes(0), p.initialSqrtPriceX96
        );
        DepositAmounts memory depositAmts = _clAmounts(p);
        require(depositAmts.amount0Desired > 0 && depositAmts.amount1Desired > 0, "ZA");
        MintOutput memory mo;
        TickRange memory t;
        (mo, t) = _mintCLFull(
            token0,
            token1,
            p.deployer,
            depositAmts,
            p.recipient,
            p.deadline
        );
        if (IERC20(token0).balanceOf(address(this)) > 0) {
            IERC20(token0).transfer(msg.sender, IERC20(token0).balanceOf(address(this)));
        }
        if (IERC20(token1).balanceOf(address(this)) > 0) {
            IERC20(token1).transfer(msg.sender, IERC20(token1).balanceOf(address(this)));
        }
        emit CLPoolCreatedAndSeeded(pool, p.deployer, t.spacing, token0, token1, mo.tokenId, mo.liquidity, mo.amount0, mo.amount1, p.recipient);
        return (pool, mo.tokenId, mo.liquidity, mo.amount0, mo.amount1);
    }

    // -------- AUTHORIZATION MANAGEMENT --------

    function addAuthorizedAccount(address account) external onlyOwner {
        require(account != address(0), "ZA");
        require(!authorizedAccounts[account], "AA"); // Already Authorized
        authorizedAccounts[account] = true;
        emit AuthorizedAccountAdded(account);
    }

    function removeAuthorizedAccount(address account) external onlyOwner {
        require(account != address(0), "ZA");
        require(authorizedAccounts[account], "NA"); // Not Authorized
        authorizedAccounts[account] = false;
        emit AuthorizedAccountRemoved(account);
    }
}