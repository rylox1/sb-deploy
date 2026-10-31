# Sing-box 多协议一键部署脚本

一个强大的 Sing-box 自动化部署工具，支持SS/HY2/TUIC/VLESS Reality/AnyTLS Reality 协议自选部署和线路机 VLESS Reality 中转的完整解决方案。

---

## ✅ 一键部署命令

安装全功能 sing-box：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rylox1/sb-deploy/main/install-singbox.sh)"
```

### Docker 部署

运行全功能安装脚本后选择 **Docker 部署**，或显式指定：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/rylox1/sb-deploy/main/install-singbox.sh)" -- --docker
```

Docker 模式面向 Linux 主机，不要求安装脚本以 root 运行，但要求本机已安装 Docker Engine、Docker Compose（`docker compose` 插件或 `docker-compose`），且当前用户可以访问 Docker daemon。脚本不会自动安装 Docker；本地还需 `curl`、`openssl` 和 `jq`。

配置、证书和 Compose 文件保存在 `${XDG_CONFIG_HOME:-$HOME/.config}/sing-box`，管理命令生成到 `$HOME/.local/bin/sb`。如果该目录不在 `PATH` 中，可运行：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Docker 使用 bridge 网络，并按协议发布端口：SS 映射 TCP/UDP，HY2 和 TUIC 映射 UDP，VLESS Reality 和 AnyTLS Reality 映射 TCP。每项均使用相同的主机端口和容器监听端口（`端口:端口`）；修改端口或配置后，`sb` 管理器会同步更新 Compose 映射并重建容器。HY2 可选连续 2–100 个 UDP 端口跳跃；Docker bridge 继续逐端口映射到同一 HY2 容器监听端口，不显示 Host 转发方式菜单。使用跳跃时需自行在主机防火墙和云安全组放行完整 UDP 范围。脚本不会修改其他 nftables 表或自动修改云安全组。

### HY2 端口跳跃转发（Host 部署）

Host 部署启用 HY2 跳跃时，可选择本机 nftables 或外部端口转发。本机模式需要 root 和当前环境具备 `CAP_NET_ADMIN`；脚本会先执行只读能力探测，并仅管理项目专属的 `inet sb_deploy_hy2` 表，不触碰其他 nftables 表。探测可用时默认选择 nftables；探测失败时不会静默改用 external，必须明确选择 external 或取消，选择不可用的 nftables 也不会写入节点配置。

外部模式适用于由宿主机、NAT 面板或管理员负责转发的环境。整个外部 UDP 范围必须多对一转发到容器监听的首端，例如 `20010-20020/udp → 容器 20010/udp`；也可逐条设置 `20010/udp → 20010/udp`、`20011/udp → 20010/udp`，直到 `20020/udp → 20010/udp`。不要配置 `20010-20020:20010-20020/udp` 一对一映射，因为容器只监听 20010。选择 external 后，安装器和 `sb` 会显示具体映射并要求输入 `y` 确认；未确认则取消且不修改节点配置。

可在 `sb` 的“配置 HY2”或协议调整流程中切换 nftables 与 external。切换到 external 会清理本项目管理的 nftables 规则及启动服务；切回 nftables 前会重新检查权限，并在事务中创建本机运行时，失败时恢复原状态。旧 Host 跳跃节点若缓存中没有转发方式字段，继续按 nftables 处理；固定端口不受此设置影响。脚本无法验证宿主机或 NAT 面板上的外部规则，真实连通性必须从容器外测试范围首端、中间端和末端。

### 已部署节点调整协议

README 推荐的一键入口 `install-singbox.sh` 同样用于更新已有节点管理器。对已有配置再次运行同一安装命令时，默认选择“安全更新管理器并调整协议”，只更新 `sb` 管理器并打开协议调整菜单，不重建配置、不旋转现存凭据，也不重启服务；只有明确选择“重新安装并重建配置”才会进入完整安装流程。既有 Host 节点需以 root 运行，Docker 节点仍需当前用户可访问 Docker daemon。

也可在节点上直接运行 `sb`，选择 **4) 调整协议**，输入期望保留的最终协议编号集合（SS、Hysteria2、TUIC、VLESS Reality、AnyTLS Reality），确认新增/删除摘要后应用。至少保留一种协议；删除协议会立即撤销对应旧链接，再次添加时生成新凭据。应用前会校验候选配置，成功后同步状态文件、链接及 Docker Compose 端口映射。HY2 菜单可调整固定端口/跳跃范围、15 秒默认跳跃间隔及 BBR/Brutal；Brutal 需手动填写客户端视角上下行 Mbps，默认服务端强制 BBR。`uris.txt` 分别列出通用标准、Shadowrocket `mport` 和 Mihomo/mihomo-kit 扩展 URI；后者扩展参数并非所有第三方导入器均支持。新端口需自行在主机防火墙或云安全组开放；跳跃启用时应放行完整 UDP 范围。

此安全升级和协议管理能力仅由本 README 当前推荐的 `install-singbox.sh` 提供，历史安装器入口不包含该功能。

普通用户需使用 rootless Docker，或已被授权访问 Docker daemon。rootless Docker 通常适合使用脚本默认的高位端口；手动指定 1024 以下端口时，需要额外配置 rootless 端口转发。请注意：加入 rootful Docker 的 `docker` 组通常等同于获得主机 root 权限；rootless Docker 则需确保其 daemon 在重启后自动启动。
