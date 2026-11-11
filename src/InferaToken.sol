// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title InferaToken
/// @notice The INFERA ERC-20. The whole fixed supply is minted once, at deployment, to the launch
///         initializer, which puts it into the INFERA/ETH pool.
///
/// Launch protection (Programmable's required rules for new Ethereum launches):
///   - Before the initializer calls {start}, the only possible transfer is the initializer seeding the
///     pool (initializer -> PoolManager).
///   - For the first 300 seconds after {start}, every address can receive at most 2% of the supply
///     in total. Selling, forwarding or burning never restores that budget, and no address is
///     exempt. Transfers into the PoolManager (sells, liquidity) are not counted.
/// @dev No owner, no later minting, no transfer tax, no pause, no blocklist, no proxy or upgrade.
contract InferaToken {
    uint256 public constant WALLET_LIMIT_BPS = 200;
    uint256 public constant PROTECTION_SECONDS = 300;
    /// @dev The PoolManager accounts amounts as int128.
    uint256 private constant MAX_SUPPLY = 2 ** 127 - 1;

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;
    /// @notice The launch initializer: receives the supply and is the only caller of {start}.
    address public immutable initializer;
    /// @notice The Uniswap v4 PoolManager the supply is seeded into.
    address public immutable poolManager;
    /// @notice 2% of the supply: the most any address can receive during the protection window.
    uint256 public immutable walletTokenLimit;
    /// @notice When trading started (the launch block's timestamp); zero before the launch.
    uint256 public startedAt;
    /// @notice INFERA received by each address during the protection window.
    mapping(address account => uint256 amount) public receivedDuringProtection;

    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event TradingStarted(uint256 startedAt);

    error ZeroAddress();
    error InvalidConfiguration();
    error NotInitializer();
    error AlreadyStarted();
    error TradingNotStarted();
    error WalletLimitExceeded(address recipient, uint256 attempted, uint256 limit);
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply_,
        address initializer_,
        address poolManager_
    ) {
        if (
            bytes(name_).length == 0 || bytes(symbol_).length == 0 || supply_ < 50 || supply_ > MAX_SUPPLY
                || initializer_ == address(0) || poolManager_.code.length == 0 || initializer_ == poolManager_
        ) revert InvalidConfiguration();
        name = name_;
        symbol = symbol_;
        totalSupply = supply_;
        initializer = initializer_;
        poolManager = poolManager_;
        walletTokenLimit = supply_ * WALLET_LIMIT_BPS / 10_000;
        balanceOf[initializer_] = supply_;
        emit Transfer(address(0), initializer_, supply_);
    }

    /// @notice Opens trading and the protection window. Called once by the initializer, right after
    ///         it seeds the pool and before the first buy.
    function start() external {
        if (msg.sender != initializer) revert NotInitializer();
        if (startedAt != 0) revert AlreadyStarted();
        startedAt = block.timestamp;
        emit TradingStarted(block.timestamp);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 available = allowance[from][msg.sender];
        if (available != type(uint256).max) {
            if (available < amount) revert InsufficientAllowance(available, amount);
            unchecked {
                allowance[from][msg.sender] = available - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        if (amount != 0) {
            if (startedAt == 0) {
                // Before the launch, only the initializer's seed settlement can move tokens.
                if (from != initializer || to != poolManager) revert TradingNotStarted();
                // forge-lint: disable-next-line(block-timestamp) the protection window is defined in seconds
            } else if (block.timestamp < startedAt + PROTECTION_SECONDS && to != poolManager && from != to) {
                // Cumulative: what an address sends on never restores its budget. A self-transfer
                // neither gains nor consumes budget.
                uint256 received = receivedDuringProtection[to] + amount;
                if (received > walletTokenLimit) revert WalletLimitExceeded(to, received, walletTokenLimit);
                receivedDuringProtection[to] = received;
            }
        }
        uint256 available = balanceOf[from];
        if (available < amount) revert InsufficientBalance(available, amount);
        unchecked {
            balanceOf[from] = available - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
