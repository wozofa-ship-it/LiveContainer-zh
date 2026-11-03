# sing-box 核心授权说明

LiveContainer 内嵌 sing-box 核心（版本 v1.14.4，SagerNet/sing-box，
GPLv3 协议），仅用于跑 TUIC 出站协议，与原有 libXray
核心并存、同一时刻只起一个核心。

本仓库不含 sing-box 源码。源码获取口径：

- 上游仓库：https://github.com/SagerNet/sing-box 的 v1.14.4 tag；
- 本仓库 `SingBoxGo/go.mod` 钉死的版本（`github.com/sagernet/sing-box v1.14.4`）
  即为对应源码；
- 本项目构建时从 Go 模块代理拉取 sing-box 源码编译进包。

如需源码副本，向分发者索取，或按上游 tag 自取。

本文件不构成法律意见，正式分发前由主 agent 再定。
