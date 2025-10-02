// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";
import {TimeLibrary} from "./libraries/TimeLibrary.sol";
import {DeliErrors} from "./libraries/DeliErrors.sol";

/**
 * @title Voter
 * @notice Weekly voting contract that allocates deposited WETH between three
 *         pre-configured options. Users hold sbfBMX; their balance determines
 *         vote weight. An optional auto-vote feature reuses the user’s latest
 *         choice across future epochs. Admin deposits WETH and finalises epochs;
 *         on finalisation the winning option’s share is sent to the safety
 *         module and the remainder streamed via RewardDistributor.
 */
contract Voter is Ownable2Step {
    using SafeERC20 for IERC20;
    using TimeLibrary for uint256;

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    struct EpochData {
        uint256 totalWeth; // deposited for this epoch
        uint256[3] optionWeight; // cumulative vote weight per option
        bool settled;
    }

    bool private finalizationInProgress;
    address[] private autoVoterList;

    uint16[3] public options; // set in constructor (basis points)
    address public admin;
    address public safetyModule;
    IRewardDistributor public distributor;
    uint256 public nextEpochToFinalize;

    IERC20 public immutable WETH;
    IERC20 public immutable SBF_BMX;
    uint256 public immutable EPOCH_ZERO; // Tuesday start timestamp

    mapping(uint256 => address[]) private pendingRemovals;
    mapping(uint256 => uint256) private pendingRemovalCursor;
    mapping(address => uint256) private autoIndex;
    mapping(uint256 => mapping(address => uint256)) private userVoteWeight;
    mapping(uint256 => uint256) private batchCursor;
    mapping(uint256 => address[]) private manualVoters;
    mapping(uint256 => bool) private autoVotingComplete;
    mapping(uint256 => mapping(address => bool)) private isManualVoter;

    /// @notice userChoice[epoch][address] = option per epoch per user (0-2, 3 = none)
    mapping(uint256 => mapping(address => uint8)) public userChoice;
    /// @notice epochInfo[epoch] = EpochData
    mapping(uint256 => EpochData) public epochInfo;
    /// @notice autoOption[address] = chosen option (0-2). 3 indicates auto-vote disabled / not set
    mapping(address => uint8) public autoOption;

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(uint256 indexed epoch, uint256 amount);
    event Vote(uint256 indexed epoch, address indexed voter, uint8 option, uint256 weight);
    event Finalize(uint256 indexed epoch, uint8 winningOption, uint256 toSafety, uint256 toRewards);
    event OptionsUpdated(uint16 opt0, uint16 opt1, uint16 opt2);
    event SafetyModuleUpdated(address newSafety);
    event DistributorUpdated(address newDistributor);
    event AutoVoteUpdated(address indexed user, bool enabled, uint8 option);
    event AdminUpdated(address newAdmin);

    /*//////////////////////////////////////////////////////////////
                                   CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _weth,
        IERC20 _sbfBmx,
        address _safetyModule,
        IRewardDistributor _distributor,
        uint256 _epochZeroTuesday,
        uint16 opt0,
        uint16 opt1,
        uint16 opt2
    ) Ownable(msg.sender) {
        if (!(opt0 < 10_000 && opt1 < 10_000 && opt2 < 10_000)) revert DeliErrors.InvalidBps();

        WETH = _weth;
        SBF_BMX = _sbfBmx;
        safetyModule = _safetyModule;
        distributor = _distributor;
        EPOCH_ZERO = _epochZeroTuesday;
        options = [opt0, opt1, opt2];
    }

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != admin) revert DeliErrors.NotAdmin();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice View helper to fetch the current epoch.
    /// @return The current epoch.
    function currentEpoch() public view returns (uint256) {
        return (block.timestamp - EPOCH_ZERO) / TimeLibrary.WEEK;
    }

    /// @notice Timestamp (unix time) when a given epoch ends.
    /// @param ep The epoch to get the end time for.
    /// @return The timestamp when the epoch ends.
    function epochEnd(uint256 ep) external view returns (uint256) {
        return EPOCH_ZERO + (ep + 1) * TimeLibrary.WEEK;
    }

    /// @notice Return a user's voting option and weight for a given epoch.
    /// @dev For auto-voters the weight is what was recorded during tally (0 until
    ///      that epoch is processed). Returns option=3 if the user has no vote.
    /// @param ep The epoch to get the user vote for.
    /// @param user The user to get the vote for.
    /// @return option The user's voting option.
    /// @return weight The user's voting weight.
    function getUserVote(uint256 ep, address user) external view returns (uint8 option, uint256 weight) {
        weight = userVoteWeight[ep][user];

        if (weight > 0) {
            // Already tallied - return stored option
            option = userChoice[ep][user];
            return (option, weight);
        }

        // Not tallied yet – check for potential live auto-vote
        (uint8 opt, bool enabled) = autoVoteOf(user);
        if (enabled) {
            option = opt;
            weight = SBF_BMX.balanceOf(user);
        } else {
            option = 3;
            weight = 0;
        }
    }

    /// @notice Snapshot of an epoch’s core data for UI/analytics.
    /// @return totalWeth  WETH deposited for the epoch
    /// @return optionWeight Array with cumulative weights for options 0-2
    /// @return settled     Whether the epoch has been finalized
    function epochData(uint256 ep)
        external
        view
        returns (uint256 totalWeth, uint256[3] memory optionWeight, bool settled)
    {
        EpochData storage e = epochInfo[ep];
        totalWeth = e.totalWeth;
        optionWeight = e.optionWeight;
        settled = e.settled;
    }

    /// @notice Convenience helper returning the active epoch id plus its data.
    /// @return epoch The current epoch.
    /// @return totalWeth The total WETH deposited for the epoch.
    /// @return optionWeight The cumulative vote weight per option.
    /// @return settled Whether the epoch has been finalized.
    function currentEpochData()
        external
        view
        returns (uint256 epoch, uint256 totalWeth, uint256[3] memory optionWeight, bool settled)
    {
        epoch = currentEpoch();
        EpochData storage e = epochInfo[epoch];
        totalWeth = e.totalWeth;
        optionWeight = e.optionWeight;
        settled = e.settled;
    }

    /// @notice Returns a user’s auto-vote setting.
    /// @param user The user to get the auto-vote setting for.
    /// @return option 0-2 chosen option; 3 when disabled
    /// @return enabled True if auto-vote is currently active
    function autoVoteOf(address user) public view returns (uint8 option, bool enabled) {
        uint8 opt = autoOption[user];

        // Check if user ever enabled auto-vote using autoIndex
        if (autoIndex[user] == 0) {
            return (3, false);
        }

        enabled = opt < 3;
        option = enabled ? opt : 3;
    }

    /// @notice Number of addresses that ever enabled auto-vote (some may be disabled now).
    /// @return The number of addresses that ever enabled auto-vote.
    function autoVoterCount() external view returns (uint256) {
        return autoVoterList.length;
    }

    /*//////////////////////////////////////////////////////////////
                               EXTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit WETH into the voter.
    /// @dev Only admin can deposit.
    /// @param amount The amount of WETH to deposit.
    function deposit(uint256 amount) external onlyAdmin {
        uint256 ep = currentEpoch();
        EpochData storage e = epochInfo[ep];
        if (e.settled) revert DeliErrors.AlreadySettled();
        if (amount == 0) revert DeliErrors.ZeroAmount();
        WETH.safeTransferFrom(msg.sender, address(this), amount);
        e.totalWeth += amount;
        emit Deposit(ep, amount);
    }

    /// @notice Batch-aware finalize: call repeatedly with batches of auto-voters until complete.
    /// @dev Only admin can finalize.
    /// @param ep The epoch to finalize.
    /// @param maxBatch The maximum number of auto-voters to process in each batch.
    function finalize(uint256 ep, uint256 maxBatch) external onlyAdmin {
        if (block.timestamp < EPOCH_ZERO + (ep + 1) * TimeLibrary.WEEK) revert DeliErrors.EpochRunning();
        EpochData storage e = epochInfo[ep];
        if (e.settled) revert DeliErrors.AlreadySettled();

        finalizationInProgress = true;

        // Process auto voters first
        if (!autoVotingComplete[ep]) {
            bool autoFinished = _tallyAutoVotes(ep, maxBatch);
            if (autoFinished) {
                autoVotingComplete[ep] = true;
                batchCursor[ep] = 0; // Reset cursor for manual voters
            }
            return; // Exit after processing auto batch
        }

        // Process manual voters
        bool manualFinished = _validateManualVoters(ep, maxBatch);

        if (manualFinished) {
            finalizationInProgress = false;
            e.settled = true;

            // determine winner with lowest-index tie-break
            uint8 win = 0;
            if (e.optionWeight[1] > e.optionWeight[win]) win = 1;
            if (e.optionWeight[2] > e.optionWeight[win]) win = 2;

            uint256 toSafety = (e.totalWeth * options[win]) / 10_000;
            uint256 toRewards = e.totalWeth - toSafety;
            if (toSafety > 0) WETH.safeTransfer(safetyModule, toSafety);
            if (toRewards > 0) {
                WETH.safeTransfer(address(distributor), toRewards);
                distributor.setTokensPerInterval(toRewards / TimeLibrary.WEEK);
            }
            // Advance pointer to the earliest unsettled epoch. This handles
            // out-of-order finalizations by skipping already-settled epochs.
            while (epochInfo[nextEpochToFinalize].settled) {
                unchecked {
                    nextEpochToFinalize++;
                }
            }

            emit Finalize(ep, win, toSafety, toRewards);
        }
    }

    /// @notice Vote and optionally set auto-vote preference in one call.
    /// @param option Index 0-2 corresponding to current `options` array.
    /// @param enableAuto Whether to remember this choice for future epochs.
    function vote(uint8 option, bool enableAuto) external {
        if (option >= 3) revert DeliErrors.InvalidOption();
        uint256 ep = currentEpoch();
        _castVote(ep, msg.sender, option);

        if (enableAuto) {
            // Enable or refresh auto-vote (always allowed)
            autoOption[msg.sender] = option;
            if (autoIndex[msg.sender] == 0) {
                autoVoterList.push(msg.sender);
                autoIndex[msg.sender] = autoVoterList.length;
            }
            emit AutoVoteUpdated(msg.sender, true, option);
        } else {
            // Prevent disabling auto-vote during any finalization or when any epoch has ended but remains unfinalized
            if (finalizationInProgress || _hasEndedUnfinalizedEpoch()) {
                revert DeliErrors.FinalizationInProgress();
            }
            // Disable auto-vote if currently enabled
            uint256 idx = autoIndex[msg.sender];
            if (idx != 0) {
                _removeAutoVoter(msg.sender, idx - 1);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Casts a vote for `voter` for `option` in `ep`.
    function _castVote(uint256 ep, address voter, uint8 option) internal {
        EpochData storage e = epochInfo[ep];
        if (e.settled) revert DeliErrors.AlreadySettled();
        uint256 newWeight = SBF_BMX.balanceOf(voter);
        if (newWeight == 0) revert DeliErrors.ZeroWeight();
        uint8 prev = userChoice[ep][voter];
        uint256 prevWeight = userVoteWeight[ep][voter];

        // Remove previous weight if there was a prior vote
        if (prev < 3 && prevWeight > 0) {
            e.optionWeight[prev] -= prevWeight;
        }

        // Add new weight
        e.optionWeight[option] += newWeight;
        userChoice[ep][voter] = option;
        userVoteWeight[ep][voter] = newWeight;

        // Track manual voter once per epoch
        if (!isManualVoter[ep][voter]) {
            manualVoters[ep].push(voter);
            isManualVoter[ep][voter] = true;
        }

        emit Vote(ep, voter, option, newWeight);
    }

    /// @dev Processes up to `maxBatch` auto-voters for `ep`, adding live balances to option weights.
    function _tallyAutoVotes(uint256 ep, uint256 maxBatch) internal returns (bool finished) {
        EpochData storage e = epochInfo[ep];
        uint256 processed;
        while (processed < maxBatch && batchCursor[ep] < autoVoterList.length) {
            uint256 i = batchCursor[ep];
            address voterAddr = autoVoterList[i];
            batchCursor[ep] = i + 1;
            processed++;

            uint8 opt = autoOption[voterAddr];
            if (opt >= 3) continue; // disabled
            if (userVoteWeight[ep][voterAddr] > 0) continue;

            uint256 bal = SBF_BMX.balanceOf(voterAddr);
            if (bal == 0) {
                // queue for removal instead of removing now
                pendingRemovals[ep].push(voterAddr);
                continue;
            }
            e.optionWeight[opt] += bal;
            userVoteWeight[ep][voterAddr] = bal;
            userChoice[ep][voterAddr] = opt;
        }

        // Process a bounded number of removals per call
        if (pendingRemovals[ep].length > 0) {
            finished = _processPendingRemovals(ep, maxBatch - processed) && (batchCursor[ep] >= autoVoterList.length);
        } else {
            finished = (batchCursor[ep] >= autoVoterList.length);
        }
    }

    /// @dev Removes `addr` from autoVoterList using swap-pop and clears indexes.
    function _removeAutoVoter(address addr, uint256 idx) internal {
        uint256 last = autoVoterList.length;
        if (idx != last - 1) {
            address lastAddr = autoVoterList[last - 1];
            autoVoterList[idx] = lastAddr;
            autoIndex[lastAddr] = idx + 1;
        }
        autoVoterList.pop();
        delete autoIndex[addr];
        autoOption[addr] = 3;
        emit AutoVoteUpdated(addr, false, 3);
    }

    /// @dev Processes up to `maxToProcess` pending removals for `ep`.
    function _processPendingRemovals(uint256 ep, uint256 maxToProcess) internal returns (bool allProcessed) {
        address[] storage toRemove = pendingRemovals[ep];
        uint256 cursor = pendingRemovalCursor[ep];
        uint256 processed = 0;
        uint256 len = toRemove.length;

        while (processed < maxToProcess && cursor < len) {
            address addr = toRemove[cursor];
            uint256 idx = autoIndex[addr];
            if (idx > 0) {
                _removeAutoVoter(addr, idx - 1);
            }
            unchecked {
                cursor++;
                processed++;
            }
        }
        pendingRemovalCursor[ep] = cursor;

        if (cursor >= len) {
            delete pendingRemovals[ep];
            delete pendingRemovalCursor[ep];
            return true;
        }
        return false;
    }

    /// @dev Returns true if there exists at least one epoch that has ended but is not yet finalized.
    function _hasEndedUnfinalizedEpoch() internal view returns (bool) {
        uint256 ep = nextEpochToFinalize;
        // If already settled (or no epochs yet), no blocking needed
        if (epochInfo[ep].settled) return false;
        // Check if this epoch has ended
        uint256 endTs = EPOCH_ZERO + (ep + 1) * TimeLibrary.WEEK;
        return block.timestamp >= endTs;
    }

    /// @dev Validates manual voters for `ep`.
    function _validateManualVoters(uint256 ep, uint256 maxBatch) internal returns (bool finished) {
        address[] storage voters = manualVoters[ep];
        uint256 processed = 0;
        uint256 cursor = batchCursor[ep];
        EpochData storage e = epochInfo[ep];

        while (processed < maxBatch && cursor < voters.length) {
            address voter = voters[cursor];
            uint256 currentBal = SBF_BMX.balanceOf(voter);
            uint256 recordedWeight = userVoteWeight[ep][voter];

            if (currentBal < recordedWeight) {
                uint8 option = userChoice[ep][voter];
                e.optionWeight[option] -= (recordedWeight - currentBal);
                userVoteWeight[ep][voter] = currentBal;
            }

            cursor++;
            processed++;
        }

        batchCursor[ep] = cursor;
        finished = (cursor >= voters.length);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the options for the voter, expressed in basis points.
    /// @param opt0 The weight for option 1.
    /// @param opt1 The weight for option 2.
    /// @param opt2 The weight for option 3.
    function setOptions(uint16 opt0, uint16 opt1, uint16 opt2) external onlyOwner {
        if (!(opt0 < 10_000 && opt1 < 10_000 && opt2 < 10_000)) revert DeliErrors.InvalidBps();
        options = [opt0, opt1, opt2];
        emit OptionsUpdated(opt0, opt1, opt2);
    }

    /// @notice Set the safety module.
    /// @param newSafety The address of the safety module.
    function setSafetyModule(address newSafety) external onlyOwner {
        if (newSafety == address(0)) revert DeliErrors.ZeroAddress();
        safetyModule = newSafety;
        emit SafetyModuleUpdated(newSafety);
    }

    /// @notice Set the distributor.
    /// @param newDist The address of the distributor.
    function setDistributor(address newDist) external onlyOwner {
        if (newDist == address(0)) revert DeliErrors.ZeroAddress();
        distributor = IRewardDistributor(newDist);
        emit DistributorUpdated(newDist);
    }

    /// @notice Set the admin.
    /// @param newAdmin The address of the admin.
    function setAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert DeliErrors.ZeroAddress();
        admin = newAdmin;
        emit AdminUpdated(newAdmin);
    }
}
