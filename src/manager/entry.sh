show_menu() {
    read_config 2>/dev/null || true

    cat <<'MENU'

==========================
 Sing-box 管理面板 (快速指令sb)
==========================
1) 查看协议链接
2) 查看配置文件路径
3) 编辑配置文件
MENU

    # 每轮菜单重新计算映射，避免协议集合变化后遗留旧选项。
    declare -g -A MENU_MAP=()
    MENU_MAP[4]=manage_protocols
    echo "4) 调整协议"
    local option=5

    if [ "${ENABLE_SS:-false}" = "true" ]; then
        echo "$option) 重置 SS 端口"
        MENU_MAP[$option]="reset_ss"
        option=$((option + 1))
    fi

    if [ "${ENABLE_HY2:-false}" = "true" ]; then
        echo "$option) 配置 HY2 端口、跳跃与拥塞控制"
        MENU_MAP[$option]="reset_hy2"
        option=$((option + 1))
    fi

    if [ "${ENABLE_TUIC:-false}" = "true" ]; then
        echo "$option) 重置 TUIC 端口"
        MENU_MAP[$option]="reset_tuic"
        option=$((option + 1))
    fi

    if [ "${ENABLE_REALITY:-false}" = "true" ]; then
        echo "$option) 重置 Vless Reality 端口"
        MENU_MAP[$option]="reset_reality"
        option=$((option + 1))
    fi

    if [ "${ENABLE_ANYTLS:-false}" = "true" ]; then
        echo "$option) 重置 AnyTLS Reality 端口"
        MENU_MAP[$option]="reset_anytls"
        option=$((option + 1))
    fi

    # 固定功能选项
    MENU_MAP[$option]="start"
    echo "$option) 启动服务"
    option=$((option + 1))

    MENU_MAP[$option]="stop"
    echo "$((option))) 停止服务"
    option=$((option + 1))

    MENU_MAP[$option]="restart"
    echo "$((option))) 重启服务"
    option=$((option + 1))

    MENU_MAP[$option]="status"
    echo "$((option))) 查看状态"
    option=$((option + 1))

    MENU_MAP[$option]="update"
    echo "$((option))) 更新 sing-box"
    option=$((option + 1))

    MENU_MAP[$option]="relay"
    echo "$((option))) 生成线路机脚本(出口为本机ss协议)"
    option=$((option + 1))

    MENU_MAP[$option]="uninstall"
    echo "$((option))) 卸载 sing-box"

    cat <<MENU2
0) 退出
==========================
MENU2
}

# 管理器主循环
manager_main() {
while true; do
    show_menu
    read -p "请输入选项: " opt

    # 处理退出
    if [ "$opt" = "0" ]; then
        exit 0
    fi

    # 处理固定选项
    case "$opt" in
        1) action_view_uri ;;
        2) action_view_config ;;
        3) action_edit_config ;;
        4) action_manage_protocols ;;
        *)
            # 处理动态选项
            action="${MENU_MAP[$opt]:-}"
            case "$action" in
                reset_ss) action_reset_ss ;;
                reset_hy2) action_configure_hy2 ;;
                reset_tuic) action_reset_tuic ;;
                reset_reality) action_reset_reality ;;
                reset_anytls) action_reset_anytls ;;
                start) service_start && info "已启动" ;;
                stop) service_stop && info "已停止" ;;
                restart) service_restart && info "已重启" ;;
                status) service_status ;;
                update) action_update ;;
                relay) action_generate_relay ;;
                uninstall) action_uninstall; exit 0 ;;
                *) warn "无效选项: $opt" ;;
            esac
            ;;
    esac

    echo ""
done
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    if [ "${1:-}" = "--manage-protocols" ]; then
        action_manage_protocols
    else
        manager_main
    fi
fi
