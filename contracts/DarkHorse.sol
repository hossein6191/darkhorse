// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {euint256, ebool, e, inco} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";

/// @title DarkHorse — hidden-side parimutuel prediction markets on Inco Lightning
///
/// @notice A parimutuel (pool-based) YES/NO prediction market where the SIZE of
/// every bet is public (it is native ETH, public by nature) but the SIDE of every
/// bet is encrypted with Inco's `ebool` until the market resolves.
///
/// Why: on transparent prediction markets, everyone watches where the smart money
/// goes, which distorts the odds (bandwagon effect / copy-trading) before close.
/// DarkHorse keeps the running YES/NO totals encrypted on-chain — nobody, not even
/// the market creator, can read which way the pool leans before resolution.
///
/// Privacy model (deliberate, documented):
///   - PUBLIC:  bettor address, stake amount, total pot, number of bettors.
///   - SECRET:  each bettor's side, the running YES total, the running NO total.
///   - REVEALED at settlement: the aggregate winning-side total (via covalidator
///     attestation, verified on-chain), and — only when a bettor opts to claim —
///     that bettor's own winning stake (0 for losers who call prepareClaim).
///
/// Trust model: Inco Lightning is TEE-based (Intel TDX) confidential compute.
/// Reveals are backed by covalidator-signed decryption attestations verified via
/// `inco.incoVerifier().isValidDecryptionAttestation`, not zero-knowledge proofs.
contract DarkHorse {
    using e for *;

    // ---------------------------------------------------------------- types

    enum Outcome {
        Unresolved,
        Yes,
        No,
        Canceled
    }

    struct Market {
        string question;
        address resolver;
        uint64 closeTime; // betting closes at this timestamp
        Outcome outcome;
        uint256 pot; // sum of all public stakes
        euint256 totalYes; // encrypted sum staked on YES
        euint256 totalNo; // encrypted sum staked on NO
        uint256 winningTotal; // plaintext winning-side total, post-attestation
        bool totalsSubmitted;
    }

    // --------------------------------------------------------------- errors

    error MarketNotFound();
    error BettingClosed();
    error BettingStillOpen();
    error AlreadyBet();
    error NothingStaked();
    error StakeRequired();
    error NotResolver();
    error AlreadyResolved();
    error NotResolved();
    error TotalsAlreadySubmitted();
    error TotalsNotSubmitted();
    error InvalidAttestation();
    error HandleMismatch();
    error AlreadyClaimed();
    error ClaimNotPrepared();
    error NotRefundable();
    error EthTransferFailed();
    error CloseTimeInPast();

    // --------------------------------------------------------------- events

    event MarketCreated(
        uint256 indexed marketId, address indexed resolver, string question, uint64 closeTime
    );
    /// @dev Deliberately carries NO side information — amount only.
    event BetPlaced(uint256 indexed marketId, address indexed bettor, uint256 amount);
    event MarketResolved(uint256 indexed marketId, Outcome outcome, bytes32 winningTotalHandle);
    event MarketCanceled(uint256 indexed marketId);
    event WinningTotalSubmitted(uint256 indexed marketId, uint256 winningTotal);
    event ClaimPrepared(uint256 indexed marketId, address indexed bettor, bytes32 winStakeHandle);
    event Claimed(uint256 indexed marketId, address indexed bettor, uint256 winStake, uint256 payout);
    event Refunded(uint256 indexed marketId, address indexed bettor, uint256 amount);

    // -------------------------------------------------------------- storage

    uint256 public marketCount;
    mapping(uint256 => Market) internal markets;

    /// Public stake per bettor (ETH amounts are public by nature — by design).
    mapping(uint256 => mapping(address => uint256)) public stakeOf;
    /// Encrypted side per bettor: true = YES, false = NO.
    mapping(uint256 => mapping(address => ebool)) internal sideOf;
    /// Encrypted "how much of my stake landed on the winning side" (set by prepareClaim).
    mapping(uint256 => mapping(address => euint256)) internal winStakeOf;
    mapping(uint256 => mapping(address => bool)) public claimed;

    // ------------------------------------------------------------ lifecycle

    /// @notice Open a new market. The creator is its resolver.
    function createMarket(string calldata question, uint64 closeTime)
        external
        returns (uint256 marketId)
    {
        if (closeTime <= block.timestamp) revert CloseTimeInPast();

        marketId = marketCount++;
        Market storage m = markets[marketId];
        m.question = question;
        m.resolver = msg.sender;
        m.closeTime = closeTime;

        // Initialize encrypted totals to E(0) and keep contract access to fold
        // future bets into them (allowThis is mandatory — access is lost forever
        // otherwise).
        m.totalYes = e.asEuint256(0);
        m.totalNo = e.asEuint256(0);
        m.totalYes.allowThis();
        m.totalNo.allowThis();

        emit MarketCreated(marketId, msg.sender, question, closeTime);
    }

    /// @notice Place a bet. `sideCiphertext` is an Inco-encrypted ebool created
    /// client-side (true = YES). The stake is `msg.value` minus the Inco fee.
    /// One bet per address per market.
    function placeBet(uint256 marketId, bytes calldata sideCiphertext) external payable {
        Market storage m = _market(marketId);
        if (block.timestamp >= m.closeTime || m.outcome != Outcome.Unresolved) {
            revert BettingClosed();
        }
        if (stakeOf[marketId][msg.sender] != 0) revert AlreadyBet();

        uint256 fee = inco.getFee(); // ingesting one ciphertext costs one fee
        if (msg.value <= fee) revert StakeRequired();
        uint256 stake = msg.value - fee;

        // Decrypt-side handle: only this contract and the bettor may access it.
        ebool side = sideCiphertext.newEbool(msg.sender);
        side.allowThis();
        side.allow(msg.sender); // bettor can privately verify their own recorded side

        // Fold the stake into the encrypted running totals without branching:
        // if side == YES then totalYes += stake else totalNo += stake.
        euint256 stakeE = e.asEuint256(stake);
        euint256 zero = e.asEuint256(0);
        m.totalYes = m.totalYes.add(side.select(stakeE, zero));
        m.totalNo = m.totalNo.add(side.select(zero, stakeE));
        m.totalYes.allowThis();
        m.totalNo.allowThis();

        sideOf[marketId][msg.sender] = side;
        stakeOf[marketId][msg.sender] = stake;
        m.pot += stake;

        emit BetPlaced(marketId, msg.sender, stake);
    }

    /// @notice Resolve the market after close. Publicly reveals ONLY the
    /// winning-side aggregate total (the losing total is derivable from the
    /// public pot anyway). Individual sides stay encrypted forever unless a
    /// bettor opts into claiming.
    function resolve(uint256 marketId, bool yesWon) external {
        Market storage m = _market(marketId);
        if (msg.sender != m.resolver) revert NotResolver();
        if (block.timestamp < m.closeTime) revert BettingStillOpen();
        if (m.outcome != Outcome.Unresolved) revert AlreadyResolved();

        m.outcome = yesWon ? Outcome.Yes : Outcome.No;

        euint256 winTotal = yesWon ? m.totalYes : m.totalNo;
        winTotal.reveal(); // irreversible, deliberate: aggregate only

        emit MarketResolved(marketId, m.outcome, euint256.unwrap(winTotal));
    }

    /// @notice Cancel an unresolved market (resolver only). Everyone refunds.
    function cancel(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (msg.sender != m.resolver) revert NotResolver();
        if (m.outcome != Outcome.Unresolved) revert AlreadyResolved();
        m.outcome = Outcome.Canceled;
        emit MarketCanceled(marketId);
    }

    /// @notice Post the covalidator attestation of the winning-side total.
    /// Anyone may call; the attestation is verified and bound to the exact
    /// handle revealed at resolve().
    function submitWinningTotal(
        uint256 marketId,
        DecryptionAttestation calldata decryption,
        bytes[] calldata signatures
    ) external {
        Market storage m = _market(marketId);
        if (m.outcome != Outcome.Yes && m.outcome != Outcome.No) revert NotResolved();
        if (m.totalsSubmitted) revert TotalsAlreadySubmitted();

        if (!inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures)) {
            revert InvalidAttestation();
        }
        euint256 winTotal = m.outcome == Outcome.Yes ? m.totalYes : m.totalNo;
        // ALWAYS bind the attestation to the expected handle.
        if (decryption.handle != euint256.unwrap(winTotal)) revert HandleMismatch();

        m.winningTotal = uint256(decryption.value);
        m.totalsSubmitted = true;

        emit WinningTotalSubmitted(marketId, m.winningTotal);
    }

    // --------------------------------------------------------------- claims

    /// @notice Step 1 of claiming: derive the encrypted "my stake on the winning
    /// side" value (equals your stake if you won, 0 if you lost) and reveal it.
    /// Opting in discloses your own result — after the market is over, and only
    /// for you. Losers can simply never call this.
    function prepareClaim(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (!m.totalsSubmitted) revert TotalsNotSubmitted();
        uint256 stake = stakeOf[marketId][msg.sender];
        if (stake == 0) revert NothingStaked();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();

        ebool side = sideOf[marketId][msg.sender];
        euint256 stakeE = e.asEuint256(stake);
        euint256 zero = e.asEuint256(0);

        // winStake = (side matches outcome) ? stake : 0 — no plaintext branch.
        euint256 winStake =
            m.outcome == Outcome.Yes ? side.select(stakeE, zero) : side.select(zero, stakeE);
        winStake.allowThis();
        winStake.allow(msg.sender);
        winStake.reveal(); // claimant opted in; needed for signature-free attested reveal

        winStakeOf[marketId][msg.sender] = winStake;
        emit ClaimPrepared(marketId, msg.sender, euint256.unwrap(winStake));
    }

    /// @notice Step 2: submit the attestation for your winStake handle and get
    /// paid pro-rata: payout = winStake * pot / winningTotal.
    function claim(
        uint256 marketId,
        DecryptionAttestation calldata decryption,
        bytes[] calldata signatures
    ) external {
        Market storage m = _market(marketId);
        if (!m.totalsSubmitted) revert TotalsNotSubmitted();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();

        euint256 expected = winStakeOf[marketId][msg.sender];
        if (euint256.unwrap(expected) == bytes32(0)) revert ClaimNotPrepared();

        if (!inco.incoVerifier().isValidDecryptionAttestation(decryption, signatures)) {
            revert InvalidAttestation();
        }
        if (decryption.handle != euint256.unwrap(expected)) revert HandleMismatch();

        uint256 winStake = uint256(decryption.value);

        // Effects before interaction.
        claimed[marketId][msg.sender] = true;

        uint256 payout = 0;
        if (winStake > 0 && m.winningTotal > 0) {
            payout = (winStake * m.pot) / m.winningTotal;
            (bool ok,) = msg.sender.call{value: payout}("");
            if (!ok) revert EthTransferFailed();
        }

        emit Claimed(marketId, msg.sender, winStake, payout);
    }

    /// @notice Refund path: market canceled, or resolved with an empty winning
    /// side (winningTotal == 0 after attestation). Everyone gets their stake back.
    function refund(uint256 marketId) external {
        Market storage m = _market(marketId);
        bool canceled = m.outcome == Outcome.Canceled;
        bool emptyWin = m.totalsSubmitted && m.winningTotal == 0;
        if (!canceled && !emptyWin) revert NotRefundable();

        uint256 stake = stakeOf[marketId][msg.sender];
        if (stake == 0) revert NothingStaked();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();

        claimed[marketId][msg.sender] = true;
        (bool ok,) = msg.sender.call{value: stake}("");
        if (!ok) revert EthTransferFailed();

        emit Refunded(marketId, msg.sender, stake);
    }

    // ---------------------------------------------------------------- views

    function getMarket(uint256 marketId)
        external
        view
        returns (
            string memory question,
            address resolver,
            uint64 closeTime,
            Outcome outcome,
            uint256 pot,
            bytes32 totalYesHandle,
            bytes32 totalNoHandle,
            uint256 winningTotal,
            bool totalsSubmitted
        )
    {
        Market storage m = _market(marketId);
        return (
            m.question,
            m.resolver,
            m.closeTime,
            m.outcome,
            m.pot,
            euint256.unwrap(m.totalYes),
            euint256.unwrap(m.totalNo),
            m.winningTotal,
            m.totalsSubmitted
        );
    }

    /// @notice The bettor's encrypted side handle (only they can decrypt it).
    function sideHandleOf(uint256 marketId, address bettor) external view returns (bytes32) {
        return ebool.unwrap(sideOf[marketId][bettor]);
    }

    /// @notice The bettor's revealed winStake handle (zero until prepareClaim).
    function winStakeHandleOf(uint256 marketId, address bettor) external view returns (bytes32) {
        return euint256.unwrap(winStakeOf[marketId][bettor]);
    }

    // ------------------------------------------------------------- internal

    function _market(uint256 marketId) internal view returns (Market storage m) {
        if (marketId >= marketCount) revert MarketNotFound();
        m = markets[marketId];
    }

    /// @dev The Inco library refunds any unused fee back to the calling
    /// contract; without this the refund reverts the whole operation.
    receive() external payable {}
}
