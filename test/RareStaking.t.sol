// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../src/RareStakingV1.sol";
import "./RareStakingUpdateTest.sol";
import "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/interfaces/IRareStaking.sol";
import "openzeppelin-contracts/token/ERC20/ERC20.sol";
import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import "openzeppelin-contracts/access/Ownable.sol";

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
    RareStakingV1 public implementation;
    RareStakingUpdateTest public implementationV2;
    ERC1967Proxy public proxy;
    IRareStaking public rareStaking;
    MockERC20 public token;
    ReentrantToken public reentrantToken;
    address public owner;
    address public alice;
    address public bob;
    address public charlie;
    address public rewardsWallet;
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
    event DelegationUpdated(
        address indexed delegator,
        address indexed delegatee,
        uint256 amount,
        uint256 timestamp
    );
    event RewardsWalletUpdated(
        address indexed oldWallet,
        address indexed newWallet,
        uint256 timestamp
    );

    function setUp() public {
        // Setup accounts
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        rewardsWallet = makeAddr("rewardsWallet");

        // Deploy mock token
        token = new MockERC20();
        reentrantToken = new ReentrantToken();

        // Generate merkle root and proof for alice and bob
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = keccak256(abi.encodePacked(alice, CLAIM_AMOUNT));
        leaves[1] = keccak256(abi.encodePacked(bob, CLAIM_AMOUNT));
        merkleRoot = _generateMerkleRoot(leaves);

        // Deploy implementation
        implementation = new RareStakingV1();

        // Deploy proxy without initialization
        proxy = new ERC1967Proxy(address(implementation), "");

        // Initialize the implementation through proxy
        RareStakingV1(address(proxy)).initialize(
            address(token),
            rewardsWallet,
            merkleRoot,
            owner
        );

        // Setup interface for easier testing
        rareStaking = IRareStaking(address(proxy));

        // Setup initial token balances
        token.mint(alice, 1000 ether);
        token.mint(bob, 1000 ether);
        token.mint(charlie, 1000 ether);
        token.mint(address(this), 1000 ether); // Mint tokens to test contract
        token.mint(rewardsWallet, 10000 ether); // Mint tokens to rewards wallet for claims

        // Set up approvals for staking
        vm.prank(alice);
        token.approve(address(proxy), type(uint256).max);
        vm.prank(bob);
        token.approve(address(proxy), type(uint256).max);
        token.approve(address(proxy), type(uint256).max); // Approve from test contract

        // Set up rewards wallet approval for claims
        vm.prank(rewardsWallet);
        token.approve(address(proxy), type(uint256).max);
    }

    // Helper function to generate merkle root
    function _generateMerkleRoot(
        bytes32[] memory leaves
    ) internal pure returns (bytes32) {
        require(leaves.length > 0, "No leaves");

        if (leaves.length == 1) {
            return leaves[0];
        }

        bytes32[] memory nextLevel = new bytes32[]((leaves.length + 1) / 2);
        for (uint256 i = 0; i < leaves.length; i += 2) {
            bytes32 left = leaves[i];
            bytes32 right = i + 1 < leaves.length ? leaves[i + 1] : leaves[i];
            // Sort the leaves to ensure consistent ordering
            if (uint256(left) > uint256(right)) {
                (left, right) = (right, left);
            }
            nextLevel[i / 2] = keccak256(abi.encodePacked(left, right));
        }

        return _generateMerkleRoot(nextLevel);
    }

    // Helper function to create merkle proof
    function _createMerkleProof(
        address account,
        uint256 amount
    ) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = new bytes32[](2);
        bytes32 aliceLeaf = keccak256(abi.encodePacked(alice, amount));
        bytes32 bobLeaf = keccak256(abi.encodePacked(bob, amount));

        // Sort leaves to ensure consistent ordering
        if (uint256(aliceLeaf) < uint256(bobLeaf)) {
            leaves[0] = aliceLeaf;
            leaves[1] = bobLeaf;
        } else {
            leaves[0] = bobLeaf;
            leaves[1] = aliceLeaf;
        }

        bytes32[] memory proof = new bytes32[](1);
        bytes32 accountLeaf = keccak256(abi.encodePacked(account, amount));

        if (accountLeaf == leaves[0]) {
            proof[0] = leaves[1];
        } else {
            proof[0] = leaves[0];
        }

        return proof;
    }

    // Test upgradeability
    function test_CannotInitializeTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        RareStakingV1(address(proxy)).initialize(
            address(token),
            rewardsWallet,
            merkleRoot,
            owner
        );
    }

    function test_OnlyOwnerCanUpgrade() public {
        RareStakingV1 newImplementation = new RareStakingV1();

        // Non-owner cannot upgrade
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        RareStakingV1(address(proxy)).upgradeTo(address(newImplementation));

        // Owner can upgrade
        vm.prank(owner);
        RareStakingV1(address(proxy)).upgradeTo(address(newImplementation));
    }

    function testConstructor() public {
        assertEq(address(rareStaking.token()), address(token));
        assertEq(rareStaking.currentClaimRoot(), merkleRoot);
        assertEq(rareStaking.currentRound(), 1);
    }

    function testConstructorZeroAddressFail() public {
        RareStakingV1 newImpl = new RareStakingV1();
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), "");
        vm.expectRevert(IRareStaking.ZeroTokenAddress.selector);
        RareStakingV1(address(newProxy)).initialize(
            address(0),
            rewardsWallet,
            merkleRoot,
            owner
        );
    }

    function testConstructorEmptyRootFail() public {
        RareStakingV1 newImpl = new RareStakingV1();
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), "");
        vm.expectRevert(IRareStaking.EmptyMerkleRoot.selector);
        RareStakingV1(address(newProxy)).initialize(
            address(token),
            rewardsWallet,
            bytes32(0),
            owner
        );
    }

    function testConstructorZeroRewardsWalletFail() public {
        RareStakingV1 newImpl = new RareStakingV1();
        ERC1967Proxy newProxy = new ERC1967Proxy(address(newImpl), "");
        vm.expectRevert(IRareStaking.ZeroRewardsWalletAddress.selector);
        RareStakingV1(address(newProxy)).initialize(
            address(token),
            address(0),
            merkleRoot,
            owner
        );
    }

    function testRewardsWalletFunctionality() public {
        // Test getter function
        assertEq(rareStaking.rewardsWallet(), rewardsWallet);

        // Test updating rewards wallet
        address newRewardsWallet = makeAddr("newRewardsWallet");

        // Only owner can update
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        rareStaking.updateRewardsWallet(newRewardsWallet);

        // Cannot set to zero address
        vm.expectRevert(IRareStaking.ZeroRewardsWalletAddress.selector);
        rareStaking.updateRewardsWallet(address(0));

        // Successful update
        vm.expectEmit(true, true, false, true);
        emit RewardsWalletUpdated(
            rewardsWallet,
            newRewardsWallet,
            block.timestamp
        );
        rareStaking.updateRewardsWallet(newRewardsWallet);
        assertEq(rareStaking.rewardsWallet(), newRewardsWallet);

        // Set up new rewards wallet with tokens and approval
        token.mint(newRewardsWallet, 5000 ether);
        vm.prank(newRewardsWallet);
        token.approve(address(proxy), type(uint256).max);

        // Test claim works with new rewards wallet
        uint256 initialBalance = token.balanceOf(alice);
        uint256 initialRewardsBalance = token.balanceOf(newRewardsWallet);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256(abi.encodePacked(bob, CLAIM_AMOUNT));

        vm.prank(alice);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        assertEq(token.balanceOf(alice), initialBalance + CLAIM_AMOUNT);
        assertEq(
            token.balanceOf(newRewardsWallet),
            initialRewardsBalance - CLAIM_AMOUNT
        );
    }

    function testClaim() public {
        // Create proof for alice
        bytes32[] memory proof = _createMerkleProof(alice, CLAIM_AMOUNT);

        // Increment round (otherwise claim will fail as round 0)
        rareStaking.updateMerkleRoot(merkleRoot);

        // Test claim
        vm.startPrank(alice);
        vm.expectEmit(true, true, false, true);
        emit TokensClaimed(merkleRoot, alice, CLAIM_AMOUNT, 2);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // Alice should have their initial balance (1000) plus claim amount (100)
        assertEq(token.balanceOf(alice), 1_100 ether);
        assertEq(rareStaking.lastClaimedRound(alice), 2);
        vm.stopPrank();
    }

    function testCannotClaimTwiceInSameRound() public {
        // Create proof for alice
        bytes32[] memory proof = _createMerkleProof(alice, CLAIM_AMOUNT);

        // Increment round
        rareStaking.updateMerkleRoot(merkleRoot);

        vm.startPrank(alice);
        // First claim should succeed
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // Second claim should fail
        vm.expectRevert(IRareStaking.AlreadyClaimed.selector);
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testCanClaimInNewRound() public {
        // Create proof for alice
        bytes32[] memory proof = _createMerkleProof(alice, CLAIM_AMOUNT);

        // First round
        vm.prank(owner);
        rareStaking.updateMerkleRoot(merkleRoot);

        vm.startPrank(alice);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // New round
        vm.stopPrank();
        vm.prank(owner);
        rareStaking.updateMerkleRoot(merkleRoot);

        vm.prank(alice);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // Alice should have initial balance (1000) plus two claims (100 each)
        assertEq(token.balanceOf(alice), 1_200 ether);
    }

    function testCannotClaimWithInvalidProof() public {
        // Create invalid proof
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = bytes32(uint256(1)); // Random invalid proof

        rareStaking.updateMerkleRoot(merkleRoot);

        vm.startPrank(alice);
        vm.expectRevert(IRareStaking.InvalidMerkleProof.selector);
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testUpdateMerkleRoot() public {
        bytes32 newRoot = bytes32(uint256(123));

        vm.expectEmit(true, true, false, true);
        emit NewClaimRootAdded(newRoot, 2, block.timestamp);
        rareStaking.updateMerkleRoot(newRoot);

        assertEq(rareStaking.currentClaimRoot(), newRoot);
        assertEq(rareStaking.currentRound(), 2);
    }

    function testUpdateMerkleRootWithSafeAddress() public {
        address safeAddress = address(
            0xc2F394a45e994bc81EfF678bDE9172e10f7c8ddc
        );
        bytes32 newRoot = bytes32(uint256(123));
        vm.deal(safeAddress, 1 ether);

        vm.startPrank(safeAddress);
        vm.expectEmit(true, true, false, true);
        emit NewClaimRootAdded(newRoot, 2, block.timestamp);
        rareStaking.updateMerkleRoot(newRoot);
        assertEq(rareStaking.currentClaimRoot(), newRoot);
        assertEq(rareStaking.currentRound(), 2);
        vm.stopPrank();
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
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IRareStaking.NotAuthorized.selector)
        );
        rareStaking.updateMerkleRoot(bytes32(uint256(123)));
    }

    function testOnlyOwnerCanUpdateTokenAddress() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
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
        vm.startPrank(charlie);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(proxy),
                0,
                100e18
            )
        );
        rareStaking.stake(100 ether);
        vm.stopPrank();
    }

    function testCannotStakeWithInsufficientAllowance() public {
        uint256 stakeAmount = 100 ether;
        uint256 allowance = 50 ether; // Less than stake amount

        vm.startPrank(alice);
        token.approve(address(rareStaking), allowance);

        // Try to stake more than allowed
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(proxy),
                50e18,
                100e18
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
        bytes32[] memory proof = _createMerkleProof(alice, CLAIM_AMOUNT);

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
        vm.startPrank(alice);
        vm.expectRevert();
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testCannotReuseProofForDifferentAddress() public {
        // Create proof for alice
        bytes32[] memory proof = _createMerkleProof(alice, CLAIM_AMOUNT);

        // Increment round
        rareStaking.updateMerkleRoot(merkleRoot);

        // Try to use alice's proof for bob
        vm.startPrank(bob);
        vm.expectRevert(IRareStaking.InvalidMerkleProof.selector);
        rareStaking.claim(CLAIM_AMOUNT, proof);
        vm.stopPrank();
    }

    function testCannotClaimDifferentAmountInSameRound() public {
        // Create proof for alice
        bytes32[] memory proof = _createMerkleProof(alice, CLAIM_AMOUNT);

        // Update merkle root to allow claiming
        rareStaking.updateMerkleRoot(merkleRoot);

        vm.startPrank(alice);
        // First claim should succeed
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // Second claim should fail even with a different amount
        vm.expectRevert(IRareStaking.InvalidMerkleProof.selector);
        rareStaking.claim(CLAIM_AMOUNT * 2, proof);
        vm.stopPrank();

        // Verify alice only received one claim amount
        assertEq(token.balanceOf(alice), 1_100 ether); // Initial 1000 + one claim of 100
    }

    function testUpgradeToV2WithStatePreservation() public {
        uint256 stakeAmount = 100 ether;

        // 1. Test staking in V1
        vm.startPrank(alice);
        rareStaking.stake(stakeAmount);
        assertEq(rareStaking.stakedAmount(alice), stakeAmount);
        vm.stopPrank();

        // 2. Create and upgrade to V2
        implementationV2 = new RareStakingUpdateTest();

        vm.prank(owner);
        RareStakingV1(address(proxy)).upgradeTo(address(implementationV2));

        // Create interface for V2
        RareStakingUpdateTest rareStakingV2 = RareStakingUpdateTest(
            address(proxy)
        );

        // 3. Verify existing state is preserved
        assertEq(rareStaking.stakedAmount(alice), stakeAmount);
        assertEq(rareStaking.totalStaked(), stakeAmount);

        // 4. Test new V2 functionality
        // Initially should show staked amount plus pending claim (alice never claimed in round 1)
        assertEq(
            rareStakingV2.getTotalAccountValue(alice),
            stakeAmount + CLAIM_AMOUNT
        );

        // Update merkle root to move to next round
        vm.prank(owner);
        rareStaking.updateMerkleRoot(merkleRoot);

        // Total value should still include the pending claim (now for round 2)
        assertEq(
            rareStakingV2.getTotalAccountValue(alice),
            stakeAmount + CLAIM_AMOUNT
        );

        // 5. Test that core functionality still works after upgrade

        // Test unstaking
        vm.startPrank(alice);
        rareStaking.unstake(50 ether); // Unstake half
        assertEq(rareStaking.stakedAmount(alice), 50 ether);

        // Test claiming
        bytes32[] memory proof = _createMerkleProof(alice, CLAIM_AMOUNT);
        rareStaking.claim(CLAIM_AMOUNT, proof);

        // After claiming, total value should only show staked amount
        assertEq(rareStakingV2.getTotalAccountValue(alice), 50 ether);
        vm.stopPrank();
    }

    // Delegation Tests
    function testBasicDelegation() public {
        uint256 STAKE_AMOUNT = 100 ether;
        uint256 DELEGATE_AMOUNT = 50 ether;

        vm.startPrank(alice);
        rareStaking.stake(STAKE_AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit DelegationUpdated(alice, bob, DELEGATE_AMOUNT, block.timestamp);
        rareStaking.delegate(bob, DELEGATE_AMOUNT);

        assertEq(rareStaking.getDelegatedAmount(alice, bob), DELEGATE_AMOUNT);
        assertEq(rareStaking.getTotalDelegatedToAddress(bob), DELEGATE_AMOUNT);
        vm.stopPrank();
    }

    function testCannotDelegateMoreThanStaked() public {
        uint256 STAKE_AMOUNT = 100 ether;
        uint256 DELEGATE_AMOUNT = 150 ether;

        vm.startPrank(alice);
        rareStaking.stake(STAKE_AMOUNT);

        vm.expectRevert(IRareStaking.InsufficientStakedBalance.selector);
        rareStaking.delegate(bob, DELEGATE_AMOUNT);
        vm.stopPrank();
    }

    function testCannotDelegateToSelf() public {
        uint256 STAKE_AMOUNT = 100 ether;

        vm.startPrank(alice);
        rareStaking.stake(STAKE_AMOUNT);

        vm.expectRevert(IRareStaking.CannotDelegateToSelf.selector);
        rareStaking.delegate(alice, STAKE_AMOUNT);
        vm.stopPrank();
    }

    function testCannotDelegateZeroAmount() public {
        uint256 STAKE_AMOUNT = 100 ether;

        vm.startPrank(alice);
        rareStaking.stake(STAKE_AMOUNT);

        vm.expectRevert(IRareStaking.ZeroStakeAmount.selector);
        rareStaking.delegate(bob, 0);
        vm.stopPrank();
    }

    function testUpdateDelegation() public {
        uint256 STAKE_AMOUNT = 100 ether;
        uint256 INITIAL_DELEGATE = 50 ether;
        uint256 UPDATED_DELEGATE = 75 ether;

        vm.startPrank(alice);
        rareStaking.stake(STAKE_AMOUNT);

        // Initial delegation
        rareStaking.delegate(bob, INITIAL_DELEGATE);
        assertEq(rareStaking.getDelegatedAmount(alice, bob), INITIAL_DELEGATE);
        assertEq(rareStaking.getTotalDelegatedToAddress(bob), INITIAL_DELEGATE);

        // Update delegation
        vm.expectEmit(true, true, false, true);
        emit DelegationUpdated(alice, bob, UPDATED_DELEGATE, block.timestamp);
        rareStaking.delegate(bob, UPDATED_DELEGATE);

        assertEq(rareStaking.getDelegatedAmount(alice, bob), UPDATED_DELEGATE);
        assertEq(rareStaking.getTotalDelegatedToAddress(bob), UPDATED_DELEGATE);
        vm.stopPrank();
    }

    function testMultipleDelegators() public {
        uint256 STAKE_AMOUNT = 100 ether;
        uint256 ALICE_DELEGATE = 50 ether;
        uint256 BOB_DELEGATE = 30 ether;

        // Alice delegates
        vm.startPrank(alice);
        rareStaking.stake(STAKE_AMOUNT);
        rareStaking.delegate(charlie, ALICE_DELEGATE);
        vm.stopPrank();

        // Bob delegates
        vm.startPrank(bob);
        rareStaking.stake(STAKE_AMOUNT);
        rareStaking.delegate(charlie, BOB_DELEGATE);
        vm.stopPrank();

        assertEq(
            rareStaking.getDelegatedAmount(alice, charlie),
            ALICE_DELEGATE
        );
        assertEq(rareStaking.getDelegatedAmount(bob, charlie), BOB_DELEGATE);
        assertEq(
            rareStaking.getTotalDelegatedToAddress(charlie),
            ALICE_DELEGATE + BOB_DELEGATE
        );
    }

    function testDelegationAfterUnstake() public {
        uint256 STAKE_AMOUNT = 100 ether;
        uint256 DELEGATE_AMOUNT = 50 ether;
        uint256 UNSTAKE_AMOUNT = 75 ether;

        vm.startPrank(alice);
        rareStaking.stake(STAKE_AMOUNT);
        rareStaking.delegate(bob, DELEGATE_AMOUNT);

        // Unstake more than remaining non-delegated amount
        vm.expectRevert(IRareStaking.InsufficientStakedBalance.selector);
        rareStaking.unstake(UNSTAKE_AMOUNT);
        vm.stopPrank();
    }
}
