#!/bin/bash
# 精简版 sing-box 一键脚本 (anytls / reality / vless-ws-tls)
# 结构参考 233boy/sing-box, 已精简 + 性能优化

set -o pipefail

# ------------- 基础变量 ------------
is_sh_bin="jsb"
is_core="sing-box"
is_core_name="sing-box"
is_core_repo="SagerNet/sing-box"
is_dir="/etc/sing-box"
is_conf_dir="$is_dir/conf"
is_bin_dir="$is_dir/bin"
is_core_bin="$is_bin_dir/sing-box"
is_sh_file="/usr/local/bin/$is_sh_bin"
is_log_dir="$is_dir/logs"
is_reality_sni="www.tesla.com"
is_anytls_sni="www.microsoft.com"

# ------------- 颜色输出 ----------------
red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
msg()   { echo -e "$*"; }
err()   { red "错误: $*"; exit 1; }

# ------- 环境检查 ----------------
check_root() {
    [[ $EUID -ne 0 ]] && err "请使用 root 用户运行 (sudo -i)."
}

check_arch() {
    case $(uname -m) in
        x86_64|amd64)  is_arch=amd64 ;;
        aarch64|arm64) is_arch=arm64 ;;
        *) err "不支持的架构: $(uname -m)" ;;
    esac
}

install_deps() {
    local pkgs="curl wget tar openssl jq"
    if command -v apt >/dev/null 2>&1; then
        apt update -y >/dev/null 2>&1
        apt install -y $pkgs qrencode >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs qrencode >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs qrencode >/dev/null 2>&1
    else
        err "不支持的包管理器, 请手动安装: $pkgs"
    fi
}

# ------- 网络工具 ----------------
_wget() { curl -fsSL --retry 3 "$@"; }

