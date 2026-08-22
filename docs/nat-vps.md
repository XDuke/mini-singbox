# 共享 NAT VPS 与端口映射

共享 NAT 实例通常只有内网地址，多个实例共用一个公网 IP。服务端监听端口和客户端
连接的公网端口因此可能不同。`mini-singbox` 明确区分这两组端口，避免把内网监听
端口错误写进二维码。

公网 IP 可以自动探测，服务商控制面的端口映射不能。容器首次部署没有显式公网端口时，
安装器会把它们标记为 `assumed` 并输出警告；`mini-singboxctl status` 也会持续显示
`verify provider NAT mapping`。这表示服务本地监听已验证，不表示公网转发已经存在。

## 控制台操作

默认三协议需要以下映射：

| 协议 | 公网协议 | 公网端口 | 实例内部端口 |
|---|---|---:|---:|
| VLESS Reality | TCP | 面板分配或自选 | `20001` |
| Hysteria2 | UDP | 面板分配或自选 | `20002` |
| AnyTLS | TCP | 面板分配或自选 | `20003` |

在实测的共享 NAT 容器控制台中，入口位于“端口映射”。新增映射时需要选择协议、
填写公网端口、内部端口和备注。单端口创建会预填一个当前可用的随机公网端口；如果
批量添加固定同端口映射后列表没有变化，通常表示该公网端口已被同一 NAT 网关上的
其他实例占用。此时改用单端口模式并接受面板分配的随机端口。

必须逐条核对列表：Reality 和 AnyTLS 是 TCP，Hysteria2 是 UDP。TCP 探测成功不能
证明 UDP 可用，UDP 映射也不能代替 TCP 映射。SSH 的公网映射只用于维护，不能复用
为代理端口。

## 首次部署

公网 IP 可以由脚本自动探测，Reality 握手域名也可以自动优选；面板分配的公网端口
无法从实例内部可靠推断，因此首次部署时需要把三项端口传给脚本：

```bash
MINI_SINGBOX_PUBLIC_REALITY_PORT=51165 \
MINI_SINGBOX_PUBLIC_HY2_PORT=25421 \
MINI_SINGBOX_PUBLIC_ANYTLS_PORT=36279 \
bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

这里的数字只是命令格式示例。使用控制台当前显示的端口，不要照抄。脚本会让服务
继续监听正确的内部端口：Reality `20001/tcp`、Hysteria2
`20002/udp`、AnyTLS `20003/tcp`，并把公网端口写入客户端交付文件。Reality 和
Hysteria2 生成通用二维码；AnyTLS 生成 v2rayN 专用二维码、内嵌服务器证书的 sing-box
出站 JSON，以及固定服务器证书 SHA-256 的 Mihomo YAML。

## NAT 端口变化后刷新客户端交付

服务商重置或重新分配映射后，不需要重新生成服务端配置：

```sh
sudo env \
  MINI_SINGBOX_REFRESH_DELIVERY=1 \
  MINI_SINGBOX_PUBLIC_REALITY_PORT=新的Reality公网TCP端口 \
  MINI_SINGBOX_PUBLIC_HY2_PORT=新的Hysteria2公网UDP端口 \
  MINI_SINGBOX_PUBLIC_ANYTLS_PORT=新的AnyTLS公网TCP端口 \
  bash -c 'set -o pipefail; curl -fsSL https://raw.githubusercontent.com/XDuke/mini-singbox/main/bootstrap.sh | bash'
```

这条路径只重建 `client-info.json`、可用的 `share-*.txt`/`share-*.png` 和三种 AnyTLS
认证交付。现有 UUID、密码、Reality 密钥、TLS 私钥和服务端配置保持不变。
部署前仍会创建备份，失败会回滚。

以后普通升级会沿用 `client-info.json` 中已经记录的公网地址和端口，无需重复填写。
只有控制台映射再次变化时才需要执行刷新命令。

## 验收顺序

1. `sudo mini-singboxctl status`：确认配置有效、进程正常，并同时查看本地监听端口和
   客户端公网端口。
2. `sudo cat /etc/mini-singbox/deployment-info.txt`：确认每个协议的
   `*_listen_port` 与 `*_public_port` 对应正确，并确认 `*_public_port_source=explicit`。
3. 从实例外部探测 Reality/AnyTLS 的两个 TCP 公网端口。
4. 使用真实客户端导入 Reality、Hysteria2 二维码以及对应客户端的 AnyTLS 认证交付并分别建立
   连接；Hysteria2 必须用真实 QUIC/UDP 客户端验证，不能只依赖 TCP 端口测试。
5. 连接同时查看 `sudo mini-singboxctl logs 100`。客户端报错但服务日志完全没有新
   连接时，优先检查面板映射、协议类型和公网端口，而不是重置凭据。

二维码、分享链接和 AnyTLS 导出包含完整客户端凭据。不要上传到 Issue、CI
Artifact、公开聊天或截图文档。控制台套餐到期、流量额度、续费和删除实例属于
服务商资源操作，本项目的部署脚本不会自动处理。
