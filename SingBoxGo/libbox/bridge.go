// Package libbox 是 LiveContainer 侧 sing-box 核心的通用 gomobile 桥。
//
// 与 TUIC Demo 的 libbox 桥同源，但不再只服务某一个配置：
// S2/S3 传入任意合法的 sing-box JSON 配置，本桥只负责校验并起停核心，
// 不解析、不改写配置内容，不区分出站协议（TUIC、WireGuard 等一视同仁）。
//
// 为什么要包一层：gomobile bind 只能把 string/数字/error 类型暴露给 Swift，
// libbox 自身的 API 拿的是结构体与接口（SetupOptions、PlatformInterface、
// CommandServerHandler），绝不能漏到 Swift 边界。本包把平台侧全部在 Go 里
// 实现，只把 string/error 函数暴露给 Swift。
//
// 上游 API 出处（sing-box v1.14.4，已在 Demo 里对源码核实过）：
//   - libbox.Setup(options *SetupOptions) error
//     experimental/libbox/setup.go
//   - libbox.CheckConfig(configContent string) error
//     experimental/libbox/config.go
//   - libbox.NewCommandServer(handler CommandServerHandler,
//     platformInterface PlatformInterface) (*CommandServer, error)
//     experimental/libbox/command_server.go
//   - (*CommandServer).Start() error,
//     (*CommandServer).StartOrReloadService(configContent string,
//     options *OverrideOptions) error,
//     (*CommandServer).CloseService() error, (*CommandServer).Close()
//     experimental/libbox/command_server.go
//   - libbox.Version() string, experimental/libbox/setup.go
//
// 注意：v1.14.4 已没有老版 BoxService/NewService API（命令系统重构时已删），
// 不要凭旧记忆写 NewService。
package libbox

import (
	"errors"

	sbox "github.com/sagernet/sing-box/experimental/libbox"
)

var commandServer *sbox.CommandServer

// Setup 初始化 libbox 进程级状态，使用前必须先调一次，且只调一次。
// basePath 必须是 Documents 根目录（不是 Documents/singbox）：
// libbox 把命令服务绑在 basePath + "/command.sock"，Darwin AF_UNIX
// sun_path 上限 104 字节，App 容器前缀本身已占 76 字节，
// Documents/singbox 再加 "/command.sock" 会到 107 字节，真机上 bind
// 报 EINVAL；Documents 根目录则为 99 字节，刚好放得下。
// workingPath/tempPath 用 Documents/singbox。
func Setup(basePath, workingPath, tempPath string) error {
	return sbox.Setup(&sbox.SetupOptions{
		BasePath:    basePath,
		WorkingPath: workingPath,
		TempPath:    tempPath,
	})
}

// CheckConfig 只校验 sing-box JSON 配置，不启动任何东西。
// 启动前先调它，让 JSON/字段错误以配置错误的形式暴露，
// 而不是变成含糊的启动失败。
func CheckConfig(configJSON string) error {
	return sbox.CheckConfig(configJSON)
}

// StartService 用给定的 sing-box JSON 配置启动核心。
// 同一时刻只跑一个服务；想换配置重起，须先调 StopService。
// 配置内容原样交给核心，本函数不解析、不落盘、不打印。
func StartService(configJSON string) error {
	if commandServer != nil {
		return errors.New("service already started, stop it first")
	}
	server, err := sbox.NewCommandServer(&commandHandler{}, &minimalPlatform{})
	if err != nil {
		return err
	}
	if err := server.Start(); err != nil {
		server.Close()
		return err
	}
	// 空 OverrideOptions：nil 迭代器是安全的，iteratorToArray(nil)
	// 返回 nil（experimental/libbox/iterator.go）。
	if err := server.StartOrReloadService(configJSON, &sbox.OverrideOptions{}); err != nil {
		server.Close()
		return err
	}
	commandServer = server
	return nil
}

// StopService 停掉正在跑的服务并释放命令服务。
func StopService() error {
	if commandServer == nil {
		return errors.New("service not started")
	}
	err := commandServer.CloseService()
	commandServer.Close()
	commandServer = nil
	return err
}

// Version 返回 sing-box 版本串（如 "1.14.4"）。
func Version() string {
	return sbox.Version()
}
