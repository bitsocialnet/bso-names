// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {NameNFT} from "../src/NameNFT.sol";
import {SeedTree} from "../script/SeedTree.sol";

/// @notice BSIP-13 change 4: sunset() and the freeze.
contract SunsetTest is Test {
    address constant FEE_RECIPIENT = 0x442A54b2AFEe1db441Df5aA825059d663c96AA6E;
    uint256 constant SUNSET_NOTICE = 30 days;
    uint256 constant DEFAULT_FEE = 0.0005 ether;
    uint256 constant MIN_COMMITMENT_AGE = 60;

    NameNFT nft;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 aliceId;
    uint256 subId;
    bytes32 pendingSecret;

    event SunsetScheduled(uint256 sunsetAt);

    /// alice owns alice.bso and sub.alice.bso, and has a commitment for "pending" that stays
    /// revealable for 24 hours.
    function setUp() public {
        nft = new NameNFT(bytes32(0), 0);
        vm.warp(nft.SEED_END());
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);

        aliceId = _register("alice", alice);
        vm.startPrank(alice);
        subId = nft.registerSubdomain("sub", aliceId);
        nft.setText(aliceId, "bitsocial", "12D3KooWAlice");
        vm.stopPrank();
    }

    function _commit(string memory label, address who) internal returns (bytes32 secret) {
        secret = keccak256(abi.encode(label, who, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, secret);
        vm.prank(who);
        nft.commit(commitment);
    }

    function _register(string memory label, address who) internal returns (uint256 id) {
        bytes32 secret = _commit(label, who);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(who);
        id = nft.reveal{value: DEFAULT_FEE}(label, secret);
    }

    function _sunset() internal returns (uint256 frozenFrom) {
        vm.prank(FEE_RECIPIENT);
        nft.sunset();
        frozenFrom = nft.sunsetAt();
    }

    /// Schedule the sunset and stop one hour before the freeze, with a live commitment.
    function _toOneHourBeforeFreeze() internal returns (uint256 frozenFrom) {
        frozenFrom = _sunset();
        vm.warp(frozenFrom - 1 hours);
        pendingSecret = _commit("pending", bob);
    }

    /*//////////////////////////////////////////////////////////////
                                SUNSET()
    //////////////////////////////////////////////////////////////*/

    function test_Sunset_OnlyFeeRecipient() public {
        vm.prank(alice);
        vm.expectRevert(NameNFT.Unauthorized.selector);
        nft.sunset();

        vm.expectRevert(NameNFT.Unauthorized.selector);
        nft.sunset();

        assertEq(nft.sunsetAt(), 0);
    }

    function test_Sunset_SetsSunsetAtThirtyDaysAheadAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit SunsetScheduled(block.timestamp + SUNSET_NOTICE);
        vm.prank(FEE_RECIPIENT);
        nft.sunset();
        assertEq(nft.sunsetAt(), block.timestamp + SUNSET_NOTICE);
    }

    /// Only once: it cannot be called again to delay the freeze, before or after it.
    function test_Sunset_OnlyOnce() public {
        uint256 frozenFrom = _sunset();

        vm.warp(block.timestamp + 10 days);
        vm.prank(FEE_RECIPIENT);
        vm.expectRevert(NameNFT.AlreadySunset.selector);
        nft.sunset();
        assertEq(nft.sunsetAt(), frozenFrom);

        vm.warp(frozenFrom + 1);
        vm.prank(FEE_RECIPIENT);
        vm.expectRevert(NameNFT.AlreadySunset.selector);
        nft.sunset();
        assertEq(nft.sunsetAt(), frozenFrom);
    }

    function test_NoSunset_NothingIsEverFrozen() public {
        vm.warp(block.timestamp + 300 days);
        vm.prank(alice);
        nft.setText(aliceId, "k", "v");
        vm.prank(bob);
        nft.renew{value: DEFAULT_FEE}(aliceId);
    }

    /// A sunset called at deployment does not get in the way of seeding: the freeze comes 30
    /// days later, after SEED_END.
    function test_Sunset_DuringSeedingDoesNotBlockSeeding() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](1);
        es[0].label = "alice";
        es[0].owner = alice;
        bytes32[] memory tree = SeedTree.build(es);
        NameNFT fresh = new NameNFT(tree[0], 1);

        vm.prank(FEE_RECIPIENT);
        fresh.sunset();
        assertGt(fresh.sunsetAt(), fresh.SEED_END());

        fresh.seedBatch(es);
        assertEq(fresh.seededCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                            THE NOTICE PERIOD
    //////////////////////////////////////////////////////////////*/

    /// During the 30 days the registry works as before, up to the last second.
    function test_Notice_EverythingWorksUntilTheLastSecond() public {
        uint256 frozenFrom = _toOneHourBeforeFreeze();
        vm.warp(frozenFrom - 1);

        vm.prank(bob);
        nft.reveal{value: DEFAULT_FEE}("pending", pendingSecret);
        _commit("another", bob);

        vm.prank(bob);
        nft.renew{value: DEFAULT_FEE}(aliceId);

        vm.startPrank(alice);
        nft.registerSubdomain("two", aliceId);
        nft.registerSubdomainFor("three", aliceId, bob);
        nft.setAddr(aliceId, alice);
        nft.setPrimaryName(aliceId);
        nft.setContenthash(aliceId, hex"e301");
        nft.setAddrForCoin(aliceId, 0, hex"00");
        nft.setText(aliceId, "bitsocial", "12D3KooWLate");
        nft.approve(bob, aliceId);
        nft.setApprovalForAll(bob, true);
        nft.transferFrom(alice, bob, subId);
        nft.safeTransferFrom(alice, bob, aliceId);
        vm.stopPrank();

        assertEq(nft.ownerOf(aliceId), bob);
    }

    /*//////////////////////////////////////////////////////////////
                               THE FREEZE
    //////////////////////////////////////////////////////////////*/

    /// From sunsetAt on, nobody can commit, register, renew, transfer, approve or change a
    /// record.
    function test_Freeze_EveryStateChangingFunctionReverts() public {
        uint256 frozenFrom = _toOneHourBeforeFreeze();
        vm.prank(alice);
        nft.approve(bob, aliceId);
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);

        vm.warp(frozenFrom);
        bytes4 frozen = NameNFT.Frozen.selector;

        vm.expectRevert(frozen);
        nft.commit(keccak256("c"));

        vm.prank(bob);
        vm.expectRevert(frozen);
        nft.reveal{value: DEFAULT_FEE}("pending", pendingSecret);

        vm.prank(bob);
        vm.expectRevert(frozen);
        nft.renew{value: DEFAULT_FEE}(aliceId);

        vm.startPrank(alice);
        vm.expectRevert(frozen);
        nft.registerSubdomain("two", aliceId);
        vm.expectRevert(frozen);
        nft.registerSubdomainFor("three", aliceId, bob);
        vm.expectRevert(frozen);
        nft.registerSubdomain("sub", aliceId); // reclaim
        vm.expectRevert(frozen);
        nft.setAddr(aliceId, alice);
        vm.expectRevert(frozen);
        nft.setPrimaryName(aliceId);
        vm.expectRevert(frozen);
        nft.setPrimaryName(0);
        vm.expectRevert(frozen);
        nft.setContenthash(aliceId, hex"e301");
        vm.expectRevert(frozen);
        nft.setAddrForCoin(aliceId, 0, hex"00");
        vm.expectRevert(frozen);
        nft.setText(aliceId, "bitsocial", "12D3KooWLate");
        vm.expectRevert(frozen);
        nft.approve(bob, aliceId);
        vm.expectRevert(frozen);
        nft.approve(address(0), aliceId);
        vm.expectRevert(frozen);
        nft.setApprovalForAll(bob, false);
        vm.expectRevert(frozen);
        nft.transferFrom(alice, bob, aliceId);
        vm.expectRevert(frozen);
        nft.safeTransferFrom(alice, bob, aliceId);
        vm.expectRevert(frozen);
        nft.safeTransferFrom(alice, bob, aliceId, "");
        vm.expectRevert(frozen);
        nft.transferFrom(alice, bob, subId);
        vm.stopPrank();

        // An operator approved before the freeze cannot move the name either.
        vm.prank(bob);
        vm.expectRevert(frozen);
        nft.transferFrom(alice, bob, aliceId);

        // seed and seedBatch ended long before, at SEED_END.
        vm.expectRevert(NameNFT.SeedingEnded.selector);
        nft.seed("x", 0, alice, "", new bytes32[](0));
        vm.expectRevert(NameNFT.SeedingEnded.selector);
        nft.seedBatch(new NameNFT.SeedEntry[](0));

        assertEq(nft.ownerOf(aliceId), alice);
        assertEq(nft.text(bytes32(aliceId), "bitsocial"), "12D3KooWAlice");
    }

    function test_Freeze_StaysFrozenForever() public {
        uint256 frozenFrom = _sunset();
        vm.warp(frozenFrom + 3650 days);
        vm.expectRevert(NameNFT.Frozen.selector);
        nft.commit(keccak256("c"));
    }

    function test_Freeze_WithdrawStillWorks() public {
        uint256 frozenFrom = _sunset();
        uint256 held = address(nft).balance;
        assertGt(held, 0);

        vm.warp(frozenFrom + 1 days);
        vm.prank(bob);
        nft.withdraw();
        assertEq(FEE_RECIPIENT.balance, held);
        assertEq(address(nft).balance, 0);
    }

    /// Names keep resolving from the frozen state until they expire.
    function test_Freeze_NamesResolveUntilTheyExpire() public {
        uint256 frozenFrom = _sunset();
        vm.warp(frozenFrom + 1 days);

        assertEq(nft.text(bytes32(aliceId), "bitsocial"), "12D3KooWAlice");
        assertEq(nft.ownerOf(aliceId), alice);
        assertEq(nft.addr(bytes32(aliceId)), alice);
        assertEq(nft.getFullName(subId), "sub.alice.bso");
        assertFalse(nft.isAvailable("alice", 0));

        vm.warp(nft.expiresAt(aliceId) + 1);
        assertEq(nft.text(bytes32(aliceId), "bitsocial"), "");
    }

    /// Changes made during the notice, renewals included, are part of the frozen state.
    function test_Freeze_KeepsChangesMadeDuringTheNotice() public {
        uint256 frozenFrom = _sunset();
        uint256 expiry = nft.expiresAt(aliceId);

        vm.warp(frozenFrom - 1);
        vm.prank(bob);
        nft.renew{value: DEFAULT_FEE}(aliceId);
        vm.prank(alice);
        nft.setText(aliceId, "bitsocial", "12D3KooWLate");

        vm.warp(frozenFrom + 300 days);
        assertEq(nft.expiresAt(aliceId), expiry + 365 days);
        assertEq(nft.text(bytes32(aliceId), "bitsocial"), "12D3KooWLate");
    }

    function testFuzz_Freeze_BoundaryIsSunsetAt(uint256 offset) public {
        uint256 frozenFrom = _sunset();
        offset = bound(offset, 0, 2 * SUNSET_NOTICE);
        vm.warp(frozenFrom - SUNSET_NOTICE + offset);

        if (block.timestamp >= frozenFrom) vm.expectRevert(NameNFT.Frozen.selector);
        nft.commit(keccak256(abi.encode(offset)));
    }
}
