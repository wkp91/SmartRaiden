package target

import (
	"fmt"

	"github.com/SmartMeshFoundation/SmartRaiden/channel/channeltype"
	"github.com/SmartMeshFoundation/SmartRaiden/transfer"
	"github.com/SmartMeshFoundation/SmartRaiden/transfer/mediatedtransfer"
	"github.com/SmartMeshFoundation/SmartRaiden/transfer/mediatedtransfer/mediator"
	"github.com/SmartMeshFoundation/SmartRaiden/transfer/route"
	"github.com/SmartMeshFoundation/SmartRaiden/utils"
)

//NameTargetTransition name for state manager
const NameTargetTransition = "TargetTransition"

func init() {
}

/*
Emits the event for closing the netting channel if from_transfer needs
    to be settled on-chain.
*/
func eventsForClose(state *mediatedtransfer.TargetState) (events []transfer.Event) {
	fromTransfer := state.FromTransfer
	fromRoute := state.FromRoute
	safeToWait := mediator.IsSafeToWait(fromTransfer, fromRoute.RevealTimeout(), state.BlockNumber)
	secretKnown := fromTransfer.Secret != utils.EmptyHash
	if !safeToWait && secretKnown {
		state.State = mediatedtransfer.StateWaitingClose
		channelClose := &mediatedtransfer.EventContractSendChannelClose{
			ChannelIdentifier: fromRoute.ChannelIdentifier,
			Token:             fromTransfer.Token,
		}
		events = append(events, channelClose)
	}
	return
}

//Withdraw from the from_channel if it is closed and the secret is known.
func eventsForWithdraw(state *mediatedtransfer.TargetState, fromRoute *route.State) (events []transfer.Event) {
	fromTransfer := state.FromTransfer
	isChannelOpen := fromRoute.State() == channeltype.StateOpened
	if !isChannelOpen && fromTransfer.Secret != utils.EmptyHash { //重复发送，直到取现成功？或者expired？
		if state.Db != nil {
			if state.Db.IsThisLockHasWithdraw(fromRoute.ChannelIdentifier, fromTransfer.Secret) {
				return
			}
		}
		withdraw := &mediatedtransfer.EventContractSendWithdraw{
			Transfer:          fromTransfer,
			ChannelIdentifier: fromRoute.ChannelIdentifier,
		}
		events = append(events, withdraw)
	}
	return
}

//Handle an ActionInitTarget state change.
func handleInitTraget(st *mediatedtransfer.ActionInitTargetStateChange) *transfer.TransitionResult {
	tr := st.FromTranfer
	route := st.FromRoute
	blockNumber := st.BlockNumber
	state := &mediatedtransfer.TargetState{
		OurAddress:   st.OurAddress,
		FromRoute:    route,
		FromTransfer: tr,
		BlockNumber:  blockNumber,
		Db:           st.Db,
	}
	safeToWait := mediator.IsSafeToWait(tr, route.RevealTimeout(), blockNumber)
	/*
			  if there is not enough time to safely withdraw the token on-chain
		     silently let the transfer expire.
	*/
	if safeToWait {
		secretRequest := &mediatedtransfer.EventSendSecretRequest{
			LockSecretHash: tr.LockSecretHash,
			Amount:         tr.Amount,
			Receiver:       tr.Initiator,
		}
		return &transfer.TransitionResult{
			NewState: state,
			Events:   []transfer.Event{secretRequest},
		}
	}
	//如果超时了,那就什么都不做,等待相关各方自己取消?
	return &transfer.TransitionResult{
		NewState: state,
		Events:   nil,
	}
}

// Validate and handle a ReceiveSecretReveal state change.
func handleSecretReveal(state *mediatedtransfer.TargetState, st *mediatedtransfer.ReceiveSecretRevealStateChange) (it *transfer.TransitionResult) {
	validSecret := utils.Sha3(st.Secret[:]) == state.FromTransfer.LockSecretHash
	var events []transfer.Event
	if validSecret {
		tr := state.FromTransfer
		route := state.FromRoute
		state.State = mediatedtransfer.StateRevealSecret
		tr.Secret = st.Secret
		reveal := &mediatedtransfer.EventSendRevealSecret{
			LockSecretHash: tr.LockSecretHash,
			Secret:         tr.Secret,
			Token:          tr.Token,
			Receiver:       route.HopNode(),
			Sender:         state.OurAddress,
		}
		events = append(events, reveal)
	} else {
		// TODO: event for byzantine behavior
	}
	it = &transfer.TransitionResult{
		NewState: state,
		Events:   events,
	}
	return
}

