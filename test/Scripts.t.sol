// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {NameNFT} from "../src/NameNFT.sol";
import {SeedTree} from "../script/SeedTree.sol";
import {SeedScript} from "../script/Deploy.s.sol";

contract SeedScriptHarness is SeedScript {
    function rehearse(NameNFT.SeedEntry[] memory entries) external {
        bytes32[] memory tree = SeedTree.build(entries);
        _rehearse(tree[0], entries);
    }

    function rehearseFile(string memory path) external {
        (bytes32 root, NameNFT.SeedEntry[] memory entries) = SeedTree.load(path);
        _rehearse(root, entries);
    }

    function seedAll(NameNFT nft, NameNFT.SeedEntry[] memory entries) external {
        _seedAll(nft, entries);
    }
}

/// @notice The checks the deploy scripts make on the seed tree file before deploying.
contract ScriptsTest is Test {
    bytes32 constant BSO_NODE = 0xe07ef0fd54600878e8c5c0087ff379e0fb9e1c49dfcc763bdada48721f534a20;

    SeedScriptHarness harness;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.warp(1_800_000_000);
        harness = new SeedScriptHarness();
    }

    function load(string memory path) external view returns (bytes32 root, uint256 count) {
        NameNFT.SeedEntry[] memory entries;
        (root, entries) = SeedTree.load(path);
        count = entries.length;
    }

    function _entry(string memory label, uint256 parent, address owner)
        internal
        pure
        returns (NameNFT.SeedEntry memory e)
    {
        e.label = label;
        e.parent = parent;
        e.owner = owner;
    }

    function _id(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(BSO_NODE, keccak256(bytes(label)))));
    }

    /*//////////////////////////////////////////////////////////////
                             SeedTree.load
    //////////////////////////////////////////////////////////////*/

    function test_Load_SmallTree() public view {
        (bytes32 root, NameNFT.SeedEntry[] memory es) =
            SeedTree.load("test/fixtures/small-tree.json");
        assertEq(root, 0xa2242caeed21982fd1ce2e7d12d12f8afe2a9033d58afc12cdb838329839e930);
        assertEq(es.length, 2);
        assertEq(es[0].label, "alice");
        assertEq(es[0].owner, alice);
        assertEq(es[0].record, "12D3KooWAlice");
        assertEq(es[1].label, "bobby");
        assertEq(es[1].proof.length, 1);
    }

    function test_Load_PublishedTree() public view {
        (bytes32 root, uint256 count) = this.load("test/fixtures/seed-tree.json");
        assertEq(root, 0x9d9fbe57a6b7aabb9821df8af3b5b7685db9a176787d51da5da16de9003b8e8b);
        assertEq(count, 119);
    }

    /// A value edited after the tree was built no longer hashes to its leaf.
    function test_Load_RejectsAValueThatIsNotAtItsLeaf() public {
        vm.expectRevert(bytes("seed tree: a value is not at its leaf"));
        this.load("test/fixtures/small-tree-wrong-owner.json");
    }

    function test_Load_RejectsARootThatIsNotTheRootOfTheValues() public {
        vm.expectRevert(bytes("seed tree: root is not the root of the values"));
        this.load("test/fixtures/small-tree-wrong-root.json");
    }

    /// More values than leaves: SEED_COUNT would be lower than the number of entries.
    function test_Load_RejectsMoreValuesThanLeaves() public {
        vm.expectRevert(bytes("seed tree: values does not have one entry per leaf"));
        this.load("test/fixtures/small-tree-extra-value.json");
    }

    /*//////////////////////////////////////////////////////////////
                         THE REHEARSAL BEFORE DEPLOY
    //////////////////////////////////////////////////////////////*/

    function test_Rehearse_PublishedTreePasses() public {
        harness.rehearseFile("test/fixtures/seed-tree.json");
    }

    function test_Rehearse_SmallTreePasses() public {
        harness.rehearseFile("test/fixtures/small-tree.json");
    }

    /// Two spellings of one label are two leaves but one name: only one can be seeded, and
    /// seededCount would never reach SEED_COUNT.
    function test_Rehearse_RejectsALabelThatIsNotNormalized() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](2);
        es[0] = _entry("alice", 0, alice);
        es[1] = _entry("Alice", 0, bob);
        vm.expectRevert(bytes("seed tree: label is not in normalized form: Alice"));
        harness.rehearse(es);
    }

    function test_Rehearse_RejectsTheSameNameListedTwice() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](2);
        es[0] = _entry("alice", 0, alice);
        es[1] = _entry("alice", 0, bob);
        vm.expectRevert(bytes("seed tree: not every entry can be seeded"));
        harness.rehearse(es);
    }

    function test_Rehearse_RejectsASubdomainListedBeforeItsParent() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](2);
        es[0] = _entry("sub", _id("alice"), bob);
        es[1] = _entry("alice", 0, alice);
        vm.expectRevert(NameNFT.Expired.selector);
        harness.rehearse(es);
    }

    function test_Rehearse_RejectsALabelThatIsTooShort() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](2);
        es[0] = _entry("alice", 0, alice);
        es[1] = _entry("ab", 0, bob);
        vm.expectRevert(NameNFT.LabelTooShort.selector);
        harness.rehearse(es);
    }

    function test_Rehearse_RejectsAZeroOwner() public {
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](1);
        es[0] = _entry("alice", 0, address(0));
        vm.expectRevert();
        harness.rehearse(es);
    }

    /// A subdomain two levels deep seeds when the file lists every parent first.
    function test_Rehearse_NestedSubdomainsInParentFirstOrder() public {
        uint256 aliceId = _id("alice");
        uint256 subId = uint256(keccak256(abi.encodePacked(bytes32(aliceId), keccak256("sub"))));
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](3);
        es[0] = _entry("alice", 0, alice);
        es[1] = _entry("sub", aliceId, bob);
        es[2] = _entry("deep", subId, alice);
        harness.rehearse(es);
    }

    /*//////////////////////////////////////////////////////////////
                                 BATCHES
    //////////////////////////////////////////////////////////////*/

    /// The default batch of 60 seeds the published tree in two calls, each under the 2^24
    /// gas cap of a transaction with room for calldata.
    function test_SeedAll_PublishedTreeInDefaultBatches() public {
        (bytes32 root, NameNFT.SeedEntry[] memory es) =
            SeedTree.load("test/fixtures/seed-tree.json");
        NameNFT nft = new NameNFT(root, es.length);

        uint256 gasBefore = gasleft();
        harness.seedAll(nft, es);
        assertLt(gasBefore - gasleft(), 2 * 12_000_000);

        assertEq(nft.seededCount(), 119);
        assertEq(nft.openAt(), block.timestamp + 1 hours);
    }
}
