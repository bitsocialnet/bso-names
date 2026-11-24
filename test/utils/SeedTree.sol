// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {NameNFT} from "../../src/NameNFT.sol";

/// @dev Reads and builds OpenZeppelin `StandardMerkleTree` dumps ("standard-v1") for the seed
///      list of BSIP-13, with leaf encoding (string label, uint256 parent, address owner,
///      string record). Used by the tests and by the deploy scripts.
library SeedTree {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Load a dump written by the OpenZeppelin merkle-tree package and derive every entry's proof
    ///      from its `tree` array. Entries keep the order of the file.
    function load(string memory path)
        internal
        view
        returns (bytes32 root, NameNFT.SeedEntry[] memory entries)
    {
        string memory json = vm.readFile(path);
        bytes32[] memory tree = vm.parseJsonBytes32Array(json, ".tree");
        root = tree[0];

        uint256 n = (tree.length + 1) / 2;
        entries = new NameNFT.SeedEntry[](n);
        for (uint256 i; i < n; ++i) {
            string memory at = string.concat(".values[", vm.toString(i), "]");
            entries[i].label = vm.parseJsonString(json, string.concat(at, ".value[0]"));
            entries[i].parent = vm.parseJsonUint(json, string.concat(at, ".value[1]"));
            entries[i].owner = vm.parseJsonAddress(json, string.concat(at, ".value[2]"));
            entries[i].record = vm.parseJsonString(json, string.concat(at, ".value[3]"));
            entries[i].proof =
                proofAt(tree, vm.parseJsonUint(json, string.concat(at, ".treeIndex")));
        }
    }

    /// @dev Build a tree over `entries` the way `StandardMerkleTree.of` does, and fill in each
    ///      entry's proof. Returns the whole tree array; `tree[0]` is the root.
    function build(NameNFT.SeedEntry[] memory entries)
        internal
        pure
        returns (bytes32[] memory tree)
    {
        uint256 n = entries.length;
        require(n > 0, "empty tree");

        // Leaves sorted by hash, ascending.
        bytes32[] memory hashes = new bytes32[](n);
        uint256[] memory order = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 h = leaf(entries[i]);
            uint256 j = i;
            while (j > 0 && hashes[j - 1] > h) {
                hashes[j] = hashes[j - 1];
                order[j] = order[j - 1];
                --j;
            }
            hashes[j] = h;
            order[j] = i;
        }

        tree = new bytes32[](2 * n - 1);
        for (uint256 i; i < n; ++i) {
            tree[tree.length - 1 - i] = hashes[i];
        }
        for (uint256 i = tree.length - n; i > 0; --i) {
            tree[i - 1] = _hashPair(tree[2 * i - 1], tree[2 * i]);
        }
        for (uint256 i; i < n; ++i) {
            entries[order[i]].proof = proofAt(tree, tree.length - 1 - i);
        }
    }

    function leaf(NameNFT.SeedEntry memory e) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(e.label, e.parent, e.owner, e.record))));
    }

    function proofAt(bytes32[] memory tree, uint256 index)
        internal
        pure
        returns (bytes32[] memory proof)
    {
        uint256 depth;
        for (uint256 i = index; i > 0; i = (i - 1) / 2) {
            ++depth;
        }
        proof = new bytes32[](depth);
        for (uint256 k; k < depth; ++k) {
            proof[k] = tree[index % 2 == 1 ? index + 1 : index - 1];
            index = (index - 1) / 2;
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
