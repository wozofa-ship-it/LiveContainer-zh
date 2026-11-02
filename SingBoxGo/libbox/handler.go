package libbox

import (
	"errors"

	sbox "github.com/sagernet/sing-box/experimental/libbox"
)

// commandHandler 在 Go 侧实现 libbox.CommandServerHandler，
// 这样 Swift 侧永远不用实现它。方法集已在 Demo 里对 sing-box v1.14.4
// experimental/libbox/command_server.go（CommandServerHandler 接口）核实过，
// 本文件只是把 Demo 的 demoHandler 改了个通用名，方法集一字未动。
type commandHandler struct{}

func (h *commandHandler) ServiceStop() error { return nil }

func (h *commandHandler) ServiceReload() error { return nil }

// 本桥不碰系统代理，直接报不可用。
func (h *commandHandler) GetSystemProxyStatus() (*sbox.SystemProxyStatus, error) {
	return &sbox.SystemProxyStatus{Available: false, Enabled: false}, nil
}

func (h *commandHandler) SetSystemProxyEnabled(enabled bool) error { return nil }

func (h *commandHandler) TriggerNativeCrash() error { return nil }

func (h *commandHandler) WriteDebugMessage(message string) {}

func (h *commandHandler) ConnectSSHAgent() (int32, error) {
	return 0, errors.New("ssh agent not supported")
}
