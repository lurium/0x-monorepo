/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.5;
pragma experimental ABIEncoderV2;

import "../libs/LibSafeMath.sol";
import "../libs/LibSignatureValidator.sol";
import "../libs/LibEIP712Hash.sol";
import "../interfaces/IStructs.sol";
import "../interfaces/IStakingEvents.sol";
import "../immutable/MixinConstants.sol";
import "../immutable/MixinStorage.sol";
import "./MixinRewardVault.sol";


contract MixinStakingPool is
    IStakingEvents,
    MixinConstants,
    MixinStorage,
    MixinRewardVault
{

    using LibSafeMath for uint256;

    /// @dev This mixin contains logic for staking pools.
    /// A pool has a single operator and any number of delegators (members).
    /// Any staker can create a pool, although at present it is only beneficial
    /// for market makers to create staking pools. A market maker *must* create a 
    /// pool in order to receive fee-based rewards at the end of each epoch (see MixinExchangeFees).
    /// Moreover, creating a staking pool leverages the delegated stake within the pool,
    /// which is counted towards a maker's total stake when computing rewards. A market maker
    /// can register any number of makerAddresses with their pool, and can incentivize delegators
    /// to join their pool by specifying a fixed percentage of their fee-based rewards to be split amonst
    /// the members of their pool. Any rewards set aside for members of the pool is divided based on
    /// how much stake each member delegated.
    ///
    /// Terminology:
    /// "Pool Id"       - A unique id generated by this contract and assigned to each pool when it is created.
    /// "Pool Operator" - The creator and operator of the pool.
    /// "Pool Members"  - Members of the pool who opted-in by delegating to the pool.
    /// "Market Makers" - Market makers on the 0x protocol.
    ///
    /// How-To for Market Makers:
    /// 1. Create a pool, specifying what percentage of rewards kept for yourself.
    ///     The remaining is divided among members of your pool.
    /// 2. Add the addresses that you use to market make on 0x.
    /// 3. Leverage the staking power of others by convincing them to delegate to your pool.

    /// @dev Asserts that the sender is the operator of the input pool.
    /// @param poolId Pool sender must be operator of.
    modifier onlyPoolOperator(bytes32 poolId) {
        require(
            msg.sender == getPoolOperator(poolId),
            "ONLY_CALLABLE_BY_POOL_OPERATOR"
        );

        _;
    }

    /// @dev Asserts that the sender is the operator of the input pool or the input maker.
    /// @param poolId Pool sender must be operator of.
    /// @param makerAddress Address of a maker in the pool.
    modifier onlyPoolOperatorOrMaker(bytes32 poolId, address makerAddress) {
        require(
            msg.sender == getPoolOperator(poolId) || msg.sender == makerAddress,
            "ONLY_CALLABLE_BY_POOL_OPERATOR_OR_MAKER"
        );

        _;
    }

    /// @dev Create a new staking pool. The sender will be the operator of this pool.
    /// Note that an operator must be payable.
    /// @param operatorShare The percentage of any rewards owned by the operator.
    /// @return poolId The unique pool id generated for this pool.
    function createPool(uint8 operatorShare)
        external
        returns (bytes32 poolId)
    {
        // note that an operator must be payable
        address payable operatorAddress = msg.sender;

        // assign pool id and generate next id
        poolId = nextPoolId;
        nextPoolId = _computeNextPoolId(poolId);

        // store metadata about this pool
        IStructs.Pool memory pool = IStructs.Pool({
            operatorAddress: operatorAddress,
            operatorShare: operatorShare
        });
        poolById[poolId] = pool;

        // register pool in reward vault
        _createPoolInRewardVault(poolId, operatorShare);

        // notify
        emit StakingPoolCreated(poolId, operatorAddress, operatorShare);
        return poolId;
    }

    /// @dev Adds a maker to a staking pool. Note that this is only callable by the pool operator.
    /// @param poolId Unique id of pool.
    /// @param makerAddress Address of maker.
    /// @param makerSignature Signature proving that maker has agreed to join the pool.
    function addMakerToPool(
        bytes32 poolId,
        address makerAddress,
        bytes calldata makerSignature
    )
        external
        onlyPoolOperator(poolId)
    {
        // sanity check - did maker agree to join this pool?
        require(
            isValidMakerSignature(poolId, makerAddress, makerSignature),
            "INVALID_MAKER_SIGNATURE"
        );

        // maker has agreed, record their address
        _recordMaker(poolId, makerAddress);
    }

    /// @dev Adds a maker to a staking pool. Note that this is only callable by the pool operator or maker.
    /// Note also that the maker does not have to *agree* to leave the pool; this action is
    /// at the sole discretion of the pool operator.
    /// @param poolId Unique id of pool.
    /// @param makerAddress Address of maker.
    function removeMakerFromPool(
        bytes32 poolId,
        address makerAddress
    )
        onlyPoolOperatorOrMaker(poolId, makerAddress)
        external
    {
        _unrecordMaker(poolId, makerAddress);
    }

    /// @dev Returns true iff the input signature is valid; meaning that the maker agrees to
    /// be added to the pool.
    /// @param poolId Unique id of pool the maker wishes to join.
    /// @param makerAddress Address of maker.
    /// @param makerSignature Signature of the maker.
    /// @return isValid True iff the maker agrees to be added to the pool.
    function isValidMakerSignature(bytes32 poolId, address makerAddress, bytes memory makerSignature)
        public
        view
        returns (bool isValid)
    {
        bytes32 approvalHash = getStakingPoolApprovalMessageHash(poolId, makerAddress);
        isValid = LibSignatureValidator._isValidSignature(approvalHash, makerAddress, makerSignature);
        return isValid;
    }

    /// @dev Returns the approval message hash - this is what a maker must sign in order to
    /// be added to a pool.
    /// @param poolId Unique id of pool the maker wishes to join.
    /// @param makerAddress Address of maker.
    /// @return approvalHash Hash of message the maker must sign.
    function getStakingPoolApprovalMessageHash(bytes32 poolId, address makerAddress)
        public
        view
        returns (bytes32 approvalHash)
    {
        IStructs.StakingPoolApproval memory approval = IStructs.StakingPoolApproval({
            poolId: poolId,
            makerAddress: makerAddress
        });

        // hash approval message and check signer address
        address verifierAddress = address(this);
        approvalHash = LibEIP712Hash._hashStakingPoolApprovalMessage(approval, CHAIN_ID, verifierAddress);

        return approvalHash;
    }

    /// @dev Returns the pool id of an input maker.
    function getPoolIdOfMaker(address makerAddress)
        public
        view
        returns (bytes32)
    {
        return poolIdByMakerAddress[makerAddress];
    }

    /// @dev Returns true iff the maker is assigned to a staking pool.
    /// @param makerAddress Address of maker
    /// @return True iff assigned.
    function isMakerAssignedToPool(address makerAddress)
        public
        view
        returns (bool)
    {
        return getPoolIdOfMaker(makerAddress) != NIL_MAKER_ID;
    }

    /// @dev Returns the makers for a given pool.
    /// @param poolId Unique id of pool.
    /// @return _makerAddressesByPoolId Makers for pool.
    function getMakersForPool(bytes32 poolId)
        public
        view
        returns (address[] memory _makerAddressesByPoolId)
    {
        // Load pointer to addresses of makers
        address[] storage makerAddressesByPoolIdPtr = makerAddressesByPoolId[poolId];
        uint256 makerAddressesByPoolIdLength = makerAddressesByPoolIdPtr.length;

        // Construct list of makers
        _makerAddressesByPoolId = new address[](makerAddressesByPoolIdLength);
        for (uint i = 0; i < makerAddressesByPoolIdLength; ++i) {
            _makerAddressesByPoolId[i] = makerAddressesByPoolIdPtr[i];
        }

        return _makerAddressesByPoolId;
    }

    /// @dev Returns the unique id that will be assigned to the next pool that is created.
    /// @return Pool id.
    function getNextPoolId()
        public
        view
        returns (bytes32)
    {
        return nextPoolId;
    }

    /// @dev Returns the pool operator
    /// @param poolId Unique id of pool
    /// @return operatorAddress Operator of the pool
    function getPoolOperator(bytes32 poolId)
        public
        view
        returns (address operatorAddress)
    {
        operatorAddress = poolById[poolId].operatorAddress;
    }

    /// @dev Convenience function for loading information on a pool.
    /// @param poolId Unique id of pool.
    /// @return pool Pool info.
    function _getPool(bytes32 poolId)
        internal
        view
        returns (IStructs.Pool memory pool)
    {
        pool = poolById[poolId];
        return pool;
    }

    /// @dev Computes the unique id that comes after the input pool id.
    /// @param poolId Unique id of pool.
    /// @return Next pool id after input pool.
    function _computeNextPoolId(bytes32 poolId)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(uint256(poolId)._add(POOL_ID_INCREMENT_AMOUNT));
    }

    /// @dev Records a maker for a pool.
    /// @param poolId Unique id of pool.
    /// @param makerAddress Address of maker.
    function _recordMaker(
        bytes32 poolId,
        address makerAddress
    )
        private
    {
        require(
            !isMakerAssignedToPool(makerAddress),
            "MAKER_ADDRESS_ALREADY_REGISTERED"
        );
        poolIdByMakerAddress[makerAddress] = poolId;
        makerAddressesByPoolId[poolId].push(makerAddress);

        // notify
        emit MakerAddedToStakingPool(
            poolId,
            makerAddress
        );
    }

    /// @dev Unrecords a maker for a pool.
    /// @param poolId Unique id of pool.
    /// @param makerAddress Address of maker.
    function _unrecordMaker(
        bytes32 poolId,
        address makerAddress
    )
        private
    {
        require(
            getPoolIdOfMaker(makerAddress) == poolId,
            "MAKER_ADDRESS_NOT_REGISTERED"
        );

        // load list of makers for the input pool.
        address[] storage makerAddressesByPoolIdPtr = makerAddressesByPoolId[poolId];
        uint256 makerAddressesByPoolIdLength = makerAddressesByPoolIdPtr.length;

        // find index of maker to remove.
        uint indexOfMakerAddress = 0;
        for (; indexOfMakerAddress < makerAddressesByPoolIdLength; ++indexOfMakerAddress) {
            if (makerAddressesByPoolIdPtr[indexOfMakerAddress] == makerAddress) {
                break;
            }
        }

        // remove the maker from the list of makers for this pool.
        // (i) move maker at end of list to the slot occupied by the maker to remove, then
        // (ii) zero out the slot at the end of the list and decrement the length.
        uint256 indexOfLastMakerAddress = makerAddressesByPoolIdLength - 1;
        if (indexOfMakerAddress != indexOfLastMakerAddress) {
            makerAddressesByPoolIdPtr[indexOfMakerAddress] = makerAddressesByPoolIdPtr[indexOfLastMakerAddress];
        }
        makerAddressesByPoolIdPtr[indexOfLastMakerAddress] = NIL_ADDRESS;
        makerAddressesByPoolIdPtr.length -= 1;

        // reset the pool id assigned to the maker.
        poolIdByMakerAddress[makerAddress] = NIL_MAKER_ID;

        // notify
        emit MakerRemovedFromStakingPool(
            poolId,
            makerAddress
        );
    }
}