get_ip() {
    is_addr=$(curl -fsSL4 --max-time 8 https://api.ipify.org 2>/dev/null)
    [[ ! $is_addr ]] && is_addr=$(curl -fsSL6 --max-time 8 https://api64.ipify.org 2>/dev/null)
    [[ ! $is_addr ]] && err "无法获取本机公网 IP."
    if [[ $is_addr == *:* ]]; then
        is_ip_fmt="[$is_addr]"
    else
        is_ip_fmt="$is_addr"
    fi
}

get_port() {
    local p
    while :; do
        p=$(shuf -i 2000-65000 -n1)
        ss -tunlp 2>/dev/null | grep -q ":$p " || { echo "$p"; return; }
    done
}

gen_uuid()    { "$is_core_bin" generate uuid; }
gen_pass()    { openssl rand -hex 16; }
gen_shortid() { openssl rand -hex 8; }

# ------------- 下载内核 ----------------
download_core() {
    green "正在获取 $is_core_name 最新版本..."
    local ver
    ver=$(_wget "https://api.github.com/repos/${is_core_repo}/releases/latest" | jq -r '.tag_name')
    [[ ! $ver ]] && err "获取最新版本失败."
    is_core_ver="$ver"

    local tmp file link
    tmp=$(mktemp -d)
    file="$tmp/core.tar.gz"
    link="https://github.com/${is_core_repo}/releases/download/${ver}/${is_core}-${ver:1}-linux-${is_arch}.tar.gz"
    green "下载内核: $ver"
    _wget "$link" -o "$file" || err "下载内核失败."
    mkdir -p "$is_bin_dir"
    tar zxf "$file" --strip-components 1 -C "$is_bin_dir"
    chmod +x "$is_core_bin"
    rm -rf "$tmp"
    [[ -x $is_core_bin ]] || err "内核安装失败."
}

# ------------- 性能优化 (BBR + sysctl) ----------------
optimize_system() {
    green "应用网络性能优化 (BBR + 缓冲区调优)..."
    modprobe tcp_bbr 2>/dev/null
    cat > /etc/sysctl.d/99-singbox-opt.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 32768
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF
    sysctl --system >/dev/null 2>&1
    if ! grep -q "singbox-nofile" /etc/security/limits.conf; then
        cat >> /etc/security/limits.conf <<'EOF'
# singbox-nofile
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
    ulimit -n 1048576 2>/dev/null
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    green "当前拥塞控制算法: $cc"
}

# --------------- 基础配置 ------------
init_base_config() {
    mkdir -p "$is_conf_dir" "$is_log_dir"
    cat > "$is_conf_dir/00base.json" <<EOF
{
  "log": { "level": "warn", "output": "$is_log_dir/box.log", "timestamp": true },
  "route": {
    "rules": [
      { "action": "sniff" }
    ]
  },
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
}

# 通用性能内联字段 (去掉 sniff 相关字段,它们在 1.13+ 已移除)
inbound_perf='"tcp_fast_open": true'

# ------- 添加节点 ----------------
add_anytls() {
    local port pass name cert key
    port=$(get_port)
    pass=$(gen_pass)
    name="anytls-$port"
    cert="$is_dir/$name.cert.pem"
    key="$is_dir/$name.key.pem"
    openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$key" -out "$cert" \
        -subj "/CN=$is_anytls_sni" 2>/dev/null

    cat > "$is_conf_dir/$name.json" <<EOF
{
  "inbounds": [
    {
      "type": "anytls",
      "tag": "$name",
      "listen": "::",
      "listen_port": $port,
      $inbound_perf,
      "users": [ { "password": "$pass" } ],
      "tls": {
        "enabled": true,
        "server_name": "$is_anytls_sni",
        "certificate_path": "$cert",
        "key_path": "$key"
      }
    }
  ]
}
EOF
    restart_core || return 1
    green "\nAnyTLS 节点已创建:"
    echo "anytls://$pass@$is_ip_fmt:$port?insecure=1#$name"
}

add_reality() {
    local port uuid keypair prikey pubkey sid name
    port=$(get_port)
    uuid=$(gen_uuid)
    keypair=$("$is_core_bin" generate reality-keypair)
    prikey=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    pubkey=$(echo "$keypair" | awk '/PublicKey/{print $2}')
    sid=$(gen_shortid)
    name="reality-$port"

    cat > "$is_conf_dir/$name.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "$name",
      "listen": "::",
      "listen_port": $port,
      $inbound_perf,
      "users": [ { "uuid": "$uuid", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "$is_reality_sni",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$is_reality_sni", "server_port": 443 },
          "private_key": "$prikey",
          "short_id": ["$sid"]
        }
      }
    }
  ]
}
EOF
    restart_core || return 1
    green "\nVLESS-Reality 节点已创建:"
    echo "vless://$uuid@$is_ip_fmt:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$is_reality_sni&fp=chrome&pbk=$pubkey&sid=$sid&type=tcp#$name"
}

add_vless_ws_tls() {
    local port=443 uuid path name domain minor tls_block enc_path
    read -rp "请输入已解析到本机的域名: " domain
    [[ ! $domain ]] && err "域名不能为空."
    uuid=$(gen_uuid)
    path="/$uuid"
    name="vless-ws-tls-$domain"

    minor=$(echo "${is_core_ver//v/}" | cut -d. -f2)
    if [[ ${minor:-0} -ge 14 ]]; then
        tls_block="\"enabled\": true, \"server_name\": \"$domain\", \"certificate_provider\": { \"type\": \"acme\", \"domain\": [\"$domain\"] }"
    else
        tls_block="\"enabled\": true, \"server_name\": \"$domain\", \"acme\": { \"domain\": [\"$domain\"] }"
    fi

    cat > "$is_conf_dir/${name}.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "$name",
      "listen": "::",
      "listen_port": $port,
      $inbound_perf,
      "users": [ { "uuid": "$uuid" } ],
      "tls": { $tls_block },
      "transport": { "type": "ws", "path": "$path", "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol" }
    }
  ]
}
EOF
    restart_core || return 1
    enc_path=$(echo "$path" | sed 's:/:%2F:g')
    green "\nVLESS-WS-TLS 节点已创建:"
    echo "vless://$uuid@$domain:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=$enc_path#$name"
}

# ---------------- systemd 服务 ------
install_service() {
    cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=$is_core_bin run -C $is_conf_dir
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
LimitNPROC=512
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
}

restart_core() {
    if ! "$is_core_bin" check -C "$is_conf_dir" 2>/tmp/sb_check.log; then
        red "配置检查失败:"; cat /tmp/sb_check.log
        return 1
    fi
    systemctl restart sing-box
}

