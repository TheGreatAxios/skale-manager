// SPDX-License-Identifier: AGPL-3.0-only

/*
    SkaleDKG.sol - SKALE Manager
    Copyright (C) 2018-Present SKALE Labs
    @author Artem Payvin

    SKALE Manager is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published
    by the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    SKALE Manager is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with SKALE Manager.  If not, see <https://www.gnu.org/licenses/>.
*/

pragma solidity 0.6.10;
pragma experimental ABIEncoderV2;
import "./Permissions.sol";
import "./delegation/Punisher.sol";
import "./SlashingTable.sol";
import "./Schains.sol";
import "./SchainsInternal.sol";
import "./utils/FieldOperations.sol";
import "./NodeRotation.sol";
import "./KeyStorage.sol";
import "./interfaces/ISkaleDKG.sol";
import "./thirdparty/ECDH.sol";
import "./utils/Precompiled.sol";
import "./Wallets.sol";
import "./dkg/SkaleDKGAlright.sol";
import "./dkg/SkaleDKGBroadcast.sol";

/**
 * @title SkaleDKG
 * @dev Contains functions to manage distributed key generation per
 * Joint-Feldman protocol.
 */
contract SkaleDKG is Permissions, ISkaleDKG {
    using Fp2Operations for Fp2Operations.Fp2Point;
    using G2Operations for G2Operations.G2Point;

    struct Channel {
        bool active;
        uint n;
        uint startedBlockTimestamp;
        uint startedBlock;
    }

    struct ProcessDKG {
        uint numberOfBroadcasted;
        uint numberOfCompleted;
        bool[] broadcasted;
        bool[] completed;
    }

    struct ComplaintData {
        uint nodeToComplaint;
        uint fromNodeToComplaint;
        uint startComplaintBlockTimestamp;
        bool isResponse;
        bytes32 keyShare;
        G2Operations.G2Point sumOfVerVec;
    }

    struct KeyShare {
        bytes32[2] publicKey;
        bytes32 share;
    }

    uint public constant COMPLAINT_TIMELIMIT = 1800;

    mapping(bytes32 => Channel) public channels;

    mapping(bytes32 => uint) public lastSuccesfulDKG;

    mapping(bytes32 => ProcessDKG) public dkgProcess;

    mapping(bytes32 => ComplaintData) public complaints;

    mapping(bytes32 => uint) public startAlrightTimestamp;

    mapping(bytes32 => mapping(uint => bytes32)) public hashedData;

    /**
     * @dev Emitted when a channel is opened.
     */
    event ChannelOpened(bytes32 schainId);

    /**
     * @dev Emitted when a channel is closed.
     */
    event ChannelClosed(bytes32 schainId);

    /**
     * @dev Emitted when a node broadcasts keyshare.
     */
    event BroadcastAndKeyShare(
        bytes32 indexed schainId,
        uint indexed fromNode,
        G2Operations.G2Point[] verificationVector,
        KeyShare[] secretKeyContribution
    );

    /**
     * @dev Emitted when all group data is received by node.
     */
    event AllDataReceived(bytes32 indexed schainId, uint nodeIndex);

    /**
     * @dev Emitted when DKG is successful.
     */
    event SuccessfulDKG(bytes32 indexed schainId);

    /**
     * @dev Emitted when a complaint against a node is verified.
     */
    event BadGuy(uint nodeIndex);

    /**
     * @dev Emitted when DKG failed.
     */
    event FailedDKG(bytes32 indexed schainId);

    /**
     * @dev Emitted when a complaint is sent.
     */
    event ComplaintSent(
        bytes32 indexed schainId, uint indexed fromNodeIndex, uint indexed toNodeIndex);

    /**
     * @dev Emitted when a new node is rotated in.
     */
    event NewGuy(uint nodeIndex);

    /**
     * @dev Emitted when an incorrect complaint is sent.
     */
    event ComplaintError(string error);

    modifier correctGroup(bytes32 schainId) {
        require(channels[schainId].active, "Group is not created");
        _;
    }

    modifier correctGroupWithoutRevert(bytes32 schainId) {
        if (!channels[schainId].active) {
            emit ComplaintError("Group is not created");
        } else {
            _;
        }
    }

    modifier correctNode(bytes32 schainId, uint nodeIndex) {
        (uint index, ) = checkAndReturnIndexInGroup(schainId, nodeIndex, true);
        _;
    }

    modifier correctNodeWithoutRevert(bytes32 schainId, uint nodeIndex) {
        (, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        if (!check) {
            emit ComplaintError("Node is not in this group");
        } else {
            _;
        }
    }

    modifier onlyNodeOwner(uint nodeIndex) {
        _checkMsgSenderIsNodeOwner(nodeIndex);
        _;
    }


    function alright(bytes32 schainId, uint fromNodeIndex)
        external
        correctGroup(schainId)
        onlyNodeOwner(fromNodeIndex)
    {
        SkaleDKGAlright.alright(
            schainId,
            fromNodeIndex,
            contractManager,
            channels,
            dkgProcess,
            complaints,
            lastSuccesfulDKG
        );
    }

    // function broadcast(
    //     bytes32 schainId,
    //     uint nodeIndex,
    //     G2Operations.G2Point[] memory verificationVector,
    //     KeyShare[] memory secretKeyContribution
    // )
    //     external
    //     correctGroup(schainId)
    //     onlyNodeOwner(nodeIndex)
    // {
    //     SkaleDKGBroadcast.broadcast(
    //         schainId,
    //         nodeIndex,
    //         verificationVector,
    //         secretKeyContribution,
    //         contractManager,
    //         channels,
    //         dkgProcess,
    //         startAlrightTimestamp,
    //         hashedData
    //     );
    // }

    // function complaint(bytes32 schainId, uint fromNodeIndex, uint toNodeIndex)
    //     external
    //     virtual
    //     correctGroupWithoutRevert(schainId)
    //     correctNode(schainId, fromNodeIndex)
    //     correctNodeWithoutRevert(schainId, toNodeIndex)
    //     onlyNodeOwner(fromNodeIndex)
    // {
    //     address skaleDKGComplaint = contractManager.getContract("SkaleDKGComplaint");
    //     // solhint-disable-next-line avoid-low-level-calls
    //     (bool success, bytes memory result) = skaleDKGComplaint.delegatecall(abi.encodeWithSignature(
    //         "complaint(bytes32,uint256,uint256)",
    //         schainId, fromNodeIndex, toNodeIndex
    //     ));
    //     require(success, _getRevertMsg(result));
    // }

    // function complaintBadData(bytes32 schainId, uint fromNodeIndex, uint toNodeIndex)
    //     external
    //     virtual
    //     correctGroupWithoutRevert(schainId)
    //     correctNode(schainId, fromNodeIndex)
    //     correctNodeWithoutRevert(schainId, toNodeIndex)
    //     onlyNodeOwner(fromNodeIndex)
    // { 
    //     address skaleDKGComplaint = contractManager.getContract("SkaleDKGComplaint");
    //     // solhint-disable-next-line avoid-low-level-calls
    //     (bool success, bytes memory result) = skaleDKGComplaint.delegatecall(abi.encodeWithSignature(
    //         "complaintBadData(bytes32,uint256,uint256)",
    //         schainId, fromNodeIndex, toNodeIndex
    //     ));
    //     require(success, _getRevertMsg(result));
    // }

    // function preResponse(
    //     bytes32 schainId,
    //     uint fromNodeIndex,
    //     G2Operations.G2Point[] calldata verificationVector,
    //     G2Operations.G2Point[] calldata verificationVectorMult,
    //     KeyShare[] calldata secretKeyContribution
    // )
    //     external
    //     virtual
    //     correctGroup(schainId)
    //     onlyNodeOwner(fromNodeIndex)
    // {
    //     address skaleDKGPreResponse = contractManager.getContract("SkaleDKGPreResponse");
    //     // solhint-disable-next-line avoid-low-level-calls
    //     (bool success, bytes memory result) = skaleDKGPreResponse.delegatecall(abi.encodeWithSignature(
    //         "preResponse(bytes32,uint256,((uint256,uint256),(uint256,uint256))[],"
    //         "((uint256,uint256),(uint256,uint256))[],(bytes32[2],bytes32)[])",
    //         schainId, fromNodeIndex, verificationVector, verificationVectorMult, secretKeyContribution)
    //     );
    //     require(success, _getRevertMsg(result));
    // }

    // function response(
    //     bytes32 schainId,
    //     uint fromNodeIndex,
    //     uint secretNumber,
    //     G2Operations.G2Point calldata multipliedShare
    // )
    //     external
    //     virtual
    //     correctGroup(schainId)
    //     onlyNodeOwner(fromNodeIndex)
    // {
    //     address skaleDKGResponse = contractManager.getContract("SkaleDKGResponse");
    //     // solhint-disable-next-line avoid-low-level-calls
    //     (bool success, bytes memory result) = skaleDKGResponse.delegatecall(abi.encodeWithSignature(
    //         "response(bytes32,uint256,uint256,((uint256,uint256),(uint256,uint256)))",
    //         schainId, fromNodeIndex, secretNumber, multipliedShare)
    //     );
    //     require(success, _getRevertMsg(result));
    // }

    // function _getRevertMsg(bytes memory _returnData) private pure returns (string memory) {
    //     if (_returnData.length < 68) return "Transaction reverted silently";

    //     // solhint-disable-next-line no-inline-assembly
    //     assembly {
    //         _returnData := add(_returnData, 0x04)
    //     }
    //     return abi.decode(_returnData, (string));
    // }


    /**
     * @dev Allows Schains and NodeRotation contracts to open a channel.
     * 
     * Emits a {ChannelOpened} event.
     * 
     * Requirements:
     * 
     * - Channel is not already created.
     */
    function openChannel(bytes32 schainId) external override allowTwo("Schains","NodeRotation") {
        _openChannel(schainId);
    }

    /**
     * @dev Allows SchainsInternal contract to delete a channel.
     *
     * Requirements:
     *
     * - Channel must exist.
     */
    function deleteChannel(bytes32 schainId) external override allow("SchainsInternal") {
        delete channels[schainId];
        delete dkgProcess[schainId];
        delete complaints[schainId];
        KeyStorage(contractManager.getContract("KeyStorage")).deleteKey(schainId);
    }

    function getChannelStartedTime(bytes32 schainId) external view returns (uint) {
        return channels[schainId].startedBlockTimestamp;
    }

    function getChannelStartedBlock(bytes32 schainId) external view returns (uint) {
        return channels[schainId].startedBlock;
    }

    function getNumberOfBroadcasted(bytes32 schainId) external view returns (uint) {
        return dkgProcess[schainId].numberOfBroadcasted;
    }

    function getNumberOfCompleted(bytes32 schainId) external view returns (uint) {
        return dkgProcess[schainId].numberOfCompleted;
    }

    function getTimeOfLastSuccesfulDKG(bytes32 schainId) external view returns (uint) {
        return lastSuccesfulDKG[schainId];
    }

    function getComplaintData(bytes32 schainId) external view returns (uint, uint) {
        return (complaints[schainId].fromNodeToComplaint, complaints[schainId].nodeToComplaint);
    }

    function getComplaintStartedTime(bytes32 schainId) external view returns (uint) {
        return complaints[schainId].startComplaintBlockTimestamp;
    }

    function getAlrightStartedTime(bytes32 schainId) external view returns (uint) {
        return startAlrightTimestamp[schainId];
    }

    /**
     * @dev Checks whether channel is opened.
     */
    function isChannelOpened(bytes32 schainId) external override view returns (bool) {
        return channels[schainId].active;
    }

    function isLastDKGSuccessful(bytes32 schainId) external override view returns (bool) {
        return channels[schainId].startedBlockTimestamp <= lastSuccesfulDKG[schainId];
    }

    function setStartAlrightTimestamp(bytes32 schainId) external allow("SkaleDKGBroadcast") {
        startAlrightTimestamp[schainId] = now;
    }

    /**
     * @dev Checks whether broadcast is possible.
     */
    function isBroadcastPossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            !dkgProcess[schainId].broadcasted[index];
    }

    /**
     * @dev Checks whether complaint is possible.
     */
    function isComplaintPossible(
        bytes32 schainId,
        uint fromNodeIndex,
        uint toNodeIndex
    )
        external
        view
        returns (bool)
    {
        (uint indexFrom, bool checkFrom) = checkAndReturnIndexInGroup(schainId, fromNodeIndex, false);
        (uint indexTo, bool checkTo) = checkAndReturnIndexInGroup(schainId, toNodeIndex, false);
        if (!checkFrom || !checkTo)
            return false;
        bool complaintSending = (
                complaints[schainId].nodeToComplaint == uint(-1) &&
                dkgProcess[schainId].broadcasted[indexTo] &&
                !dkgProcess[schainId].completed[indexFrom]
            ) ||
            (
                dkgProcess[schainId].broadcasted[indexTo] &&
                complaints[schainId].startComplaintBlockTimestamp.add(_getComplaintTimelimit()) <= block.timestamp &&
                complaints[schainId].nodeToComplaint == toNodeIndex
            ) ||
            (
                !dkgProcess[schainId].broadcasted[indexTo] &&
                complaints[schainId].nodeToComplaint == uint(-1) &&
                channels[schainId].startedBlockTimestamp.add(_getComplaintTimelimit()) <= block.timestamp
            ) ||
            (
                complaints[schainId].nodeToComplaint == uint(-1) &&
                isEveryoneBroadcasted(schainId) &&
                dkgProcess[schainId].completed[indexFrom] &&
                !dkgProcess[schainId].completed[indexTo] &&
                startAlrightTimestamp[schainId].add(_getComplaintTimelimit()) <= block.timestamp
            );
        return channels[schainId].active &&
            dkgProcess[schainId].broadcasted[indexFrom] &&
            _isNodeOwnedByMessageSender(fromNodeIndex, msg.sender) &&
            complaintSending;
    }

    /**
     * @dev Checks whether sending Alright response is possible.
     */
    function isAlrightPossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            channels[schainId].n == dkgProcess[schainId].numberOfBroadcasted &&
            (complaints[schainId].fromNodeToComplaint != nodeIndex ||
            (nodeIndex == 0 && complaints[schainId].startComplaintBlockTimestamp == 0)) &&
            !dkgProcess[schainId].completed[index];
    }

    /**
     * @dev Checks whether sending a pre-response is possible.
     */
    function isPreResponsePossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            complaints[schainId].nodeToComplaint == nodeIndex &&
            !complaints[schainId].isResponse;
    }

    /**
     * @dev Checks whether sending a response is possible.
     */
    function isResponsePossible(bytes32 schainId, uint nodeIndex) external view returns (bool) {
        (, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return channels[schainId].active &&
            check &&
            _isNodeOwnedByMessageSender(nodeIndex, msg.sender) &&
            complaints[schainId].nodeToComplaint == nodeIndex &&
            complaints[schainId].isResponse;
    }

    function initialize(address contractsAddress) public override initializer {
        Permissions.initialize(contractsAddress);
    }

    function isNodeBroadcasted(bytes32 schainId, uint nodeIndex) public view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return check && dkgProcess[schainId].broadcasted[index];
    }

    /**
     * @dev Checks whether all data has been received by node.
     */
    function isAllDataReceived(bytes32 schainId, uint nodeIndex) public view returns (bool) {
        (uint index, bool check) = checkAndReturnIndexInGroup(schainId, nodeIndex, false);
        return check && dkgProcess[schainId].completed[index];
    }

    function isEveryoneBroadcasted(bytes32 schainId) public view returns (bool) {
        return channels[schainId].n == dkgProcess[schainId].numberOfBroadcasted;
    }

    function _finalizeSlashing(bytes32 schainId, uint badNode) internal {
        NodeRotation nodeRotation = NodeRotation(contractManager.getContract("NodeRotation"));
        SchainsInternal schainsInternal = SchainsInternal(
            contractManager.getContract("SchainsInternal")
        );
        emit BadGuy(badNode);
        emit FailedDKG(schainId);

        if (schainsInternal.isAnyFreeNode(schainId)) {
            uint newNode = nodeRotation.rotateNode(
                badNode,
                schainId,
                false
            );
            emit NewGuy(newNode);
        } else {
            _openChannel(schainId);
            schainsInternal.removeNodeFromSchain(
                badNode,
                schainId
            );
            channels[schainId].active = false;
        }
        Punisher(contractManager.getPunisher()).slash(
            Nodes(contractManager.getContract("Nodes")).getValidatorId(badNode),
            SlashingTable(contractManager.getContract("SlashingTable")).getPenalty("FailedDKG")
        );
    }

    function _refundGasBySchain(bytes32 schainId, uint nodeIndex, uint spentGas, bool isDebt) internal {
        Wallets(payable(contractManager.getContract("Wallets")))
        .refundGasBySchain(schainId, nodeIndex, spentGas, isDebt);
    }

    function _refundGasByValidatorToSchain(uint validatorId, bytes32 schainId) internal {
        Wallets(payable(contractManager.getContract("Wallets")))
        .refundGasByValidatorToSchain(validatorId, schainId);
    }

    function _getComplaintTimelimit() internal view returns (uint) {
        return ConstantsHolder(contractManager.getConstantsHolder()).complaintTimelimit();
    }

    function checkAndReturnIndexInGroup(
        bytes32 schainId,
        uint nodeIndex,
        bool revertCheck
    )
        public
        view
        returns (uint, bool)
    {
        uint index = SchainsInternal(contractManager.getContract("SchainsInternal"))
            .getNodeIndexInGroup(schainId, nodeIndex);
        if (index >= channels[schainId].n && revertCheck) {
            revert("Node is not in this group");
        }
        return (index, index < channels[schainId].n);
    }

    function hashData(
        KeyShare[] memory secretKeyContribution,
        G2Operations.G2Point[] memory verificationVector
    )
        external
        pure
        returns (bytes32)
    {
        bytes memory data;
        for (uint i = 0; i < secretKeyContribution.length; i++) {
            data = abi.encodePacked(data, secretKeyContribution[i].publicKey, secretKeyContribution[i].share);
        }
        for (uint i = 0; i < verificationVector.length; i++) {
            data = abi.encodePacked(
                data,
                verificationVector[i].x.a,
                verificationVector[i].x.b,
                verificationVector[i].y.a,
                verificationVector[i].y.b
            );
        }
        return keccak256(data);
    }

    function _openChannel(bytes32 schainId) private {
        SchainsInternal schainsInternal = SchainsInternal(
            contractManager.getContract("SchainsInternal")
        );

        uint len = schainsInternal.getNumberOfNodesInGroup(schainId);
        channels[schainId].active = true;
        channels[schainId].n = len;
        delete dkgProcess[schainId].completed;
        delete dkgProcess[schainId].broadcasted;
        dkgProcess[schainId].broadcasted = new bool[](len);
        dkgProcess[schainId].completed = new bool[](len);
        complaints[schainId].fromNodeToComplaint = uint(-1);
        complaints[schainId].nodeToComplaint = uint(-1);
        delete complaints[schainId].startComplaintBlockTimestamp;
        delete dkgProcess[schainId].numberOfBroadcasted;
        delete dkgProcess[schainId].numberOfCompleted;
        channels[schainId].startedBlockTimestamp = now;
        channels[schainId].startedBlock = block.number;
        KeyStorage(contractManager.getContract("KeyStorage")).initPublicKeyInProgress(schainId);

        emit ChannelOpened(schainId);
    }

    function _isNodeOwnedByMessageSender(uint nodeIndex, address from) private view returns (bool) {
        return Nodes(contractManager.getContract("Nodes")).isNodeExist(from, nodeIndex);
    }

    function _checkMsgSenderIsNodeOwner(uint nodeIndex) private view {
        require(_isNodeOwnedByMessageSender(nodeIndex, msg.sender), "Node does not exist for message sender");
    }

}
