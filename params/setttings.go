package params

import (
	"fmt"

	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/params"
)

const INITIAL_PORT = 40001

const CACHE_TTL = 60
const ESTIMATED_BLOCK_TIME = 7
const GAS_LIMIT = 3141592 //den's gasLimit.

const GAS_PRICE = params.Shannon * 20

const DEFAULT_PROTOCOL_RETRIES_BEFORE_BACKOFF = 5
const DEFAULT_PROTOCOL_THROTTLE_CAPACITY = 10.
const DEFAULT_PROTOCOL_THROTTLE_FILL_RATE = 10.
const DEFAULT_PROTOCOL_RETRY_INTERVAL = 1.

const DEFAULT_REVEAL_TIMEOUT = 30
const DEFAULT_SETTLE_TIMEOUT = DEFAULT_REVEAL_TIMEOUT * 20
const DEFAULT_EVENTS_POLL_TIMEOUT = 0.5
const DEFAULT_POLL_TIMEOUT = 180 * time.Second
const DEFAULT_JOINABLE_FUNDS_TARGET = 0.4
const DEFAULT_INITIAL_CHANNEL_TARGET = 3
const DEFAULT_WAIT_FOR_SETTLE = true

const DEFAULT_NAT_KEEPALIVE_RETRIES = 5
const DEFAULT_NAT_KEEPALIVE_TIMEOUT = 30
const DEFAULT_NAT_INVITATION_TIMEOUT = 180
const Default_Tx_Timeout = 5 * time.Minute //15seconds for one block,it may take sever minutes

var GAS_LIMIT_HEX string
var ROPSTEN_REGISTRY_ADDRESS = common.HexToAddress("Cf3C7400C227be86FcdB2c9Be7DEf5c671087620")
var ROPSTEN_DISCOVERY_ADDRESS = common.HexToAddress("5a93A5E5b754898f06F7A0f4abac419547600B25")

const NETTINGCHANNEL_SETTLE_TIMEOUT_MIN = 6

/*
# The maximum settle timeout is chosen as something above
# 1 year with the assumption of very fast block times of 12 seconds.
# There is a maximum to avoidpotential overflows as described here:
# https://github.com/raiden-network/raiden/issues/1038
*/
const NETTINGCHANNEL_SETTLE_TIMEOUT_MAX = 2700000

const UDP_MAX_MESSAGE_SIZE = 1200

func init() {
	GAS_LIMIT_HEX = fmt.Sprintf("0x%x", GAS_LIMIT)
}
