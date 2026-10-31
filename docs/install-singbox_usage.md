# install-singbox.sh 使用说明

## 功能概述

部署支持 SS、Hysteria2、TUIC、VLESS Reality、AnyTLS Reality 的 sing-box 节点，并生成客户端链接与 `sb` 管理入口。对已有节点重新运行此脚本时，默认只安全更新管理器并进入协议调整，不重建既有配置。

## 使用方法

```bash
bash install-singbox.sh [--host|--docker]
```

在本仓库目录中运行；部署要求与管理说明详见 README。源码维护者应编辑 `src/` 中对应模块，并使用 `bash scripts/build.sh` 重新生成此发布入口；构建与同步检查详见 [build_usage.md](build_usage.md)。

## 参数说明

- `--host`：主机服务部署；需要 root，支持脚本覆盖的 Systemd/OpenRC 环境。
- `--docker`：Docker Compose 部署；要求 Linux、Docker、Compose 和当前用户对 Docker daemon 的访问权限。
- 不指定参数：交互选择 Host 或 Docker。

重跑时检测到已有 `config.json`，选择“安全更新管理器并调整协议”（默认）或明确选择“重新安装并重建配置”。安全路径要求已有运行模式依赖可用；不会安装依赖、拉取 Docker 镜像、重建配置或重启服务。随后通过 `sb` 的“调整协议”菜单指定最终协议集合。

## 示例

```bash
bash install-singbox.sh --host
bash install-singbox.sh --docker
sb
```

## 输出说明

首次安装会生成服务配置、管理面板以及客户端链接；已有节点安全升级会更新管理器并打开协议管理入口。协议调整成功后同步 `config.json`、协议状态缓存、`uris.txt` 和 Docker 端口映射（Docker 模式）。Host 模式的 HY2 跳跃若选择 external，`uris.txt` 会在三类 HY2 URI 附近附上外部多对一转发契约；客户端 URI 本身不因转发方式改变。

## 注意事项

- 协议调整至少保留一种协议；删除即撤销旧链接，未来重新添加会生成新凭据。
- HY2 端口跳跃默认关闭；启用后范围须为连续 2–100 个 UDP 端口，首端作为 sing-box 监听端口，跳跃间隔默认为 15 秒（允许 5–3600 秒）。
- Host 启用跳跃时可选本机 nftables 或外部端口转发。本机模式需要 root 和 `CAP_NET_ADMIN`；脚本先探测 nftables 权限，并仅使用项目专属的 `inet sb_deploy_hy2` 表，不触碰其他 nftables 表。探测失败时必须明确选择 external 或取消，不会静默切换，也不会在选择不可用的 nftables 后写入节点配置。可用时默认 nftables。旧 Host 跳跃节点缺少转发方式缓存字段时按 nftables 处理，固定端口不受影响。
- external 模式要求完整外部 UDP 范围转发到容器内的首端，例如 `20010-20020/udp → 容器 20010/udp`；也可逐条配置 `20010/udp → 20010/udp`、`20011/udp → 20010/udp`，直至范围末端。禁止 `20010-20020:20010-20020/udp` 一对一映射，因为 sing-box 只监听 20010。选择 external 后会显示实际映射并要求输入 `y` 强确认；拒绝确认即取消且不修改配置。
- 在 `sb` 的 HY2 配置或协议调整流程中可切换 nftables/external。切到 external 会清理本项目规则和启动服务；切回 nftables 前重新探测权限，并在事务中创建本机运行时，失败时回滚。Docker 保持 bridge 网络，继续逐端口映射到同一容器监听端口，不提供 Host 转发方式菜单。
- 脚本无法验证宿主机或 NAT 面板的 external 规则。真实连通性必须从容器外测试 UDP 范围首端、中间端和末端。
- HY2 默认由服务端强制 BBR；主动开启 Brutal 时须输入客户端视角上行和下行 Mbps。`uris.txt` 输出通用标准、Shadowrocket 和 Mihomo/mihomo-kit 三种清晰标注的 URI；非官方 Mihomo 扩展仅保证本地 mihomo-kit 兼容。
- 新增协议端口需用户自行在主机防火墙和云安全组放行；跳跃启用时放行完整 UDP 范围。脚本不会自动更改云安全组或用户自建 nftables 表。
- 仅此脚本入口支持既有节点安全升级，历史安装脚本不支持该能力。
