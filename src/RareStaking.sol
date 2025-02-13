// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "openzeppelin-contracts/token/ERC20/IERC20.sol";
import "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-contracts/utils/Context.sol";
import "openzeppelin-contracts/access/Ownable.sol";
import "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-contracts/utils/cryptography/MerkleProof.sol";
import "./interfaces/IRareStaking.sol";

contract RareStaking is IRareStaking, Context, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public override currentClaimRoot;
    IERC20 private _token;
    uint256 public override currentRound;
    mapping(address => uint256) public override lastClaimedRound;

    // State variables for staking
    mapping(address => uint256) public override stakedAmount;
    uint256 public override totalStaked;

    constructor(
        address superRareToken,
        bytes32 merkleRoot
    ) Ownable(msg.sender) {
        if (superRareToken == address(0)) revert ZeroTokenAddress();
        if (merkleRoot == bytes32(0)) revert EmptyMerkleRoot();
        _token = IERC20(superRareToken);
        currentClaimRoot = merkleRoot;
        currentRound = 0;
        emit NewClaimRootAdded(merkleRoot, currentRound, block.timestamp);
    }

    function token() external view override returns (address) {
        return address(_token);
    }

    function stake(uint256 amount) external override {
        if (amount == 0) revert ZeroStakeAmount();

        _token.safeTransferFrom(_msgSender(), address(this), amount);
        stakedAmount[_msgSender()] += amount;
        totalStaked += amount;

        emit Staked(_msgSender(), amount, block.timestamp);
    }

    function unstake(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroUnstakeAmount();
        if (stakedAmount[_msgSender()] < amount)
            revert InsufficientStakedBalance();

        stakedAmount[_msgSender()] -= amount;
        totalStaked -= amount;

        _token.safeTransfer(_msgSender(), amount);

        emit Unstaked(_msgSender(), amount, block.timestamp);
    }

    function getStakedBalance(
        address staker
    ) external view override returns (uint256) {
        return stakedAmount[staker];
    }

    function claim(
        uint256 amount,
        bytes32[] calldata proof
    ) public override nonReentrant {
        if (!verifyEntitled(_msgSender(), amount, proof))
            revert InvalidMerkleProof();
        if (lastClaimedRound[_msgSender()] >= currentRound)
            revert AlreadyClaimed();

        lastClaimedRound[_msgSender()] = currentRound;
        _token.safeTransfer(_msgSender(), amount);

        emit TokensClaimed(
            currentClaimRoot,
            _msgSender(),
            amount,
            currentRound
        );
    }

    function verifyEntitled(
        address recipient,
        uint256 value,
        bytes32[] memory proof
    ) public view override returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(recipient, value));
        return verifyProof(leaf, proof);
    }

    function verifyProof(
        bytes32 leaf,
        bytes32[] memory proof
    ) internal view returns (bool) {
        return MerkleProof.verify(proof, currentClaimRoot, leaf);
    }

    function updateMerkleRoot(bytes32 newRoot) external override onlyOwner {
        if (newRoot == bytes32(0)) revert EmptyMerkleRoot();
        currentClaimRoot = newRoot;
        currentRound++;
        emit NewClaimRootAdded(newRoot, currentRound, block.timestamp);
    }

    function updateTokenAddress(address _newToken) external override onlyOwner {
        if (_newToken == address(0)) revert ZeroTokenAddress();
        _token = IERC20(_newToken);
    }
}
