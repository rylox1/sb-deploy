protocol_key() {
    case "$1" in
        1) echo ss ;; 2) echo hy2 ;; 3) echo tuic ;; 4) echo reality ;; 5) echo anytls ;;
        *) return 1 ;;
    esac
}
protocol_name() {
    case "$1" in
        ss) echo "Shadowsocks (SS)" ;; hy2) echo "Hysteria2" ;; tuic) echo "TUIC" ;;
        reality) echo "VLESS Reality" ;; anytls) echo "AnyTLS Reality" ;;
    esac
}
protocol_type() {
    case "$1" in ss) echo shadowsocks ;; hy2) echo hysteria2 ;; tuic) echo tuic ;; reality) echo vless ;; anytls) echo anytls ;; esac
}
protocol_selector() {
    case "$1" in
        ss) echo '.type == "shadowsocks"' ;;
        hy2) echo '.type == "hysteria2"' ;;
        tuic) echo '.type == "tuic"' ;;
        reality) echo '.type == "vless" and .tls.reality.enabled == true' ;;
        anytls) echo '.type == "anytls" and .tls.reality.enabled == true' ;;
    esac
}
protocol_flag() {
    case "$1" in ss) echo ENABLE_SS ;; hy2) echo ENABLE_HY2 ;; tuic) echo ENABLE_TUIC ;; reality) echo ENABLE_REALITY ;; anytls) echo ENABLE_ANYTLS ;; esac
}

