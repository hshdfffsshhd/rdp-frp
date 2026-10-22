# RDP over frp

参考 [QsacQ11/rdp](https://github.com/QsacQ11/rdp/blob/main/.github/workflows/main.yml) 的实现，用**你自己的 frps** 替代 Tailscale，不依赖任何第三方隧道服务。

- frps 地址：`47.98.228.129`
- frps 控制端口：`7000`（已实测可连通）
- 认证：无 token
- 适用系统：Windows 10/11 Pro、Enterprise、Windows Server（Home 版不能作为 RDP 服务端）

## 功能对照

| 原 workflow | 本项目 |
| --- | --- |
| 开启 RDP、关闭 NLA、开放 3389 防火墙、重启 TermService | `scripts/Enable-Rdp.ps1` |
| 创建 `RDP` 用户，生成 16 位随机强密码，加入 Administrators / Remote Desktop Users | `scripts/New-RdpUser.ps1`（Actions 可用 `RDP_PASSWORD` Secret 固定密码） |
| 安装 Tailscale | `scripts/Install-Frpc.ps1`（只装 frp 官方客户端） |
| `tailscale up` 建立隧道 | `scripts/Start-FrpTunnel.ps1`（frpc 连接 47.98.228.129:7000） |
| `Test-NetConnection` 验证 3389 | `scripts/Test-FrpTunnel.ps1`（TCP + 真实 RDP 握手） |
| 循环打印访问信息、保持连接 | `scripts/Watch-FrpTunnel.ps1`（frpc 掉线自动重启） |
| GitHub Actions 一键运行 | `.github/workflows/main.yml`（仍可用，但隧道走你的 frps） |

## 目录结构

```
.
├── .github/workflows/main.yml     # 主工作流（Tailscale 换成 frp）
├── .github/workflows/rdp-test.yml # 公开测试工作流（地址写入 RDP_INFO.txt，密码来自 Secret）
├── scripts/
│   ├── FrpHelpers.ps1             # 公共函数（随机密码、TOML、TCP/RDP 探测、状态文件）
│   ├── Enable-Rdp.ps1             # 开启 RDP + 防火墙 + 服务检查
│   ├── New-RdpUser.ps1            # 创建/重置 RDP 用户
│   ├── Install-Frpc.ps1           # 下载并安装 frpc
│   ├── Start-FrpTunnel.ps1        # 生成配置、启动 frpc、自动选端口、验证
│   ├── Test-FrpTunnel.ps1         # 独立验证隧道与 RDP 握手
│   ├── Watch-FrpTunnel.ps1        # 守护进程：掉线重启、定期打印访问信息
│   └── Invoke-RdpFrpSetup.ps1     # 一键入口：以上全部串起来
└── examples/frpc.toml.example     # 手动配置示例
```

## 快速开始（任意 Windows 机器，不需要 GitHub）

1. 用**管理员身份**打开 PowerShell。
2. 进入项目目录，执行：

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\scripts\Invoke-RdpFrpSetup.ps1 -Supervise
```

国内直连 GitHub 下载 frpc 很慢时，加 `-UseMirror`（只影响下载 frpc，运行时隧道仍然只走你的 frps）：

```powershell
.\scripts\Invoke-RdpFrpSetup.ps1 -UseMirror -Supervise
```

脚本会依次：开启 RDP → 创建 `RDP` 用户（未提供密码时生成随机密码）→ 下载 frpc → 自动选择一个可用的远程端口 → 建立隧道 → 用真实 RDP 握手验证 → 进入守护循环。屏幕上和 `C:\ProgramData\rdp-frp\state.json` 中都会有访问信息。

不要守护循环时去掉 `-Supervise`，frpc 会留在后台继续运行。

### 常用参数

```powershell
# 指定对外端口（例如只放行了 3389）
.\scripts\Invoke-RdpFrpSetup.ps1 -RemotePort 3389 -Supervise

# 使用本地已有的 frp 压缩包，完全不联网下载
.\scripts\Invoke-RdpFrpSetup.ps1 -FrpZip C:\downloads\frp_0.62.1_windows_amd64.zip -Supervise

# 下载加速（GitHub 直连慢时，改用指定镜像）
.\scripts\Invoke-RdpFrpSetup.ps1 -DownloadUrl "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v0.62.1/frp_0.62.1_windows_amd64.zip" -Supervise

# 自动按 gh-proxy.com -> ghproxy.net -> ghfast.top -> GitHub 顺序尝试下载
.\scripts\Invoke-RdpFrpSetup.ps1 -UseMirror -Supervise

# 使用固定密码，并在输出中隐藏密码
$env:RDP_PASSWORD = "你的固定密码"
.\scripts\Invoke-RdpFrpSetup.ps1 -HidePassword -Supervise

# 也可以直接传 -Password
.\scripts\Invoke-RdpFrpSetup.ps1 -Password "你的固定密码" -HidePassword -Supervise

# frps 以后加了 token
.\scripts\Invoke-RdpFrpSetup.ps1 -Token "你的token" -Supervise

# 只验证，不改系统
.\scripts\Test-FrpTunnel.ps1

# 守护已经在跑的隧道
.\scripts\Watch-FrpTunnel.ps1
```

`Invoke-RdpFrpSetup.ps1` 主要参数：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-ServerAddr` | `47.98.228.129` | frps 地址 |
| `-ServerPort` | `7000` | frps `bindPort` |
| `-RemotePort` | `0` | 对外端口；`0` 表示自动挑选 |
| `-PreferredRemotePorts` | 空 | 自动模式下优先尝试的端口列表 |
| `-MinRemotePort` / `-MaxRemotePort` | `30000` / `49999` | 自动挑选的随机范围 |
| `-MaxAttempts` | `30` | 自动模式下最多尝试的随机端口数量 |
| `-UserName` | `RDP` | 本地用户名 |
| `-Password` | 自动生成 | 指定密码；也可通过环境变量 `RDP_PASSWORD` 提供 |
| `-HidePassword` | 关闭 | 输出中隐藏密码（Actions 工作流使用） |
| `-Token` | 空 | frps `auth.token` |
| `-KeepNla` | 关闭 | 保留 NLA（默认按参考项目关闭） |
| `-FrpZip` | 空 | 使用本地 frp zip |
| `-DownloadUrl` | 空 | 自定义下载地址/镜像 |
| `-UseMirror` | 关闭 | 依次尝试常用 GitHub 下载镜像 |
| `-SkipRdpSetup` | 关闭 | 跳过系统 RDP 配置，只重开隧道 |
| `-SkipVerify` | 关闭 | 跳过隧道验证 |
| `-TcpOnly` | 关闭 | 只做 TCP 验证，不做 RDP 握手 |
| `-Supervise` | 关闭 | 前台守护循环 |

## GitHub Actions 方式（保持参考项目的用法）

把仓库推到 GitHub，进入 **Actions → RDP → Run workflow**。工作流仍然是 `workflow_dispatch` 手动触发、`windows-latest`、`timeout-minutes: 3600`，但不再安装 Tailscale，而是直接连你的 frps。

运行前先创建一个仓库 Secret：

- **Settings → Secrets and variables → Actions → New repository secret**
- Name：`RDP_PASSWORD`
- Value：你的固定密码

工作流会强制检查这个 Secret，缺失时直接失败。密码不会打印到日志或 job summary，脚本以 `-HidePassword` 输出 `********`。另外提供了 `.github/workflows/rdp-test.yml` 测试工作流：它会把地址、用户名写入 `RDP_INFO.txt`，密码同样只来自 Secret。

可选输入：

- `server_port`：frps 控制端口，默认 `7000`
- `remote_port`：对外端口，默认 `0`（自动）

运行后，在 **Establish frp Tunnel** 的日志和 job summary 里能看到地址、端口和用户名；密码来自仓库 Secret，不会显示。

## 连接方式

在 Windows 上打开“远程桌面连接”（`mstsc`）：

- 计算机：`47.98.228.129:<远程端口>`
- 用户名：`RDP`
- 密码：仓库 Secret `RDP_PASSWORD`（本地模式则看脚本输出，或用 `-HidePassword` 隐藏）

## 工作原理

```
mstsc ──TCP──▶ 47.98.228.129:<remotePort> (frps)
                        │
                        ▼
                   frpc (本机)
                        │
                        ▼
              127.0.0.1:3389 (TermService)
```

frpc 只主动向外连接 frps，不需要公网 IP、不需要路由器端口映射、不需要 Tailscale。frpc 与 frps 之间的流量默认开启 frp 加密（`transport.useEncryption = true`），可用 `-NoEncryption` 关闭。

### 自动选端口

`-RemotePort 0` 时，脚本会在 `30000-49999` 范围内随机生成 30 个互不重复的端口（默认 `-MaxAttempts 30`），逐个尝试，不使用 `3389`、`6000` 等常用端口兜底。每个端口都会：

1. 启动 frpc，等待日志出现 `start proxy success`；
2. 从本机连接 `47.98.228.129:<端口>`；
3. 发送一个 Mini RDP 握手包，确认端到端确实到达了 RDP 服务。

失败的端口会自动换下一个，直到 30 个候选都试完。如果 frps 配置了 `allowPorts` 或云安全组只开放了特定端口，请直接用 `-RemotePort` 指定。

## frps 端要求

默认假设你的 frps 是常见配置：

```toml
bindPort = 7000
# 没有 auth.token
# allowPorts 不限制，或包含脚本选中的端口
```

如果 frps 开了 `allowPorts`，远程端口必须落在允许范围内；如果云厂商安全组只放行了部分端口，也需要对应放行。实测 `47.98.228.129` 的 `7000`、`7001`、`7500`、`3389` 端口均能到达（`7001/7500/3389` 返回 RST），说明安全组限制较宽松，自动选端口通常可以直接成功。

## 安全说明

> **公开仓库提示**：地址和端口会出现在公开仓库的日志/`RDP_INFO.txt` 中，但密码来自仓库 Secret，不会打印。公开仓库仍只建议做短时间连通性测试，跑完立即取消；真实使用请把仓库设为私有。

这个项目的效果等同于把一台 Windows 的 RDP 暴露在公网 frps 的某个端口上，请至少注意：

- GitHub Actions 使用仓库 Secret `RDP_PASSWORD` 作为固定密码，并用 `-HidePassword` 隐藏输出；本地模式未提供密码时生成 16 位随机密码。`state.json` 只允许 Administrators 和 SYSTEM 读取。
- 默认按参考项目关闭了 NLA（`SecurityLayer=0`、`UserAuthentication=0`）以兼容老客户端；如果客户端支持，建议加 `-KeepNla` 保留 NLA。
- 你的 frps 没有 token，任何人都能连接控制端口并占用端口。建议后续给 frps 增加 `auth.token`、`allowPorts`，并用云安全组只放行 RDP 用的远程端口。
- 不需要时及时停止：`Get-Process frpc | Stop-Process -Force`，并可用 `Remove-LocalUser RDP` 删除账号。

## 常见问题

**`port not allowed` / 所有自动端口都失败**
frps 配置了 `allowPorts`。用 `-RemotePort` 指定一个允许范围内的端口。

**`frpc connected, but <ip>:<port> is not reachable`**
frps 接受了代理，但云安全组/服务器防火墙没放行该端口。放行端口，或 `-RemotePort` 换成已放行的端口。

**`Cannot reach the frps control port`**
检查 `47.98.228.129:7000` 是否可从当前网络访问，以及 frps 是否在运行。

**TCP 能通但 RDP 握手失败**
RDP 服务没起来。重新执行 `Enable-Rdp.ps1`；Home 版 Windows 无法作为 RDP 服务端。确认只是验证方式问题时可用 `-TcpOnly`。

**下载 frpc 失败**
用 `-UseMirror`，或 `-FrpZip` 指定本地 zip，或 `-DownloadUrl` 指定镜像地址。镜像只用于下载，运行时隧道仍然只连你的 frps。

**想换端口/重启隧道**
`.\scripts\Invoke-RdpFrpSetup.ps1 -SkipRdpSetup -Supervise`，会复用已创建的 RDP 用户，只重开隧道。
