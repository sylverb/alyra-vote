// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20 <0.9.0;
 
import "https://github.com/OpenZeppelin/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @dev Contract which provides a simple voting mechanism
 * A vote follows this workflow :
 * - Registering Voters :
 *   the administrator is allowed to register the list of voters using the
 *   registerVotersAddress / registerVotersAddresses functions. Once done, the administrator can
 *   call startProposalsRegistration to go to the next step.
 * - ProposalsRegistrationStarted :
 *   the registered voters can submit some voting options (they
 *   can submit any number of voting proposal) using addVoteChoice function.
 *   Note that the administrator is not allowed to submit voting options unless he added himself
 *   as a registered voter.
 *   Registered voters can get list of submited vote choices using getVoteChoices.
 *   Once all proposals have been submited, the administrator shall call endProposalRegistration
 *   to go to next step.
 * - ProposalsRegistrationEnded :
 *   Voters can't send proposals anymore.
 *   Administrator can go to next state anytime he wants by using startVotingSession function.
 * - VotingSessionStarted :
 *   the registered voters are now allowed to submit their voting choice using vote function.
 *   Each voter can only submit one voting choice and will not be allowed to change his vote unless
 *   administration set allowVoteUpdate to true using setAllowVoteUpdate function. If allowVoteUpdate
 *   is set to true, voters will be allowed to change their mind as long as vote session is not
 *   finished.
 *   Once done, the administrator shall call endVotingSession to go to the next step.
 * - VotingSessionEnded :
 *   voting is not possible anymore.
 *   Administrator can trigger the counting of votes to find the winning proposal by calling
 *   countVotes function.
 * - VotesTallied :
 *   the result is now publicly available using getWinner function and getWinnerProposalDetails.
 *   After a grace period defined in resultGracePeriod, the administrator can restart a new
 *   voting session by calling startNewVote.
 *
 *   Notes :
 *   - This code probably has to be optimised in term of gas usage.
 *   - Some functions can be called by voters only, this is to be updated according to the wanted
 *     visibility for voting process (do you want anyone to be able to see voting process, or
 *     only voters should see info ?).
 *   - vote function will not allow voters to update their vote unless allowVoteUpdate is set to
 *     true. This is set to false by default but can be updated by admin using setAllowVoteUpdate
 *     function (only during the first step of the process as we should change the rules after the
 *     start of the voting process).
 *   - Privacy notice : Anyone with an access to the blockchain explorer will have access to the
 *     contract activity. Don't use this if privacy is a concern for vote.
 */

