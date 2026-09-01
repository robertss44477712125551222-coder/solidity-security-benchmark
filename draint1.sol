pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract AsteriaReceivablesMarket {
    uint256 public constant BPS = 10_000;
    uint256 public constant INDEX = 1e18;
    uint256 public constant DEFAULT_GRACE = 1 days;
    uint256 public constant PREMIUM_TO_RESERVE_BPS = 8_000;

    IERC20 public immutable asset;
    address public owner;

    uint256 public nextFacilityId = 1;
    uint256 public nextNoteId = 1;

    uint256 public insuranceReserve;
    uint256 public protocolFees;

    bool private entered;

    enum FacilityStatus {
        None,
        Funding,
        Active,
        Repaid,
        Defaulted,
        Expired
    }

    struct Facility {
        address borrower;
        uint128 targetPrincipal;
        uint128 fundedPrincipal;
        uint64 fundingEndsAt;
        uint64 dueAt;
        uint32 termSeconds;
        uint32 interestBps;
        uint32 coverageBps;
        uint32 originationPremiumBps;
        uint32 insuranceInterestCutBps;
        bool premiumPaid;
        bool drawn;
        bool repaid;
        bool defaulted;
        uint256 repaymentEscrow;
        uint256 coverageEscrow;
        uint256 coverageIndex;
    }

    struct Note {
        uint256 facilityId;
        address owner;
        uint128 principal;
        bool settled;
    }

    mapping(address => bool) public approvedBorrower;
    mapping(uint256 => Facility) public facilities;
    mapping(uint256 => Note) public notes;
    mapping(uint256 => mapping(address => uint256)) private settlementDebt;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BorrowerApprovalChanged(address indexed borrower, bool approved);
    event FacilityCreated(
        uint256 indexed facilityId,
        address indexed borrower,
        uint256 targetPrincipal,
        uint256 fundingEndsAt,
        uint256 termSeconds,
        uint256 interestBps,
        uint256 coverageBps
    );
    event PremiumPaid(
        uint256 indexed facilityId,
        uint256 grossPremium,
        uint256 reserveContribution,
        uint256 protocolFee
    );
    event NoteCreated(
        uint256 indexed noteId,
        uint256 indexed facilityId,
        address indexed owner,
        uint256 principal
    );
    event NoteTransferred(
        uint256 indexed noteId,
        address indexed from,
        address indexed to
    );
    event FacilityDrawn(
        uint256 indexed facilityId,
        address indexed borrower,
        uint256 principal,
        uint256 dueAt
    );
    event FacilityRepaid(
        uint256 indexed facilityId,
        uint256 principal,
        uint256 grossInterest,
        uint256 insuranceCut,
        uint256 repaymentEscrow
    );
    event FacilityDefaulted(
        uint256 indexed facilityId,
        uint256 coverageEscrow,
        uint256 coverageIndex
    );
    event RepaidNoteRedeemed(
        uint256 indexed noteId,
        address indexed owner,
        address indexed receiver,
        uint256 amount
    );
    event DefaultCoverageClaimed(
        uint256 indexed noteId,
        address indexed owner,
        address indexed receiver,
        uint256 amount
    );
    event UnfundedNoteRefunded(
        uint256 indexed noteId,
        address indexed owner,
        address indexed receiver,
        uint256 amount
    );
    event InsuranceToppedUp(address indexed provider, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed receiver, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "OWNER");
        _;
    }

    modifier nonReentrant() {
        require(!entered, "REENTRANT");
        entered = true;
        _;
        entered = false;
    }

    constructor(IERC20 asset_) {
        require(address(asset_) != address(0), "ASSET");
        asset = asset_;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "ZERO");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setApprovedBorrower(address borrower, bool approved) external onlyOwner {
        require(borrower != address(0), "ZERO");
        approvedBorrower[borrower] = approved;
        emit BorrowerApprovalChanged(borrower, approved);
    }

    function createFacility(
        address borrower,
        uint256 targetPrincipal,
        uint256 fundingWindow,
        uint256 termSeconds,
        uint256 interestBps,
        uint256 coverageBps,
        uint256 originationPremiumBps,
        uint256 insuranceInterestCutBps
    ) external onlyOwner returns (uint256 facilityId) {
        require(approvedBorrower[borrower], "BORROWER");
        require(targetPrincipal > 0, "PRINCIPAL");
        require(fundingWindow >= 1 days, "FUNDING");
        require(termSeconds >= 7 days, "TERM");
        require(interestBps <= 5_000, "INTEREST");
        require(coverageBps <= BPS, "COVERAGE");
        require(originationPremiumBps <= 2_000, "PREMIUM");
        require(insuranceInterestCutBps <= BPS, "CUT");

        facilityId = nextFacilityId++;

        facilities[facilityId] = Facility({
            borrower: borrower,
            targetPrincipal: uint128(targetPrincipal),
            fundedPrincipal: 0,
            fundingEndsAt: uint64(block.timestamp + fundingWindow),
            dueAt: 0,
            termSeconds: uint32(termSeconds),
            interestBps: uint32(interestBps),
            coverageBps: uint32(coverageBps),
            originationPremiumBps: uint32(originationPremiumBps),
            insuranceInterestCutBps: uint32(insuranceInterestCutBps),
            premiumPaid: false,
            drawn: false,
            repaid: false,
            defaulted: false,
            repaymentEscrow: 0,
            coverageEscrow: 0,
            coverageIndex: 0
        });

        emit FacilityCreated(
            facilityId,
            borrower,
            targetPrincipal,
            block.timestamp + fundingWindow,
            termSeconds,
            interestBps,
            coverageBps
        );
    }

    function payOriginationPremium(uint256 facilityId) external nonReentrant {
        Facility storage facility = facilities[facilityId];

        require(facility.borrower != address(0), "FACILITY");
        require(msg.sender == facility.borrower, "BORROWER");
        require(!facility.premiumPaid, "PAID");
        require(!facility.drawn, "DRAWN");
        require(block.timestamp < facility.fundingEndsAt, "EXPIRED");

        uint256 grossPremium =
            uint256(facility.targetPrincipal) * facility.originationPremiumBps / BPS;

        require(grossPremium > 0, "ZERO_PREMIUM");

        _pull(msg.sender, grossPremium);

        uint256 reserveContribution =
            grossPremium * PREMIUM_TO_RESERVE_BPS / BPS;

        uint256 fee = grossPremium - reserveContribution;

        insuranceReserve += reserveContribution;
        protocolFees += fee;
        facility.premiumPaid = true;

        emit PremiumPaid(
            facilityId,
            grossPremium,
            reserveContribution,
            fee
        );
    }

    function fundFacility(
        uint256 facilityId,
        uint256 amount
    ) external nonReentrant returns (uint256 noteId) {
        Facility storage facility = facilities[facilityId];

        require(facility.borrower != address(0), "FACILITY");
        require(facility.premiumPaid, "PREMIUM");
        require(!facility.drawn, "DRAWN");
        require(!facility.repaid && !facility.defaulted, "CLOSED");
        require(block.timestamp < facility.fundingEndsAt, "EXPIRED");
        require(amount > 0, "AMOUNT");

        uint256 newFunded = uint256(facility.fundedPrincipal) + amount;
        require(newFunded <= facility.targetPrincipal, "TARGET");

        _pull(msg.sender, amount);

        facility.fundedPrincipal = uint128(newFunded);

        noteId = nextNoteId++;

        notes[noteId] = Note({
            facilityId: facilityId,
            owner: msg.sender,
            principal: uint128(amount),
            settled: false
        });

        emit NoteCreated(
            noteId,
            facilityId,
            msg.sender,
            amount
        );
    }

    function drawdown(uint256 facilityId) external nonReentrant {
        Facility storage facility = facilities[facilityId];

        require(facility.borrower != address(0), "FACILITY");
        require(msg.sender == facility.borrower, "BORROWER");
        require(facility.premiumPaid, "PREMIUM");
        require(!facility.drawn, "DRAWN");
        require(block.timestamp < facility.fundingEndsAt, "EXPIRED");
        require(
            facility.fundedPrincipal == facility.targetPrincipal,
            "NOT_FULL"
        );

        facility.drawn = true;
        facility.dueAt = uint64(block.timestamp + facility.termSeconds);

        _push(
            facility.borrower,
            facility.targetPrincipal
        );

        emit FacilityDrawn(
            facilityId,
            facility.borrower,
            facility.targetPrincipal,
            facility.dueAt
        );
    }

    function repay(uint256 facilityId) external nonReentrant {
        Facility storage facility = facilities[facilityId];

        require(facility.borrower != address(0), "FACILITY");
        require(msg.sender == facility.borrower, "BORROWER");
        require(facility.drawn, "NOT_DRAWN");
        require(!facility.repaid, "REPAID");
        require(!facility.defaulted, "DEFAULTED");

        uint256 principal = facility.targetPrincipal;
        uint256 grossInterest =
            principal * facility.interestBps / BPS;

        uint256 totalDue = principal + grossInterest;

        _pull(msg.sender, totalDue);

        uint256 insuranceCut =
            grossInterest * facility.insuranceInterestCutBps / BPS;

        uint256 lenderInterest = grossInterest - insuranceCut;

        insuranceReserve += insuranceCut;
        facility.repaymentEscrow = principal + lenderInterest;
        facility.repaid = true;

        emit FacilityRepaid(
            facilityId,
            principal,
            grossInterest,
            insuranceCut,
            facility.repaymentEscrow
        );
    }

    function markDefault(uint256 facilityId) external {
        Facility storage facility = facilities[facilityId];

        require(facility.borrower != address(0), "FACILITY");
        require(facility.drawn, "NOT_DRAWN");
        require(!facility.repaid, "REPAID");
        require(!facility.defaulted, "DEFAULTED");
        require(
            block.timestamp > uint256(facility.dueAt) + DEFAULT_GRACE,
            "GRACE"
        );

        facility.defaulted = true;

        uint256 maximumCoverage =
            uint256(facility.fundedPrincipal) * facility.coverageBps / BPS;

        uint256 allocated =
            insuranceReserve < maximumCoverage
                ? insuranceReserve
                : maximumCoverage;

        insuranceReserve -= allocated;
        facility.coverageEscrow = allocated;

        if (facility.fundedPrincipal > 0) {
            facility.coverageIndex =
                allocated * INDEX / facility.fundedPrincipal;
        }

        emit FacilityDefaulted(
            facilityId,
            facility.coverageEscrow,
            facility.coverageIndex
        );
    }

    function transferNote(
        uint256 noteId,
        address to
    ) external {
        Note storage note = notes[noteId];

        require(note.owner == msg.sender, "OWNER");
        require(to != address(0), "ZERO");
        require(!note.settled, "SETTLED");

        address from = note.owner;
        note.owner = to;

        emit NoteTransferred(
            noteId,
            from,
            to
        );
    }

    function redeemRepaidNote(
        uint256 noteId,
        address receiver
    ) external nonReentrant returns (uint256 payout) {
        Note storage note = notes[noteId];
        Facility storage facility = facilities[note.facilityId];

        require(note.owner == msg.sender, "OWNER");
        require(receiver != address(0), "ZERO");
        require(!note.settled, "SETTLED");
        require(facility.repaid, "NOT_REPAID");

        uint256 grossInterest =
            uint256(facility.targetPrincipal) * facility.interestBps / BPS;

        uint256 insuranceCut =
            grossInterest * facility.insuranceInterestCutBps / BPS;

        uint256 lenderInterest = grossInterest - insuranceCut;

        uint256 noteInterest =
            lenderInterest * note.principal / facility.targetPrincipal;

        payout = uint256(note.principal) + noteInterest;

        require(
            facility.repaymentEscrow >= payout,
            "ESCROW"
        );

        note.settled = true;
        facility.repaymentEscrow -= payout;

        _push(receiver, payout);

        emit RepaidNoteRedeemed(
            noteId,
            msg.sender,
            receiver,
            payout
        );
    }

    function claimDefaultCoverage(
        uint256 noteId,
        address receiver
    ) external nonReentrant returns (uint256 payout) {
        Note storage note = notes[noteId];
        Facility storage facility = facilities[note.facilityId];

        require(note.owner == msg.sender, "OWNER");
        require(receiver != address(0), "ZERO");
        require(!note.settled, "SETTLED");
        require(facility.defaulted, "NOT_DEFAULTED");

        uint256 grossEntitlement =
            uint256(note.principal) * facility.coverageIndex / INDEX;

        uint256 debt =
            settlementDebt[noteId][msg.sender];

        require(
            grossEntitlement > debt,
            "NO_COVERAGE"
        );

        payout = grossEntitlement - debt;

        require(
            facility.coverageEscrow >= payout,
            "ESCROW"
        );

        settlementDebt[noteId][msg.sender] =
            grossEntitlement;

        facility.coverageEscrow -= payout;

        _push(receiver, payout);

        emit DefaultCoverageClaimed(
            noteId,
            msg.sender,
            receiver,
            payout
        );
    }

    function refundUnfundedNote(
        uint256 noteId,
        address receiver
    ) external nonReentrant returns (uint256 amount) {
        Note storage note = notes[noteId];
        Facility storage facility = facilities[note.facilityId];

        require(note.owner == msg.sender, "OWNER");
        require(receiver != address(0), "ZERO");
        require(!note.settled, "SETTLED");
        require(!facility.drawn, "DRAWN");
        require(block.timestamp >= facility.fundingEndsAt, "FUNDING");

        amount = note.principal;

        note.settled = true;
        facility.fundedPrincipal -= note.principal;

        _push(receiver, amount);

        emit UnfundedNoteRefunded(
            noteId,
            msg.sender,
            receiver,
            amount
        );
    }

    function topUpInsurance(uint256 amount) external nonReentrant {
        require(amount > 0, "AMOUNT");

        _pull(msg.sender, amount);

        insuranceReserve += amount;

        emit InsuranceToppedUp(
            msg.sender,
            amount
        );
    }

    function withdrawProtocolFees(
        address receiver,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(receiver != address(0), "ZERO");
        require(amount <= protocolFees, "FEES");

        protocolFees -= amount;

        _push(receiver, amount);

        emit ProtocolFeesWithdrawn(
            receiver,
            amount
        );
    }

    function previewOriginationPremium(
        uint256 facilityId
    ) external view returns (
        uint256 grossPremium,
        uint256 reserveContribution,
        uint256 protocolFee
    ) {
        Facility storage facility = facilities[facilityId];

        grossPremium =
            uint256(facility.targetPrincipal) *
            facility.originationPremiumBps /
            BPS;

        reserveContribution =
            grossPremium * PREMIUM_TO_RESERVE_BPS / BPS;

        protocolFee =
            grossPremium - reserveContribution;
    }

    function previewRepayment(
        uint256 facilityId
    ) external view returns (
        uint256 principal,
        uint256 grossInterest,
        uint256 insuranceCut,
        uint256 lenderInterest,
        uint256 totalDue
    ) {
        Facility storage facility = facilities[facilityId];

        principal = facility.targetPrincipal;

        grossInterest =
            principal * facility.interestBps / BPS;

        insuranceCut =
            grossInterest *
            facility.insuranceInterestCutBps /
            BPS;

        lenderInterest =
            grossInterest - insuranceCut;

        totalDue =
            principal + grossInterest;
    }

    function previewNoteRepayment(
        uint256 noteId
    ) external view returns (uint256 payout) {
        Note storage note = notes[noteId];
        Facility storage facility = facilities[note.facilityId];

        uint256 grossInterest =
            uint256(facility.targetPrincipal) *
            facility.interestBps /
            BPS;

        uint256 insuranceCut =
            grossInterest *
            facility.insuranceInterestCutBps /
            BPS;

        uint256 lenderInterest =
            grossInterest - insuranceCut;

        uint256 noteInterest =
            lenderInterest *
            note.principal /
            facility.targetPrincipal;

        payout =
            uint256(note.principal) + noteInterest;
    }

    function previewDefaultCoverage(
        uint256 noteId,
        address holder
    ) external view returns (
        uint256 grossEntitlement,
        uint256 previouslyAccounted,
        uint256 claimable
    ) {
        Note storage note = notes[noteId];
        Facility storage facility = facilities[note.facilityId];

        grossEntitlement =
            uint256(note.principal) *
            facility.coverageIndex /
            INDEX;

        previouslyAccounted =
            settlementDebt[noteId][holder];

        if (grossEntitlement > previouslyAccounted) {
            claimable =
                grossEntitlement - previouslyAccounted;
        }
    }

    function facilityStatus(
        uint256 facilityId
    ) external view returns (FacilityStatus) {
        Facility storage facility = facilities[facilityId];

        if (facility.borrower == address(0)) {
            return FacilityStatus.None;
        }

        if (facility.defaulted) {
            return FacilityStatus.Defaulted;
        }

        if (facility.repaid) {
            return FacilityStatus.Repaid;
        }

        if (facility.drawn) {
            return FacilityStatus.Active;
        }

        if (block.timestamp >= facility.fundingEndsAt) {
            return FacilityStatus.Expired;
        }

        return FacilityStatus.Funding;
    }

    function noteOwner(
        uint256 noteId
    ) external view returns (address) {
        return notes[noteId].owner;
    }

    function notePrincipal(
        uint256 noteId
    ) external view returns (uint256) {
        return notes[noteId].principal;
    }

    function noteFacility(
        uint256 noteId
    ) external view returns (uint256) {
        return notes[noteId].facilityId;
    }

    function noteSettled(
        uint256 noteId
    ) external view returns (bool) {
        return notes[noteId].settled;
    }

    function _pull(
        address from,
        uint256 amount
    ) internal {
        require(
            asset.transferFrom(
                from,
                address(this),
                amount
            ),
            "TRANSFER_FROM"
        );
    }

    function _push(
        address to,
        uint256 amount
    ) internal {
        require(
            asset.transfer(
                to,
                amount
            ),
            "TRANSFER"
        );
    }
}