func handleBalanceProof(state *mediatedtransfer.TargetState, st *mediatedtransfer.ReceiveBalanceProofStateChange) (it *transfer.TransitionResult) {
	it = &transfer.TransitionResult{
		NewState: state,
		Events:   nil,
	}
	//TODO: byzantine behavior event when the sender doesn't match
	if st.NodeAddress == state.FromRoute.HopNode() {
		state.State = mediatedtransfer.StateBalanceProof
	}
	return
}

/*
After Raiden learns about a new block this function must be called to
    handle expiration of the hash time lock.
*/
func handleBlock(state *mediatedtransfer.TargetState, st *transfer.BlockStateChange) (it *transfer.TransitionResult) {
	if state.BlockNumber < st.BlockNumber {
		state.BlockNumber = st.BlockNumber
	}
	/*
	   only emit the close event once

	*/
	var events []transfer.Event
	if state.State != mediatedtransfer.StateWaitingClose {
		events = eventsForClose(state)
	}
	events2 := eventsForWithdraw(state, state.FromRoute)
	events = append(events, events2...)
	it = &transfer.TransitionResult{
		NewState: state,
		Events:   events,
	}
	return
}

//Clear the state if the transfer was either completed or failed
func clearIfFinalized(previt *transfer.TransitionResult) (it *transfer.TransitionResult) {
	if previt.NewState == nil {
		return previt
	}
	state, ok := previt.NewState.(*mediatedtransfer.TargetState)
	if !ok {
		panic(fmt.Sprintf("clearIfFinalized for targetstate type error:%s", utils.StringInterface1(previt)))
	}
	it = previt
	if state.FromTransfer.Secret == utils.EmptyHash && state.BlockNumber > state.FromTransfer.Expiration {
		failed := &mediatedtransfer.EventWithdrawFailed{
			LockSecretHash:    state.FromTransfer.LockSecretHash,
			ChannelIdentifier: state.FromRoute.ChannelIdentifier,
			Reason:            "lock expired",
		}
		it = &transfer.TransitionResult{
			NewState: nil,
			Events:   []transfer.Event{failed},
		}
	} else if state.State == mediatedtransfer.StateBalanceProof {
		//这些事件对应的处理都没有
		transferSuccess := &transfer.EventTransferReceivedSuccess{
			LockSecretHash:    state.FromTransfer.LockSecretHash,
			Amount:            state.FromTransfer.Amount,
			Initiator:         state.FromTransfer.Initiator,
			ChannelIdentifier: state.FromRoute.ChannelIdentifier,
		}
		unlockSuccess := &mediatedtransfer.EventWithdrawSuccess{
			LockSecretHash: state.FromTransfer.LockSecretHash,
		}
		it = &transfer.TransitionResult{
			NewState: nil,
			Events:   []transfer.Event{transferSuccess, unlockSuccess},
		}
	}
	return it
}

// StateTransiton is State machine for the target node of a target transfer.
func StateTransiton(originalState transfer.State, stateChange transfer.StateChange) (it *transfer.TransitionResult) {
	it = &transfer.TransitionResult{
		NewState: originalState,
		Events:   nil,
	}
	if originalState == nil {
		ait, ok := stateChange.(*mediatedtransfer.ActionInitTargetStateChange)
		if ok {
			it = handleInitTraget(ait)
		}
	} else {
		state, ok := originalState.(*mediatedtransfer.TargetState)
		if !ok {
			panic(fmt.Sprintf("targetstate StateTransiton type error:%s", utils.StringInterface1(originalState)))
		}
		if state.FromTransfer.Secret == utils.EmptyHash {
			switch st2 := stateChange.(type) {
			case *mediatedtransfer.ReceiveSecretRevealStateChange:
				it = handleSecretReveal(state, st2)
			case *transfer.BlockStateChange:
				it = handleBlock(state, st2)
			}
		} else if state.FromTransfer.Secret != utils.EmptyHash {
			switch st2 := stateChange.(type) {
			case *mediatedtransfer.ReceiveBalanceProofStateChange:
				it = handleBalanceProof(state, st2)
			case *transfer.BlockStateChange:
				it = handleBlock(state, st2)
			}
		}
	}
	return clearIfFinalized(it)
}
