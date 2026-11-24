// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {NameNFT} from "../src/NameNFT.sol";
import {SeedTree} from "./SeedTree.sol";

/// @dev The seed tree is the `seed-tree.json` of BSIP-13 (`assets/bsip-13/` in the BSIPs
///      repository), an OpenZeppelin StandardMerkleTree dump. Its path comes from the
///      SEED_TREE environment variable.
abstract contract SeedScript is Script {
    function _tree() internal view returns (bytes32 root, NameNFT.SeedEntry[] memory entries) {
        return SeedTree.load(vm.envString("SEED_TREE"));
    }

    function _id(NameNFT nft, NameNFT.SeedEntry memory e) internal view returns (uint256) {
        bytes32 parentNode = e.parent == 0 ? nft.BSO_NODE() : bytes32(e.parent);
        return
            uint256(
                keccak256(abi.encodePacked(parentNode, keccak256(bytes(nft.normalize(e.label)))))
            );
    }

    function _batchSize() internal view returns (uint256 size) {
        size = vm.envOr("SEED_BATCH", uint256(60));
        require(size != 0, "SEED_BATCH must be at least 1");
    }

    function _seedAll(NameNFT nft, NameNFT.SeedEntry[] memory entries) internal {
        uint256 batchSize = _batchSize();
        for (uint256 from; from < entries.length; from += batchSize) {
            uint256 to = from + batchSize > entries.length ? entries.length : from + batchSize;
            NameNFT.SeedEntry[] memory batch = new NameNFT.SeedEntry[](to - from);
            for (uint256 i = from; i < to; ++i) {
                batch[i - from] = entries[i];
            }
            nft.seedBatch(batch);
        }
    }

    /// @dev Seed the whole tree into a throwaway registry inside the script's own EVM, the way
    ///      `Seed` will, and require that every entry registers. A tree with an entry that
    ///      cannot be seeded (two spellings of one label, a label that is too short or
    ///      invalid, a subdomain listed before its parent) would never reach SEED_COUNT, and
    ///      registration would open only at SEED_END.
    function _rehearse(bytes32 root, NameNFT.SeedEntry[] memory entries) internal {
        NameNFT rehearsal = new NameNFT(root, entries.length);
        for (uint256 i; i < entries.length; ++i) {
            require(
                keccak256(bytes(rehearsal.normalize(entries[i].label)))
                    == keccak256(bytes(entries[i].label)),
                string.concat("seed tree: label is not in normalized form: ", entries[i].label)
            );
        }
        _seedAll(rehearsal, entries);
        require(
            rehearsal.seededCount() == entries.length && rehearsal.openAt() != 0,
            "seed tree: not every entry can be seeded"
        );
        for (uint256 i; i < entries.length; ++i) {
            require(
                rehearsal.ownerOf(_id(rehearsal, entries[i])) == entries[i].owner,
                string.concat("seed tree: entry not seeded to its owner: ", entries[i].label)
            );
        }
    }

    function _requireSameTree(NameNFT nft, bytes32 root, uint256 count) internal view {
        require(root == nft.SEED_ROOT(), "seed tree does not match the registry's SEED_ROOT");
        require(count == nft.SEED_COUNT(), "seed tree does not match the registry's SEED_COUNT");
    }
}

/// @notice Deploy the registry with the root and the number of entries of the seed tree,
///         after checking the tree file and rehearsing the seeding of every entry.
///
///   SEED_TREE=seed-tree.json forge script script/Deploy.s.sol:Deploy \
///     --rpc-url <rpc> --account <keystore> --broadcast --verify
contract Deploy is SeedScript {
    function run() external returns (NameNFT nft) {
        (bytes32 root, NameNFT.SeedEntry[] memory entries) = _tree();
        _rehearse(root, entries);

        // FEE_RECIPIENT is the maintainers' Safe on Ethereum mainnet. On a testnet nothing may
        // be deployed at that address: fees sent there by withdraw() are lost, and sunset()
        // cannot be called.
        address feeRecipient = 0x442A54b2AFEe1db441Df5aA825059d663c96AA6E;
        if (block.chainid == 1) {
            require(feeRecipient.code.length != 0, "FEE_RECIPIENT has no code on mainnet");
        } else if (feeRecipient.code.length == 0) {
            console2.log("WARNING: FEE_RECIPIENT has no code on chain", block.chainid);
        }

        vm.startBroadcast();
        nft = new NameNFT(root, entries.length);
        vm.stopBroadcast();
        require(nft.FEE_RECIPIENT() == feeRecipient, "FEE_RECIPIENT differs from the script's");

        console2.log("NameNFT", address(nft));
        console2.log("SEED_ROOT");
        console2.logBytes32(root);
        console2.log("SEED_COUNT", entries.length);
        console2.log("SEED_END", nft.SEED_END());
    }
}

/// @notice Seed every entry of the tree, in the order of the file, in batches of SEED_BATCH
///         entries (default 60), one transaction each. The registry skips entries that are
///         already seeded, so the script can be run again after a failure.
///
///   SEED_TREE=seed-tree.json REGISTRY=<address> forge script script/Deploy.s.sol:Seed \
///     --rpc-url <rpc> --account <keystore> --broadcast --slow
contract Seed is SeedScript {
    function run() external {
        NameNFT nft = NameNFT(vm.envAddress("REGISTRY"));
        (bytes32 root, NameNFT.SeedEntry[] memory entries) = _tree();
        _requireSameTree(nft, root, entries.length);

        vm.startBroadcast();
        _seedAll(nft, entries);
        vm.stopBroadcast();
    }
}

/// @notice Check that every entry of the tree is registered to its listed owner with its
///         listed record, and print the opening time. Sends no transaction.
/// @dev Run it right after seeding. An owner may transfer a seeded name or change its record
///      at once, and such a name is then reported as not as listed.
///
///   SEED_TREE=seed-tree.json REGISTRY=<address> forge script script/Deploy.s.sol:CheckSeeded \
///     --rpc-url <rpc>
contract CheckSeeded is SeedScript {
    function run() external view {
        NameNFT nft = NameNFT(vm.envAddress("REGISTRY"));
        (bytes32 root, NameNFT.SeedEntry[] memory entries) = _tree();
        _requireSameTree(nft, root, entries.length);

        uint256 wrong;
        for (uint256 i; i < entries.length; ++i) {
            if (!_asListed(nft, entries[i])) {
                ++wrong;
                console2.log("NOT AS LISTED:", entries[i].label, entries[i].parent);
            }
        }

        console2.log("entries", entries.length);
        console2.log("seededCount", nft.seededCount());
        console2.log("not as listed", wrong);
        console2.log("openAt", nft.openAt());
        console2.log("SEED_END", nft.SEED_END());
        require(wrong == 0, "some entries are not registered as listed");
        require(nft.seededCount() == nft.SEED_COUNT(), "seededCount != SEED_COUNT");
    }

    function _asListed(NameNFT nft, NameNFT.SeedEntry memory e) internal view returns (bool) {
        uint256 id = _id(nft, e);
        (string memory label,,,,) = nft.records(id);
        if (bytes(label).length == 0) return false;
        if (nft.ownerOf(id) != e.owner) return false;
        return keccak256(bytes(nft.text(bytes32(id), "bitsocial"))) == keccak256(bytes(e.record));
    }
}
