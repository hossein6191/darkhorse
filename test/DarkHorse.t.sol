// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IncoTest} from "@inco/lightning/src/test/IncoTest.sol";
import {inco, euint256, ebool, e} from "@inco/lightning/src/Lib.sol";
import {DecryptionAttestation} from "@inco/lightning/src/lightning-parts/DecryptionAttester.types.sol";
import {DarkHorse} from "../contracts/DarkHorse.sol";

contract DarkHorseTest is IncoTest {
    DarkHorse dh;

    uint64 constant CLOSE = 1_000_000; // absolute test timestamp
    uint256 fee;

    function setUp() public override {
        super.setUp();
        dh = new DarkHorse();
        fee = inco.getFee();
        vm.warp(1); // deterministic start
    }

    // ------------------------------------------------------------- helpers

    function _createMarket() internal returns (uint256 id) {
        id = dh.createMarket("Will ETH close above $5k this month?", CLOSE);
    }

    /// Place a bet as `who` with `stake` wei on `side` (true = YES).
    function _bet(uint256 id, address who, uint256 stake, bool side) internal {
        bytes memory ct = fakePrepareEboolCiphertext(side, who, address(dh));
        vm.deal(who, stake + fee);
        vm.prank(who);
        dh.placeBet{value: stake + fee}(id, ct);
        processAllOperations();
    }

    /// Fetch a covalidator-style attestation for a revealed/allowed handle.
    /// The DarkHorse contract itself is always allowed (allowThis), so request
    /// as the contract — on-chain verification only checks the attestation.
    function _attest(bytes32 handle)
        internal
        returns (DecryptionAttestation memory att, bytes[] memory sigs)
    {
        (att, sigs) = getDecryptionAttestation(
            address(dh), HandleWithProof({handle: handle, proof: _emptyAllowanceProof()})
        );
    }

    function _resolveAndSubmit(uint256 id, bool yesWon) internal {
        vm.warp(CLOSE + 1);
        dh.resolve(id, yesWon);
        processAllOperations();

        (,,,,, bytes32 yesH, bytes32 noH,,) = dh.getMarket(id);
        (DecryptionAttestation memory att, bytes[] memory sigs) = _attest(yesWon ? yesH : noH);
        dh.submitWinningTotal(id, att, sigs);
    }

    function _claim(uint256 id, address who) internal returns (uint256 paid) {
        vm.prank(who);
        dh.prepareClaim(id);
        processAllOperations();

        bytes32 h = dh.winStakeHandleOf(id, who);
        (DecryptionAttestation memory att, bytes[] memory sigs) = _attest(h);

        uint256 before = who.balance;
        vm.prank(who);
        dh.claim(id, att, sigs);
        paid = who.balance - before;
    }

    // ------------------------------------------------------------ lifecycle

    function testFullMarketLifecycle() public {
        uint256 id = _createMarket();

        _bet(id, alice, 3 ether, true); // YES
        _bet(id, bob, 1 ether, false); // NO
        _bet(id, carol, 1 ether, true); // YES

        (,,,, uint256 pot,,,,) = dh.getMarket(id);
        assertEq(pot, 5 ether, "pot tracks public stakes");

        // Encrypted totals are correct inside the TEE mock.
        (,,,,, bytes32 yesH, bytes32 noH,,) = dh.getMarket(id);
        assertEq(getUint256Value(euint256.wrap(yesH)), 4 ether, "encrypted YES total");
        assertEq(getUint256Value(euint256.wrap(noH)), 1 ether, "encrypted NO total");

        _resolveAndSubmit(id, true); // YES wins

        (,,,,,,, uint256 winningTotal, bool submitted) = dh.getMarket(id);
        assertTrue(submitted);
        assertEq(winningTotal, 4 ether);

        // Winners split the whole pot pro-rata.
        assertEq(_claim(id, alice), (3 ether * 5 ether) / 4 ether, "alice payout 3.75");
        assertEq(_claim(id, carol), (1 ether * 5 ether) / 4 ether, "carol payout 1.25");
        // Loser gets zero.
        assertEq(_claim(id, bob), 0, "bob lost, zero payout");

        // Contract is drained exactly to dust (rounding only).
        assertLe(address(dh).balance, 2, "no stuck funds beyond rounding dust");
    }

    function testNoWinnersMeansRefunds() public {
        uint256 id = _createMarket();
        _bet(id, alice, 2 ether, false);
        _bet(id, bob, 1 ether, false);

        _resolveAndSubmit(id, true); // YES wins but nobody bet YES

        (,,,,,,, uint256 winningTotal,) = dh.getMarket(id);
        assertEq(winningTotal, 0);

        uint256 before = alice.balance;
        vm.prank(alice);
        dh.refund(id);
        assertEq(alice.balance - before, 2 ether, "alice refunded");

        before = bob.balance;
        vm.prank(bob);
        dh.refund(id);
        assertEq(bob.balance - before, 1 ether, "bob refunded");
    }

    function testCancelRefunds() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);

        dh.cancel(id);

        uint256 before = alice.balance;
        vm.prank(alice);
        dh.refund(id);
        assertEq(alice.balance - before, 1 ether);

        // No double refund.
        vm.prank(alice);
        vm.expectRevert(DarkHorse.AlreadyClaimed.selector);
        dh.refund(id);
    }

    // ------------------------------------------------------------- privacy

    function testSideIsNotReadableByOthers() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);

        bytes32 sideH = dh.sideHandleOf(id, alice);
        // The bettor and the contract are allowed; bob is not.
        assertTrue(inco.isAllowed(sideH, alice), "bettor may decrypt own side");
        assertTrue(inco.isAllowed(sideH, address(dh)), "contract retains access");
        assertFalse(inco.isAllowed(sideH, bob), "third parties cannot decrypt a side");
    }

    function testTotalsAreNotPublicBeforeResolve() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);

        (,,,,, bytes32 yesH,,,) = dh.getMarket(id);
        // Nobody but the contract can read the running total pre-resolve.
        assertFalse(inco.isAllowed(yesH, alice));
        assertFalse(inco.isAllowed(yesH, bob));
        assertTrue(inco.isAllowed(yesH, address(dh)));
    }

    // ------------------------------------------------------- attack paths

    function testCannotSubmitAttestationForWrongHandle() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);
        _bet(id, bob, 1 ether, false);

        vm.warp(CLOSE + 1);
        dh.resolve(id, true); // winning handle = totalYes
        processAllOperations();

        // Attest the LOSING total and try to pass it off as the winning one.
        (,,,,,, bytes32 noH,,) = dh.getMarket(id);
        (DecryptionAttestation memory att, bytes[] memory sigs) = _attest(noH);

        vm.expectRevert(DarkHorse.HandleMismatch.selector);
        dh.submitWinningTotal(id, att, sigs);
    }

    function testCannotClaimWithSomeoneElsesAttestation() public {
        uint256 id = _createMarket();
        _bet(id, alice, 3 ether, true);
        _bet(id, bob, 1 ether, false);
        _resolveAndSubmit(id, true);

        // Alice prepares a legitimate claim.
        vm.prank(alice);
        dh.prepareClaim(id);
        processAllOperations();
        bytes32 aliceH = dh.winStakeHandleOf(id, alice);
        (DecryptionAttestation memory att, bytes[] memory sigs) = _attest(aliceH);

        // Bob tries to use Alice's attestation without preparing his own claim.
        vm.prank(bob);
        vm.expectRevert(DarkHorse.ClaimNotPrepared.selector);
        dh.claim(id, att, sigs);

        // Bob prepares his own claim, then still tries Alice's attestation:
        // handle binding must reject it.
        vm.prank(bob);
        dh.prepareClaim(id);
        processAllOperations();
        vm.prank(bob);
        vm.expectRevert(DarkHorse.HandleMismatch.selector);
        dh.claim(id, att, sigs);
    }

    function testNoDoubleClaim() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);
        _bet(id, bob, 1 ether, false);
        _resolveAndSubmit(id, true);

        _claim(id, alice);

        bytes32 h = dh.winStakeHandleOf(id, alice);
        (DecryptionAttestation memory att, bytes[] memory sigs) = _attest(h);
        vm.prank(alice);
        vm.expectRevert(DarkHorse.AlreadyClaimed.selector);
        dh.claim(id, att, sigs);
    }

    // ---------------------------------------------------------- guardrails

    function testOneBetPerAddress() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);

        bytes memory ct = fakePrepareEboolCiphertext(false, alice, address(dh));
        vm.deal(alice, 1 ether + fee);
        vm.prank(alice);
        vm.expectRevert(DarkHorse.AlreadyBet.selector);
        dh.placeBet{value: 1 ether + fee}(id, ct);
    }

    function testNoBetsAfterClose() public {
        uint256 id = _createMarket();
        vm.warp(CLOSE);

        bytes memory ct = fakePrepareEboolCiphertext(true, alice, address(dh));
        vm.deal(alice, 1 ether + fee);
        vm.prank(alice);
        vm.expectRevert(DarkHorse.BettingClosed.selector);
        dh.placeBet{value: 1 ether + fee}(id, ct);
    }

    function testStakeMustExceedFee() public {
        uint256 id = _createMarket();
        bytes memory ct = fakePrepareEboolCiphertext(true, alice, address(dh));
        vm.deal(alice, fee);
        vm.prank(alice);
        vm.expectRevert(DarkHorse.StakeRequired.selector);
        dh.placeBet{value: fee}(id, ct);
    }

    function testOnlyResolverResolvesAfterClose() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);

        // Not yet closed.
        vm.warp(CLOSE - 1);
        vm.expectRevert(DarkHorse.BettingStillOpen.selector);
        dh.resolve(id, true);

        // Wrong caller.
        vm.warp(CLOSE + 1);
        vm.prank(alice);
        vm.expectRevert(DarkHorse.NotResolver.selector);
        dh.resolve(id, true);

        // Resolver works, and only once.
        dh.resolve(id, true);
        vm.expectRevert(DarkHorse.AlreadyResolved.selector);
        dh.resolve(id, false);
    }

    function testCannotCreateMarketClosingInPast() public {
        vm.warp(500);
        vm.expectRevert(DarkHorse.CloseTimeInPast.selector);
        dh.createMarket("expired", 500);
    }

    function testClaimRequiresTotals() public {
        uint256 id = _createMarket();
        _bet(id, alice, 1 ether, true);
        vm.warp(CLOSE + 1);
        dh.resolve(id, true);
        processAllOperations();

        vm.prank(alice);
        vm.expectRevert(DarkHorse.TotalsNotSubmitted.selector);
        dh.prepareClaim(id);
    }
}