# 从候选 JSON 重新生成协议标记和缓存，shell 值采用 Bash 可逆转义。
state_write_shell() {
    local output="$1" name="$2" value="$3" escaped
    printf -v escaped '%q' "$value"
    printf '%s=%s\n' "$name" "$escaped" >> "$output"
}
state_write_raw() {
    printf '%s=%s\n' "$2" "$3" >> "$1"
}
render_protocol_state() {
    local config="$1" protocols_out="$2" cache_out="$3" type key value flag selector name path pair public_key_file
    : > "$protocols_out" || return 1
    : > "$cache_out" || return 1
    for key in ss hy2 tuic reality anytls; do
        type=$(protocol_type "$key"); flag=$(protocol_flag "$key"); selector=$(protocol_selector "$key")
        if jq -e "[.inbounds[]? | select($selector)] | length > 0" "$config" >/dev/null; then value=true; else value=false; fi
        state_write_shell "$protocols_out" "$flag" "$value" || return 1
        state_write_shell "$cache_out" "$flag" "$value" || return 1
        [ "$value" = true ] || continue
        case "$key" in
            ss)
                value=$(jq -er '.inbounds[]|select(.type=="shadowsocks")|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" SS_PORT "$value" || return 1
                for pair in 'SS_PSK:.password' 'SS_METHOD:.method'; do name=${pair%%:*}; path=${pair#*:}; value=$(jq -er ".inbounds[]|select(.type==\"shadowsocks\")${path}" "$config") || return 1; state_write_shell "$cache_out" "$name" "$value" || return 1; done ;;
            hy2)
                value=$(jq -er '.inbounds[]|select(.type=="hysteria2")|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" HY2_PORT "$value" || return 1
                value=$(jq -er '.inbounds[]|select(.type=="hysteria2")|.users[0].password' "$config") || return 1
                state_write_shell "$cache_out" HY2_PSK "$value" || return 1 ;;
            tuic)
                value=$(jq -er '.inbounds[]|select(.type=="tuic")|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" TUIC_PORT "$value" || return 1
                for pair in 'TUIC_UUID:.users[0].uuid' 'TUIC_PSK:.users[0].password'; do name=${pair%%:*}; path=${pair#*:}; value=$(jq -er ".inbounds[]|select(.type==\"tuic\")${path}" "$config") || return 1; state_write_shell "$cache_out" "$name" "$value" || return 1; done ;;
            reality)
                value=$(jq -er '.inbounds[]|select(.type=="vless" and .tls.reality.enabled==true)|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" REALITY_PORT "$value" || return 1
                value=$(jq -er '.inbounds[]|select(.type=="vless" and .tls.reality.enabled==true)|.users[0].uuid' "$config") || return 1
                state_write_shell "$cache_out" REALITY_UUID "$value" || return 1 ;;
            anytls)
                value=$(jq -er '.inbounds[]|select(.type=="anytls" and .tls.reality.enabled==true)|.listen_port' "$config") || return 1
                state_write_raw "$cache_out" ANYTLS_PORT "$value" || return 1
                for pair in 'ANYTLS_USER:.users[0].name' 'ANYTLS_PSK:.users[0].password'; do name=${pair%%:*}; path=${pair#*:}; value=$(jq -er ".inbounds[]|select(.type==\"anytls\" and .tls.reality.enabled==true)${path}" "$config") || return 1; state_write_shell "$cache_out" "$name" "$value" || return 1; done ;;
        esac
    done
    state_write_shell "$cache_out" LOG_ENABLED "${LOG_ENABLED:-false}" || return 1
    state_write_shell "$cache_out" CUSTOM_IP "${CUSTOM_IP:-}" || return 1
    if jq -e '[.inbounds[]?|select((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true)]|length>0' "$config" >/dev/null; then
        for pair in 'REALITY_SNI:.tls.server_name // .tls.reality.handshake.server' 'REALITY_PK:.tls.reality.private_key' 'REALITY_SID:.tls.reality.short_id[0]'; do
            name=${pair%%:*}; path=${pair#*:}
            value=$(jq -er "[.inbounds[]?|select((.type==\"vless\" or .type==\"anytls\") and .tls.reality.enabled==true)][0] | ${path} // empty" "$config") || { err "读取候选 Reality 字段失败: $name"; return 1; }
            state_write_shell "$cache_out" "$name" "$value" || { err "写入候选 Reality 字段失败: $name"; return 1; }
        done
        public_key_file="$CONFIG_DIR/.reality_pub"
        [ -f "$TX_DIR/material/.reality_pub" ] && public_key_file="$TX_DIR/material/.reality_pub"
        if [ -f "$public_key_file" ]; then value=$(<"$public_key_file") || return 1; state_write_shell "$cache_out" REALITY_PUB "$value" || return 1; fi
    fi
}

protocol_port_free() {
    local target="$1" candidate="$2" key type port transport used
    if jq -e --arg port "$candidate" '
      [.inbounds[]? | select((.listen_port|tostring)==$port) |
       select(.type!="shadowsocks" and .type!="hysteria2" and .type!="tuic" and
         (((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true) | not))] | length>0
    ' "$CONFIG_PATH" >/dev/null; then
        return 1
    fi
    for key in ss hy2 tuic reality anytls; do
        [ "$key" = "$target" ] && continue
        case " ${PROTOCOL_REMOVING:-} " in *" $key "*) continue ;; esac
        type=$(protocol_type "$key")
        while IFS= read -r port; do
            [ -n "$port" ] || continue
            [ "$port" = "$candidate" ] || continue
            case "$key:$target" in
                ss:*) return 1 ;; *:ss) return 1 ;;
                hy2:hy2|hy2:tuic|tuic:hy2|tuic:tuic) return 1 ;;
                reality:reality|reality:anytls|anytls:reality|anytls:anytls) return 1 ;;
            esac
        done < <(jq -r --arg t "$type" '.inbounds[]?|select(.type==$t)|.listen_port|tostring' "$CONFIG_PATH")
    done
    local staged staged_type staged_key staged_port
    for staged in "$TX_DIR"/*.json; do
        [ -f "$staged" ] || continue
        staged_type=$(jq -r '.type' "$staged")
        staged_port=$(jq -r '.listen_port|tostring' "$staged")
        [ "$staged_port" = "$candidate" ] || continue
        case "$staged_type" in shadowsocks) staged_key=ss ;; hysteria2) staged_key=hy2 ;; tuic) staged_key=tuic ;; vless) staged_key=reality ;; anytls) staged_key=anytls ;; *) continue ;; esac
        case "$staged_key:$target" in
            ss:*|*:ss|hy2:hy2|hy2:tuic|tuic:hy2|tuic:tuic|reality:reality|reality:anytls|anytls:reality|anytls:anytls) return 1 ;;
        esac
    done
    return 0
}

collect_protocol_inbound() {
    local key="$1" port="$2" method="" pass="" uuid="" user="" sni="${REALITY_SNI:-addons.mozilla.org}" pk="${REALITY_PK:-}" sid="${REALITY_SID:-}"
    case "$key" in
        ss) read -r -p 'SS 加密方式 [1=2022-blake3-aes-128-gcm, 2=aes-128-gcm，默认 1]: ' choice || choice=; method=2022-blake3-aes-128-gcm; [ "$choice" = 2 ] && method=aes-128-gcm; pass=$(rand_pass); jq -n --argjson port "$port" --arg method "$method" --arg pass "$pass" '{type:"shadowsocks",listen:"::",listen_port:$port,method:$method,password:$pass,tag:"ss-in"}' > "$TX_DIR/$key.json" ;;
        hy2) pass=$(rand_pass); jq -n --argjson port "$port" --arg pass "$pass" '{type:"hysteria2",tag:"hy2-in",listen:"::",listen_port:$port,users:[{password:$pass}],tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$TX_DIR/$key.json" ;;
        tuic) pass=$(rand_pass); uuid=$(rand_uuid); jq -n --argjson port "$port" --arg pass "$pass" --arg uuid "$uuid" '{type:"tuic",tag:"tuic-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,password:$pass}],congestion_control:"bbr",tls:{enabled:true,alpn:["h3"],certificate_path:"/etc/sing-box/certs/fullchain.pem",key_path:"/etc/sing-box/certs/privkey.pem"}}' > "$TX_DIR/$key.json" ;;
        reality) uuid=$(rand_uuid); jq -n --argjson port "$port" --arg uuid "$uuid" --arg sni "$sni" --arg pk "$pk" --arg sid "$sid" '{type:"vless",tag:"vless-in",listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' > "$TX_DIR/$key.json" ;;
        anytls) user=$(openssl rand -hex 4); pass=$(rand_pass); jq -n --argjson port "$port" --arg user "$user" --arg pass "$pass" --arg sni "$sni" --arg pk "$pk" --arg sid "$sid" '{type:"anytls",tag:"anytls-in",listen:"::",listen_port:$port,users:[{name:$user,password:$pass}],padding_scheme:[],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$pk,short_id:[$sid]}}}' > "$TX_DIR/$key.json" ;;
    esac
}

validate_candidate_ports() {
    local candidate="$1"
    jq -e '
      [.inbounds[]? | select(.type=="shadowsocks" or .type=="hysteria2" or .type=="tuic" or ((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true)) | {type,port:.listen_port}] as $managed |
      all($managed[]; (.port|type)=="number" and .port>=1 and .port<=65535 and .port==(.port|floor)) and
      ([.inbounds[]? | select(.listen_port|type=="number") | {type,port:.listen_port,reality:(.tls.reality.enabled==true)}] as $items |
       [$items[] | if .type=="shadowsocks" then "tcp/\(.port)","udp/\(.port)"
        elif .type=="hysteria2" or .type=="tuic" then "udp/\(.port)"
        elif (.type=="vless" or .type=="anytls") and .reality then "tcp/\(.port)"
        else "tcp/\(.port)","udp/\(.port)" end] | length == (unique|length))
    ' "$candidate" >/dev/null || { err '候选配置存在非法端口或 TCP/UDP 映射冲突（含未知 inbound）'; return 1; }
}

protocol_restore_trap() {
    local signal="$1" saved_trap="$2"
    if [ -n "$saved_trap" ]; then eval "$saved_trap"; else trap - "$signal"; fi
}

protocol_transaction_restore_signal_traps() {
    protocol_restore_trap INT "$saved_int_trap"
    protocol_restore_trap TERM "$saved_term_trap"
    protocol_restore_trap HUP "$saved_hup_trap"
}

protocol_transaction_signal_handler() {
    trap '' INT TERM HUP
    rollback_protocol_transaction
    protocol_transaction_restore_signal_traps
    [ -z "${TX_DIR:-}" ] || rm -rf "$TX_DIR"
    TX_DIR=""
    exit 130
}

apply_protocol_transaction() {
    local candidate="$1" new_protocols="$2" cache_candidate="$3" uri_backup="$4" file item config_check
    local saved_int_trap saved_term_trap saved_hup_trap
    saved_int_trap=$(trap -p INT); saved_term_trap=$(trap -p TERM); saved_hup_trap=$(trap -p HUP)
    local snapshot="$TX_DIR/backup"; mkdir -m 700 "$snapshot" || return 1
    local rollback_active=false
    for file in config.json .protocols .config_cache uris.txt .reality_pub .reality_sid certs/fullchain.pem certs/privkey.pem docker-compose.yml; do
        if [ -e "$CONFIG_DIR/$file" ]; then mkdir -p "$snapshot/$(dirname "$file")" || return 1; cp -p "$CONFIG_DIR/$file" "$snapshot/$file" || return 1; touch "$snapshot/$file.present" || return 1; fi
    done
    rollback_protocol_transaction() {
        local path restore_ok=true service_ok=false
        [ "$rollback_active" = true ] || return 0
        rollback_active=false
        rm -f "$CONFIG_DIR/config.json.tmp.$$" "$CONFIG_DIR/.protocols.tmp.$$" "$CONFIG_DIR/.config_cache.tmp.$$" "$CONFIG_DIR/uris.txt.tmp.$$" || restore_ok=false
        for path in config.json .protocols .config_cache uris.txt .reality_pub .reality_sid certs/fullchain.pem certs/privkey.pem docker-compose.yml; do
            if [ -f "$snapshot/$path.present" ]; then
                mkdir -p "$CONFIG_DIR/$(dirname "$path")" && cp -p "$snapshot/$path" "$CONFIG_DIR/$path" || restore_ok=false
            else
                rm -f "$CONFIG_DIR/$path" || restore_ok=false
            fi
        done
        if [ "$DEPLOY_MODE" = docker ]; then
            docker_compose up -d --force-recreate && service_ok=true
        else
            service_restart && service_ok=true
        fi
        if [ "$restore_ok" = true ] && [ "$service_ok" = true ]; then info '已恢复原配置、状态文件和服务'
        else err '回滚未能完整恢复文件或服务，请立即检查 sing-box 与 Docker Compose 状态'; fi
    }
    local check_candidate="$TX_DIR/check.json" check_cert check_key
    cp "$candidate" "$check_candidate" || return 1
    if [ -f "$TX_DIR/material/certs/fullchain.pem" ]; then
        if [ "$DEPLOY_MODE" = docker ]; then
            check_cert="/etc/sing-box/$(basename "$TX_DIR")/material/certs/fullchain.pem"
            check_key="/etc/sing-box/$(basename "$TX_DIR")/material/certs/privkey.pem"
        else
            check_cert="$TX_DIR/material/certs/fullchain.pem"
            check_key="$TX_DIR/material/certs/privkey.pem"
        fi
        jq --arg cert "$check_cert" --arg key "$check_key" '
          .inbounds |= map(if (.type=="hysteria2" or .type=="tuic") and .tls.enabled==true
            then .tls.certificate_path=$cert | .tls.key_path=$key else . end)
        ' "$candidate" > "$check_candidate" || return 1
    fi
    if [ "$DEPLOY_MODE" = docker ]; then config_check="/etc/sing-box/$(basename "$TX_DIR")/check.json"; else config_check="$check_candidate"; fi
    run_singbox check -c "$config_check" >/dev/null 2>&1 || { err '候选配置校验失败，未停止当前服务'; return 1; }
    rollback_active=true
    trap 'protocol_transaction_signal_handler INT' INT
    trap 'protocol_transaction_signal_handler TERM' TERM
    trap 'protocol_transaction_signal_handler HUP' HUP
    while IFS= read -r -d '' item; do
        local relative=${item#"$TX_DIR/material/"} target="$CONFIG_DIR/${item#"$TX_DIR/material/"}"
        mkdir -p "$(dirname "$target")"
        cp "$item" "$target" || { rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    done < <(find "$TX_DIR/material" -type f -print0)
    for item in "$candidate:$CONFIG_DIR/config.json" "$new_protocols:$CONFIG_DIR/.protocols" "$cache_candidate:$CONFIG_DIR/.config_cache"; do
        local src dst tmp
        src=${item%%:*}; dst=${item#*:}; tmp="$dst.tmp.$$"
        cp "$src" "$tmp" && mv "$tmp" "$dst" || { rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    done
    service_restart || { err '新配置服务重启失败，正在回滚'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    generate_uris || { err '链接重建失败，正在回滚'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    if ! jq -e '[.inbounds[]?|select((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true)]|length>0' "$CONFIG_DIR/config.json" >/dev/null; then
        rm -f "$CONFIG_DIR/.reality_pub" "$CONFIG_DIR/.reality_sid" || { err '清理已撤销 Reality 材料失败'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    fi
    if ! jq -e '[.inbounds[]?|select(.type=="hysteria2" or .type=="tuic")]|length>0' "$CONFIG_DIR/config.json" >/dev/null; then
        rm -f "$CONFIG_DIR/certs/fullchain.pem" "$CONFIG_DIR/certs/privkey.pem" || { err '清理已撤销证书失败'; rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    fi
    [ -f "$CONFIG_DIR/.protocols" ] || { rollback_protocol_transaction; protocol_transaction_restore_signal_traps; return 1; }
    rollback_active=false
    protocol_transaction_restore_signal_traps
    return 0
}

action_manage_protocols_impl() {
    read_config || return 1
    local key type enabled current='' input token target='' invalid=false added='' removed='' unchanged='' port raw i
    echo '当前协议集合：'
    local index=1
    for key in ss hy2 tuic reality anytls; do
        flag=$(protocol_flag "$key"); enabled=${!flag}; printf '%s) %s %s\n' "$index" "$(protocol_name "$key")" "$([ "$enabled" = true ] && echo '[已启用]' || echo '[未启用]')"; [ "$enabled" = true ] && current+="$index "; index=$((index+1))
    done
    read -r -p '输入期望的最终协议编号（空格分隔）: ' input || input=
    [ -n "${input//[[:space:]]/}" ] || { err '协议集合不能为空，未做修改'; return 1; }
    declare -A requested=()
    for token in $input; do case "$token" in 1|2|3|4|5) requested[$token]=1 ;; *) invalid=true ;; esac; done
    [ "$invalid" = false ] || { err '包含无效编号，未做修改'; return 1; }
    [ "${#requested[@]}" -gt 0 ] || { err '至少保留一个协议'; return 1; }
    for i in 1 2 3 4 5; do
        key=$(protocol_key "$i"); flag=$(protocol_flag "$key"); enabled=${!flag}
        if [ "${requested[$i]:-}" = 1 ]; then [ "$enabled" = true ] && unchanged+="$key " || added+="$key "; else [ "$enabled" = true ] && removed+="$key "; fi
    done
    if [ -z "$added$removed" ]; then info '协议集合没有变化，无需调整'; return 0; fi
    TX_DIR=$(mktemp -d "$CONFIG_DIR/.protocol-update.XXXXXX") || return 1
    chmod 700 "$TX_DIR" && mkdir "$TX_DIR/material" || { rm -rf "$TX_DIR"; TX_DIR=""; return 1; }
    local reality_retained=false cert_retained=false
    PROTOCOL_REMOVING="$removed"
    for key in $unchanged; do case "$key" in reality|anytls) reality_retained=true ;; hy2|tuic) cert_retained=true ;; esac; done
    if [ "$cert_retained" = true ] && { [[ " $added " == *' hy2 '* ]] || [[ " $added " == *' tuic '* ]]; }; then
        if ! jq -e '[.inbounds[]?|select(.type=="hysteria2" or .type=="tuic") | .tls | select(.certificate_path=="/etc/sing-box/certs/fullchain.pem" and .key_path=="/etc/sing-box/certs/privkey.pem")]|length>0' "$CONFIG_PATH" >/dev/null || [ ! -f "$CONFIG_DIR/certs/fullchain.pem" ] || [ ! -f "$CONFIG_DIR/certs/privkey.pem" ]; then
            err '现存 HY2/TUIC 未使用可复用的共享证书文件，拒绝更改现存协议参数'
            return 1
        fi
    fi
    if [[ " $added " == *' reality '* || " $added " == *' anytls '* ]]; then
        if [ "$reality_retained" = true ]; then
            [ -n "${REALITY_PK:-}" ] && [ -n "${REALITY_SID:-}" ] && [ -n "${REALITY_PUB:-}" ] || { err '已有 Reality 参数或 .reality_pub 缺失，拒绝改变现存 Reality 链接'; return 1; }
        else
            read -r -p 'Reality SNI（默认 addons.mozilla.org）: ' REALITY_SNI || REALITY_SNI=
            REALITY_SNI=${REALITY_SNI:-addons.mozilla.org}
            local key_output; key_output=$(run_singbox generate reality-keypair 2>&1) || { err 'Reality 密钥生成失败'; return 1; }
            REALITY_PK=$(printf '%s\n' "$key_output"|awk '/PrivateKey/{print $NF}'); REALITY_PUB=$(printf '%s\n' "$key_output"|awk '/PublicKey/{print $NF}'); REALITY_SID=$(run_singbox generate rand 8 --hex 2>&1) || return 1
            [ -n "$REALITY_PK" ] && [ -n "$REALITY_PUB" ] && [ -n "$REALITY_SID" ] || { err 'Reality 密钥参数不完整'; return 1; }
            printf '%s' "$REALITY_PUB" > "$TX_DIR/material/.reality_pub"; printf '%s' "$REALITY_SID" > "$TX_DIR/material/.reality_sid"
        fi
    fi
    if [[ " $added " == *' hy2 '* || " $added " == *' tuic '* ]]; then
        if [ "$cert_retained" = false ]; then
            mkdir -p "$TX_DIR/material/certs"
            openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TX_DIR/material/certs/privkey.pem" -out "$TX_DIR/material/certs/fullchain.pem" -days 3650 -subj '/CN=www.bing.com' >/dev/null 2>&1 || { err '共享证书生成失败'; return 1; }
        fi
    fi
    for key in $added; do
        read -r -p "$(protocol_name "$key") 端口（回车随机）: " raw || raw=
        if [ -z "$raw" ]; then
            local attempts=0; while :; do raw=$(rand_port); protocol_port_free "$key" "$raw" && break; attempts=$((attempts+1)); [ "$attempts" -lt 500 ] || { err '找不到可用随机端口'; return 1; }; done
        fi
        validate_port "$raw" || return 1
        protocol_port_free "$key" "$raw" || { err "端口 $raw 与目标协议发生传输层冲突"; return 1; }
        collect_protocol_inbound "$key" "$raw" || return 1
    done
    local candidate="$TX_DIR/candidate.json" jq_args=() filter=''
    for key in $removed; do type=$(protocol_type "$key"); jq_args+=(--arg "remove_$key" "$type"); filter+="| map(select(.type != \$remove_$key))"; done
    # 将不同协议的用户新增 inbound 逐项 append，未知及未变入站原样保留。
    jq '.inbounds' "$CONFIG_PATH" >/dev/null || return 1
    cp "$CONFIG_PATH" "$candidate"
    for key in $added; do candidate_tmp="$TX_DIR/step-$key.json"; jq --slurpfile inbound "$TX_DIR/$key.json" '.inbounds += $inbound' "$candidate" > "$candidate_tmp" || return 1; mv "$candidate_tmp" "$candidate"; done
    for key in $removed; do type=$(protocol_type "$key"); candidate_tmp="$TX_DIR/remove-$key.json"; selector=$(protocol_selector "$key"); jq " .inbounds |= map(select((($selector) | not))) " "$candidate" > "$candidate_tmp" || return 1; mv "$candidate_tmp" "$candidate"; done
    validate_candidate_ports "$candidate" || return 1
    render_protocol_state "$candidate" "$TX_DIR/protocols" "$TX_DIR/cache" || { err '候选协议状态生成失败，未修改节点配置'; return 1; }
    echo "将新增：${added:-无}"; echo "将删除：${removed:-无}"; echo "保持不变：${unchanged:-无}"
    read -r -p '确认应用以上变更？[y/N] ' confirm || confirm=
    [[ "$confirm" =~ ^[Yy]$ ]] || { info '已取消，未修改配置'; return 0; }
    apply_protocol_transaction "$candidate" "$TX_DIR/protocols" "$TX_DIR/cache" "$TX_DIR/uri-backup" || return 1
    read_config || return 1
    info '协议调整成功；新协议链接如下：'
    for key in $added; do case "$key" in ss) grep -A2 '^=== Shadowsocks' "$CONFIG_DIR/uris.txt" ;; hy2) grep -A1 '^=== Hysteria2' "$CONFIG_DIR/uris.txt" ;; tuic) grep -A1 '^=== TUIC' "$CONFIG_DIR/uris.txt" ;; reality) grep -A1 '^=== VLESS Reality' "$CONFIG_DIR/uris.txt" ;; anytls) grep -A1 '^=== AnyTLS Reality' "$CONFIG_DIR/uris.txt" ;; esac; done
    echo "最终协议：$(jq -r '[.inbounds[]?|select(.type=="shadowsocks" or .type=="hysteria2" or .type=="tuic" or ((.type=="vless" or .type=="anytls") and .tls.reality.enabled==true))|.type]|join(", ")' "$CONFIG_PATH")"
}

action_manage_protocols() {
    local result=0 active_dir
    action_manage_protocols_impl "$@" || result=$?
    active_dir="${TX_DIR:-}"
    [ -z "$active_dir" ] || rm -rf "$active_dir"
    TX_DIR=""
    return "$result"
}

# 动态生成菜单
