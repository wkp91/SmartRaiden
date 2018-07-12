package mediatedtransfer

import (
	"encoding/gob"

	"math/big"

	"github.com/SmartMeshFoundation/SmartRaiden/channel/channeltype"
	"github.com/SmartMeshFoundation/SmartRaiden/encoding"
	"github.com/SmartMeshFoundation/SmartRaiden/network/rpc/contracts"
	"github.com/SmartMeshFoundation/SmartRaiden/transfer"
	"github.com/SmartMeshFoundation/SmartRaiden/transfer/route"
	"github.com/ethereum/go-ethereum/common"
)

/*
ActionInitInitiatorStateChange start a mediated transfer
 Note: The init states must contain all the required data for trying doing
 useful work, ie. there must /not/ be an event for requesting new data.
*/
type ActionInitInitiatorStateChange struct {
	OurAddress     common.Address       //This node address.
	Tranfer        *LockedTransferState //A state object containing the transfer details.
	Routes         *route.RoutesState   //The current available routes.
	BlockNumber    int64                //The current block number.
	Db             channeltype.Db       //get the latest channel state
	LockSecretHash common.Hash
	Secret         common.Hash
}

//ActionInitMediatorStateChange  Initial state for a new mediator.
type ActionInitMediatorStateChange struct {
	OurAddress  common.Address             //This node address.
	FromTranfer *LockedTransferState       //The received MediatedTransfer.
	Routes      *route.RoutesState         //The current available routes.
	FromRoute   *route.State               //The route from which the MediatedTransfer was received.
	BlockNumber int64                      //The current block number.
	Message     *encoding.MediatedTransfer //the message trigger this statechange
	Db          channeltype.Db             //get the latest channel state
}

//ActionInitTargetStateChange Initial state for a new target.
type ActionInitTargetStateChange struct {
	OurAddress  common.Address       //This node address.
	FromTranfer *LockedTransferState //The received MediatedTransfer.
	FromRoute   *route.State         //The route from which the MediatedTransfer was received.
	BlockNumber int64
	Message     *encoding.MediatedTransfer //the message trigger this statechange
	Db          channeltype.Db             //get the latest channel state
}

/*
ActionCancelRouteStateChange Cancel the current route.
 Notes:
        Used to cancel a specific route but not the transfer, may be used for
        timeouts.
*/
type ActionCancelRouteStateChange struct {
	LockSecretHash common.Hash
}

//ReceiveSecretRequestStateChange A SecretRequest message received.
type ReceiveSecretRequestStateChange struct {
	Amount         *big.Int
	LockSecretHash common.Hash
	Sender         common.Address
	Message        *encoding.SecretRequest //the message trigger this statechange
}

//ReceiveSecretRevealStateChange A SecretReveal message received
type ReceiveSecretRevealStateChange struct {
	Secret  common.Hash
	Sender  common.Address
	Message *encoding.RevealSecret //the message trigger this statechange
}

//ReceiveTransferRefundStateChange A AnnounceDisposed message received.
type ReceiveTransferRefundStateChange struct {
	Sender   common.Address
	Transfer *LockedTransferState
	Message  *encoding.AnnounceDisposed //the message trigger this statechange
}

//ReceiveBalanceProofStateChange A balance proof `identifier` was received.
type ReceiveBalanceProofStateChange struct {
	LockSecretHash common.Hash
	NodeAddress    common.Address
	BalanceProof   *transfer.BalanceProofState
	Message        encoding.EnvelopMessager //the message trigger this statechange
}

/*
密码在链上注册了
1.诚实的节点在检查对方可以在链上unlock 这个锁的时候,应该主动发送unloc消息,移除此锁
2.自己应该把密码保存在本地,然后在需要的时候链上兑现
*/
type ContractSecretRevealStateChange struct {
	Secret      common.Hash
	BlockNumber int64
}

type ContractReceiveChannelWithdrawStateChange struct {
	ChannelAddress *contracts.ChannelUniqueID
	//剩余的 balance 有意义?目前提供的 Event 并不知道 Participant1是谁,所以没啥用.
	Participant1        common.Address
	Participant1Balance *big.Int
	Participant2        common.Address
	Participant2Balance *big.Int
	TokenNetworkAddress common.Address
}

//ContractReceiveClosedStateChange a channel was closed
type ContractReceiveClosedStateChange struct {
	ChannelIdentifier   common.Hash
	ClosingAddress      common.Address
	ClosedBlock         int64 //block number when close
	LocksRoot           common.Hash
	TransferredAmount   *big.Int
	TokenNetworkAddress common.Address
}

//ContractReceiveSettledStateChange a channel was settled
type ContractReceiveSettledStateChange struct {
	ChannelIdentifier   common.Hash
	SettledBlock        int64
	TokenNetworkAddress common.Address
}

//ContractReceiveCooperativeSettledStateChange a channel was cooperatively settled
type ContractReceiveCooperativeSettledStateChange struct {
	ChannelIdentifier   common.Hash
	SettledBlock        int64
	TokenNetworkAddress common.Address
}

//ContractReceiveBalanceStateChange new deposit on channel
type ContractReceiveBalanceStateChange struct {
	ChannelIdentifier   common.Hash
	ParticipantAddress  common.Address
	Balance             *big.Int
	BlockNumber         int64
	TokenNetworkAddress common.Address
}

//ContractReceiveNewChannelStateChange new channel created on block chain
type ContractReceiveNewChannelStateChange struct {
	ChannelIdentifier   *contracts.ChannelUniqueID
	Participant1        common.Address
	Participant2        common.Address
	SettleTimeout       int
	TokenNetworkAddress common.Address
}

//ContractReceiveTokenAddedStateChange a new token registered
type ContractReceiveTokenAddedStateChange struct {
	RegistryAddress     common.Address
	TokenAddress        common.Address
	TokenNetworkAddress common.Address
}

//ContractBalanceProofUpdatedStateChange contrct TransferUpdated event
type ContractBalanceProofUpdatedStateChange struct {
	ChannelIdentifier   common.Hash
	Participant         common.Address
	LocksRoot           common.Hash
	TransferredAmount   *big.Int
	TokenNetworkAddress common.Address
}

func init() {
	gob.Register(&ActionInitInitiatorStateChange{})
	gob.Register(&ActionInitMediatorStateChange{})
	gob.Register(&ActionInitTargetStateChange{})
	gob.Register(&ActionCancelRouteStateChange{})
	gob.Register(&ReceiveSecretRequestStateChange{})
	gob.Register(&ReceiveSecretRevealStateChange{})
	gob.Register(&ReceiveTransferRefundStateChange{})
	gob.Register(&ReceiveBalanceProofStateChange{})
	gob.Register(&ContractSecretRevealStateChange{})
	gob.Register(&ContractReceiveClosedStateChange{})
	gob.Register(&ContractReceiveSettledStateChange{})
	gob.Register(&ContractReceiveBalanceStateChange{})
	gob.Register(&ContractReceiveNewChannelStateChange{})
	gob.Register(&ContractReceiveTokenAddedStateChange{})
	gob.Register(&ContractBalanceProofUpdatedStateChange{})
}
