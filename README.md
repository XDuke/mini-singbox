# mini-singbox

[![CI](https://github.com/XDuke/mini-singbox/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/XDuke/mini-singbox/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/XDuke/mini-singbox)](https://github.com/XDuke/mini-singbox/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

`mini-singbox` 是面向个人、小型 NAT VPS、LXC、Alpine Linux 和 128 MiB 容器的精简 sing-box
服务端。它只保留 VLESS Reality、Hysteria2 和 AnyTLS，使用官方 sing-box
内核，不包含面板、多用户、订阅服务、流量统计、管理 API、TUN、WireGuard、限速或
自动更新守护进程。当前正式版是 `v1.1.1`；本分支为 `v1.2.0` 候选版，继续使用官方
sing-box `v1.13.18`。

## v1.2.0 候选版

这一轮在不增加常驻管理面板、不提高默认 128 MiB 资源上限的前提下，补齐 Alpine 与
OCI 容器运行链，并保持小虚拟机只下载已构建二进制、不在目标机编译。

- 一行安装改为“Release 资产优先”：先验证独立固定的 minisign 公钥、签名校验清单、
  版本元数据和每个部署文件，再执行安装；`v1.1.1` 仍保留兼容回退路径；
- 原生支持 Debian/Ubuntu `systemd` 与 Alpine `OpenRC`，两者都有非 root 用户、开机
  自启、启动稳定性、进程身份、配置和监听端口检查；
- 完整运行 OpenRC 的 Alpine 容器使用 `openrc-container` profile，仍由 OpenRC 自启；
  没有真实 init 的服务商容器才使用 `external` 前台入口；
- 所有容器 profile 与 OCI 内强制禁止自动写宿主 TCP sysctl；TCP 调优只能由真正拥有
  宿主内核的原生 systemd/OpenRC 主机执行；
- 新增 rootless Podman/Docker 管理工具，提供 `init/up/status/logs/check/upgrade/rollback`、
  二维码、事务续证和保留配置卸载；默认只读根文件系统、空 capabilities、128 MiB 与
  64 PID 上限；
- 正式版发布流程增加 `linux/amd64`、`linux/arm64` GHCR 镜像、不可变 digest、GitHub
  provenance，以及 Alpine 3.23/3.24、OpenRC 和 rootless Podman CI 验收。
- 容器首次部署如果没有显式提供公网端口，会醒目标记端口只是“按内部端口假定”，并在
  `status` 中持续提示核对服务商 NAT 映射，避免监听正常却生成不可用的客户端配置；
- AnyTLS 同时生成三种认证交付：sing-box 出站 JSON、Mihomo 代理 YAML，以及仅供当前
  v2rayN 导入的内部格式链接/二维码；不再把 v2rayN 二维码误称为 Clash 通用二维码；
- 新增 `export anytls <sing-box|mihomo|v2rayn>`，`qr anytls` 和 `qr all` 在二维码下方
  显示协议链接及另外两种导出路径；证书续期会同步重建全部三种交付；
- OpenRC 不再依赖容器里可能不存在的 syslog socket；服务输出写入 root 管理、仅服务组
  可追加的私有本地日志，启动时超过 1 MiB 会保留最近 512 KiB，`mini-singboxctl logs`
  可直接读取真实错误。
- 低内存升级不再同时复制“下载文件、旧二进制备份、新安装文件”三份大文件：验证后的
  二进制优先在安装文件系统硬链接暂存，旧二进制直接重命名进入回滚目录，再原子切换；
  仍保留跨文件系统回退和失败回滚。

Alpine、外部 supervisor 和 OCI 的边界与测试方法见
[Alpine 与容器运行指南](docs/alpine-container.md)。

## v1.1.1 安全更新

`v1.1.1` 是不轮换现有 UUID、密码、Reality 私钥或 TLS 证书的安全维护版本。旧版
AnyTLS 部署会在升级时自动清除未认证证书的交付文件并生成安全出站配置；AnyTLS
客户端需要重新导入 `/etc/mini-singbox/client-anytls-sing-box-outbound.json`。Reality 与
Hysteria2 客户端在普通升级时无需重新导入，只有主动续证或重新生成凭据时例外。

- 修复官方 `curl | bash` 命令在 `set -u` 下读取未定义 `BASH_SOURCE` 的问题，并加入
  标准输入执行回归测试；
- bootstrap 独立内置 minisign 公钥，不再从待验证的 Release 标签取得信任根；
- AnyTLS 自签名部署默认不再生成无法携带证书认证信息的通用 URI/二维码，改为输出
  内嵌服务器证书且保持 `insecure=false` 的 sing-box 出站配置；
- `generate --force` 改为整组事务：所有新文件完成落盘和内容校验后才清理旧副本，
  中途失败会逆序恢复；
- 新增只续 TLS 证书的 `certificate renew`，会重建客户端 pin、验证服务并在失败时
  完整回滚；
- 卸载增加独立的 `PURGE_BACKUPS=1`，严格校验所有布尔开关，并限制配置、密钥、证书
  和交付路径使用符号链接；
- 修复 Docker Compose 自定义协议端口只影响部分生成或映射的问题；
- 正式支持范围收敛为具备完整部署、回滚和 CI 覆盖的 systemd，移除旧的重复
  `install.sh`/OpenRC 发布入口。

## v1.1.0 更新

`v1.1.0` 是一次面向小内存 VPS 的运维与网络安全升级，普通升级会保留现有 UUID、
密码、Reality 私钥和 TLS 证书，客户端无需重新导入。

- 新增部署后自动 TCP 调优：本地识别 Reality/AnyTLS TCP 工作负载、cgroup v1/v2
  有效内存和内核能力，只应用可验证的 BBR、FQ 与 MTU 黑洞探测安全项；
- 新增 `tune detect/plan/apply/verify/status/rollback`，所有写入都有前置基线、回读验证、
  所有权漂移保护和精确回滚；纯 Hysteria2 部署不会修改 TCP；
- 新增 `mini-singbox-update` 与 `mini-singbox-uninstall`，继续保持按需执行、无常驻进程；
- 一行部署入口现在解析最新不可变正式标签，部署器仍验证 minisign、SHA-256、ELF
  架构、静态链接、版本和完整 Git 提交；
- 官方 sing-box 从 `v1.13.16` 更新到 `v1.13.18`，构建工具链更新到包含标准库安全修复的
  Go `1.26.6`；
- 自动调优不测速、不访问公共 DNS，不修改 buffer、RPS/RFS、路由、防火墙、内核、
  模块或流量整形；可用 `MINI_SINGBOX_AUTO_TUNE=0` 完全关闭。

从 `v1.0.0` 升级只需重新运行下方“一行部署”命令。升级前后的配置备份和 TCP 调优
基线相互独立；如需先观察计划，可在升级后执行
`sudo mini-singboxctl tune status`。

## 主要特点

- 单进程、单个官方 sing-box Box，每个协议只有一个本地凭据；
- 严格的专用 JSON Schema，拒绝未知字段和任意原生 sing-box 配置；
- `check`、`generate` 和空载运行不执行项目级主动联网；
- 自动探测公网 IPv4/IPv6，并从经过 TLS 1.3、HTTP/2 和证书验证的候选中选择
  Reality 握手目标；
- 支持共享 NAT 的公网端口与内部监听端口分离；
- 自动生成 Reality、Hysteria2 分享链接和二维码，以及经过证书认证的 AnyTLS
  sing-box、Mihomo 和 v2rayN 客户端交付；
- 只下载当前精确版本的 CI 静态二进制，不在小虚拟机编译；
- 128 MiB 升级优先使用硬链接暂存和重命名切换二进制，减少大文件复制产生的页缓存峰值；
- 正式版本验证 minisign 签名、SHA-256、ELF 架构、静态链接、版本和 Git 提交；
- 部署后离线检测内核、cgroup 有效内存和 TCP 能力，只应用可验证、可持久化、可回滚的
  安全核心调优；
- systemd/OpenRC/external/OCI 均使用非 root 进程，默认 `GOMAXPROCS=1`、
  `GOMEMLIMIT=48MiB`、`GOGC=70`；容器模式不写宿主 sysctl。

## 协议和默认端口

| 协议 | 内部端口 | 传输 | 客户端交付 |
|---|---:|---|---|
| VLESS Reality | `20001/tcp` | TCP + Reality | `vless://`、二维码 |
| Hysteria2 | `20002/udp` | QUIC/UDP + TLS 1.3 | `hysteria2://`、二维码 |
| AnyTLS | `20003/tcp` | TCP + TLS 1.3 | sing-box JSON、Mihomo YAML、v2rayN 专用二维码 |

Reality 与 AnyTLS 必须使用不同 TCP 端口；Hysteria2 必须映射 UDP。共享 NAT
服务器可以使用任意不同的公网端口映射到以上内部端口。

> 共享 NAT 容器必须先在服务商后台创建三条映射。脚本能自动获取公网 IP，但无法从
> 容器内部猜出服务商分配的公网端口；只存在 SSH 映射时，三个代理协议都会不通。
> 具体操作见[共享 NAT VPS 与端口映射](docs/nat-vps.md)。

## 一行部署

支持 Debian 12/13、Ubuntu 24.04 的 systemd 环境以及 Alpine Linux 3.23/3.24 的
OpenRC 环境。Debian/Ubuntu 安装和以后升级运行：

```bash
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

Alpine 的 BusyBox `ash` 支持相同的失败传播；基础镜像自带 `wget`，入口启动后会自动补齐
`curl`、CA 证书和校验工具，因此使用：

```sh
sh -c 'set -o pipefail; wget -qO- https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | sh'
```

非 root 环境会自动使用已有的 `sudo` 或 `doas`；最小 Alpine 容器两者都没有时应直接在
root shell 中执行。

`bootstrap.sh` 只负责解析 GitHub 最新正式版和验证部署资产。`v1.2.0` 起不会为正常
安装克隆仓库：它使用入口脚本内置的独立 minisign 公钥验证签名校验清单，再逐项验证
版本元数据、部署器、控制工具、systemd/OpenRC/external 文件；`deploy.sh` 随后验证
SHA-256、ELF、版本和完整 Git 提交。目标虚拟机只下载静态二进制，不编译。旧的
`v1.1.1` 固定安装仍自动使用经验证的兼容路径。

普通重跑会先备份并保留 UUID、密码、Reality 私钥和证书；只有显式设置
`MINI_SINGBOX_REGENERATE=1` 才会轮换凭据。固定到当前正式版：

```bash
MINI_SINGBOX_VERSION=v1.1.1 bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

短命令的第一跳来自可变的 `main` 分支，适合日常安装和升级；正式负载仍来自精确、
不可变并带签名的 Release。需要先审阅入口脚本时：

```sh
curl -fL --proto '=https' --tlsv1.2 -o bootstrap.sh \
  https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

完全固定、分步审阅方式：

```sh
git clone --branch v1.1.1 --depth 1 https://github.com/XDuke/mini-singbox.git
cd mini-singbox
test "$(git cat-file -t refs/tags/v1.1.1)" = tag
sudo ./scripts/deploy.sh
```

部署器会自动：

1. 识别 amd64/arm64、systemd、OpenRC 和外部 supervisor 容器；
2. 安装最少的运行和校验工具；
3. 探测公网地址并优选 Reality 目标；
4. 检查端口占用和协议端口冲突；
5. 下载正式 Release 的静态二进制；
6. 验证 minisign、SHA-256、ELF 架构、静态链接、版本和完整提交；
7. 生成安全凭据、证书、Reality/Hysteria2 二维码和三种认证证书的 AnyTLS 客户端交付；
8. 以低内存暂存/重命名方式备份并切换二进制，安装非 root 服务并检查配置、进程身份、
   监听端口和启动状态；external 模式只准备前台入口，明确交给外层 supervisor 启动；
9. 仅在真正拥有宿主内核的 systemd/OpenRC 环境，为 Reality/AnyTLS 自动执行保守的
   TCP 检测、计划、应用和回读验证；
10. 为已有安装和 TCP 调优分别保留精确回滚状态。

脚本不会修改云平台安全组、防火墙、NAT 映射、内核版本、路由、RPS/RFS 或流量整形。

## 共享 NAT 部署

先在服务商面板创建三条映射，再执行：

```bash
MINI_SINGBOX_PUBLIC_REALITY_PORT=51165 \
MINI_SINGBOX_PUBLIC_HY2_PORT=25421 \
MINI_SINGBOX_PUBLIC_ANYTLS_PORT=36279 \
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

- Reality：公网 TCP → `20001/tcp`
- Hysteria2：公网 UDP → `20002/udp`
- AnyTLS：公网 TCP → `20003/tcp`

示例数字必须替换成面板实际分配值。完整说明见
[NAT VPS 指南](docs/nat-vps.md)。

## 常用部署选项

把下表变量直接放在上方一行部署命令前；未设置的选项保持默认值。

| 目的 | 一行部署命令前缀 |
|---|---|
| 保留配置升级/重装 | 无，直接重跑 |
| 固定当前正式版 | `MINI_SINGBOX_VERSION=v1.1.1` |
| 重新生成全部凭据 | `MINI_SINGBOX_REGENERATE=1` |
| 只刷新公网地址、端口和二维码 | `MINI_SINGBOX_REFRESH_DELIVERY=1`，并提供新的公网值 |
| 强制使用 IPv4 | `MINI_SINGBOX_IP_FAMILY=4` |
| 强制使用 IPv6 | `MINI_SINGBOX_IP_FAMILY=6` |
| 只启用 Reality | `MINI_SINGBOX_PROTOCOLS=reality` |
| 只启用 Hysteria2 | `MINI_SINGBOX_PROTOCOLS=hy2` |
| 只启用 AnyTLS | `MINI_SINGBOX_PROTOCOLS=anytls` |
| Reality + AnyTLS | `MINI_SINGBOX_PROTOCOLS=reality,anytls` |
| 关闭部署后 TCP 调优 | `MINI_SINGBOX_AUTO_TUNE=0` |
| 危险兼容：生成 AnyTLS 通用二维码 | `MINI_SINGBOX_ALLOW_INSECURE_ANYTLS_SHARE=1` |

例如重新生成全部凭据：

```bash
MINI_SINGBOX_REGENERATE=1 bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

普通升级不会轮换 UUID、密码或私钥。只有 `MINI_SINGBOX_REGENERATE=1` 会使旧客户端
配置失效。修改 NAT 公网端口时使用 `MINI_SINGBOX_REFRESH_DELIVERY=1`。

AnyTLS 通用 URI 没有跨客户端统一的自签证书 pin 字段，因此默认改用带认证材料的
v2rayN 专用二维码；sing-box 和 Mihomo 使用各自的导出文件，不共用该二维码。
`MINI_SINGBOX_ALLOW_INSECURE_ANYTLS_SHARE=1` 生成的链接带有 `insecure=1`，只能用于
明确接受中间人风险的临时兼容测试，不是推荐配置。

## 内核与项目升级

mini-singbox 项目版本和内置 sing-box 内核版本相互独立。仓库每周只为官方
`github.com/sagernet/sing-box` 检查更新并创建依赖 PR，不自动合并、不直接替换服务器
二进制。每次升级必须通过单元测试、竞态测试、漏洞扫描、禁用功能审计、amd64/arm64
静态构建和发布签名，审核后再发布新的 mini-singbox 正式版。

服务器无需运行更新守护进程。`v1.1.0` 起可执行 `sudo mini-singbox-update`，或重跑
同一条一行部署命令，即可升级并保留凭据；`sudo mini-singboxctl version` 会同时显示
mini-singbox 与 `sing_box_version`。

## 全部部署变量

| 变量 | 默认值 | 用途 |
|---|---|---|
| `MINI_SINGBOX_VERSION` | GitHub 最新正式版 | bootstrap 固定精确项目版本 |
| `MINI_SINGBOX_RUNTIME` | `auto` | `auto`、`systemd`、`openrc` 或 `external`；通常不要手动指定 |
| `MINI_SINGBOX_PROTOCOLS` | `reality,hy2,anytls` | 启用协议，逗号分隔 |
| `MINI_SINGBOX_LISTEN` | `::` | 内部监听 IP 字面量 |
| `MINI_SINGBOX_REALITY_PORT` | `20001` | Reality 内部 TCP 端口 |
| `MINI_SINGBOX_HY2_PORT` | `20002` | Hysteria2 内部 UDP 端口 |
| `MINI_SINGBOX_ANYTLS_PORT` | `20003` | AnyTLS 内部 TCP 端口 |
| `MINI_SINGBOX_PUBLIC_ADDRESS` | 自动探测 | 客户端连接的公网 IP/域名 |
| `MINI_SINGBOX_PUBLIC_REALITY_PORT` | 同内部端口 | Reality 公网 TCP 端口 |
| `MINI_SINGBOX_PUBLIC_HY2_PORT` | 同内部端口 | Hysteria2 公网 UDP 端口 |
| `MINI_SINGBOX_PUBLIC_ANYTLS_PORT` | 同内部端口 | AnyTLS 公网 TCP 端口 |
| `MINI_SINGBOX_IP_FAMILY` | `auto` | `auto`、`4` 或 `6` |
| `MINI_SINGBOX_REALITY_SERVER_NAME` | 自动优选 | Reality Server Name |
| `MINI_SINGBOX_REALITY_HANDSHAKE` | 优选域名的 `443` | Reality 握手 `HOST:PORT` |
| `MINI_SINGBOX_REALITY_CANDIDATES` | 内置四个域名 | 最多 12 个候选域名 |
| `MINI_SINGBOX_TLS_SAN` | 公网地址 | HY2/AnyTLS 证书 SAN |
| `MINI_SINGBOX_AUTO_DETECT` | `1` | `0` 关闭公网地址和目标探测 |
| `MINI_SINGBOX_AUTO_TUNE` | `1` | `0` 关闭部署后的保守 TCP 调优 |
| `MINI_SINGBOX_REGENERATE` | `0` | `1` 备份并重新生成配置 |
| `MINI_SINGBOX_REFRESH_DELIVERY` | `0` | `1` 保留凭据刷新交付文件 |
| `MINI_SINGBOX_ALLOW_INSECURE_ANYTLS_SHARE` | `0` | 危险兼容开关；`1` 才生成未认证证书的 AnyTLS URI/二维码 |
| `MINI_SINGBOX_BACKUP_KEEP` | `5` | 成功部署后保留最近 1–50 份受管回滚备份 |

直接运行已审阅 Git checkout 内的 `scripts/deploy.sh` 时还可使用
`MINI_SINGBOX_RELEASE_TAG` 和 `MINI_SINGBOX_MINISIGN_PUBKEY_FILE`。短命令 bootstrap
会固定前者为解析出的精确标签，并把后者固定为入口脚本内置公钥，不接受环境覆盖。

关闭自动探测时必须显式提供所需值：

```bash
MINI_SINGBOX_AUTO_DETECT=0 \
MINI_SINGBOX_PUBLIC_ADDRESS=203.0.113.10 \
MINI_SINGBOX_TLS_SAN=203.0.113.10 \
MINI_SINGBOX_REALITY_SERVER_NAME=www.example.com \
MINI_SINGBOX_REALITY_HANDSHAKE=www.example.com:443 \
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

## 运行模式与快捷命令

安装器自动选择运行模式：真实 Debian/Ubuntu 主机使用 systemd；原生 Alpine 与 PID 1
确实由 OpenRC 管理的 Alpine 容器使用 OpenRC；没有真实 init 的服务商容器使用
external。OpenRC 容器记录 `openrc-container` profile，由 OpenRC 管理服务，但禁止写
宿主 TCP sysctl。通常不允许隐式跨模式迁移；旧版误判的 inactive external 安装可在
确认 OpenRC 为 PID 1 后事务迁移，若 external 进程仍运行则拒绝迁移。

| 环境 | 启动与自启所有者 | 常用命令 |
|---|---|---|
| systemd | `mini-singbox.service` | `sudo systemctl status/restart mini-singbox` |
| Alpine OpenRC（原生或完整 init 容器） | `/etc/init.d/mini-singbox` | `sudo rc-service mini-singbox status/restart` |
| 服务商容器 | 外层 supervisor | 前台命令 `/usr/local/bin/mini-singbox-run` |
| rootless Podman/Docker | `mini-singbox-containerctl` | `init/up/status/logs/upgrade/rollback/down` |

external 模式安装完成后不会偷偷后台运行。应在服务商提供的 supervisor 中把启动用户设为
`mini-singbox`，命令设为 `/usr/local/bin/mini-singbox-run`；若 supervisor 只能以 root
启动，入口会先通过 `runuser` 降权。停止 supervisor 后才能升级或续证。

OCI 正式镜像发布到 `ghcr.io/xduke/mini-singbox`。生产使用应从 Release 的
`oci-digests.txt` 复制完整 `镜像@sha256:...`，不要只依赖可移动的 `latest`。安装
`mini-singbox-containerctl` 后，一套完整命令是。该工具会同时确认 Podman/Docker
守护端确实以 rootless 模式运行；仅把普通用户加入 rootful Docker 的 `docker` 组不会通过：

```sh
export MINI_SINGBOX_IMAGE='ghcr.io/xduke/mini-singbox@sha256:REPLACE_WITH_RELEASE_DIGEST'
export MINI_SINGBOX_PUBLIC_ADDRESS='proxy.example.com'
export MINI_SINGBOX_REALITY_SERVER_NAME='www.example.com'
export MINI_SINGBOX_REALITY_HANDSHAKE='www.example.com:443'
export MINI_SINGBOX_TLS_SAN='proxy.example.com'

mini-singbox-containerctl init
mini-singbox-containerctl up
mini-singbox-containerctl status
mini-singbox-containerctl logs 100
mini-singbox-containerctl qr all
mini-singbox-containerctl check
mini-singbox-containerctl certificate renew
mini-singbox-containerctl upgrade 'ghcr.io/xduke/mini-singbox@sha256:NEW_DIGEST'
mini-singbox-containerctl rollback
mini-singbox-containerctl down
mini-singbox-containerctl uninstall
```

`init` 绝不覆盖已有凭据；`upgrade` 会先拉取并离线检查新镜像，再切换并观察启动，失败
恢复旧镜像；`rollback` 使用上一次升级记录的镜像 ID；`certificate renew` 先停容器、备份
完整配置、生成和验证新证书，失败恢复原配置。容器内没有 `tune apply` 路径，宿主网络
调优必须在宿主上单独完成。

## 运维命令

主机一键部署会安装四个按需工具，均不常驻、不监听端口。`mini-singboxctl`
严格离线；`mini-singbox-update` 只在用户显式升级时访问 GitHub，
`mini-singbox-containerctl` 只在显式拉取/升级 OCI 镜像时访问所选镜像仓库。

| 命令 | 作用 |
|---|---|
| `sudo mini-singbox-update` | 安装/升级到最新正式版，保留现有凭据 |
| `sudo mini-singbox-uninstall` | 卸载服务和程序，默认保留配置与密钥 |
| `mini-singbox-containerctl help` | 查看 rootless Podman/Docker 全部生命周期命令（不要用 sudo） |
| `sudo mini-singboxctl status` | 检查版本、配置、服务、内存、任务、端口和证书 |
| `sudo mini-singboxctl check` | 仅校验配置，不启动监听器 |
| `sudo mini-singboxctl certificate` | 检查 TLS 证书到期时间 |
| `sudo mini-singboxctl certificate renew` | 只续 TLS 证书并重建 pin 交付；失败自动恢复旧配置 |
| `sudo mini-singboxctl qr reality` | Reality 二维码及其协议链接 |
| `sudo mini-singboxctl qr hy2` | Hysteria2 二维码及其协议链接 |
| `sudo mini-singboxctl qr anytls` | v2rayN 专用 AnyTLS 二维码、链接及其他认证导出路径 |
| `sudo mini-singboxctl qr all` | 依次显示三个协议的二维码并在每个二维码下附协议链接 |
| `sudo mini-singboxctl export anytls sing-box` | 输出内嵌服务器证书的 sing-box AnyTLS 出站 JSON |
| `sudo mini-singboxctl export anytls mihomo` | 输出带服务器证书 SHA-256 固定的 Mihomo AnyTLS YAML |
| `sudo mini-singboxctl export anytls v2rayn` | 输出可复制或扫码导入 v2rayN 的内部格式链接 |
| `sudo mini-singboxctl logs 100` | 最近 100 行服务状态和日志 |
| `sudo mini-singboxctl tune detect` | 只检测环境、有效 RAM、工作负载和系统能力 |
| `sudo mini-singboxctl tune plan` | 生成逐项 TCP 调优计划，不修改系统 |
| `sudo mini-singboxctl tune apply --dry-run` | 显示自动应用内容，不写系统 |
| `sudo mini-singboxctl tune apply` | 应用高置信度安全项并立即回读验证 |
| `sudo mini-singboxctl tune verify` | 检查运行值、持久化文件和所有权漂移 |
| `sudo mini-singboxctl tune status` | 同时显示环境、当前计划和管理状态 |
| `sudo mini-singboxctl tune rollback` | 精确恢复应用前原值并移除本项目持久化文件 |
| `sudo mini-singboxctl version` | 二进制版本和构建身份 |

二维码、其下方链接和 AnyTLS 导出都包含完整客户端凭据，不要截图或复制到公开聊天、
Issue 或日志。sing-box 用户把导出的 JSON 对象合并到客户端 `outbounds`；Mihomo/Clash
Meta 用户把 YAML 中的代理对象合并到 `proxies`。v2rayN 用户可复制链接或扫码导入。
原版 Clash 不支持 AnyTLS，也不能识别 v2rayN 内部二维码。

三种默认交付都对当前自签名证书做认证：sing-box 和 v2rayN 内嵌服务器证书并保持
`insecure=false`；Mihomo 允许自签名证书通过系统 CA 检查之外的路径，但继续固定完整
服务器证书的 SHA-256 指纹。标准 `anytls://` 不能携带这些认证材料，仅在显式设置
`MINI_SINGBOX_ALLOW_INSECURE_ANYTLS_SHARE=1` 时作为不安全兼容项生成。

自签名证书有效期为 365 天。续证命令不会改变 UUID、协议密码或 Reality 密钥；它先在
临时目录生成并校验完整交付文件，备份当前配置，停服切换并确认服务稳定，失败则恢复。
证书 pin 已变化，因此 Hysteria2 和 AnyTLS 客户端必须重新导入新的交付文件。

直接控制 systemd：

```sh
sudo systemctl status mini-singbox --no-pager
sudo systemctl restart mini-singbox
sudo journalctl -u mini-singbox -n 100 --no-pager
sudo journalctl -u mini-singbox -f
```

Alpine OpenRC：

```sh
sudo rc-service mini-singbox status
sudo rc-service mini-singbox restart
sudo rc-service mini-singbox stop
sudo rc-service mini-singbox start
sudo rc-update show default | grep mini-singbox
```

## 部署后自动 TCP 调优

自动调优严格区分协议：Reality 和 AnyTLS 是 TCP 工作负载；Hysteria2 是 UDP/QUIC，
不会被宣传为受到 BBR 或 TCP sysctl 优化。若只启用 Hysteria2，TCP 计划全部跳过。

默认自动应用范围只有：

- 内核已经在 `tcp_available_congestion_control` 注册 `bbr` 时，选择 `bbr`；
- 能从已加载模块或内核 built-in 配置证明 `fq` 已可用且 sysctl 可写时，将 `fq` 设为
  后续新建 qdisc 的默认值；不会加载模块或用 `tc` 替换当前网卡已有 qdisc；
- 将 `tcp_mtu_probing` 设为 `1`，仅在检测到 TCP PMTU 黑洞后启用探测。

`tcp_slow_start_after_idle` 默认保持原值。第一轮不修改 TCP/UDP buffer、`tcp_mem`、
RPS/RFS、`initcwnd`、ECN、路由、MTU/MSS、`tc` 或防火墙，不加载模块，不更换内核，
也不访问测速站、公共 DNS 或项目服务器。cgroup v1/v2 限制会参与有效内存和风险级别
判断，但本轮不会据此扩大 socket buffer。

任何写入前都会在 root 专属的 `/var/lib/mini-singbox/tune/` 保存前置基线；持久化只写入
`/etc/sysctl.d/90-mini-singbox-tune.conf`。应用失败会恢复已改变的值。回滚只恢复仍等于
mini-singbox 写入值的参数；如果管理员或服务商后来改过它，工具报告漂移并拒绝覆盖。
卸载程序会先完成调优回滚，失败时保留程序供人工处理。

已知套餐带宽和常见 RTT 时可以生成仅供观察的 BDP：

```sh
sudo mini-singboxctl tune plan --bw 500 --rtt 80
```

该 BDP 不会自动转换为 buffer 参数。完整设计、安全边界和故障处理见
[TCP 调优说明](docs/tcp-tuning.md)。

## 配置、二维码与备份

| 路径 | 权限 | 内容 |
|---|---:|---|
| `/etc/mini-singbox/config.json` | `0600` | 严格服务端配置 |
| `/etc/mini-singbox/client-info.json` | `0600` | 客户端信息和分享 URI |
| `/etc/mini-singbox/client-anytls-sing-box-outbound.json` | `0600` | 内嵌服务器证书的 AnyTLS sing-box 出站配置 |
| `/etc/mini-singbox/client-anytls-mihomo.yaml` | `0600` | 固定服务器证书 SHA-256 的 Mihomo AnyTLS 代理配置 |
| `/etc/mini-singbox/share-anytls-v2rayn.txt` | `0600` | 内嵌服务器证书的 v2rayN 专用 AnyTLS 分享链接 |
| `/etc/mini-singbox/share-anytls-v2rayn.png` | `0600` | 上述 v2rayN 专用链接的二维码 |
| `/etc/mini-singbox/deployment-info.txt` | `0600` | 非凭据部署摘要 |
| `/etc/mini-singbox/reality.key` | `0600` | Reality 私钥 |
| `/etc/mini-singbox/tls.key` | `0600` | TLS 私钥 |
| `/etc/mini-singbox/tls.crt` | `0644` | 365 天自签名证书 |
| `/etc/mini-singbox/share-*.txt` | `0600` | Reality/Hysteria2 与 v2rayN 专用 AnyTLS 链接；标准 AnyTLS 仅危险兼容模式生成 |
| `/etc/mini-singbox/share-*.png` | `0600` | 对应二维码；标准 AnyTLS 二维码仅危险兼容模式生成 |
| `/var/lib/mini-singbox/tune/` | `0700` | root 专属调优基线、活动状态和历史回滚记录 |
| `/var/log/mini-singbox/service.log` | `0620` | OpenRC stdout/stderr；root 所有、仅服务组可写，可能包含连接元数据 |
| `/etc/sysctl.d/90-mini-singbox-tune.conf` | `0644` | 仅含本项目实际拥有的 TCP sysctl |
| `/var/backups/mini-singbox/` | `0700` | 部署前回滚备份，可能包含仍有效的历史凭据 |

成功部署后只清理名称和项目生成格式完全匹配的旧备份，并始终保留本次回滚点；默认保留
最近 5 份，可用 `MINI_SINGBOX_BACKUP_KEEP` 调整。卸载时除非显式设置
`PURGE_BACKUPS=1`，这些历史凭据仍会保留。

## 资源边界

所有运行后端默认设置：

```text
GOMAXPROCS=1
GOMEMLIMIT=48MiB
GOGC=70
MemoryMax=128M
TasksMax=64
```

前三项由 systemd、OpenRC、external runner 和 OCI 容器共同设置。`MemoryMax` 与
`TasksMax` 由 systemd 或 OCI runtime 强制；OpenRC/external 依赖外层主机或容器的资源
限制，因此不能把 Go runtime 建议值表述成硬内存上限。

`GOMEMLIMIT` 主要约束 Go Runtime 管理的内存，不是容器总内存硬限制，也不包含全部
内核 Socket 内存。

普通 systemd VM 使用完整沙箱；受限 systemd LXC 会使用 container-compatible unit，保留
非 root、空 capabilities、`NoNewPrivileges`、内存和任务上限，但依赖外层容器提供挂载
命名空间与 seccomp 边界。完整 OpenRC 容器使用 `openrc-container` profile。所有 profile
都会写入 `deployment-info.txt`；容器 profile 不执行宿主 TCP 调优，也不宣称保护等价。

2026-08-09 的 1 vCPU/128 MiB 共享 NAT 实机测试基于 `v1.0.0`（sing-box
`v1.13.16`、Go `1.26.5`）；三协议同时运行时观测到：

- 收/发吞吐峰值约 `57.20/72.17 Mbps`；
- 服务 CPU 峰值 `18%`，流量期间内存峰值 `41.4 MiB`；
- 系统最低可用内存 `69.6 MiB`，Swap 使用 `0`；
- TCP 重传率约 `0.061%`；
- UDP/IP/网卡错误、丢包、服务重启、警告和 OOM 均为 `0`。

以上是旧版参考环境的实测值，不是对 `v1.1.1`、`v1.2.0` 或所有线路、宿主机的性能保证。
`v1.2.0` 发布门禁进一步覆盖 Alpine/OpenRC、外部 supervisor、rootless Podman、128 MiB
限制和升级回滚；这些仍属于功能验收，不冒充每一种宿主环境下的长期性能保证。旧版
真实流量摘要见[正式版验证记录](docs/validation.md)。

## Docker Compose（仅开发和验证）

`compose.yaml` 会在当前机器从源码构建镜像，不是 128 MiB 小虚拟机的安装方式。
小虚拟机必须使用前面的签名 Release 一行部署；该流程只下载 CI 二进制，不编译。
需要复现容器硬化检查的开发机可以执行：

```sh
git clone --branch develop/v1.2.0-alpine --depth 1 https://github.com/XDuke/mini-singbox.git
cd mini-singbox
mkdir config
sudo chown 65532:65532 config
sudo chmod 0700 config

REALITY_SERVER_NAME=www.example.com \
REALITY_HANDSHAKE=www.example.com:443 \
TLS_SAN=proxy.example.com \
PUBLIC_ADDRESS=proxy.example.com \
docker compose --profile tools run --rm generate

docker compose run --rm --no-deps mini-singbox check -c /etc/mini-singbox/config.json
docker compose up -d mini-singbox
```

镜像使用 scratch、UID/GID `65532:65532`、只读根文件系统、空 capability、
`no-new-privileges`、64 PID 上限和 128 MiB 内存上限。生成容器禁用网络。

## 直接使用二进制

```text
mini-singbox run -c CONFIG
mini-singbox check -c CONFIG
mini-singbox generate [OPTIONS]
mini-singbox deliver [OPTIONS]
mini-singbox version
```

`deliver` 只从现有配置重建公网地址、端口、分享链接和二维码，不轮换服务端凭据。

## 从源码验证

构建不是小虚拟机部署流程的一部分。开发环境使用 Go `1.26.6`：

```sh
go mod verify
go vet -tags with_utls ./...
go test -tags with_utls ./...
go test -race -tags with_utls ./...
CGO_ENABLED=0 go build -tags with_utls -trimpath -o mini-singbox ./cmd/mini-singbox
```

## Release 验证

`v1.2.0` 起正式 Release 包含 amd64/arm64 静态二进制、`SHA256SUMS`、minisign 签名、
SPDX SBOM、GitHub provenance、许可证、systemd/OpenRC/external 安装文件，以及记录
GHCR 多架构镜像不可变身份的 `oci-digests.txt`。手工验证：

```sh
minisign -Vm SHA256SUMS -x SHA256SUMS.minisig -p release/minisign.pub
sha256sum -c SHA256SUMS --ignore-missing
go version -m mini-singbox-linux-amd64
gh attestation verify \
  "oci://$(cat oci-digests.txt)" -R XDuke/mini-singbox
```

详见[可复现发布流程](docs/release.md)。

## 卸载

`v1.1.0` 起可直接使用以下命令。

保留配置和密钥：

```sh
sudo mini-singbox-uninstall
```

删除当前配置、密钥和调优状态（保留历史部署备份）：

```sh
sudo env PURGE=1 mini-singbox-uninstall
```

永久删除当前数据和历史备份中的凭据：

```sh
sudo env PURGE=1 PURGE_BACKUPS=1 mini-singbox-uninstall
```

卸载会先恢复 mini-singbox 管理的 TCP 参数，再删除程序。两个开关只接受 `0` 或 `1`，
脚本会在删除前列出固定目标路径。`PURGE=1` 和 `PURGE_BACKUPS=1` 均不可由卸载脚本
恢复；如仍需旧客户端、调优审计或回滚记录，应先离线备份对应目录。

## 安全边界与许可

安全报告方式见 [SECURITY.md](SECURITY.md)。项目采用 GPL-3.0-or-later，并链接官方
sing-box；上游说明见 [NOTICE](NOTICE)。项目与 SagerNet 没有官方隶属或背书关系。
