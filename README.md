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

Docker 使用 bridge 网络，并按协议发布端口：SS 映射 TCP/UDP，HY2 和 TUIC 映射 UDP，VLESS Reality 和 AnyTLS Reality 映射 TCP。每项均使用相同的主机端口和容器监听端口（`端口:端口`）；修改端口或配置后，`sb` 管理器会同步更新 Compose 映射并重建容器。脚本不会自动修改云安全组或主机防火墙，需由用户自行放行相应协议和端口。

### 已部署节点调整协议

README 推荐的一键入口 `install-singbox.sh` 同样用于更新已有节点管理器。对已有配置再次运行同一安装命令时，默认选择“安全更新管理器并调整协议”，只更新 `sb` 管理器并打开协议调整菜单，不重建配置、不旋转现存凭据，也不重启服务；只有明确选择“重新安装并重建配置”才会进入完整安装流程。既有 Host 节点需以 root 运行，Docker 节点仍需当前用户可访问 Docker daemon。

也可在节点上直接运行 `sb`，选择 **4) 调整协议**，输入期望保留的最终协议编号集合（SS、Hysteria2、TUIC、VLESS Reality、AnyTLS Reality），确认新增/删除摘要后应用。至少保留一种协议；删除协议会立即撤销对应旧链接，再次添加时生成新凭据。应用前会校验候选配置，成功后同步状态文件、链接及 Docker Compose 端口映射。协议调整不会自动修改主机防火墙或云厂商安全组，新端口需自行开放。

此安全升级和协议管理能力仅由本 README 当前推荐的 `install-singbox.sh` 提供，历史安装器入口不包含该功能。

普通用户需使用 rootless Docker，或已被授权访问 Docker daemon。rootless Docker 通常适合使用脚本默认的高位端口；手动指定 1024 以下端口时，需要额外配置 rootless 端口转发。请注意：加入 rootful Docker 的 `docker` 组通常等同于获得主机 root 权限；rootless Docker 则需确保其 daemon 在重启后自动启动。
