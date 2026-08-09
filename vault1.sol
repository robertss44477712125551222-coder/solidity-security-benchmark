pragma solidity ^0.8.24; contract Vault {
    uint256 public constant BPS = 10_000;
    address public owner;
    address public pendingOwner;
    address public treasury;
    bool public paused;
    uint256 private entered;
    uint256 public minDeposit = 0.01 ether;
    uint256 public maxAccountShares = 250 ether;
    uint256 public earlyExitWindow = 3 days;
    uint256 public maturityWindow = 21 days;
    uint256 public movementCooldown = 30 minutes;
    uint256 public earlyExitFeeBps = 150;
    uint256 public maturityBonusBps = 75;
    uint256 public maxBonusPerWithdrawal = 0.5 ether;
    uint256 public totalShares;
    uint256 public totalPrincipal;
    uint256 public rewardReserve;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public maturityStart;
    mapping(address => uint256) public lastMovementAt;
    event OwnershipTransferStarted(address indexed currentOwner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event PauseStatusUpdated(bool paused);
    event DepositLimitsUpdated(uint256 minimum, uint256 maximum);
    event ExitConfigurationUpdated(uint256 earlyWindow, uint256 matureWindow, uint256 cooldown);
    event ExitEconomicsUpdated(uint256 earlyFeeBps, uint256 matureBonusBps, uint256 maxBonus);
    event Deposited(address indexed payer, address indexed account, uint256 assets, uint256 sharesMinted);
    event SharesTransferred(address indexed from, address indexed to, uint256 amount);
    event Withdrawn(address indexed account, address indexed recipient, uint256 principal, uint256 fee, uint256 bonus, uint256 amountSent);
    event RewardsFunded(address indexed funder, uint256 amount);
    event RewardsWithdrawn(address indexed recipient, uint256 amount);
    event ExcessSwept(address indexed recipient, uint256 amount);
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _; } modifier whenNotPaused() {
        require(!paused, "paused");
        _; } modifier nonReentrant() {
        require(entered == 0, "reentrant");
        entered = 1; _; entered = 0; }
    constructor(address initialTreasury) {
        require(initialTreasury != address(0), "zero treasury");
        owner = msg.sender;
        treasury = initialTreasury; }
    function beginOwnershipTransfer(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero owner");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }
    function cancelOwnershipTransfer() external onlyOwner {
        pendingOwner = address(0);
        emit OwnershipTransferStarted(owner, address(0));
    }
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }
    function setPaused(bool newPaused) external onlyOwner {
        paused = newPaused;
        emit PauseStatusUpdated(newPaused);
    }
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "zero treasury");
        address previousTreasury = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(previousTreasury, newTreasury);
    }
    function setDepositLimits(uint256 newMinimum, uint256 newMaximum) external onlyOwner {
        require(newMinimum > 0, "zero minimum");
        require(newMaximum >= newMinimum, "invalid maximum");
        minDeposit = newMinimum;
        maxAccountShares = newMaximum;
        emit DepositLimitsUpdated(newMinimum, newMaximum);
    } function setExitConfiguration(
        uint256 newEarlyWindow,
        uint256 newMaturityWindow,
        uint256 newMovementCooldown
    ) external onlyOwner {
        require(newEarlyWindow <= 14 days, "early window too long");
        require(newMaturityWindow >= newEarlyWindow, "invalid maturity");
        require(newMaturityWindow <= 90 days, "maturity too long");
        require(newMovementCooldown <= 2 days, "cooldown too long");
        earlyExitWindow = newEarlyWindow;
        maturityWindow = newMaturityWindow;
        movementCooldown = newMovementCooldown;
        emit ExitConfigurationUpdated(newEarlyWindow, newMaturityWindow, newMovementCooldown);
    } function setExitEconomics(
        uint256 newEarlyFeeBps,
        uint256 newMaturityBonusBps,
        uint256 newMaxBonus
    ) external onlyOwner {
        require(newEarlyFeeBps <= 1_000, "fee too high");
        require(newMaturityBonusBps <= 500, "bonus too high");
        earlyExitFeeBps = newEarlyFeeBps;
        maturityBonusBps = newMaturityBonusBps;
        maxBonusPerWithdrawal = newMaxBonus;
        emit ExitEconomicsUpdated(newEarlyFeeBps, newMaturityBonusBps, newMaxBonus);
    }
    function deposit() external payable whenNotPaused {
        _deposit(msg.sender, msg.sender, msg.value);
    }
    function depositFor(address account) external payable whenNotPaused {
        require(account != address(0), "zero account");
        _deposit(msg.sender, account, msg.value);
    }
    function transferShares(address to, uint256 amount) external whenNotPaused {
        require(to != address(0), "zero recipient");
        require(to != msg.sender, "self transfer");
        require(amount > 0, "zero amount");
        uint256 senderShares = shares[msg.sender];
        require(senderShares >= amount, "insufficient shares");
        uint256 recipientShares = shares[to];
        require(recipientShares + amount <= maxAccountShares, "account limit");
        uint256 senderStart = maturityStart[msg.sender];
        shares[msg.sender] = senderShares - amount;
        shares[to] = recipientShares + amount;
        lastMovementAt[msg.sender] = block.timestamp;
        lastMovementAt[to] = block.timestamp;
        if (shares[msg.sender] == 0) {
            maturityStart[msg.sender] = 0;
        }
        _mergeTransferredMaturity(to, amount, senderStart);
        emit SharesTransferred(msg.sender, to, amount);
    }
    function withdraw(uint256 amount, address payable recipient)
        external whenNotPaused
        nonReentrant {
        require(amount > 0, "zero amount");
        require(recipient != address(0), "zero recipient");
        uint256 accountShares = shares[msg.sender];
        require(accountShares >= amount, "insufficient shares");
        require(block.timestamp >= lastMovementAt[msg.sender] + movementCooldown, "movement cooldown");
        (uint256 fee, uint256 bonus, uint256 amountToSend) = _quoteExit(msg.sender, amount);
        shares[msg.sender] = accountShares - amount;
        totalShares -= amount;
        totalPrincipal -= amount;
        if (shares[msg.sender] == 0) {
            maturityStart[msg.sender] = 0;
        }
        lastMovementAt[msg.sender] = block.timestamp;
        if (bonus > 0) {
            rewardReserve -= bonus; }
        _sendValue(recipient, amountToSend);
        if (fee > 0) {
            _sendValue(payable(treasury), fee);
        }
        emit Withdrawn(msg.sender, recipient, amount, fee, bonus, amountToSend);
    }
    function fundRewards() external payable {
        require(msg.value > 0, "zero reward");
        rewardReserve += msg.value;
        emit RewardsFunded(msg.sender, msg.value);
    }
    function withdrawRewardReserve(uint256 amount, address payable recipient)
        external onlyOwner nonReentrant {
        require(recipient != address(0), "zero recipient");
        require(amount <= rewardReserve, "insufficient reserve");
        rewardReserve -= amount;
        _sendValue(recipient, amount);
        emit RewardsWithdrawn(recipient, amount);
    }
    function sweepExcess(address payable recipient) external onlyOwner nonReentrant {
        require(recipient != address(0), "zero recipient");
        uint256 accounted = totalPrincipal + rewardReserve;
        uint256 currentBalance = address(this).balance;
        require(currentBalance > accounted, "no excess");
        uint256 excess = currentBalance - accounted;
        _sendValue(recipient, excess);
        emit ExcessSwept(recipient, excess);
    }
    function previewWithdrawal(address account, uint256 amount)
        external view
        returns (uint256 fee, uint256 bonus, uint256 amountToSend)
    {
        require(amount <= shares[account], "insufficient shares");
        return _quoteExit(account, amount);
    }
    function accountAge(address account) external view returns (uint256) {
        uint256 start = maturityStart[account];
        if (start == 0 || start > block.timestamp) {
            return 0; }
        return block.timestamp - start; }
    function canWithdraw(address account, uint256 amount) external view returns (bool) {
        if (paused) { return false; }
        if (amount == 0 || amount > shares[account]) {
            return false; }
        if (block.timestamp < lastMovementAt[account] + movementCooldown) {
            return false;
        } return true; }
    function accountValue(address account) external view returns (uint256) {
        return shares[account]; }
    function accountedBalance() external view returns (uint256) {
        return totalPrincipal + rewardReserve;
    }
    function excessBalance() external view returns (uint256) {
        uint256 accounted = totalPrincipal + rewardReserve;
        uint256 currentBalance = address(this).balance;
        if (currentBalance <= accounted) {
            return 0; }
        return currentBalance - accounted;
    }
    function exitTier(address account) external view returns (uint8) {
        uint256 start = maturityStart[account];
        if (start == 0 || start > block.timestamp) {
            return 0; }
        uint256 age = block.timestamp - start;
        if (age < earlyExitWindow) {
            return 1; }
        if (age < maturityWindow) {
            return 2; } return 3; }
    function configuration()
        external view returns (
            uint256 minimum,
            uint256 maximum,
            uint256 earlyWindow,
            uint256 matureWindow,
            uint256 cooldown
        ) { return ( minDeposit,
            maxAccountShares,
            earlyExitWindow,
            maturityWindow,
            movementCooldown ); }
    function economics()
        external view returns (
            uint256 earlyFee,
            uint256 matureBonus,
            uint256 maxBonus,
            uint256 reserve
        ) { return ( earlyExitFeeBps,
            maturityBonusBps,
            maxBonusPerWithdrawal,
            rewardReserve ); }
    function _deposit(address payer, address account, uint256 amount) internal {
        require(amount >= minDeposit, "deposit too small");
        uint256 oldShares = shares[account];
        uint256 newShares = oldShares + amount;
        require(newShares <= maxAccountShares, "account limit");
        _mergeDepositMaturity(account, oldShares, amount);
        shares[account] = newShares;
        totalShares += amount;
        totalPrincipal += amount;
        lastMovementAt[account] = block.timestamp;
        emit Deposited(payer, account, amount, amount);
    } function _mergeDepositMaturity(
        address account,
        uint256 oldShares,
        uint256 incomingShares
    ) internal { if (oldShares == 0) {
            maturityStart[account] = block.timestamp;
            return; }
        uint256 oldStart = maturityStart[account];
        uint256 weightedOld = oldStart * oldShares;
        uint256 weightedIncoming = block.timestamp * incomingShares;
        maturityStart[account] =
            (weightedOld + weightedIncoming) / (oldShares + incomingShares);
    } function _mergeTransferredMaturity(
        address account,
        uint256 incomingShares,
        uint256 incomingStart
    ) internal {
        uint256 currentShares = shares[account];
        if (currentShares == incomingShares) {
            maturityStart[account] = incomingStart;
            return; }
        uint256 currentStart = maturityStart[account];
        uint256 weightedCurrent = currentStart * currentShares;
        uint256 weightedIncoming = incomingStart * incomingShares;
        maturityStart[account] =
            (weightedCurrent + weightedIncoming) / (currentShares + incomingShares);
    }
    function _quoteExit(address account, uint256 amount)
        internal view
        returns (uint256 fee, uint256 bonus, uint256 amountToSend)
    {
        uint256 start = maturityStart[account];
        uint256 age;
        if (start != 0 && start <= block.timestamp) {
            age = block.timestamp - start;
        } if (age < earlyExitWindow) {
            fee = (amount * earlyExitFeeBps) / BPS;
        } else if (age >= maturityWindow) {
            bonus = (amount * maturityBonusBps) / BPS;
            if (bonus > maxBonusPerWithdrawal) {
                bonus = maxBonusPerWithdrawal;
            }
            if (bonus > rewardReserve) {
                bonus = rewardReserve;
            } }
        amountToSend = amount - fee + bonus;
    }
    function _sendValue(address payable recipient, uint256 amount) internal {
        (bool sent, ) = recipient.call{value: amount}("");
        require(sent, "transfer failed");
    } receive() external payable {
        revert("use deposit or fundRewards");
    } }
