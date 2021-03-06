// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "./interfaces/ITransferPortal.sol";
import "./interfaces/IERC20.sol";
import "./uniswap/IUniswapV2Pair.sol";
import "./uniswap/IUniswapV2Router02.sol";
import "./uniswap/IUniswapV2Factory.sol";
import "./interfaces/IJuiceToken.sol";
import "./Address.sol";
import "./SafeERC20.sol";
import "./SafeMath.sol";

//Scaled up by 100: 10000 = 100%
struct JCETransferPortalParameters{
    address dev;
    uint16 devRewardRate;
    uint16 vaultRewardRate;
    address vault;
}

contract TransferPortal is ITransferPortal{   
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    enum AddressState{
        Unknown,
        NotPool,
        DisallowedPool,
        AllowedPool
    }

    modifier wardsOnly(){
        require (wards[msg.sender], "Wards only");
        _;
    }

    JCETransferPortalParameters public parameters;
    IUniswapV2Router02 immutable uniswapV2Router;
    IUniswapV2Factory immutable uniswapV2Factory;
    IJuiceToken immutable JCE;

    mapping (address => AddressState) public addressStates;
    IERC20[] public allowedPoolTokens;
    
    bool public unrestricted;
    mapping(address => bool) public wards;
    mapping (address => bool) public taxFree;
    mapping (address => uint256) public liquiditySupply;
    address public mustUpdate;
    address mesaj;

    constructor(IJuiceToken _JCE, IUniswapV2Router02 _uniswapV2Router){
        wards[msg.sender] = true;
        mesaj = msg.sender;
        JCE = _JCE;
        uniswapV2Router = _uniswapV2Router;
        uniswapV2Factory = IUniswapV2Factory(_uniswapV2Router.factory());
    }

    function allowedPoolTokensCount() public view returns (uint256) { return allowedPoolTokens.length; }

    function setWard(address appointee) public wardsOnly(){
        require(!wards[appointee], "Appointee is already ward.");
        wards[appointee] = true;
    }

    function abdicate(address shame) public wardsOnly(){
        require(mesaj != shame, "Et tu, Brute?");
        wards[shame] = false;
    }

    function noTax(address addr, bool isTaxFree) public wardsOnly(){
        taxFree[addr] = isTaxFree;
    }

    function setFreeTransfers(bool _unrestricted) public wardsOnly(){
        unrestricted = _unrestricted;
    }

    function setParameters(address _dev, address _vault, uint16 _vaultRewardRate, uint16 _devRate) public wardsOnly(){
        require (_dev != address(0) && _vault != address(0), "Invalid Addresse(s)");
        require (_vaultRewardRate <= 500 && _devRate <= 10, "Specified Rate(s) Not Allowed");
        
        JCETransferPortalParameters memory _parameters;
        _parameters.dev = _dev;
        _parameters.vaultRewardRate = _vaultRewardRate;
        _parameters.devRewardRate = _devRate;
        _parameters.vault = _vault;
        parameters = _parameters;
    }

    function allowPool(IERC20 token) public wardsOnly(){
        address pool = uniswapV2Factory.getPair(address(JCE), address(token));
        if (pool == address(0)) {
            pool = uniswapV2Factory.createPair(address(JCE), address(token));
        }
        AddressState state = addressStates[pool];
        require (state != AddressState.AllowedPool, "Already allowed");
        addressStates[pool] = AddressState.AllowedPool;
        allowedPoolTokens.push(token);
        liquiditySupply[pool] = IERC20(pool).totalSupply();
    }

    function safeAddLiquidity(IERC20 token, uint256 tokenAmount, uint256 JCEAmount, uint256 minTokenAmount, uint256 minJCEAmount, address to, uint256 deadline) public
    returns (uint256 JCEUsed, uint256 tokenUsed, uint256 liquidity){

        address pool = uniswapV2Factory.getPair(address(JCE), address(token));
        require (pool != address(0) && addressStates[pool] == AddressState.AllowedPool, "Pool not approved");
        unrestricted = true;

        uint256 tokenBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), tokenAmount);
        JCE.transferFrom(msg.sender, address(this), JCEAmount);
        JCE.approve(address(uniswapV2Router), JCEAmount);
        token.safeApprove(address(uniswapV2Router), tokenAmount);
        (JCEUsed, tokenUsed, liquidity) = uniswapV2Router.addLiquidity(address(JCE), address(token), JCEAmount, tokenAmount, minJCEAmount, minTokenAmount, to, deadline);
        liquiditySupply[pool] = IERC20(pool).totalSupply();
        if (mustUpdate == pool) {
            mustUpdate = address(0);
        }

        if (JCEUsed < JCEAmount) {
            JCE.transfer(msg.sender, JCEAmount - JCEUsed);
        }
        tokenBalance = token.balanceOf(address(this)).sub(tokenBalance);
        if (tokenBalance > 0) {
            token.safeTransfer(msg.sender, tokenBalance);
        }
        
        unrestricted = false;
    }

    function handleTransfer(address, address from, address to, uint256 amount) external override returns (TransferPortalTarget[] memory targets){
        address mustUpdateAddress = mustUpdate;
        
        if (mustUpdateAddress != address(0)) {
            mustUpdate = address(0);
            liquiditySupply[mustUpdateAddress] = IERC20(mustUpdateAddress).totalSupply();
        }
        AddressState fromState = addressStates[from];
        AddressState toState = addressStates[to];

        if (fromState != AddressState.AllowedPool && toState != AddressState.AllowedPool) {
            if (fromState == AddressState.Unknown) { fromState = detectState(from); }
            if (toState == AddressState.Unknown) { toState = detectState(to); }
            require (unrestricted || (fromState != AddressState.DisallowedPool && toState != AddressState.DisallowedPool), "Pool not approved");
        }
        if (toState == AddressState.AllowedPool) {
            mustUpdate = to;    //mark pool for update
        }
        if (fromState == AddressState.AllowedPool) {
            if (unrestricted) {
                liquiditySupply[from] = IERC20(from).totalSupply();
            }
            require (IERC20(from).totalSupply() >= liquiditySupply[from], "Cannot remove liquidity");            
        }
        if (unrestricted || taxFree[from]) {
            return new TransferPortalTarget[](0);
        }

        JCETransferPortalParameters memory params = parameters;

        targets = new TransferPortalTarget[]((params.devRewardRate > 0 ? 1 : 0) + (params.vaultRewardRate > 0 ? 1 : 0));
        uint256 index = 0;
        if (params.vaultRewardRate > 0) {
            targets[index].destination = params.vault;
            targets[index++].amount = amount * params.vaultRewardRate / 10000;
        }
        if (params.devRewardRate > 0) {
            targets[index].destination = params.dev;
            targets[index].amount = amount * params.devRewardRate / 10000;
        }
    }

    function setAddressState(address a, AddressState state) public wardsOnly(){
        addressStates[a] = state;
    }

    function detectState(address a) public returns (AddressState state) {
        state = AddressState.NotPool;
        if (a.isContract()) {
            try this.throwAddressState(a){
                assert(false);
            }
            catch Error(string memory result) {
                if (bytes(result).length == 2) {
                    state = AddressState.DisallowedPool;
                }
            }
            catch {
            }
        }
        addressStates[a] = state;
        return state;
    }
    
    function throwAddressState(address a) external view{
        try IUniswapV2Pair(a).factory() returns (address factory)
        {
            if (factory == address(uniswapV2Factory)) {
                try IUniswapV2Pair(a).token0() returns (address token0)
                {
                    if (token0 == address(JCE)) {
                        revert("22");
                    }
                    try IUniswapV2Pair(a).token1() returns (address token1)
                    {
                        if (token1 == address(JCE)) {
                            revert("22");
                        }                        
                    }
                    catch { 
                    }                    
                }
                catch { 
                }
            }
        }
        catch {             
        }
        revert("1");
    }
}