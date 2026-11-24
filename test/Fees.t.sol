// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {NameNFT} from "../src/NameNFT.sol";

/// @notice The fee tier of a top-level label goes by its length in Unicode code points, as
///         ENS's does. Upstream goes by bytes.
contract FeesTest is Test {
    uint256 constant MIN_COMMITMENT_AGE = 60;
    uint256 constant FEE_LEN3 = 0.05 ether;
    uint256 constant FEE_LEN4 = 0.01 ether;
    uint256 constant DEFAULT_FEE = 0.0005 ether;

    NameNFT nft;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        nft = new NameNFT(bytes32(0), 0);
        vm.warp(nft.SEED_END());
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _commit(string memory label) internal returns (bytes32 secret) {
        secret = keccak256(abi.encode(label, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, alice, secret);
        vm.prank(alice);
        nft.commit(commitment);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
    }

    /// Registers `label` overpaying, and returns what it cost after the refund.
    function _costToRegister(string memory label) internal returns (uint256 cost, uint256 id) {
        bytes32 secret = _commit(label);
        uint256 before = alice.balance;
        vm.prank(alice);
        id = nft.reveal{value: 1 ether}(label, secret);
        cost = before - alice.balance;
    }

    function _assertFee(string memory label, uint256 fee) internal {
        // One wei short is refused.
        bytes32 secret = _commit(label);
        vm.prank(alice);
        vm.expectRevert(NameNFT.InsufficientFee.selector);
        nft.reveal{value: fee - 1}(label, secret);

        // The exact fee is accepted, and renewal costs the same.
        vm.prank(alice);
        uint256 id = nft.reveal{value: fee}(label, secret);
        assertEq(nft.ownerOf(id), alice, label);

        vm.prank(bob);
        vm.expectRevert(NameNFT.InsufficientFee.selector);
        nft.renew{value: fee - 1}(id);

        uint256 before = bob.balance;
        vm.prank(bob);
        nft.renew{value: 1 ether}(id);
        assertEq(before - bob.balance, fee, label);
    }

    function test_ThreeCharacters_CostTheThreeCharacterFee_InAnyScript() public {
        _assertFee("abc", FEE_LEN3);
        _assertFee(unicode"абв", FEE_LEN3); // 6 bytes
        _assertFee(unicode"日本語", FEE_LEN3); // 9 bytes
        _assertFee(unicode"😀😀😀", FEE_LEN3); // 12 bytes
        _assertFee(unicode"aé中", FEE_LEN3);
    }

    function test_FourCharacters_CostTheFourCharacterFee_InAnyScript() public {
        _assertFee("abcd", FEE_LEN4);
        _assertFee(unicode"абвг", FEE_LEN4); // 8 bytes
        _assertFee(unicode"日本語字", FEE_LEN4); // 12 bytes
    }

    function test_FiveOrMoreCharacters_CostTheDefaultFee() public {
        _assertFee("alice", DEFAULT_FEE);
        _assertFee(unicode"абвгд", DEFAULT_FEE);
        _assertFee(unicode"日本語字字", DEFAULT_FEE);
        _assertFee("relationship-advice", DEFAULT_FEE);
    }

    /// Uppercase ASCII is lowercased before it is counted: same name, same fee.
    function test_UppercaseCostsTheSame() public {
        (uint256 cost,) = _costToRegister("ABC");
        assertEq(cost, FEE_LEN3);
    }

    /// getFee takes a length in characters. Its tiers are upstream's.
    function test_GetFee_TiersAreUpstreams() public view {
        assertEq(nft.getFee(1), 0.5 ether);
        assertEq(nft.getFee(2), 0.1 ether);
        assertEq(nft.getFee(3), FEE_LEN3);
        assertEq(nft.getFee(4), FEE_LEN4);
        assertEq(nft.getFee(5), DEFAULT_FEE);
        assertEq(nft.getFee(255), DEFAULT_FEE);
    }

    /// The fee and the expiry premium add up as upstream.
    function test_PremiumIsAddedToTheCharacterFee() public {
        (, uint256 id) = _costToRegister(unicode"日本語");
        vm.warp(nft.expiresAt(id) + 90 days + 10.5 days - MIN_COMMITMENT_AGE);

        // Halfway through the 21 days the premium is half of 100 ETH.
        bytes32 secret = _commit(unicode"日本語");
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.reveal{value: 60 ether}(unicode"日本語", secret);
        assertEq(before - alice.balance, 50 ether + FEE_LEN3);
    }

    function _codePoints(bytes memory b) internal pure returns (uint256 n) {
        uint256 i;
        while (i < b.length) {
            uint8 c = uint8(b[i]);
            i += c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
            ++n;
        }
    }

    /// For every registrable label, reveal and renew charge getFee of its character count,
    /// counted here by decoding lead bytes, independently of the contract.
    function testFuzz_RevealAndRenewChargeByCharacters(string calldata label) public {
        if (!nft.isAvailable(label, 0)) return;
        uint256 fee = nft.getFee(_codePoints(bytes(label)));

        (uint256 cost, uint256 id) = _costToRegister(label);
        assertEq(cost, fee);

        uint256 before = bob.balance;
        vm.prank(bob);
        nft.renew{value: 1 ether}(id);
        assertEq(before - bob.balance, fee);
        assertEq(address(nft).balance, 2 * fee);
    }

    /// Labels built from 3 to 6 code points of every UTF-8 width.
    function testFuzz_BuiltLabels(uint256 seed, uint8 points) public {
        points = uint8(bound(points, 3, 6));
        bytes memory b;
        for (uint256 i; i < points; ++i) {
            uint256 width = (seed >> (i * 8)) % 4;
            if (width == 0) b = bytes.concat(b, "x");
            else if (width == 1) b = bytes.concat(b, unicode"é");
            else if (width == 2) b = bytes.concat(b, unicode"中");
            else b = bytes.concat(b, unicode"😀");
        }
        (uint256 cost,) = _costToRegister(string(b));
        assertEq(cost, points == 3 ? FEE_LEN3 : points == 4 ? FEE_LEN4 : DEFAULT_FEE);
    }
}
