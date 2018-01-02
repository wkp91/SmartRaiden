package params

import (
	"crypto/ecdsa"
	"os"
	"os/user"
	"path/filepath"
	"runtime"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/node"
)

type protocolConfig struct {
	RetryInterval        int
	RetriesBeforeBackoff int
	ThrottleCapacity     float64
	ThrottleFillRate     float64
	NatInvitationTimeout int
	NatKeepAliveRetries  int
	NatKeepAliveTimeout  int64
}
type Config struct {
	Host             string
	Port             int
	ExternIp         string
	ExternPort       int
	PrivateKeyHex    string
	PrivateKey       *ecdsa.PrivateKey
	RevealTimeout    int
	SettleTimeout    int
	DataBasePath     string
	MsgTimeout       float64
	Protocol         protocolConfig
	UseRpc           bool
	UseConsole       bool
	ApiHost          string
	ApiPort          int
	RegistryAddress  common.Address
	DiscoveryAddress common.Address
	DataDir          string
	MyAddress        common.Address
}

var DefaultConfig = Config{
	Port:          INITIAL_PORT,
	ExternPort:    INITIAL_PORT,
	PrivateKeyHex: "",
	RevealTimeout: DEFAULT_REVEAL_TIMEOUT,
	SettleTimeout: DEFAULT_SETTLE_TIMEOUT,
	Protocol: protocolConfig{
		RetryInterval:        DEFAULT_PROTOCOL_RETRY_INTERVAL,
		RetriesBeforeBackoff: DEFAULT_PROTOCOL_RETRIES_BEFORE_BACKOFF,
		ThrottleCapacity:     DEFAULT_PROTOCOL_THROTTLE_CAPACITY,
		ThrottleFillRate:     DEFAULT_PROTOCOL_THROTTLE_FILL_RATE,
		NatInvitationTimeout: DEFAULT_NAT_INVITATION_TIMEOUT,
		NatKeepAliveRetries:  DEFAULT_NAT_KEEPALIVE_RETRIES,
		NatKeepAliveTimeout:  DEFAULT_NAT_KEEPALIVE_TIMEOUT,
	},
	UseRpc:           true,
	UseConsole:       false,
	RegistryAddress:  ROPSTEN_REGISTRY_ADDRESS,
	DiscoveryAddress: ROPSTEN_DISCOVERY_ADDRESS,
}

func init() {

}
func DefaultDataDir() string {
	// Try to place the data folder in the user's home dir
	home := homeDir()
	if home != "" {
		if runtime.GOOS == "darwin" {
			return filepath.Join(home, "Library", "GoRaiden")
		} else if runtime.GOOS == "windows" {
			return filepath.Join(home, "AppData", "Roaming", "GoRaiden")
		} else {
			return filepath.Join(home, ".GoRaiden")
		}
	}
	// As we cannot guess a stable location, return empty and handle later
	return ""
}

func homeDir() string {
	if home := os.Getenv("HOME"); home != "" {
		return home
	}
	if usr, err := user.Current(); err == nil {
		return usr.HomeDir
	}
	return ""
}

func DefaultKeyStoreDir() string {
	return filepath.Join(node.DefaultDataDir(), "keystore")
}
