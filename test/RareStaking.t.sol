// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/RareStaking.sol";
import "../src/interfaces/IRareStaking.sol";
import "openzeppelin-contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/token/ERC20/IERC20.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MTK") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract ReentrantToken is ERC20 {
    address private target;
    bytes private callData;
    bool private shouldReenter;

    constructor() ERC20("Reentrant Token", "RENT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function setReentrant(address _target, bytes memory _callData) external {
        target = _target;
        callData = _callData;
        shouldReenter = true;
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (shouldReenter) {
            shouldReenter = false; // Prevent infinite recursion
            // Try to reenter
            (bool success, ) = target.call(callData);
            require(success, "Reentrant call failed");
        }
        return super.transfer(to, amount);
    }
}

contract RareStakingTest is Test {
    RareStaking public rareStaking;
    MockERC20 public token;
    address public owner;
    address public user1;
    address public user2;
    bytes32 public merkleRoot;
    uint256 public constant CLAIM_AMOUNT = 100 ether;

    // Events
    event TokensClaimed(
        bytes32 indexed root,
        address indexed addr,
        uint256 amount,
        uint256 round
    );
    event NewClaimRootAdded(
        bytes32 indexed root,
        uint256 indexed round,
        uint256 timestamp
    );
    event Staked(address indexed user, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed user, uint256 amount, uint256 timestamp);

    // Custom errors from OpenZeppelin ERC20
    error ERC20InsufficientAllowance(
        address spender,
        uint256 allowance,
        uint256 needed
    );

    function setUp() public {
        owner = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Deploy mock token and mint tokens directly
        token = new MockERC20();
        token.mint(owner, 1_000_000 ether); // Mint 1M tokens to owner

        // Create merkle root for testing
        bytes32 leaf1 = keccak256(abi.encodePacked(user1, CLAIM_AMOUNT));
        bytes32 leaf2 = keccak256(abi.encodePacked(user2, CLAIM_AMOUNT));
        merkleRoot = keccak256(abi.encodePacked(leaf1, leaf2));

        // Deploy RareStaking contract
        rareStaking = new RareStaking(address(token), merkleRoot);

        // Transfer tokens to contract and users
        token.transfer(address(rareStaking), 10_000 ether);
        token.transfer(user1, 1_000 ether);
        token.transfer(user2, 1_000 ether);
    }

    function testConstructor() public {
        assertEq(address(rareStaking.token()), address(token));
        assertEq(rareStaking.currentClaimRoot(), merkleRoot);
        assertEq(rareStaking.currentRound(), 0);
    }

    function testConstructorZeroAddressFail() public {
        vm.expectRevert(IRareStaking.ZeroTokenAddress.selector);
        new RareStaking(address(0), merkleRoot);
    }

    function testConstructorEmptyRootFail() public {
        vm.expectRevert(IRareStaking.EmptyMerkleRoot.selector);
        new RareStaking(address(token), bytes32(0));
    }

    function testClaim() public {
        // Create proof for user1
        bytes32[] memory proof = new bytes32[](1);
        bytes32 leaf1 = keccak256(abi.encodePacked(user1, CLAIM_AMOUNT));
        bytes32 leaf2 = keccak256(abi.encodePacked(user2, CLAIM_AMOUNT));
        proof[0] = leaf2;

        // Increment round (otherwise claim will fail as round 0)
        rareStaking.updateMerkleRoot(merkleRoot);

        // Test claim
        vm.startPrank(user1);
        vm.expectEmit(true, true, false, true);
        emit TokensClaimed(merkleRoot, user1, CLAIM_AMOUNT, 1);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // User should have their initial balance (1000) plus claim amount (100)
        assertEq(token.balanceOf(user1), 1_100 ether);
        assertEq(rareStaking.lastClaimedRound(user1), 1);
        vm.stopPrank();
    }

    function testCannotClaimTwiceInSameRound() public {
        // Create proof for user1
        bytes32[] memory proof = new bytes32[](1);
        bytes32 leaf2 = keccak256(abi.encodePacked(user2, CLAIM_AMOUNT));
        proof[0] = leaf2;

        // Increment round
        rareStaking.updateMerkleRoot(merkleRoot);

        vm.startPrank(user1);
        // First claim should succeed
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // Second claim should fail
        vm.expectRevert(IRareStaking.AlreadyClaimed.selector);
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testCanClaimInNewRound() public {
        // Create proof for user1
        bytes32[] memory proof = new bytes32[](1);
        bytes32 leaf2 = keccak256(abi.encodePacked(user2, CLAIM_AMOUNT));
        proof[0] = leaf2;

        // First round
        vm.prank(owner);
        rareStaking.updateMerkleRoot(merkleRoot);

        vm.startPrank(user1);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // New round
        vm.stopPrank();
        vm.prank(owner);
        rareStaking.updateMerkleRoot(merkleRoot);

        vm.prank(user1);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // User should have initial balance (1000) plus two claims (100 each)
        assertEq(token.balanceOf(user1), 1_200 ether);
    }

    function testCannotClaimWithInvalidProof() public {
        // Create invalid proof
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(uint256(1)); // Random invalid proof

        rareStaking.updateMerkleRoot(merkleRoot);

        vm.startPrank(user1);
        vm.expectRevert(IRareStaking.InvalidMerkleProof.selector);
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testUpdateMerkleRoot() public {
        bytes32 newRoot = bytes32(uint256(123));

        vm.expectEmit(true, true, false, true);
        emit NewClaimRootAdded(newRoot, 1, block.timestamp);
        rareStaking.updateMerkleRoot(newRoot);

        assertEq(rareStaking.currentClaimRoot(), newRoot);
        assertEq(rareStaking.currentRound(), 1);
    }

    function testUpdateMerkleRootEmptyRootFail() public {
        vm.expectRevert(IRareStaking.EmptyMerkleRoot.selector);
        rareStaking.updateMerkleRoot(bytes32(0));
    }

    function testUpdateTokenAddress() public {
        address newToken = makeAddr("newToken");
        rareStaking.updateTokenAddress(newToken);
        assertEq(address(rareStaking.token()), newToken);
    }

    function testUpdateTokenAddressZeroAddressFail() public {
        vm.expectRevert(IRareStaking.ZeroTokenAddress.selector);
        rareStaking.updateTokenAddress(address(0));
    }

    function testOnlyOwnerCanUpdateMerkleRoot() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user1
            )
        );
        rareStaking.updateMerkleRoot(bytes32(uint256(123)));
    }

    function testOnlyOwnerCanUpdateTokenAddress() public {
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "OwnableUnauthorizedAccount(address)",
                user1
            )
        );
        rareStaking.updateTokenAddress(makeAddr("newToken"));
    }

    function testStake() public {
        uint256 stakeAmount = 100 ether;

        vm.startPrank(address(this));
        token.approve(address(rareStaking), stakeAmount);

        // Get initial balances
        uint256 initialBalance = token.balanceOf(address(this));
        uint256 initialContractBalance = token.balanceOf(address(rareStaking));

        // Stake tokens
        vm.expectEmit(true, false, false, true);
        emit Staked(address(this), stakeAmount, block.timestamp);
        rareStaking.stake(stakeAmount);

        // Verify balances
        assertEq(token.balanceOf(address(this)), initialBalance - stakeAmount);
        assertEq(
            token.balanceOf(address(rareStaking)),
            initialContractBalance + stakeAmount
        );
        assertEq(rareStaking.stakedAmount(address(this)), stakeAmount);
        assertEq(rareStaking.totalStaked(), stakeAmount);
        vm.stopPrank();
    }

    function testCannotStakeZero() public {
        vm.expectRevert(IRareStaking.ZeroStakeAmount.selector);
        rareStaking.stake(0);
    }

    function testCannotStakeWithoutAllowance() public {
        // Try to stake without approving
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientAllowance.selector,
                address(rareStaking),
                0,
                100 ether
            )
        );
        rareStaking.stake(100 ether);
    }

    function testCannotStakeWithInsufficientAllowance() public {
        uint256 stakeAmount = 100 ether;
        uint256 allowance = 50 ether; // Less than stake amount

        vm.startPrank(user1);
        token.approve(address(rareStaking), allowance);

        // Try to stake more than allowed
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientAllowance.selector,
                address(rareStaking),
                allowance,
                stakeAmount
            )
        );
        rareStaking.stake(stakeAmount);
        vm.stopPrank();
    }

    function testUnstake() public {
        uint256 stakeAmount = 100 ether;

        // Setup: approve and stake tokens
        vm.startPrank(address(this));
        token.approve(address(rareStaking), stakeAmount);
        rareStaking.stake(stakeAmount);

        // Get balances before unstake
        uint256 balanceBeforeUnstake = token.balanceOf(address(this));
        uint256 contractBalanceBeforeUnstake = token.balanceOf(
            address(rareStaking)
        );

        // Unstake tokens
        vm.expectEmit(true, false, false, true);
        emit Unstaked(address(this), stakeAmount, block.timestamp);
        rareStaking.unstake(stakeAmount);

        // Verify balances
        assertEq(
            token.balanceOf(address(this)),
            balanceBeforeUnstake + stakeAmount
        );
        assertEq(
            token.balanceOf(address(rareStaking)),
            contractBalanceBeforeUnstake - stakeAmount
        );
        assertEq(rareStaking.stakedAmount(address(this)), 0);
        assertEq(rareStaking.totalStaked(), 0);
        vm.stopPrank();
    }

    function testCannotUnstakeZero() public {
        vm.expectRevert(IRareStaking.ZeroUnstakeAmount.selector);
        rareStaking.unstake(0);
    }

    function testCannotUnstakeMoreThanStaked() public {
        uint256 stakeAmount = 100 ether;

        // Setup: approve and stake tokens
        vm.startPrank(address(this));
        token.approve(address(rareStaking), stakeAmount);
        rareStaking.stake(stakeAmount);

        // Try to unstake more than staked
        vm.expectRevert(IRareStaking.InsufficientStakedBalance.selector);
        rareStaking.unstake(stakeAmount + 1);
        vm.stopPrank();
    }

    function testGetStakedBalance() public {
        uint256 stakeAmount = 100 ether;

        // Setup: approve and stake tokens
        vm.startPrank(address(this));
        token.approve(address(rareStaking), stakeAmount);
        rareStaking.stake(stakeAmount);

        assertEq(rareStaking.getStakedBalance(address(this)), stakeAmount);
        vm.stopPrank();
    }

    function testStakeAfterTokenUpdate() public {
        uint256 stakeAmount = 100 ether;
        MockERC20 newToken = new MockERC20();

        // Mint tokens to test contract for the new token
        newToken.mint(address(this), 1_000_000 ether);

        // Update token address
        rareStaking.updateTokenAddress(address(newToken));

        // Setup staking with new token
        vm.startPrank(address(this));
        newToken.approve(address(rareStaking), stakeAmount);

        // Get initial balances
        uint256 initialBalance = newToken.balanceOf(address(this));
        uint256 initialContractBalance = newToken.balanceOf(
            address(rareStaking)
        );

        // Stake tokens
        vm.expectEmit(true, false, false, true);
        emit Staked(address(this), stakeAmount, block.timestamp);
        rareStaking.stake(stakeAmount);

        // Verify balances
        assertEq(
            newToken.balanceOf(address(this)),
            initialBalance - stakeAmount
        );
        assertEq(
            newToken.balanceOf(address(rareStaking)),
            initialContractBalance + stakeAmount
        );
        assertEq(rareStaking.stakedAmount(address(this)), stakeAmount);
        assertEq(rareStaking.totalStaked(), stakeAmount);
        vm.stopPrank();
    }

    function testPreventReentrantUnstake() public {
        // Deploy malicious token
        ReentrantToken maliciousToken = new ReentrantToken();
        maliciousToken.mint(address(this), 1_000_000 ether);

        // Update staking contract to use malicious token
        rareStaking.updateTokenAddress(address(maliciousToken));

        // Prepare for staking
        uint256 stakeAmount = 100 ether;
        maliciousToken.approve(address(rareStaking), stakeAmount);
        rareStaking.stake(stakeAmount);

        // Prepare reentrant call data (another unstake)
        bytes memory unstakeCall = abi.encodeWithSignature(
            "unstake(uint256)",
            stakeAmount
        );
        maliciousToken.setReentrant(address(rareStaking), unstakeCall);

        // Try to unstake - should revert due to reentrancy guard
        vm.expectRevert();
        rareStaking.unstake(stakeAmount);
    }

    function testPreventReentrantClaim() public {
        // Deploy malicious token
        ReentrantToken maliciousToken = new ReentrantToken();
        maliciousToken.mint(address(this), 1_000_000 ether);

        // Update staking contract to use malicious token
        rareStaking.updateTokenAddress(address(maliciousToken));

        // Transfer tokens to contract for rewards
        maliciousToken.transfer(address(rareStaking), 10_000 ether);

        // Create proof for claim
        bytes32[] memory proof = new bytes32[](1);
        bytes32 leaf2 = keccak256(abi.encodePacked(user2, CLAIM_AMOUNT));
        proof[0] = leaf2;

        // Update merkle root to allow claiming
        rareStaking.updateMerkleRoot(merkleRoot);

        // Prepare reentrant call data (another claim)
        bytes memory claimCall = abi.encodeWithSignature(
            "claim(uint256,bytes32[])",
            CLAIM_AMOUNT,
            proof
        );
        maliciousToken.setReentrant(address(rareStaking), claimCall);

        // Try to claim - should revert due to reentrancy guard
        vm.startPrank(user1);
        vm.expectRevert();
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testCannotReuseProofForDifferentAddress() public {
        // Create proof for user1
        bytes32[] memory proof = new bytes32[](1);
        bytes32 leaf2 = keccak256(abi.encodePacked(user2, CLAIM_AMOUNT));
        proof[0] = leaf2;

        // Increment round
        rareStaking.updateMerkleRoot(merkleRoot);

        // Try to use user1's proof for user2
        vm.startPrank(user2);
        vm.expectRevert(IRareStaking.InvalidMerkleProof.selector);
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testCannotClaimDifferentAmountInSameRound() public {
        // Create two different valid proofs for user1
        bytes32[] memory proof1 = new bytes32[](1);
        bytes32[] memory proof2 = new bytes32[](1);

        // Create a new merkle tree with two different amounts for user1
        bytes32 leaf1 = keccak256(abi.encodePacked(user1, CLAIM_AMOUNT));
        bytes32 leaf2 = keccak256(abi.encodePacked(user1, CLAIM_AMOUNT * 2));
        bytes32 newRoot = keccak256(abi.encodePacked(leaf1, leaf2));

        // Set up proofs
        proof1[0] = leaf2; // Proof for first amount
        proof2[0] = leaf1; // Proof for second amount

        // Update merkle root to allow both proofs
        rareStaking.updateMerkleRoot(newRoot);

        vm.startPrank(user1);
        // First claim should succeed
        rareStaking.claim(CLAIM_AMOUNT, proof1);

        // Second claim should fail even with a different valid proof
        vm.expectRevert(IRareStaking.AlreadyClaimed.selector);
        rareStaking.claim(CLAIM_AMOUNT * 2, proof2);
        vm.stopPrank();

        // Verify user only received one claim amount
        assertEq(token.balanceOf(user1), 1_100 ether); // Initial 1000 + one claim of 100
    }
}
