# airportx

[English](./README.md) | **中文**

`airportx` 是一个 macOS Wi‑Fi 状态查看工具，可以在 **不触发位置权限（TCC）** 的前提下，输出当前服务、SSID、BSSID、信号质量、加密方式、信道、DHCP 元数据以及每个字段的来源路径，不依赖私有 `airport` 命令，也不执行主动的 CoreWLAN 扫描。

## 功能亮点

- **安全合规**：默认仅使用 SystemConfiguration；CoreWLAN 读取为只读且可通过 `--no-live` 禁用。
- **精细溯源**：字段按 SystemConfiguration → CoreWLAN → IORegistry → 已知网络 → Derived/Heuristic 的优先级合并，`--detail` 可显示具体来源。
- **智能选网**：自动跳过 VPN / `utun*`，选择活跃的 Wi‑Fi 服务；也支持固定接口查询。
- **可脚本化**：`--json` 输出单一、有序的 JSON 对象；配合 `--detail` 可直接做监控或日志上报。
- **单文件实现**：纯 Swift，带详细注释，便于审计和二次开发。

## 安装方式

### Homebrew Tap（推荐）

```bash
brew tap fjh658/airportx https://github.com/fjh658/airportx
brew install fjh658/airportx/airportx
```

安装后即可直接运行 `airportx`。工具不会尝试提升权限；如果系统拒绝访问已知网络数据库（Known Networks），相应字段会被省略。

### 从源码构建

```bash
# 生成 x86_64 + arm64 双架构二进制
make universal

# 可选：拷贝到 PATH（示例）
install -m 0755 airportx /usr/local/bin/airportx
```

### Swift Package Manager

```bash
swift build -c release --arch x86_64 --arch arm64
cp .build/apple/Products/Release/airportx ./airportx
```

SwiftPM 现已统一最低系统版本到 macOS 11，因此两个架构的 Release 构建可以直接
通用，无需额外脚本即可得到与 `make universal` 相同的产物。

## 使用方法

```text
airportx [options] [iface]

常用选项：
  -h, --help        查看帮助
  -V, --version     查看版本
  -v, --verbose     在 stderr 输出选网过程与环境信息
      --json        输出单个 JSON 对象（字段顺序固定）
      --detail      配合 --json 输出 `<key>Source` 溯源字段
      --ssid        仅输出 SSID
      --bssid       仅输出 BSSID
      --no-live     禁用 CoreWLAN 增强
      --no-color    禁用彩色输出
```

- 默认不带参数时，会自动选择当前活跃的 Wi‑Fi 服务。
- 指定接口（如 `airportx en1`）时严格绑定该接口，即使是有线网卡，也会输出 `Unknown (not associated)` 并返回 0。
- 未找到接口 → 退出码 3；参数错误 → 退出码 2。

### JSON + 溯源示例

```bash
airportx --json --detail
{
  "iface" : "en0",
  "ifaceSource" : "SystemConfiguration",
  "bssid" : "aa:bb:cc:dd:ee:ff",
  "bssidSource" : "CoreWLAN",
  …
}
```

来源字段说明：

| Source                 | 说明                                                         |
| ---------------------- | ------------------------------------------------------------ |
| `SystemConfiguration`  | 动态存储（运行时网络状态）                                   |
| `CoreWLAN`             | `CWWiFiClient` 的即时无线信息（仅在允许时使用）              |
| `IORegistry`           | 通过 `IO80211Interface` 获取的硬件属性                       |
| `KnownNetworks`        | 根据 `/Library/Preferences/com.apple.wifi.known-networks.plist` 推断 |
| `LeaseFile`            | 从 `/var/db/dhcpclient/leases` 读取的历史 DHCP 信息          |
| `Heuristic`            | 无法获取权威数据时的推测（如 DHCP server ≈ Router）         |
| `Derived`              | 由其它字段推导出的数值（如频段和 SNR）                       |

## 工作原理

1. 使用 SystemConfiguration 获取服务、接口、Router、DHCP Server Identifier。
2. 可选：通过 CoreWLAN 获取实时 SSID/BSSID/RSSI/Noise/Channel 等信息。
3. 如被拒绝，再退到 IORegistry 读取频道、国家码等缓存字段。
4. 读取系统级 known-networks plist（使用 `O_NOFOLLOW` 并校验 UID），通过 DHCP / Router / Channel 匹配找回 SSID/BSSID/Security。
5. 计算派生字段，如频段和 SNR。

## 安全注意事项

- 不调用 CoreLocation，不依赖私有 `airport` 工具。
- 程序不会尝试提升权限；仅在可访问时读取系统已知网络（Known Networks），无法访问则跳过。
- 使用 `airportx` 不需要 `sudo`。

## 开发者提示

```bash
swiftc -typecheck -parse-as-library airportx.swift
swiftc airportx.swift -o airportx
# 或者：
make universal

./airportx --json --detail
```

项目为单文件实现，欢迎提 Issue 或 PR。提交前请确保通过 `swiftc -typecheck`。

## 许可证

MIT License（如仓库根目录包含 `LICENSE` 文件，以文件内容为准）。

## 致谢

- Apple SystemConfiguration / IOKit / CoreWLAN 提供的公共接口。
- 社区对 macOS Wi‑Fi 诊断和 known-networks 数据结构的分享与分析。
