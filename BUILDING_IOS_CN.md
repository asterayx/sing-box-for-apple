# macOS 本地构建 iOS 开发安装包

本文针对当前客户端 `1.14.0-beta.10`。它依赖同版本的 sing-box Go 核心；不同版本的 `Libbox.xcframework` 不能混用。

## 当前代码包含的改动

- `Patches/sing-box-without-vmess-vless.patch` 为核心增加 `without_vmess_vless` 与 `without_openvpn_openconnect_naive` 构建标签。启用后，VMess、VLESS、OpenVPN、OpenConnect、Naive 不再注册，配置检查会报 `unknown ... type`，对应实现包可被 Go 链接器裁掉。
- Apple 端统一通过裁剪后的 Libbox `ConfigurationValidator` 拒绝上述协议。
- iOS Packet Tunnel 保存的日志由 3000 条降为 300 条，避免长日志占用数 MiB 常驻内存。
- iOS 启动时只向 Packet Tunnel 传递 App Group 中的配置文件名，不再把完整 JSON 同时保存在启动参数、偏好快照和 Go 解析器中。
- Release 运行配置会在不改写用户原始配置的前提下补齐保守默认值：日志 `warn`、DNS cache 1024、TUN UDP 1 分钟/512 项、QUIC 小接收窗口与 multiplex 上限。仅严格 JSON 注入这些默认值；带注释、尾逗号或其他扩展语法的 JSON5/JSONC 原样交给 Libbox，避免转换改变语义。用户显式填写的值优先，只有成功转换且启用 `includeAllNetworks` 时才会强制 TUN 使用 `gvisor`；JSON5/JSONC 配置应自行明确填写该栈。TUIC 是例外：核心的 `with_low_memory` 构建还会为缺省字段设置 1 MiB 单流窗口、4 MiB 连接窗口、32 条入站流和 30 秒空闲超时，因此 JSON5/JSONC 的 TUIC 也能获得相同保护。
- Go heap soft limit 固定为 32 MiB，`GOGC` 等效值为 75；核心的 50 MiB Packet Tunnel 物理内存保护仍然启用。
- iOS 收到系统 critical memory-pressure 通知时会立即重置高占用网络连接并归还空闲页，不再等物理占用增长到约 45 MiB；这可能中断正在进行的 Speedtest，但优先保住 Packet Tunnel 进程。
- 手动启动的 iOS VPN 会在本次会话期间启用默认按需连接规则。若扩展仍被 jetsam，系统可以重新拉起；用户主动停止 VPN 时会同步关闭这条临时恢复规则。
- entitlement 使用 `BASE_PACKAGE_IDENTIFIER`/`APP_GROUP_IDENTIFIER`，不再写死上游作者的 App ID。

注意：Shadowsocks 的内置 `v2ray-plugin` 和一处旧 mux 地址判断仍会引用 `sing-vmess` 模块。这里删除的是 VMess/VLESS 协议能力，不保证依赖图中完全没有名为 `sing-vmess` 的模块。若还要移除该模块，必须同时放弃 Shadowsocks `v2ray-plugin` 兼容性。

## 1. 本机要求

- Xcode 26.2 或更高版本；项目最低 iOS 15，Widget 最低 iOS 18。
- Go 1.26（以当前核心 `go.mod` 为准）。
- SagerNet gomobile/gobind `v0.1.12`。
- `xcbeautify`。
- Apple Developer 账号、`Apple Development` 证书和一台已注册设备。
- 开发者后台为自有 App ID 开启 Network Extensions（Packet Tunnel）、App Groups 和 iCloud；主应用以及 `.extension`、`.intents`、`.widget`、`.fileprovider` 子 ID 需要能生成匹配的开发描述文件。

先检查：

```sh
xcodebuild -version
go version
security find-identity -v -p codesigning
```

`security` 必须至少显示一个有效的 `Apple Development` identity。没有证书时只能做无签名编译检查，不能导出可安装 IPA。

安装 Go mobile 工具：

```sh
go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
```

## 2. 准备依赖

初始化 Runestone 子模块：

```sh
cd /path/to/sing-box-for-apple
git submodule update --init --recursive
```

另外检出精确匹配的核心，不要使用 `v1.13.x`：

```sh
git clone --branch v1.14.0-beta.10 --depth 1 \
  https://github.com/SagerNet/sing-box.git /path/to/sing-box-core
```

Swift Package 依赖由 Xcode 按 `Package.resolved` 自动解析。首次构建需要访问 GitHub。

## 3. 裁掉 VMess/VLESS/OpenVPN/OpenConnect/Naive 并生成 Libbox

```sh
make apply_ios_core_protocol_patch \
  SING_BOX_SOURCE=/path/to/sing-box-core

make test_ios_core_protocol_patch \
  SING_BOX_SOURCE=/path/to/sing-box-core

make build_libbox_ios \
  SING_BOX_SOURCE=/path/to/sing-box-core
```

最后一个命令生成包含 iPhone arm64 和 Simulator arm64/x86_64 slice 的 Release `Libbox.xcframework`，并放到项目根目录。

## 4. 签名与导出开发 IPA

准备两个值：

- `TEAM_ID`：Apple Developer Team ID；本地默认值已设为 `EL6G8M5A96`。
- `BUNDLE_ID`：你拥有的唯一主 Bundle ID；本地默认值已设为 `com.asterayx.sfi.dev`。子 target 会自动派生后缀，App Group 为 `group.com.asterayx.sfi.dev`，iCloud container 为 `iCloud.com.asterayx.sfi.dev`。