contract Vote is Ownable {

    enum WorkflowStatus {
        RegisteringVoters,
        ProposalsRegistrationStarted,
        ProposalsRegistrationEnded,
        VotingSessionStarted,
        VotingSessionEnded,
        VotesTallied
    }

    struct Voter {
        bool isRegistered;
        bool hasVoted;
        uint votedProposalId;
    }

    struct Proposal {
        string description;
        uint voteCount;
    }

    uint resultGracePeriod = 10 minutes; // We want the results to be available for a minimum period so everyone could see them
    WorkflowStatus votingStep;
    mapping (address => Voter) voters;
    address[] votersArray; // Needed to reset voters when starting a new vote
    Proposal[] proposalsArray;
    uint resultDate;
    uint winningProposalId;
    bool allowVoteUpdate;

    // events sent during voting process
    event VoterRegistered(address voterAddress); 
    event WorkflowStatusChange(WorkflowStatus previousStatus, WorkflowStatus newStatus);
    event ProposalRegistered(uint proposalId);
    event Voted(address voter, uint proposalId);
    event VoteUpdated(address voter, uint previousProposalId, uint newProposalId);

    /*
     * @dev Allow to progress in the voting state machine defined in WorkflowStatus and emit event
     * @param newStep WorkflowStatus The new state we want to go to
     * Note : it's only possible to progress to next state in the WorkflowStatus and to loop
     *        from the last state to the first one.
     */
    function setVotingStep(WorkflowStatus newStep) internal onlyOwner {
        // Only accept transition from a state to the next one
        // %(uint(type(WorkflowStatus).max)+1) is to allow transition from last state to first one
        require((uint(newStep) == ((uint(votingStep)+1)%(uint(type(WorkflowStatus).max)+1))), "Illegal new step");
        emit WorkflowStatusChange(votingStep, newStep);
        votingStep = newStep;
    }

    /*
     * @dev Allow admin to enable or disable vote update possibility (only
     *      available during first step and can't be changed after)
     * @param _value bool true to enable vote update and false to disable it
     */
    function setAllowVoteUpdate(bool _value) external onlyDuringVotersRegistering onlyOwner {
        allowVoteUpdate = _value;
    }

    /*
     * @dev Allow to get the current state of the voting process
     * @return current step
     */
    function getVotingStep() external view returns (uint) {
        return uint(votingStep);
    }

    /*
     * @dev Allow admin and voters to get the the list of registered voters
     * @return address[] containing registered voters addresses
     */
    function getVotersList() external view returns (address[] memory) {
        require ((owner() == msg.sender) || (voters[msg.sender].isRegistered),"You are not allowed");
        return votersArray;
    }

    /*
     * @dev Allow voters to get vote info from any voter
     * @return Voter structure
     */
    function getVoterInfo(address _address) view external whitelistedVotersOnly returns (Voter memory) {
        return voters[_address];
    }

    /*
     * @dev Allow voters to get vote info for all voters
     * @return VoterDetails array
     */
    struct VoterDetails {
        address VoterAddress;
        bool hasVoted;
        uint votedProposalId;
    }
    function getAllVotersInfo() view external whitelistedVotersOnly returns (VoterDetails[] memory) {
        VoterDetails[] memory votersDetails = new VoterDetails[](votersArray.length);
        for (uint i=0; i<votersArray.length; i++) {
            VoterDetails memory voterDetails =
                VoterDetails(votersArray[i],voters[votersArray[i]].hasVoted,voters[votersArray[i]].votedProposalId);
            votersDetails[i]=voterDetails;
        }
        return votersDetails;
    }

    /*
     * @dev Allow voters to get the list of available proposals
     * @return string[] containing a list addresses
     * Note : the id of each vote option is its index in the table
     */
    function getVoteChoices() view external whitelistedVotersOnly returns (string[] memory) {
        string[] memory voteChoices = new string[](proposalsArray.length);
        for (uint i=0; i<proposalsArray.length; i++) {
            voteChoices[i] = proposalsArray[i].description;
        }
        return voteChoices;
    }

    /*
     * @dev Allow voters to get the detailed information of all proposals
     * @return string[] containing registered voters addresses
     * Note : the id of each vote option is its index in the table
     */
    function getVotesDetails() view external whitelistedVotersOnly returns (Proposal[] memory) {
        return proposalsArray;
    }

    /*
     * @dev Allow voters to get info on a vote option
     * @return string[] containing 
     * Note : the id of each vote option is its index in the table
     */
    function getProposalInfo(uint _proposalId) view external whitelistedVotersOnly returns (Proposal memory) {
        require (_proposalId < proposalsArray.length, "Invalid proposal id");
        return proposalsArray[_proposalId];
    }

    /****************************************************/
    /* Actions available during RegisteringVoters state */
    /****************************************************/
    modifier onlyDuringVotersRegistering() {
        require(votingStep == WorkflowStatus.RegisteringVoters, "Voters registration period ended");
        _;
    }

    /*
     * @dev Allow admin to register a list of voters addresses
     * @param _addresses address[] a list of addresses to register
     *        example : [0xAb8483F64d9C6d1EcF9b849Ae677dD3315835cb2,0x4B20993Bc481177ec7E8f571ceCaE8A9e22C02db]
     */
    function registerVotersAddresses(address[] memory _addresses) external onlyOwner onlyDuringVotersRegistering {
        for (uint i=0; i<_addresses.length; i++) {
            voters[_addresses[i]].isRegistered = true;
            votersArray.push(_addresses[i]);
            emit VoterRegistered(_addresses[i]);
        }
    }

    /*
     * @dev Allow admin to register a single voter address
     * @param _address address an address to register
     */
    function registerVotersAddress(address _address) external onlyOwner onlyDuringVotersRegistering {
        require(voters[_address].isRegistered == false,"Voter already registered");
        emit VoterRegistered(_address);
        voters[_address].isRegistered = true;
        votersArray.push(_address);
    }

    /*
     * @dev Allow admin to end voters registration step and start proposals registration step
     * Note : admin has to add at least one voter to be allowed to go to next step
     */
    function startProposalsRegistration() external onlyOwner onlyDuringVotersRegistering {
        require(votersArray.length != 0,"At least one voter must be registered to continue to next step"); // Who wants to start a vote with no voter ?
        setVotingStep(WorkflowStatus.ProposalsRegistrationStarted);
    }

    /*********************************************************/
    /* Actions available during ProposalsRegistrationStarted */
    /*********************************************************/
    modifier whitelistedVotersOnly() {
        require(voters[msg.sender].isRegistered, "You are not whitelisted");
        _;
    }

    modifier onlyDuringProposalRegistering() {
        require(votingStep == WorkflowStatus.ProposalsRegistrationStarted, "Proposal registering period not started or already done");
        _;
    }

    /*
     * @dev Allow voters to add a vote option and emit event
     * @param _proposalDescription string description of a new vote option
     */
    function addVoteChoice(string memory _proposalDescription) external whitelistedVotersOnly onlyDuringProposalRegistering {
        // Check that the proposal is not already existing
        // this is probably quite gas expensive, it should probably be optimized or removed.
        for (uint i=0; i<proposalsArray.length; i++) {
            if (keccak256(abi.encodePacked(_proposalDescription)) == keccak256(abi.encodePacked(proposalsArray[i].description))) {
                revert("This proposal already exists");
            }
        }

        // emit event is done before adding proposal in array,
        // this way length of array is equal to the id of the item
        // we are going to add
        emit ProposalRegistered(proposalsArray.length);
        proposalsArray.push(Proposal(_proposalDescription,0));
    }

    /*
     * @dev Allow admin to end voters proposals registering step
     * Note : voters have to add at least one voting option to be able to
     *        end this step.
     */
    function endProposalRegistration() external onlyOwner onlyDuringProposalRegistering {
        require(proposalsArray.length != 0,"At least one vote proposal must be registered to continue to next step");
        setVotingStep(WorkflowStatus.ProposalsRegistrationEnded);
    }

    /*********************************************************/
    /* Actions available during ProposalsRegistrationEnded   */
    /*********************************************************/
    /*
     * @dev Allow admin to start voting session
     */
    function startVotingSession() external onlyOwner {
        require(votingStep == WorkflowStatus.ProposalsRegistrationEnded, "Not in proposals registation ended state");
        setVotingStep(WorkflowStatus.VotingSessionStarted);
    }

    /*********************************************************/
    /* Actions available during VotingSessionStarted         */
    /*********************************************************/
    modifier onlyDuringVotingSession() {
        require(votingStep == WorkflowStatus.VotingSessionStarted, "Voting session not ongoing");
        _;
    }

    /*
     * @dev Allow registered voters to vote for their favorite voting option
     * 
     */
    function vote(uint _proposalId) external whitelistedVotersOnly onlyDuringVotingSession {
        if (!allowVoteUpdate)
            require(voters[msg.sender].hasVoted == false,"You can only vote once");
        require(_proposalId < proposalsArray.length,"Proposal ID does not exist");

        if (allowVoteUpdate && voters[msg.sender].hasVoted) {
            // We are updating vote, remove previous vote and send update event
            proposalsArray[voters[msg.sender].votedProposalId].voteCount--;
            emit VoteUpdated(msg.sender, voters[msg.sender].votedProposalId, _proposalId);
        } else {
            // This is the initial vote, mark vote as done and send vote event
            voters[msg.sender].hasVoted = true;
            emit Voted(msg.sender, _proposalId);
        }
        voters[msg.sender].votedProposalId = _proposalId;
        proposalsArray[_proposalId].voteCount++;
    }

    /*
     * @dev Allow administrator to end voting session
     */
    function endVotingSession() external onlyOwner onlyDuringVotingSession {
        setVotingStep(WorkflowStatus.VotingSessionEnded);
    }

    /*********************************************************/
    /* Actions available during VotingSessionEnded           */
    /*********************************************************/
    /*
     * @dev Allow administrator to trigger finding winning proposal
     */
    function countVotes() external onlyOwner {
        require(votingStep == WorkflowStatus.VotingSessionEnded, "Not in voting session ended state");
        // find winning proposal
        uint maxVoteCount = 0;
        winningProposalId = 0;
        resultDate = block.timestamp;
        for (uint i=0; i<proposalsArray.length; i++) {
            if (proposalsArray[i].voteCount > maxVoteCount) {
                maxVoteCount = proposalsArray[i].voteCount;
                winningProposalId = i;
            }
        }
        // Results are now available !
        setVotingStep(WorkflowStatus.VotesTallied);
    }

    /*********************************************************/
    /* Actions available during VotesTallied                 */
    /*********************************************************/
    modifier onlyDuringVotesTallied() {
        require(votingStep == WorkflowStatus.VotesTallied, "Result is not yet available");
        _;
    }

    /*
     * @dev Allow to get id of the winning proposal
     * @return uint32 containing id of the winning proposal
     */
    function getWinnerId() external view onlyDuringVotesTallied returns (uint) {
        return winningProposalId;
    }

    /*
     * @dev Allow to get id of the winning proposal
     * @return uint32 containing id of the winning proposal
     */
    function getWinnerProposalDetails() external view onlyDuringVotesTallied returns (Proposal memory) {
        return proposalsArray[winningProposalId];
    }

    /*
     * @dev Allow admin to reset result and start a new vote
     * Note : a grace period have to be respected to make sure that the result
     *        has been available for enough time.
     *        When restarted, everything is reinitialized, including voters list.
     */
    function startNewVote() external onlyOwner onlyDuringVotesTallied {
        require(block.timestamp >= resultDate + resultGracePeriod,"Wait for the grace period to end");
        winningProposalId = 0;
        // remove current voters
        for (uint i=0;i<votersArray.length;i++) {
            delete voters[votersArray[i]];
        }
        delete votersArray;
        delete proposalsArray;
        setVotingStep(WorkflowStatus.RegisteringVoters);
    }
}