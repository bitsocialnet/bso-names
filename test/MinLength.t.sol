// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {NameNFT} from "../src/NameNFT.sol";
import {SeedTree} from "../script/SeedTree.sol";

/// @notice BSIP-13 change 5: a top-level label has at least 3 Unicode code points.
contract MinLengthTest is Test {
    uint256 constant MIN_COMMITMENT_AGE = 60;
    bytes32 constant BSO_NODE = 0xe07ef0fd54600878e8c5c0087ff379e0fb9e1c49dfcc763bdada48721f534a20;

    NameNFT nft;
    address alice = address(0xA11CE);

    function setUp() public {
        nft = new NameNFT(bytes32(0), 0);
        vm.warp(nft.SEED_END());
        vm.deal(alice, 1000 ether);
    }

    function _reveal(string memory label) internal returns (uint256 id) {
        bytes32 secret = keccak256(abi.encode(label, block.timestamp));
        // makeCommitment is unchanged: it accepts a label that reveal will reject.
        bytes32 commitment = nft.makeCommitment(label, alice, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(alice);
        id = nft.reveal{value: 1 ether}(label, secret);
    }

    function _assertTooShort(string memory label) internal {
        assertFalse(nft.isAvailable(label, 0), label);

        bytes32 secret = keccak256(abi.encode(label));
        bytes32 commitment = nft.makeCommitment(label, alice, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(alice);
        vm.expectRevert(NameNFT.LabelTooShort.selector);
        nft.reveal{value: 1 ether}(label, secret);
    }

    function _assertLongEnough(string memory label) internal {
        assertTrue(nft.isAvailable(label, 0), label);
        uint256 id = _reveal(label);
        assertEq(nft.ownerOf(id), alice, label);
        assertFalse(nft.isAvailable(label, 0), label);
    }

    /*//////////////////////////////////////////////////////////////
                        REVEAL AND ISAVAILABLE
    //////////////////////////////////////////////////////////////*/

    function test_TooShort_OneAndTwoAsciiCharacters() public {
        _assertTooShort("a");
        _assertTooShort("ab");
        _assertTooShort("AB");
        _assertTooShort("a1");
        _assertTooShort("__");
    }

    /// One character of 2 bytes, and two of them: still fewer than 3 characters.
    function test_TooShort_AccentedLetters() public {
        _assertTooShort(unicode"é");
        _assertTooShort(unicode"éé");
        _assertTooShort(unicode"aé");
    }

    /// A single CJK character is 3 bytes, which upstream would price as a 3-byte label.
    function test_TooShort_CjkCharacters() public {
        _assertTooShort(unicode"中");
        _assertTooShort(unicode"中文");
    }

    /// A single emoji is 4 bytes; an emoji with a skin tone and a flag are 2 code points each.
    function test_TooShort_EmojiOfOneOrTwoCodePoints() public {
        _assertTooShort(unicode"😀");
        _assertTooShort(unicode"👍🏽");
        _assertTooShort(unicode"🇺🇸");
        _assertTooShort(unicode"😀😀");
    }

    function test_LongEnough_ThreeCharacters() public {
        _assertLongEnough("abc");
        _assertLongEnough("ABD");
        _assertLongEnough("a-b");
        _assertLongEnough(unicode"ééé");
        _assertLongEnough(unicode"中文字");
        _assertLongEnough(unicode"aé中");
        _assertLongEnough(unicode"😀😀😀");
        _assertLongEnough(unicode"a😀b");
    }

    /// An emoji sequence of three or more code points passes although it displays as one
    /// symbol: a family of three joined by zero-width joiners is 5 code points.
    function test_LongEnough_EmojiSequenceOfThreeOrMoreCodePoints() public {
        _assertLongEnough(unicode"👨‍👩‍👧");
    }

    function test_LongEnough_LongerNamesUnaffected() public {
        _assertLongEnough("alice");
        _assertLongEnough("relationship_advice");
    }

    /*//////////////////////////////////////////////////////////////
                        WHAT IS LEFT AS UPSTREAM
    //////////////////////////////////////////////////////////////*/

    /// makeCommitment and normalize only compute a value: they keep accepting short labels.
    function test_MakeCommitmentAndNormalize_StillAcceptShortLabels() public view {
        assertEq(nft.normalize("A"), "a");
        assertEq(nft.normalize("ab"), "ab");
        nft.makeCommitment("a", alice, bytes32(0));
        nft.makeCommitment(unicode"中", alice, bytes32(0));
    }

    /// Subdomain labels have no minimum beyond upstream's 1 byte.
    function test_Subdomains_AreExempt() public {
        uint256 parentId = _reveal("alice");

        assertTrue(nft.isAvailable("a", parentId));
        assertTrue(nft.isAvailable(unicode"中", parentId));

        vm.startPrank(alice);
        uint256 one = nft.registerSubdomain("a", parentId);
        uint256 two = nft.registerSubdomainFor("ab", parentId, alice);
        uint256 cjk = nft.registerSubdomain(unicode"中", parentId);
        vm.stopPrank();

        assertEq(nft.getFullName(one), "a.alice.bso");
        assertEq(nft.getFullName(two), "ab.alice.bso");
        assertEq(nft.getFullName(cjk), unicode"中.alice.bso");
    }

    /// An invalid label still fails validation first, as upstream.
    function test_InvalidLabelStillRevertsWithUpstreamErrors() public {
        vm.expectRevert(NameNFT.InvalidLength.selector);
        nft.reveal("", bytes32(0));
        vm.expectRevert(NameNFT.InvalidName.selector);
        nft.reveal("-a", bytes32(0));
        vm.expectRevert(NameNFT.InvalidName.selector);
        nft.reveal("a.", bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                                  SEED
    //////////////////////////////////////////////////////////////*/

    function test_Seed_RejectsShortTopLevelLabel_AcceptsShortSubdomain() public {
        uint256 parentId = uint256(keccak256(abi.encodePacked(BSO_NODE, keccak256("alice"))));
        NameNFT.SeedEntry[] memory es = new NameNFT.SeedEntry[](4);
        es[0].label = "ab";
        es[1].label = unicode"中";
        es[2].label = "alice";
        es[3].label = "a";
        es[3].parent = parentId;
        for (uint256 i; i < es.length; ++i) {
            es[i].owner = alice;
        }
        bytes32[] memory tree = SeedTree.build(es);
        NameNFT fresh = new NameNFT(tree[0], es.length);

        vm.expectRevert(NameNFT.LabelTooShort.selector);
        fresh.seed(es[0].label, 0, alice, "", es[0].proof);
        vm.expectRevert(NameNFT.LabelTooShort.selector);
        fresh.seed(es[1].label, 0, alice, "", es[1].proof);

        // In a batch it is not skipped: the batch reverts.
        vm.expectRevert(NameNFT.LabelTooShort.selector);
        fresh.seedBatch(es);

        fresh.seed(es[2].label, 0, alice, "", es[2].proof);
        fresh.seed(es[3].label, parentId, alice, "", es[3].proof);
        assertEq(
            fresh.getFullName(
                uint256(keccak256(abi.encodePacked(bytes32(parentId), keccak256("a"))))
            ),
            "a.alice.bso"
        );
    }

    /// The published seed list has no top-level label under 3 characters.
    function test_PublishedTree_NoShortTopLevelLabel() public view {
        (, NameNFT.SeedEntry[] memory es) = SeedTree.load("test/fixtures/seed-tree.json");
        for (uint256 i; i < es.length; ++i) {
            if (es[i].parent == 0) assertTrue(nft.isAvailable(es[i].label, 0), es[i].label);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// Count code points by decoding lead bytes, independently of the contract, which counts
    /// the bytes that are not continuation bytes.
    function _codePoints(bytes memory b) internal pure returns (uint256 n) {
        uint256 i;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            i += c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
            ++n;
        }
    }

    /// For every valid label: isAvailable and reveal agree with each other and with the count.
    function testFuzz_RevealAgreesWithIsAvailableAndTheCount(string calldata label) public {
        string memory normalized;
        try nft.normalize(label) returns (string memory n) {
            normalized = n;
        } catch {
            return;
        }
        bool longEnough = _codePoints(bytes(normalized)) >= 3;
        assertEq(nft.isAvailable(label, 0), longEnough);

        bytes32 secret = keccak256("s");
        bytes32 commitment = nft.makeCommitment(label, alice, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(alice);
        if (!longEnough) vm.expectRevert(NameNFT.LabelTooShort.selector);
        nft.reveal{value: 1 ether}(label, secret);
    }

    /// Labels built from 1 to 4 code points of every UTF-8 width, so the short cases that
    /// random strings rarely produce are covered.
    function testFuzz_BuiltLabels(uint256 seed, uint8 points) public {
        points = uint8(bound(points, 1, 4));
        bytes memory b;
        for (uint256 i; i < points; ++i) {
            uint256 width = (seed >> (i * 8)) % 4;
            if (width == 0) b = bytes.concat(b, "x");
            else if (width == 1) b = bytes.concat(b, unicode"é");
            else if (width == 2) b = bytes.concat(b, unicode"中");
            else b = bytes.concat(b, unicode"😀");
        }
        string memory label = string(b);
        assertEq(nft.isAvailable(label, 0), points >= 3);
        if (points >= 3) {
            _reveal(label);
        } else {
            _assertTooShort(label);
        }
    }
}