# ------------- 快捷命令 jsb ----------
install_shortcut() {
    # 处理进程替换的情况
    if [[ -f "$0" && "$0" != "/dev/fd/"* ]]; then
        cp -f "$0" "$is_dir/install.sh" 2>/dev/null
    else
        # 如果是进程替换,从 GitHub 重新下载
        _wget "https://raw.githubusercontent.com/johanneszhao/Rules/refs/heads/main/jsb.sh" -o "$is_dir/install.sh"
    fi
    ln -sf "$is_dir/install.sh" "$is_sh_file"
    chmod +x "$is_dir/install.sh" "$is_sh_file" 2>/dev/null
}

# ---------------- 卸载 ----------------
uninstall_all() {
    yellow "即将完整卸载 sing-box、所有配置及优化设置。"
    read -rp "确认卸载? [y/N]: " yn
    [[ ! $yn =~ ^[Yy]$ ]] && { msg "已取消."; return; }
    systemctl stop sing-box 2>/dev/null
    systemctl disable sing-box 2>/dev/null
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    rm -rf "$is_dir"
    rm -f "$is_sh_file"
    rm -f /etc/sysctl.d/99-singbox-opt.conf
    sysctl --system >/dev/null 2>&1
    sed -i '/# singbox-nofile/,+2d' /etc/security/limits.conf 2>/dev/null
    green "已完整卸载。"
}

# ---------------- 状态 / 列表 ------------
show_status() {
    systemctl status sing-box --no-pager -l | head -n 12
}

list_nodes() {
    green "已安装节点配置:"
    ls -1 "$is_conf_dir"/*.json 2>/dev/null | grep -v 00base | sed 's#.*/##; s#.json##' | sed 's/^/  /'
}

# ------------- 安装主流程 ----------------
do_install() {
    check_root
    check_arch
    green "安装依赖..."
    install_deps
    download_core
    init_base_config
    optimize_system
    install_service
    install_shortcut
    systemctl start sing-box 2>/dev/null
    green "\n安装完成! 版本: $is_core_ver"
    green "以后输入 jsb 打开菜单。\n"
    menu
}

# ---------------- 菜单 ----------
menu() {
    check_root
    check_arch
    [[ -x $is_core_bin ]] && is_core_ver=$("$is_core_bin" version 2>/dev/null | awk 'NR==1{print "v"$3}')
    get_ip
    echo
    green "===== sing-box 精简管理菜单 ====="
    echo "  1) 添加 AnyTLS       (自动端口/密码)"
    echo "  2) 添加 Reality      (自动端口/密钥, 伪装 $is_reality_sni)"
    echo "  3) 添加 VLESS-WS-TLS (需域名)"
    echo "  4) 查看节点列表"
    echo "  5) 运行状态"
    echo "  6) 重启服务"
    echo "  7) 重建基础配置 (修复 legacy 字段问题)"
    echo "  9) 完整卸载"
    echo "  0) 退出"
    echo "=================================="
    read -rp "请选择: " opt
    case $opt in
        1) add_anytls ;;
        2) add_reality ;;
        3) add_vless_ws_tls ;;
        4) list_nodes ;;
        5) show_status ;;
        6) systemctl restart sing-box && green "已重启." ;;
        7) init_base_config && green "已重建基础配置." ;;
        9) uninstall_all ;;
        0) exit 0 ;;
        *) red "无效选项" ;;
    esac
}

# --------- 入口 ------------
case "$1" in
    install|"")
        if [[ -x $is_core_bin ]]; then menu; else do_install; fi
        ;;
    add)          menu ;;
    anytls)       check_root; check_arch; get_ip; add_anytls ;;
    reality)      check_root; check_arch; get_ip; add_reality ;;
    ws|vless)     check_root; check_arch; get_ip; add_vless_ws_tls ;;
    status|s)     show_status ;;
    list|ls)      list_nodes ;;
    restart)      systemctl restart sing-box && green "已重启." ;;
    uninstall|un) uninstall_all ;;
    repair)       init_base_config && green "已修复基础配置." ;;
    *)            menu ;;
esac
