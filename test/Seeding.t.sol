// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {NameNFT} from "../src/NameNFT.sol";
import {SeedTree} from "../script/SeedTree.sol";

/// @dev Has no `onERC721Received`, so `_safeMint` to it would revert.
contract NoReceiverHook {}

/// @notice BSIP-13 change 3: seeding and the pause until the opening.
contract SeedingTest is Test {
    string constant TREE_PATH = "test/fixtures/seed-tree.json";
    bytes32 constant BSO_NODE = 0xe07ef0fd54600878e8c5c0087ff379e0fb9e1c49dfcc763bdada48721f534a20;

    uint256 constant OPEN_DELAY = 1 hours;
    uint256 constant REGISTRATION_PERIOD = 365 days;
    uint256 constant MIN_COMMITMENT_AGE = 60;
    uint256 constant DEFAULT_FEE = 0.0005 ether;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address stranger = address(0x5712A);

    event NameRegistered(
        uint256 indexed tokenId, string label, address indexed owner, uint256 expiresAt
    );
    event SubdomainRegistered(uint256 indexed tokenId, uint256 indexed parentId, string label);
    event TextChanged(bytes32 indexed node, string indexed key, string value);
    event RegistrationOpening(uint256 openAt);

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _id(string memory label, uint256 parent) internal pure returns (uint256) {
        bytes32 parentNode = parent == 0 ? BSO_NODE : bytes32(parent);
        return uint256(keccak256(abi.encodePacked(parentNode, keccak256(bytes(label)))));
    }

    function _entry(string memory label, uint256 parent, address owner, string memory record)
        internal
        pure
        returns (NameNFT.SeedEntry memory e)
    {
        e.label = label;
        e.parent = parent;
        e.owner = owner;
        e.record = record;
    }

    /// @dev alice.bso (with a record), bob.bso (no record), and sub.alice.bso owned by bob.
    function _smallList() internal view returns (NameNFT.SeedEntry[] memory es) {
        es = new NameNFT.SeedEntry[](3);
        es[0] = _entry("alice", 0, alice, "12D3KooWAlice");
        es[1] = _entry("bob", 0, bob, "");
        es[2] = _entry("sub", _id("alice", 0), bob, "12D3KooWSub");
    }

    function _deploy(NameNFT.SeedEntry[] memory es) internal returns (NameNFT nft) {
        bytes32[] memory tree = SeedTree.build(es);
        nft = new NameNFT(tree[0], es.length);
    }

    function _seed(NameNFT nft, NameNFT.SeedEntry memory e) internal {
        nft.seed(e.label, e.parent, e.owner, e.record, e.proof);
    }

    function _slice(NameNFT.SeedEntry[] memory es, uint256 from, uint256 to)
        internal
        pure
        returns (NameNFT.SeedEntry[] memory out)
    {
        out = new NameNFT.SeedEntry[](to - from);
        for (uint256 i = from; i < to; ++i) {
            out[i - from] = es[i];
        }
    }

    function _commit(NameNFT nft, string memory label, address who) internal returns (bytes32 s) {
        s = keccak256(abi.encode(label, who));
        bytes32 commitment = nft.makeCommitment(label, who, s);
        vm.prank(who);
        nft.commit(commitment);
    }

    /*//////////////////////////////////////////////////////////////
                    THE PUBLISHED TREE (assets/bsip-13)
    //////////////////////////////////////////////////////////////*/

    /// The Solidity builder used for the other tests reproduces the published root from the
    /// published values, so trees built here are the trees the OpenZeppelin merkle-tree package builds.
    function test_PublishedTree_BuilderReproducesRoot() public view {
        (bytes32 root, NameNFT.SeedEntry[] memory es) = SeedTree.load(TREE_PATH);
        bytes32[] memory proofsFromFile = new bytes32[](es.length);
        for (uint256 i; i < es.length; ++i) {
            proofsFromFile[i] = keccak256(abi.encode(es[i].proof));
        }
        bytes32[] memory tree = SeedTree.build(es);
        assertEq(tree[0], root, "root");
        for (uint256 i; i < es.length; ++i) {
            assertEq(keccak256(abi.encode(es[i].proof)), proofsFromFile[i], "proof");
        }
    }

    /// Every published entry seeds one by one, with the proof derived from the published
    /// tree, and lands on its listed owner with its listed record.
    function test_PublishedTree_EveryEntrySeeds() public {
        (bytes32 root, NameNFT.SeedEntry[] memory es) = SeedTree.load(TREE_PATH);
        NameNFT nft = new NameNFT(root, es.length);

        for (uint256 i; i < es.length; ++i) {
            vm.prank(stranger);
            _seed(nft, es[i]);
        }

        assertEq(nft.seededCount(), es.length);
        assertEq(nft.seededCount(), nft.SEED_COUNT());
        assertEq(nft.openAt(), block.timestamp + OPEN_DELAY);

        for (uint256 i; i < es.length; ++i) {
            uint256 id = _id(es[i].label, es[i].parent);
            assertEq(nft.ownerOf(id), es[i].owner, es[i].label);
            assertEq(nft.text(bytes32(id), "bitsocial"), es[i].record, es[i].label);
            assertEq(
                nft.expiresAt(id), es[i].parent == 0 ? block.timestamp + REGISTRATION_PERIOD : 0
            );
        }
    }

    /// The leaf hashes the label as supplied, so every published label must already be in the
    /// form the registry stores. Otherwise the registered name would differ from the listed one.
    function test_PublishedTree_LabelsAreNormalized() public {
        (bytes32 root, NameNFT.SeedEntry[] memory es) = SeedTree.load(TREE_PATH);
        NameNFT nft = new NameNFT(root, es.length);
        for (uint256 i; i < es.length; ++i) {
            assertEq(nft.normalize(es[i].label), es[i].label);
        }
    }

    /// No two published entries name the same token, or `seededCount` could never reach
    /// `SEED_COUNT`.
    function test_PublishedTree_NoDuplicateNames() public view {
        (, NameNFT.SeedEntry[] memory es) = SeedTree.load(TREE_PATH);
        for (uint256 i; i < es.length; ++i) {
            for (uint256 j = i + 1; j < es.length; ++j) {
                assertTrue(
                    _id(es[i].label, es[i].parent) != _id(es[j].label, es[j].parent), es[i].label
                );
            }
        }
    }

    /// The published order seeds in batches of 70, the BSIP's estimate, under the 2^24 gas cap
    /// of a transaction.
    function test_PublishedTree_SeedsInBatchesOf70() public {
        (bytes32 root, NameNFT.SeedEntry[] memory es) = SeedTree.load(TREE_PATH);
        NameNFT nft = new NameNFT(root, es.length);

        for (uint256 from; from < es.length; from += 70) {
            uint256 to = from + 70 > es.length ? es.length : from + 70;
            NameNFT.SeedEntry[] memory batch = _slice(es, from, to);
            uint256 gasBefore = gasleft();
            nft.seedBatch(batch);
            uint256 used = gasBefore - gasleft();
            emit log_named_uint("seedBatch entries", batch.length);
            emit log_named_uint("seedBatch gas", used);
            assertLt(used, 2 ** 24);
        }
        assertEq(nft.seededCount(), es.length);
        assertEq(nft.openAt(), block.timestamp + OPEN_DELAY);
    }

    /*//////////////////////////////////////////////////////////////
                                  SEED
    //////////////////////////////////////////////////////////////*/

    function test_Seed_TopLevel_RegistersForAYearAndSetsRecord() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        uint256 id = _id("alice", 0);

        vm.expectEmit(true, true, false, true);
        emit NameRegistered(id, "alice", alice, block.timestamp + REGISTRATION_PERIOD);
        vm.expectEmit(true, true, false, true);
        emit TextChanged(bytes32(id), "bitsocial", "12D3KooWAlice");
        vm.prank(stranger);
        _seed(nft, es[0]);

        assertEq(nft.ownerOf(id), alice);
        assertEq(nft.expiresAt(id), block.timestamp + REGISTRATION_PERIOD);
        assertEq(nft.text(bytes32(id), "bitsocial"), "12D3KooWAlice");
        assertEq(nft.getFullName(id), "alice.bso");
        assertEq(nft.seededCount(), 1);
        assertEq(nft.openAt(), 0);
        assertEq(address(nft).balance, 0);

        (string memory label, uint256 parent,, uint64 epoch, uint64 parentEpoch) = nft.records(id);
        assertEq(label, "alice");
        assertEq(parent, 0);
        assertEq(epoch, 1);
        assertEq(parentEpoch, 0);
    }

    function test_Seed_EmptyRecord_SetsNoTextAndEmitsNoTextChanged() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        vm.recordLogs();
        _seed(nft, es[1]);
        // Transfer (mint) and NameRegistered only.
        assertEq(vm.getRecordedLogs().length, 2);
        assertEq(nft.text(bytes32(_id("bob", 0)), "bitsocial"), "");
        assertEq(nft.ownerOf(_id("bob", 0)), bob);
    }

    function test_Seed_Subdomain_UnderSeededParent() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        uint256 parentId = _id("alice", 0);
        uint256 id = _id("sub", parentId);

        _seed(nft, es[0]);

        vm.expectEmit(true, true, false, true);
        emit NameRegistered(id, "sub", bob, 0);
        vm.expectEmit(true, true, false, true);
        emit SubdomainRegistered(id, parentId, "sub");
        vm.expectEmit(true, true, false, true);
        emit TextChanged(bytes32(id), "bitsocial", "12D3KooWSub");
        _seed(nft, es[2]);

        // Owned by the listed owner, not by the parent's owner.
        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.expiresAt(id), 0);
        assertEq(nft.getFullName(id), "sub.alice.bso");
        assertEq(nft.text(bytes32(id), "bitsocial"), "12D3KooWSub");

        (, uint256 parent,,, uint64 parentEpoch) = nft.records(id);
        assertEq(parent, parentId);
        assertEq(parentEpoch, 1);
    }

    function test_Seed_Subdomain_RevertsBeforeItsParent() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        vm.expectRevert(NameNFT.Expired.selector);
        _seed(nft, es[2]);
    }

    function test_Seed_Subdomain_RespectsDepthLimit() public {
        // a0.bso, a1.a0.bso, ... each under the previous one. Upstream allows depth 10.
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](12);
        uint256 parent;
        for (uint256 i; i < es.length; ++i) {
            string memory label = string.concat("lvl", vm.toString(i));
            es[i] = _entry(label, parent, alice, "");
            parent = _id(label, parent);
        }
        NameNFT nft = _deploy(es);

        for (uint256 i; i < 11; ++i) {
            _seed(nft, es[i]);
        }
        vm.expectRevert(NameNFT.TooDeep.selector);
        _seed(nft, es[11]);
    }

    function test_Seed_RevertsIfAlreadySeeded() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        _seed(nft, es[0]);
        vm.expectRevert(NameNFT.AlreadyRegistered.selector);
        _seed(nft, es[0]);
        assertEq(nft.seededCount(), 1);
    }

    function test_Seed_RevertsOnWrongOwnerRecordParentOrProof() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        NameNFT.SeedEntry memory e = es[0];

        vm.expectRevert(NameNFT.InvalidProof.selector);
        nft.seed(e.label, e.parent, stranger, e.record, e.proof);

        vm.expectRevert(NameNFT.InvalidProof.selector);
        nft.seed(e.label, e.parent, e.owner, "12D3KooWOther", e.proof);

        vm.expectRevert(NameNFT.InvalidProof.selector);
        nft.seed("mallory", e.parent, e.owner, e.record, e.proof);

        vm.expectRevert(NameNFT.InvalidProof.selector);
        nft.seed(e.label, e.parent, e.owner, e.record, es[1].proof);

        vm.expectRevert(NameNFT.InvalidProof.selector);
        nft.seed(e.label, e.parent, e.owner, e.record, new bytes32[](0));

        assertEq(nft.seededCount(), 0);
    }

    /// The leaf hashes the label as supplied: a different spelling of a listed label has no
    /// proof, even though it normalizes to the same name.
    function test_Seed_RevertsForADifferentSpellingOfTheLabel() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        vm.expectRevert(NameNFT.InvalidProof.selector);
        nft.seed("ALICE", es[0].parent, es[0].owner, es[0].record, es[0].proof);
    }

    function test_Seed_RevertsOnInvalidLabel() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](1);
        es[0] = _entry("has space", 0, alice, "");
        NameNFT nft = _deploy(es);

        vm.expectRevert(NameNFT.InvalidName.selector);
        _seed(nft, es[0]);
    }

    /// `_mint`, not `_safeMint`: a contract owner without the receiver hook still gets its name.
    function test_Seed_MintsToContractWithoutReceiverHook() public {
        address safe = address(new NoReceiverHook());
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](1);
        es[0] = _entry("vault", 0, safe, "");
        NameNFT nft = _deploy(es);

        _seed(nft, es[0]);
        assertEq(nft.ownerOf(_id("vault", 0)), safe);
    }

    function test_Seed_SingleEntryTree_EmptyProof() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](1);
        es[0] = _entry("solo", 0, alice, "rec");
        NameNFT nft = _deploy(es);
        assertEq(es[0].proof.length, 0);

        _seed(nft, es[0]);
        assertEq(nft.openAt(), block.timestamp + OPEN_DELAY);
    }

    function test_Seed_RevertsFromSeedEnd() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        vm.warp(nft.SEED_END() - 1);
        _seed(nft, es[0]);

        vm.warp(nft.SEED_END());
        vm.expectRevert(NameNFT.SeedingEnded.selector);
        _seed(nft, es[1]);

        vm.expectRevert(NameNFT.SeedingEnded.selector);
        nft.seedBatch(_slice(es, 1, 3));

        vm.expectRevert(NameNFT.SeedingEnded.selector);
        nft.seedBatch(new NameNFT.SeedEntry[](0));
    }

    function test_SeedEnd_IsSevenDaysAfterDeployment() public {
        NameNFT nft = _deploy(_smallList());
        assertEq(nft.SEED_END(), block.timestamp + 7 days);
        assertEq(nft.OPEN_DELAY(), 1 hours);
    }

    /// A seeded name is an ordinary name: anyone can renew it, at the ordinary fee.
    function test_Seed_SeededNameRenewsLikeAnyOther() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        _seed(nft, es[0]);
        uint256 id = _id("alice", 0);
        uint256 expiry = nft.expiresAt(id);

        vm.prank(bob);
        nft.renew{value: DEFAULT_FEE}(id);
        assertEq(nft.expiresAt(id), expiry + REGISTRATION_PERIOD);
    }

    /*//////////////////////////////////////////////////////////////
                               SEED BATCH
    //////////////////////////////////////////////////////////////*/

    function test_SeedBatch_SeedsInOrderParentThenSubdomain() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        nft.seedBatch(es);
        assertEq(nft.seededCount(), 3);
        assertEq(nft.ownerOf(_id("sub", _id("alice", 0))), bob);
    }

    /// Anyone can seed, so an entry seeded by someone else must not revert the batch.
    function test_SeedBatch_FrontRunEntryIsSkipped() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        vm.prank(stranger);
        _seed(nft, es[1]);
        assertEq(nft.seededCount(), 1);

        nft.seedBatch(es);
        assertEq(nft.seededCount(), 3, "counts only names actually registered");
        assertEq(nft.openAt(), block.timestamp + OPEN_DELAY);
        assertEq(nft.ownerOf(_id("bob", 0)), bob);
    }

    /// The existence check comes first: an already-seeded name is skipped without looking at
    /// the proof that came with it.
    function test_SeedBatch_SkipsExistingNameWithoutCheckingProof() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        _seed(nft, es[0]);

        NameNFT.SeedEntry[] memory batch = new NameNFT.SeedEntry[](2);
        batch[0] = _entry("alice", 0, stranger, "junk");
        batch[1] = es[1];
        nft.seedBatch(batch);

        assertEq(nft.ownerOf(_id("alice", 0)), alice);
        assertEq(nft.text(bytes32(_id("alice", 0)), "bitsocial"), "12D3KooWAlice");
        assertEq(nft.seededCount(), 2);
    }

    function test_SeedBatch_ReplayingTheWholeBatchChangesNothing() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        nft.seedBatch(es);
        uint256 opened = nft.openAt();
        vm.warp(block.timestamp + 10);
        nft.seedBatch(es);

        assertEq(nft.seededCount(), 3);
        assertEq(nft.openAt(), opened);
    }

    function test_SeedBatch_RevertsOnBadProofOfAnUnseededEntry() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        es[1].owner = stranger;

        vm.expectRevert(NameNFT.InvalidProof.selector);
        nft.seedBatch(es);
        assertEq(nft.seededCount(), 0, "the whole batch reverted");
    }

    function test_SeedBatch_RevertsWhenSubdomainComesBeforeItsParent() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        NameNFT.SeedEntry[] memory batch = new NameNFT.SeedEntry[](2);
        batch[0] = es[2];
        batch[1] = es[0];
        vm.expectRevert(NameNFT.Expired.selector);
        nft.seedBatch(batch);
    }

    /*//////////////////////////////////////////////////////////////
                               THE OPENING
    //////////////////////////////////////////////////////////////*/

    function test_Opening_LastSeedSetsOpenAtAndEmits() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        _seed(nft, es[0]);
        _seed(nft, es[1]);
        assertEq(nft.openAt(), 0);

        vm.warp(block.timestamp + 500);
        vm.expectEmit(false, false, false, true);
        emit RegistrationOpening(block.timestamp + OPEN_DELAY);
        vm.prank(stranger);
        _seed(nft, es[2]);
        assertEq(nft.openAt(), block.timestamp + OPEN_DELAY);
    }

    function test_Opening_RevealFailsOneSecondBeforeAndWorksAtIt() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        nft.seedBatch(es);
        uint256 opening = nft.openAt();

        // Commit is not paused.
        bytes32 secret = _commit(nft, "carol", bob);

        vm.warp(opening - 1);
        vm.prank(bob);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.reveal{value: DEFAULT_FEE}("carol", secret);

        vm.warp(opening);
        vm.prank(bob);
        uint256 id = nft.reveal{value: DEFAULT_FEE}("carol", secret);
        assertEq(nft.ownerOf(id), bob);
    }

    /// Nobody can register a listed label before it is seeded.
    function test_Opening_ListedLabelCannotBeRevealedBeforeItIsSeeded() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        bytes32 secret = _commit(nft, "alice", bob);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(bob);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.reveal{value: DEFAULT_FEE}("alice", secret);
    }

    /// The owner of a seeded parent can neither register a listed subname before it is seeded
    /// nor reclaim one after.
    function test_Opening_SubdomainCannotBeRegisteredOrReclaimedBefore() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        uint256 parentId = _id("alice", 0);
        _seed(nft, es[0]);

        vm.startPrank(alice);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.registerSubdomain("sub", parentId);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.registerSubdomainFor("sub", parentId, alice);
        vm.stopPrank();

        _seed(nft, es[1]);
        _seed(nft, es[2]);
        uint256 opening = nft.openAt();

        vm.warp(opening - 1);
        vm.startPrank(alice);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.registerSubdomain("sub", parentId);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.registerSubdomainFor("sub", parentId, alice);
        vm.stopPrank();
        assertEq(nft.ownerOf(_id("sub", parentId)), bob);

        // From the opening, upstream's rule applies again: the parent's owner controls it.
        vm.warp(opening);
        vm.prank(alice);
        nft.registerSubdomain("sub", parentId);
        assertEq(nft.ownerOf(_id("sub", parentId)), alice);
    }

    /// Nothing else is paused: a seeded owner can transfer and edit records at once.
    function test_Opening_SeededOwnerCanTransferAndEditBefore() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        _seed(nft, es[0]);
        uint256 id = _id("alice", 0);

        vm.startPrank(alice);
        nft.setText(id, "bitsocial", "12D3KooWNew");
        nft.setAddr(id, alice);
        nft.setPrimaryName(id);
        nft.approve(bob, id);
        nft.transferFrom(alice, bob, id);
        vm.stopPrank();

        assertEq(nft.ownerOf(id), bob);
        assertEq(nft.text(bytes32(id), "bitsocial"), "12D3KooWNew");
    }

    /// If the count is never reached, registration opens at SEED_END, and an unseeded label
    /// is then open to anyone.
    function test_Opening_AtSeedEndWhenCountIsNeverReached() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        _seed(nft, es[1]);
        uint256 seedEnd = nft.SEED_END();

        vm.warp(seedEnd - MIN_COMMITMENT_AGE);
        bytes32 secret = _commit(nft, "alice", bob);

        vm.warp(seedEnd - 1);
        vm.prank(bob);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.reveal{value: DEFAULT_FEE}("alice", secret);

        vm.warp(seedEnd);
        assertEq(nft.openAt(), 0);
        vm.prank(bob);
        uint256 id = nft.reveal{value: DEFAULT_FEE}("alice", secret);
        assertEq(nft.ownerOf(id), bob);
    }

    /// If the last seed lands in the final hour, openAt is after SEED_END, and SEED_END wins.
    function test_Opening_SeedEndWinsWhenOpenAtIsLater() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        uint256 seedEnd = nft.SEED_END();

        vm.warp(seedEnd - 10 minutes);
        nft.seedBatch(es);
        assertEq(nft.openAt(), seedEnd + 50 minutes);

        bytes32 secret = _commit(nft, "carol", bob);

        vm.warp(seedEnd - 1);
        vm.prank(bob);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.reveal{value: DEFAULT_FEE}("carol", secret);

        vm.warp(seedEnd);
        vm.prank(bob);
        nft.reveal{value: DEFAULT_FEE}("carol", secret);
    }

    /// With an empty seed list nothing is ever seeded and registration opens at SEED_END.
    function test_Opening_EmptySeedListOpensAtSeedEnd() public {
        NameNFT nft = new NameNFT(bytes32(0), 0);
        bytes32 secret = _commit(nft, "carol", bob);

        vm.warp(nft.SEED_END() - 1);
        vm.prank(bob);
        vm.expectRevert(NameNFT.NotOpen.selector);
        nft.reveal{value: DEFAULT_FEE}("carol", secret);

        vm.warp(nft.SEED_END());
        bytes32 secret2 = _commit(nft, "david", bob);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(bob);
        nft.reveal{value: DEFAULT_FEE}("david", secret2);
    }

    /// A seeded label cannot be taken at the opening: it is registered until it expires.
    function test_Opening_SeededLabelIsNotAvailableAfterOpening() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        nft.seedBatch(es);

        bytes32 secret = _commit(nft, "alice", bob);
        vm.warp(nft.openAt());
        assertFalse(nft.isAvailable("alice", 0));
        vm.prank(bob);
        vm.expectRevert(NameNFT.AlreadyRegistered.selector);
        nft.reveal{value: DEFAULT_FEE}("alice", secret);
    }

    /// isAvailable does not know about the pause: before the opening it reports an unseeded
    /// listed label as available although reveal reverts.
    function test_Opening_IsAvailableIgnoresThePause() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);
        assertTrue(nft.isAvailable("alice", 0));
        _seed(nft, es[0]);
        assertFalse(nft.isAvailable("alice", 0));
    }

    /// The subdomain functions cannot register a top-level name: parent 0 is never active.
    function test_RegisterSubdomain_WithParentZeroCannotRegisterATopLevelName() public {
        NameNFT nft = new NameNFT(bytes32(0), 0);
        vm.warp(nft.SEED_END());

        vm.startPrank(alice);
        vm.expectRevert(NameNFT.Expired.selector);
        nft.registerSubdomain("alice", 0);
        vm.expectRevert(NameNFT.Expired.selector);
        nft.registerSubdomainFor("ab", 0, alice);
        vm.stopPrank();
    }

    /// openAt is set once, by the seed that reaches the count. With a SEED_COUNT lower than
    /// the number of leaves (a deployment mistake) later seeds do not move it.
    function test_Opening_OpenAtIsSetOnlyOnce() public {
        NameNFT.SeedEntry[] memory es = _smallList();
        bytes32[] memory tree = SeedTree.build(es);
        NameNFT nft = new NameNFT(tree[0], 1);

        _seed(nft, es[0]);
        uint256 opened = nft.openAt();
        assertEq(opened, block.timestamp + OPEN_DELAY);

        vm.warp(block.timestamp + 100);
        _seed(nft, es[1]);
        assertEq(nft.seededCount(), 2);
        assertEq(nft.openAt(), opened);
    }

    /// Two spellings of one label are two leaves but one name. Whoever seeds first decides the
    /// owner and the other leaf can never be seeded, so the list must not contain such a pair
    /// (the deploy script refuses it).
    function test_Seed_TwoSpellingsOfOneLabelAreOneName() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](2);
        es[0] = _entry("alice", 0, alice, "");
        es[1] = _entry("Alice", 0, bob, "");
        NameNFT nft = _deploy(es);

        _seed(nft, es[1]);
        assertEq(nft.ownerOf(_id("alice", 0)), bob);
        (string memory label,,,,) = nft.records(_id("alice", 0));
        assertEq(label, "alice");

        vm.expectRevert(NameNFT.AlreadyRegistered.selector);
        _seed(nft, es[0]);
        assertEq(nft.openAt(), 0);
    }

    /// Any subset of the list, in any order that puts parents first, seeds to the same state.
    function testFuzz_SeedThenBatch_AlwaysReachesTheCount(uint256 mask) public {
        NameNFT.SeedEntry[] memory es = _smallList();
        NameNFT nft = _deploy(es);

        // Seed a random subset one by one first (the subdomain only if its parent is in).
        if (mask & 1 != 0) _seed(nft, es[0]);
        if (mask & 2 != 0) _seed(nft, es[1]);
        if (mask & 5 == 5) _seed(nft, es[2]);

        nft.seedBatch(es);
        assertEq(nft.seededCount(), 3);
        assertGt(nft.openAt(), 0);
    }
}
