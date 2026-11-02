package libbox

import (
	"errors"

	sbox "github.com/sagernet/sing-box/experimental/libbox"
)

// minimalPlatform 在 Go 侧完整实现 libbox.PlatformInterface。
//
// 本桥跑的是 in-app SOCKS 模式（不走 NetworkExtension、不申请新 entitlement），
// 所以与真实 VPN 相关的平台方法（OpenTun、接口监听、shell、bridge）
// 都是桩：核心在 SOCKS 配置下不会走到它们；走到则明确报错，
// 而不是静默返回一个假成功。
//
// 对 SOCKS 配置真正起作用的返回：
//   - UsePlatformAutoDetectInterfaceControl: false，核心不找我们
//     把 socket 绑到指定接口。
//   - GetInterfaces: 空迭代器（不报任何接口）。
//   - UnderNetworkExtension: false（这是普通 App 内进程，不是
//     NetworkExtension）。
//   - LocalDNSTransport: nil。LocalDNSTransport 是接口类型
//     （experimental/libbox/dns.go），nil 是合法返回；
//     只有非 nil 时 baseContext 才会注册本地传输
//     （experimental/libbox/config.go）。
//
// 方法集已在 Demo 里对 sing-box v1.14.4
// experimental/libbox/platform.go（PlatformInterface 接口）核实过，
// 本文件只是把 Demo 的注释里的 "demo" 字样去掉，方法集一字未动。
type minimalPlatform struct{}

var _ sbox.PlatformInterface = (*minimalPlatform)(nil)

func (p *minimalPlatform) LocalDNSTransport() sbox.LocalDNSTransport { return nil }

func (p *minimalPlatform) UsePlatformAutoDetectInterfaceControl() bool { return false }

func (p *minimalPlatform) AutoDetectInterfaceControl(fd int32) error { return nil }

func (p *minimalPlatform) OpenTun(options sbox.TunOptions) (int32, error) {
	return 0, errors.New("tun not supported")
}

func (p *minimalPlatform) FindConnectionOwner(ipProtocol int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (*sbox.ConnectionOwner, error) {
	return nil, errors.New("connection owner lookup not supported")
}

func (p *minimalPlatform) StartDefaultInterfaceMonitor(listener sbox.InterfaceUpdateListener) error {
	return nil
}

func (p *minimalPlatform) CloseDefaultInterfaceMonitor(listener sbox.InterfaceUpdateListener) error {
	return nil
}

func (p *minimalPlatform) GetInterfaces() (sbox.NetworkInterfaceIterator, error) {
	return &emptyInterfaceIterator{}, nil
}

func (p *minimalPlatform) UnderNetworkExtension() bool { return false }

func (p *minimalPlatform) IncludeAllNetworks() bool { return false }

func (p *minimalPlatform) ReadWIFIState() *sbox.WIFIState { return nil }

func (p *minimalPlatform) ClearDNSCache() {}

func (p *minimalPlatform) SendNotification(notification *sbox.Notification) error { return nil }

func (p *minimalPlatform) CancelNotification(identifier string, typeID int32) error {
	return nil
}

func (p *minimalPlatform) StartNeighborMonitor(listener sbox.NeighborUpdateListener) error {
	return nil
}

func (p *minimalPlatform) CloseNeighborMonitor(listener sbox.NeighborUpdateListener) error {
	return nil
}

func (p *minimalPlatform) RegisterMyInterface(name string) {}

func (p *minimalPlatform) UsePlatformShell() bool { return false }

func (p *minimalPlatform) CheckPlatformShell() error { return nil }

func (p *minimalPlatform) OpenShellSession(user *sbox.PlatformUser, command string, environ sbox.StringIterator, term string, rows int32, cols int32) (sbox.ShellSession, error) {
	return nil, errors.New("shell not supported")
}

func (p *minimalPlatform) LookupUser(username string) (*sbox.PlatformUser, error) {
	return nil, errors.New("user lookup not supported")
}

func (p *minimalPlatform) LookupSFTPServer() (string, error) {
	return "", errors.New("sftp not supported")
}

func (p *minimalPlatform) ReadSystemSSHHostKey() (string, error) {
	return "", errors.New("ssh host key not supported")
}

func (p *minimalPlatform) TailscaleHostname() string { return "" }

func (p *minimalPlatform) UsePlatformBridge() bool { return false }

func (p *minimalPlatform) CreateBridge(options *sbox.BridgeOptions) (sbox.BridgeSession, error) {
	return nil, errors.New("bridge not supported")
}

// emptyInterfaceIterator 实现 sbox.NetworkInterfaceIterator，
// 零接口。方法集已在 Demo 里对
// experimental/libbox/platform.go（NetworkInterfaceIterator 接口）核实过。
type emptyInterfaceIterator struct{}

func (e *emptyInterfaceIterator) Next() *sbox.NetworkInterface { return nil }

func (e *emptyInterfaceIterator) HasNext() bool { return false }
