// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract Vault {
    address public owner;
    address public treasury;

    bool public paused;

    uint256 public feeBps = 50;
    uint256 public minDeposit = 0.01 ether;
    uint256 public maxAccountBalance = 100 ether;
    uint256 public withdrawalCooldown = 1 hours;

    uint256 public totalDeposits;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lastDepositAt;

    event Deposited(
        address indexed account,
        uint256 amount
    );

    event Withdrawn(
        address indexed account,
        address indexed recipient,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 fee
    );

    event Paused(
        address indexed caller
    );

    event Unpaused(
        address indexed caller
    );

    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    event FeeUpdated(
        uint256 oldFee,
        uint256 newFee
    );

    event LimitsUpdated(
        uint256 minDeposit,
        uint256 maxAccountBalance
    );

    event CooldownUpdated(
        uint256 oldCooldown,
        uint256 newCooldown
    );

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(address initialTreasury) {
        require(initialTreasury != address(0), "zero treasury");

        owner = msg.sender;
        treasury = initialTreasury;
    }

    function deposit()
        external
        payable
        whenNotPaused
    {
        require(msg.value >= minDeposit, "deposit too small");

        uint256 newBalance =
            balances[msg.sender] + msg.value;

        require(
            newBalance <= maxAccountBalance,
            "account limit"
        );

        balances[msg.sender] = newBalance;
        totalDeposits += msg.value;
        lastDepositAt[msg.sender] = block.timestamp;

        emit Deposited(
            msg.sender,
            msg.value
        );
    }

    function withdraw(
        uint256 amount,
        address payable recipient
    )
        external
        whenNotPaused
    {
        require(amount > 0, "zero amount");
        require(recipient != address(0), "zero recipient");

        uint256 userBalance = balances[msg.sender];

        require(
            userBalance >= amount,
            "insufficient balance"
        );

        require(
            block.timestamp
                >= lastDepositAt[msg.sender]
                    + withdrawalCooldown,
            "cooldown"
        );

        uint256 fee =
            (amount * feeBps) / 10_000;

        uint256 amountAfterFee =
            amount - fee;

        uint256 currentTotal =
            totalDeposits;

        (bool sent, ) =
            recipient.call{value: amountAfterFee}("");

        require(sent, "transfer failed");

        balances[msg.sender] =
            userBalance - amount;

        totalDeposits =
            currentTotal - amount;

        if (fee > 0) {
            (bool feeSent, ) =
                payable(treasury).call{value: fee}("");

            require(feeSent, "fee transfer failed");
        }

        emit Withdrawn(
            msg.sender,
            recipient,
            amount,
            amountAfterFee,
            fee
        );
    }

    function availableBalance(
        address account
    )
        external
        view
        returns (uint256)
    {
        return balances[account];
    }

    function canWithdraw(
        address account
    )
        external
        view
        returns (bool)
    {
        if (paused) {
            return false;
        }

        if (balances[account] == 0) {
            return false;
        }

        return
            block.timestamp
                >= lastDepositAt[account]
                    + withdrawalCooldown;
    }

    function setPaused(
        bool newPaused
    )
        external
        onlyOwner
    {
        paused = newPaused;

        if (newPaused) {
            emit Paused(msg.sender);
        } else {
            emit Unpaused(msg.sender);
        }
    }

    function setTreasury(
        address newTreasury
    )
        external
        onlyOwner
    {
        require(
            newTreasury != address(0),
            "zero treasury"
        );

        address oldTreasury = treasury;
        treasury = newTreasury;

        emit TreasuryUpdated(
            oldTreasury,
            newTreasury
        );
    }

    function setFee(
        uint256 newFeeBps
    )
        external
        onlyOwner
    {
        require(
            newFeeBps <= 500,
            "fee too high"
        );

        uint256 oldFee = feeBps;
        feeBps = newFeeBps;

        emit FeeUpdated(
            oldFee,
            newFeeBps
        );
    }

    function setDepositLimits(
        uint256 newMinimum,
        uint256 newMaximum
    )
        external
        onlyOwner
    {
        require(
            newMinimum > 0,
            "zero minimum"
        );

        require(
            newMaximum >= newMinimum,
            "invalid limits"
        );

        minDeposit = newMinimum;
        maxAccountBalance = newMaximum;

        emit LimitsUpdated(
            newMinimum,
            newMaximum
        );
    }

    function setWithdrawalCooldown(
        uint256 newCooldown
    )
        external
        onlyOwner
    {
        require(
            newCooldown <= 7 days,
            "cooldown too long"
        );

        uint256 oldCooldown =
            withdrawalCooldown;

        withdrawalCooldown =
            newCooldown;

        emit CooldownUpdated(
            oldCooldown,
            newCooldown
        );
    }

    receive() external payable {
        revert("use deposit");
    }
}
