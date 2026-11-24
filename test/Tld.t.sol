// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {NameNFT} from "../src/NameNFT.sol";

/// @notice BSIP-13 change 1: the .bso root and names.
contract TldTest is Test {
    bytes32 constant BSO_NODE = 0xe07ef0fd54600878e8c5c0087ff379e0fb9e1c49dfcc763bdada48721f534a20;
    uint256 constant MIN_COMMITMENT_AGE = 60;

    NameNFT nft;
    address alice = address(0xA11CE);

    function setUp() public {
        nft = new NameNFT(bytes32(0), 0);
        vm.warp(nft.SEED_END());
        vm.deal(alice, 100 ether);
    }

    function _register(string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(bytes(label));
        bytes32 commitment = nft.makeCommitment(label, alice, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(alice);
        id = nft.reveal{value: 1 ether}(label, secret);
    }

    function _node(string memory label) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(BSO_NODE, keccak256(bytes(label))));
    }

    function test_NameAndSymbol() public view {
        assertEq(nft.name(), "Bitsocial Names");
        assertEq(nft.symbol(), "BSONAME");
    }

    function test_BsoNode_IsNamehashOfBso() public view {
        assertEq(nft.BSO_NODE(), keccak256(abi.encodePacked(bytes32(0), keccak256("bso"))));
        assertEq(nft.BSO_NODE(), BSO_NODE);
    }

    /// The example of BSIP-13, "Resolving .bso names".
    function test_BsipExample_MemesBso() public {
        bytes32 node = 0x32766e8bc53e343c21d132d673d112b27f0e1aa11965199b934d29721837a941;
        assertEq(nft.computeNamehash("memes.bso"), node);

        uint256 id = _register("memes");
        assertEq(bytes32(id), node);
        vm.prank(alice);
        nft.setText(id, "bitsocial", "12D3KooWNsF2eMrdw3YFPycAaFEvZ9Eq3ekhNL3vrAAfN6dAwXLp");
        assertEq(
            nft.text(node, "bitsocial"), "12D3KooWNsF2eMrdw3YFPycAaFEvZ9Eq3ekhNL3vrAAfN6dAwXLp"
        );
    }

    function test_ComputeNamehash_StripsTheBsoSuffixOnly() public view {
        assertEq(nft.computeNamehash(""), BSO_NODE);
        assertEq(nft.computeNamehash(".bso"), BSO_NODE);
        assertEq(nft.computeNamehash("alice"), _node("alice"));
        assertEq(nft.computeNamehash("alice.bso"), _node("alice"));
        assertEq(nft.computeNamehash("ALICE.BsO"), _node("alice"));

        // A label that merely ends in "bso" is not a suffix: the dot is required.
        assertEq(nft.computeNamehash("abso"), _node("abso"));
        assertEq(nft.computeNamehash("xbso"), _node("xbso"));
        assertEq(nft.computeNamehash("bso"), _node("bso"));
        assertEq(nft.computeNamehash("bso.bso"), _node("bso"));

        // The upstream suffix is now an ordinary label.
        bytes32 gweiLabel = _node("gwei");
        assertEq(
            nft.computeNamehash("alice.gwei"),
            keccak256(abi.encodePacked(gweiLabel, keccak256("alice")))
        );

        // Only one suffix is stripped: x.bso.bso is x under the name bso.bso.
        assertEq(
            nft.computeNamehash("x.bso.bso"),
            keccak256(abi.encodePacked(_node("bso"), keccak256("x")))
        );
        assertEq(
            nft.computeNamehash("a.b.bso"), keccak256(abi.encodePacked(_node("b"), keccak256("a")))
        );
    }

    function test_ComputeNamehash_EmptyLabelsRevert() public {
        vm.expectRevert(NameNFT.EmptyLabel.selector);
        nft.computeNamehash("..bso");
        vm.expectRevert(NameNFT.EmptyLabel.selector);
        nft.computeNamehash("a..bso");
    }

    function test_FullNameAndReverseResolve_EndInBso() public {
        uint256 id = _register("alice");
        vm.startPrank(alice);
        uint256 subId = nft.registerSubdomain("sub", id);
        nft.setPrimaryName(subId);
        vm.stopPrank();

        assertEq(nft.getFullName(id), "alice.bso");
        assertEq(nft.getFullName(subId), "sub.alice.bso");
        assertEq(nft.reverseResolve(alice), "sub.alice.bso");
        assertEq(nft.computeId("sub.alice.bso"), subId);
    }

    function test_TokenURI_NamesTheBsoNameAndBitsocialNames() public {
        uint256 id = _register("alice");
        string memory uri = nft.tokenURI(id);
        string memory prefix = "data:application/json;base64,";
        assertTrue(LibString.startsWith(uri, prefix));

        string memory json =
            string(Base64.decode(LibString.slice(uri, bytes(prefix).length, bytes(uri).length)));
        assertTrue(LibString.startsWith(json, '{"name":"alice.bso","description":"'), json);
        assertTrue(LibString.contains(json, '"description":"Bitsocial Names: alice.bso"'), json);
        assertFalse(LibString.contains(LibString.lower(json), "gwei"), json);

        // The image shows the same name.
        string memory imagePrefix = '"image":"data:image/svg+xml;base64,';
        uint256 start = LibString.indexOf(json, imagePrefix) + bytes(imagePrefix).length;
        uint256 end = LibString.indexOf(json, '"', start);
        string memory svg = string(Base64.decode(LibString.slice(json, start, end)));
        assertTrue(LibString.contains(svg, ">alice.bso</text>"), svg);
    }
}