让 Xcode 自动创建或下载描述文件并生成开发 IPA：

```sh
make package_ios_development_trimmed \
  SING_BOX_SOURCE=/path/to/sing-box-core \
  ALLOW_PROVISIONING_UPDATES=1
```

产物位于：

```text
build/SFI-development/*.ipa
```

如果 Libbox 已生成，可只运行 `make package_ios_development ...`。若不允许命令行访问开发者账号，先在 Xcode 打开 `sing-box.xcodeproj`，对 SFI 及其嵌入扩展选择同一个 Team、修复 Signing & Capabilities，再执行不带 `ALLOW_PROVISIONING_UPDATES=1` 的命令。

从 Xcode 安装到已配对的 iPhone：连接并解锁手机、开启 Developer Mode，在工具栏选择 `SFI` scheme 和目标 iPhone，然后按 `⌘R`。首次运行时按手机提示信任开发者。Team `EL6G8M5A96` 尚未获批 Multicast Networking capability，因此开发 entitlement 已移除此项；这不影响 Packet Tunnel，但局域网组播发现不可用。

安装到已注册设备可使用 Xcode 的 Devices and Simulators，或：

```sh
xcrun devicectl device install app --device <DEVICE_ID> build/SFI-development/*.ipa
```

## 5. 50 MB 内存目标

50 MB 指 Packet Tunnel extension 的物理内存，不是主 SwiftUI App，也不是磁盘 IPA 大小。当前核心已有三层保护：iOS 编译自动启用 `with_low_memory`（通用 buffer 从 32 KiB 降为 16 KiB，UDP buffer 从 16 KiB 降为 8 KiB）；Network Extension 默认总内存目标为 50 MiB；Go heap soft limit 为 32 MiB 且 GC 目标为 75。接近阈值时核心会清理 JSON 反射缓存、请求归还空闲页，必要时重置网络连接。

“低于 50 MB”不能只靠删 VMess/VLESS 保证：未使用的协议实现主要影响二进制和映射代码页，对运行时 heap 的收益通常很小。决定性因素依次是 TUN 栈、规则集、并发连接、QUIC/Tailscale 等重型功能和日志。

建议按以下顺序处理：

1. 不启用 `includeAllNetworks` 时使用 `"stack": "system"`；启用时强制使用 `"stack": "gvisor"`，因为该模式必须保留 gVisor 才能覆盖所有网络路径。运行配置转换器已自动执行这条规则。
2. 只加载实际命中的二进制 `.srs` rule-set；避免大体积内联 domain/IP 规则、重复规则集和一次加载多个国家全集。记录每个 rule-set 增加的稳态内存。
3. 日志使用 `warn` 或 `error`，不要在生产测量中使用 `debug`/`trace`。本项目已把 extension 的保留上限降到 300 条。
4. 控制并发连接和 multiplex stream 数。`with_low_memory` 只能缩小单连接 buffer；连接数线性增长仍会突破 50 MB。
5. OpenVPN、OpenConnect、Naive 已从注册表和 Go 依赖闭包裁掉；其余协议仍保留。没有使用时不要在配置中启用 Tailscale endpoint、WireGuard endpoint、Hysteria/TUIC/HTTP3。
6. DNS 内存 cache 已限制为核心允许的最小容量 1024。场景允许时仍可显式设置 `"disable_cache": true`，但要评估额外 DNS 请求带来的功耗和延迟。

推荐测试矩阵：冷启动空闲 5 分钟、1 条连接、100 条并发连接、rule-set 首次加载、网络切换和 30 分钟持续流量。每个场景记录峰值和回落后的稳态值；Release 构建在真机上用 Instruments Allocations/VM Tracker，并同时查看项目内 OOM Report。验收建议设为稳态不超过 45 MB、短时峰值不超过 48 MB，留出系统统计误差与突发流量余量。

如果 `system` 栈、精简规则、32 MiB Go soft limit 和 300 条日志后空闲基线仍超过 40 MB，下一步应制作“最小功能 Libbox”对照组：保留 `with_gvisor`，依次对比移除 `with_tailscale`、`with_quic`、`with_usbip`、`with_clash_api` 的版本，每次只改一组标签并重复同一测试矩阵。这样才能量化每项能力的真实成本，避免凭二进制大小推断运行内存。

当前本机 Release 实测磁盘产物从约 120 MB 降到约 104 MB，`Library.framework` 从约 87 MB 降到约 71 MB。它证明裁剪生效，但磁盘大小不能直接推导 Packet Tunnel 的物理内存；50 MB 目标必须在连接建立后用 Instruments 或 OOM Report 验证。

TUIC Speedtest 的 OOM Report 若显示 `memoryUsage = 40 MB`、`availableMemory = 12 MB`，同时 `heapAlloc` 只有约 16 MB，表示 40 MB 是 Packet Tunnel 的真实物理占用，而不是 Go heap；剩余部分来自 Go runtime span/stack、gVisor、映射页及 Network Extension/QUIC 相关分配。40 MB 报告通常由 iOS 的 critical memory-pressure 通知提前生成，不等于已经达到 50 MiB 的硬上限。应比较同一测速场景的峰值、测速是否中断，以及停止测速 1 分钟后的回落值。
