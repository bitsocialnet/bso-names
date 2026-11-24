// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {NameNFT} from "../src/NameNFT.sol";

/// @dev Stands in for the fee recipient's code: calls back into the registry on receiving ETH.
contract ReenteringRecipient {
    NameNFT public nft;
    bool public reentered;
    bool public reentryFailed;

    function arm(NameNFT _nft) external {
        nft = _nft;
    }

    receive() external payable {
        if (address(nft) != address(0) && !reentered) {
            reentered = true;
            try nft.withdraw() {}
            catch {
                reentryFailed = true;
            }
        }
    }
}

/// @dev Rejects ETH.
contract RejectingRecipient {
    receive() external payable {
        revert("no");
    }
}

/// @notice BSIP-13 change 2: fees are collected, not locked.
contract WithdrawTest is Test {
    address constant FEE_RECIPIENT = 0x442A54b2AFEe1db441Df5aA825059d663c96AA6E;
    uint256 constant DEFAULT_FEE = 0.0005 ether;
    uint256 constant FEE_LEN3 = 0.05 ether;
    uint256 constant MIN_COMMITMENT_AGE = 60;
    uint256 constant REGISTRATION_PERIOD = 365 days;
    uint256 constant GRACE_PERIOD = 90 days;

    NameNFT nft;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        nft = new NameNFT(bytes32(0), 0);
        vm.warp(nft.SEED_END());
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    function _register(string memory label, address who, uint256 value)
        internal
        returns (uint256 id)
    {
        bytes32 secret = keccak256(abi.encode(label, who, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(who);
        id = nft.reveal{value: value}(label, secret);
    }

    function test_FeeRecipient_IsTheBsipAddress() public view {
        assertEq(nft.FEE_RECIPIENT(), FEE_RECIPIENT);
    }

    function test_Withdraw_AnyoneCanCall_AllGoesToFeeRecipient() public {
        _register("alice", alice, DEFAULT_FEE);
        _register("bob", bob, FEE_LEN3);
        assertEq(address(nft).balance, DEFAULT_FEE + FEE_LEN3);

        uint256 callerBefore = bob.balance;
        vm.prank(bob);
        nft.withdraw();

        assertEq(address(nft).balance, 0);
        assertEq(FEE_RECIPIENT.balance, DEFAULT_FEE + FEE_LEN3);
        assertEq(bob.balance, callerBefore, "the caller gets nothing");
    }

    function test_Withdraw_WithZeroBalance() public {
        nft.withdraw();
        assertEq(FEE_RECIPIENT.balance, 0);
    }

    function test_Withdraw_CollectsRenewalFeesAndPremiums() public {
        uint256 id = _register("alice", alice, DEFAULT_FEE);
        vm.prank(bob);
        nft.renew{value: DEFAULT_FEE}(id);
        nft.withdraw();
        assertEq(FEE_RECIPIENT.balance, 2 * DEFAULT_FEE);

        // Let it lapse, then re-register during the premium decay, overpaying.
        vm.warp(nft.expiresAt(id) + GRACE_PERIOD + 10.5 days - MIN_COMMITMENT_AGE);
        _commitAndReveal("alice", bob, 60 ether);

        // Exactly halfway through the 21 days: half of the 100 ETH premium, plus the fee.
        assertEq(nft.ownerOf(id), bob);
        assertEq(address(nft).balance, 50 ether + DEFAULT_FEE);

        nft.withdraw();
        assertEq(FEE_RECIPIENT.balance, 50 ether + 3 * DEFAULT_FEE);
        assertEq(address(nft).balance, 0);
    }

    function _commitAndReveal(string memory label, address who, uint256 value) internal {
        bytes32 secret = keccak256(abi.encode(label, who, block.timestamp));
        bytes32 commitment = nft.makeCommitment(label, who, secret);
        vm.prank(who);
        nft.commit(commitment);
        vm.warp(block.timestamp + MIN_COMMITMENT_AGE);
        vm.prank(who);
        nft.reveal{value: value}(label, secret);
    }

    /// Overpayment is refunded by reveal and renew as upstream; only the fee stays to withdraw.
    function test_Withdraw_OverpaymentIsRefundedNotCollected() public {
        uint256 before = alice.balance;
        uint256 id = _register("alice", alice, 1 ether);
        assertEq(alice.balance, before - DEFAULT_FEE);

        vm.prank(alice);
        nft.renew{value: 1 ether}(id);
        assertEq(alice.balance, before - 2 * DEFAULT_FEE);

        nft.withdraw();
        assertEq(FEE_RECIPIENT.balance, 2 * DEFAULT_FEE);
    }

    /// ETH attached by mistake to the payable ERC721 functions is swept with the fees.
    function test_Withdraw_SweepsEthSentWithApproveAndTransfer() public {
        uint256 id = _register("alice", alice, DEFAULT_FEE);

        vm.startPrank(alice);
        nft.approve{value: 1 ether}(bob, id);
        nft.transferFrom{value: 2 ether}(alice, bob, id);
        vm.stopPrank();

        nft.withdraw();
        assertEq(FEE_RECIPIENT.balance, DEFAULT_FEE + 3 ether);
    }

    /// The registry has no receive or fallback: plain ETH transfers are rejected.
    function test_PlainEthTransferIsRejected() public {
        vm.prank(alice);
        (bool ok,) = address(nft).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_Withdraw_WorksBeforeTheOpeningAndRepeatedly() public {
        NameNFT fresh = new NameNFT(bytes32(0), 0);
        fresh.withdraw();
        fresh.withdraw();
    }

    function test_Withdraw_IsNotReentrant() public {
        _register("alice", alice, DEFAULT_FEE);
        vm.etch(FEE_RECIPIENT, address(new ReenteringRecipient()).code);
        ReenteringRecipient(payable(FEE_RECIPIENT)).arm(nft);

        nft.withdraw();

        assertTrue(ReenteringRecipient(payable(FEE_RECIPIENT)).reentered());
        assertTrue(ReenteringRecipient(payable(FEE_RECIPIENT)).reentryFailed());
        assertEq(FEE_RECIPIENT.balance, DEFAULT_FEE);
    }

    /// If the recipient refuses ETH, withdraw reverts and the fees stay; nothing else is affected.
    function test_Withdraw_RevertsIfRecipientRejects_RegistryKeepsWorking() public {
        _register("alice", alice, DEFAULT_FEE);
        vm.etch(FEE_RECIPIENT, address(new RejectingRecipient()).code);

        vm.expectRevert();
        nft.withdraw();
        assertEq(address(nft).balance, DEFAULT_FEE);

        _register("bobby", bob, DEFAULT_FEE);
        assertEq(address(nft).balance, 2 * DEFAULT_FEE);
    }

    function testFuzz_Withdraw_SendsExactlyTheBalance(uint96 amount, address caller) public {
        vm.assume(caller != FEE_RECIPIENT && caller != address(nft));
        vm.deal(address(nft), amount);
        vm.prank(caller);
        nft.withdraw();
        assertEq(FEE_RECIPIENT.balance, amount);
        assertEq(address(nft).balance, 0);
    }
}
