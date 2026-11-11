// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title InferaToken
/// @notice The INFERA ERC-20. The whole fixed supply is minted once, at deployment, to the launch
///         initializer, which puts it into the INFERA/ETH pool.
/// @dev No owner, no later minting, no transfer tax, no pause, no blocklist, no proxy or upgrade.
contract InferaToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error ZeroAddress();
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);

    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient_) {
        if (recipient_ == address(0)) revert ZeroAddress();
        name = name_;
        symbol = symbol_;
        totalSupply = supply_;
        balanceOf[recipient_] = supply_;
        emit Transfer(address(0), recipient_, supply_);
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
        uint256 available = balanceOf[from];
        if (available < amount) revert InsufficientBalance(available, amount);
        unchecked {
            balanceOf[from] = available - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
