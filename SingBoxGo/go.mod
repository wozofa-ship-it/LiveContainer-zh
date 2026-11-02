module singboxgo

// sing-box 钉死 v1.14.4：与 TUIC Demo 真机验证过的版本一致，
// 不要随手升版，升版须重走 CI + 真机验证。
// go directive 说明：与 Demo 的 go.mod 一致写 1.24；
// 本机无 Go 工具链，未核实 sing-box 1.14.4 自身的 go directive，
// CI 若报 "requires go >= x.y"，把下面这行改成对应版本即可。
go 1.24

require github.com/sagernet/sing-box v1.14.4

// go.sum 由 CI 的 `go mod tidy` 生成（本机无 Go，无法预生成）。
// 切勿手写 go.sum。
// gomobile 的 tool 依赖（golang.org/x/mobile/cmd/gobind）
// 由 CI 步骤 `go get -tool` 写入，不预先手写进本文件。
