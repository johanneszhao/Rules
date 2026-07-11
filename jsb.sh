#!/bin/bash
# jsb - 精简版 sing-box 一键脚本 (AnyTLS / Reality / VLESS-WS-TLS)
# 结构参考 233boy/sing-box，按需求重写并修复了历史踩坑的 sing-box 1.13+ 兼容性问题
# repo: https://github.com/johanneszhao/Rules (jsb.sh)

set -o pipefail

# ---------------- 基础变量 ----------------
is_sh_bin="jsb"
is_core="sing-box"
is_core_name="sing-box"
is_core_repo="SagerNet/sing-box"
is_dir="/etc/sing-box"
is_conf_dir="$is_dir/conf"
is_bin_dir="$is_dir/bin"
is_cert_dir="$is_dir/certs"
is_link_dir="$is_dir/links"
is_core_bin="$is_bin_dir/sing-box"
is_sh_self="$is_dir/jsb.sh"
is_sh_file="/usr/local/bin/$is_sh_bin"
is_log_dir="$is_dir/logs"
is_reality_sni_default="www.tesla.com"
is_reality_sni_pool=(www.tesla.com www.amazon.com addons.mozilla.org www.cloudflare.com itunes.apple.com)
# 自更新源：改成你自己仓库里 jsb.sh 的 raw 地址
is_repo_raw="https://raw.githubusercontent.com/johanneszhao/Rules/refs/heads/main/jsb.sh"

# ---------------- 颜色输出 ----------------
red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
msg()    { echo -e "$*"; }
err()    { red "错误: $*"; exit 1; }

# ---------------- 环境检查 ----------------
check_root() {
    [[ $EUID -ne 0 ]] && err "请使用 root 用户运行 (sudo -i)."
}

check_arch() {
    case $(uname -m) in
        x86_64 | amd64) is_arch=amd64 ;;
        aarch64 | arm64) is_arch=arm64 ;;
        *) err "不支持的架构: $(uname -m) (仅支持 64 位 amd64 / arm64)" ;;
    esac
}

install_deps() {
    local pkgs="curl wget tar openssl jq qrencode"
    if command -v apt >/dev/null 2>&1; then
        apt update -y >/dev/null 2>&1
        apt install -y $pkgs iproute2 >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y $pkgs iproute >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y $pkgs iproute >/dev/null 2>&1
    else
        err "不支持的包管理器, 请手动安装: $pkgs"
    fi
    local c
    for c in curl wget tar openssl jq; do
        command -v "$c" >/dev/null 2>&1 || err "依赖 ($c) 安装失败, 请手动安装后重试."
    done
}

# ---------------- 网络工具 ----------------
_wget() { curl -fsSL --retry 3 "$@"; }

get_ip() {
    [[ $is_addr ]] && return
    local p
    for p in https://api.ipify.org https://ip.sb https://ifconfig.me; do
        is_addr=$(curl -fsSL4 --max-time 6 "$p" 2>/dev/null)
        [[ $is_addr ]] && break
    done
    if [[ ! $is_addr ]]; then
        for p in https://api64.ipify.org https://ip.sb; do
            is_addr=$(curl -fsSL6 --max-time 6 "$p" 2>/dev/null)
            [[ $is_addr ]] && break
        done
    fi
    [[ ! $is_addr ]] && err "无法获取本机公网 IP, 请检查网络连接."
    if [[ $is_addr == *:* ]]; then
        is_ip_fmt="[$is_addr]"
    else
        is_ip_fmt="$is_addr"
    fi
}

get_port() {
    local p tries=0
    while :; do
        ((tries++))
        [[ $tries -ge 50 ]] && err "自动获取可用端口失败次数过多, 请检查端口占用情况."
        p=$(shuf -i 20000-60000 -n1)
        if command -v ss >/dev/null 2>&1; then
            ss -tunlp 2>/dev/null | awk '{print $5}' | grep -q ":$p\$" || { echo "$p"; return; }
        else
            (echo >"/dev/tcp/127.0.0.1/$p") 2>/dev/null && continue
            echo "$p"
            return
        fi
    done
}

gen_uuid()    { "$is_core_bin" generate uuid; }
gen_pass()    { openssl rand -hex 16; }
gen_shortid() { openssl rand -hex 8; }

get_core_ver() {
    [[ -x $is_core_bin ]] && is_core_ver="v$("$is_core_bin" version 2>/dev/null | awk 'NR==1{print $3}')"
}

# ---------------- 下载内核 ----------------
download_core() {
    green "正在获取 $is_core_name 版本信息..."
    local ver=$is_core_ver_override
    if [[ ! $ver ]]; then
        ver=$(_wget "https://api.github.com/repos/${is_core_repo}/releases/latest?v=$RANDOM" | jq -r '.tag_name // empty')
    fi
    [[ ! $ver ]] && err "获取 $is_core_name 版本失败 (可能是 GitHub API 限流), 请稍后重试, 或用 'jsb install v1.13.12' 手动指定版本."
    is_core_ver="$ver"

    local tmp file link
    tmp=$(mktemp -d)
    file="$tmp/core.tar.gz"
    link="https://github.com/${is_core_repo}/releases/download/${ver}/${is_core}-${ver:1}-linux-${is_arch}.tar.gz"
    green "下载内核: $ver"
    _wget "$link" -o "$file" || err "下载内核失败, 请检查网络或该版本是否存在."
    mkdir -p "$is_bin_dir"
    tar zxf "$file" --strip-components 1 -C "$is_bin_dir"
    chmod +x "$is_core_bin"
    rm -rf "$tmp"
    [[ -x $is_core_bin ]] || err "内核安装失败."
}

# ---------------- 性能优化 (BBR + sysctl) ----------------
optimize_system() {
    green "应用网络性能优化 (BBR + 缓冲区调优)..."
    modprobe tcp_bbr 2>/dev/null
    cat >/etc/sysctl.d/99-singbox-opt.conf <<'EOF'
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
    if ! grep -q "singbox-nofile" /etc/security/limits.conf 2>/dev/null; then
        cat >>/etc/security/limits.conf <<'EOF'
# singbox-nofile
* soft nofile 1048576
* hard nofile 1048576
EOF
    fi
    ulimit -n 1048576 2>/dev/null
    local cc
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ $cc == bbr ]]; then
        green "当前拥塞控制算法: bbr"
    else
        yellow "当前内核不支持 BBR, 已回退为: ${cc:-未知} (不影响使用, 可升级内核后重新执行 optimize)"
    fi
}

# ---------------- 防火墙自动放行 ----------------
open_port() {
    local port=$1 proto=${2:-tcp}
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "$port/$proto" >/dev/null 2>&1
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="$port/$proto" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    fi
}

# ---------------- 基础配置 ----------------
# 注意: 不写 domain_strategy / sniff 等已废弃的 inbound-level 字段,
# 这些字段在 sing-box 1.13.0 起会导致 check 直接 FATAL。
init_base_config() {
    mkdir -p "$is_conf_dir" "$is_log_dir" "$is_cert_dir" "$is_link_dir"
    cat >"$is_conf_dir/00base.json" <<EOF
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

repair_base() {
    check_root
    init_base_config
    green "已重建 00base.json (清除过期/废弃字段引发的启动失败)."
    restart_core
}

# 唯一保留的 listen 级性能字段: tcp_fast_open 在 sing-box 1.13+ 仍然合法,
# sniff / sniff_override_destination / domain_strategy 已彻底移除, 绝不能再加回来。
inbound_perf='"tcp_fast_open": true'

# ---------------- 重启并校验, 失败自动回滚 ----------------
restart_core() {
    local bad_file=$1
    if ! "$is_core_bin" check -C "$is_conf_dir" 2>/tmp/sb_check.log; then
        red "配置检查失败:"
        cat /tmp/sb_check.log
        if [[ $bad_file && -f $bad_file ]]; then
            rm -f "$bad_file"
            yellow "已自动删除刚才写入的坏配置 ($bad_file), 不会影响其余已存在的节点。"
        fi
        return 1
    fi
    systemctl restart sing-box
    sleep 0.3
    if ! systemctl is-active --quiet sing-box; then
        red "sing-box 服务未能正常启动, 请执行: journalctl -u sing-box -n 50 --no-pager 查看详细日志."
        return 1
    fi
}

# ---------------- 添加节点 ----------------
# AnyTLS: 自签证书, 不设置任何伪装域名 (insecure=1 已跳过证书校验, 伪装域名没有实际意义)
add_anytls() {
    local port pass name cert key
    port=$(get_port)
    pass=$(gen_pass)
    name="anytls-$port"
    mkdir -p "$is_cert_dir"
    cert="$is_cert_dir/$name.cert.pem"
    key="$is_cert_dir/$name.key.pem"
    openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
    openssl req -new -x509 -days 36500 -key "$key" -out "$cert" -subj "/CN=$is_addr" 2>/dev/null

    cat >"$is_conf_dir/$name.json" <<EOF
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
        "certificate_path": "$cert",
        "key_path": "$key"
      }
    }
  ]
}
EOF
    restart_core "$is_conf_dir/$name.json" || return 1
    open_port "$port" tcp
    local url="anytls://$pass@$is_ip_fmt:$port?insecure=1#$name"
    mkdir -p "$is_link_dir"
    echo "$url" >"$is_link_dir/$name.txt"
    green "\nAnyTLS 节点已创建 (无伪装域名, 自签证书):"
    echo "$url"
}

# Reality: 伪装站默认 www.tesla.com, 可用 jsb reality <域名> 或菜单里选择/自定义
pick_reality_sni() {
    is_reality_sni=${is_reality_sni_input:-$is_reality_sni_default}
}

add_reality() {
    local port uuid keypair prikey pubkey sid name
    pick_reality_sni
    port=$(get_port)
    uuid=$(gen_uuid)
    keypair=$("$is_core_bin" generate reality-keypair)
    prikey=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    pubkey=$(echo "$keypair" | awk '/PublicKey/{print $2}')
    sid=$(gen_shortid)
    name="reality-$port"

    cat >"$is_conf_dir/$name.json" <<EOF
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
    restart_core "$is_conf_dir/$name.json" || return 1
    open_port "$port" tcp
    local url="vless://$uuid@$is_ip_fmt:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$is_reality_sni&fp=chrome&pbk=$pubkey&sid=$sid&type=tcp#$name"
    mkdir -p "$is_link_dir"
    echo "$url" >"$is_link_dir/$name.txt"
    green "\nVLESS-Reality 节点已创建 (伪装: $is_reality_sni):"
    echo "$url"
}

add_vless_ws_tls() {
    local port=443 uuid path name domain enc_path url resolved
    read -rp "请输入已解析到本机的域名: " domain
    [[ ! $domain ]] && err "域名不能为空."

    # 域名解析检查 (套 CF 橙云会导致 ACME 失败, 提前提醒)
    resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR==1{print $1}')
    if [[ $resolved && $resolved != "$is_addr" ]]; then
        yellow "警告: $domain 解析到 $resolved, 与本机 IP ($is_addr) 不一致。"
        yellow "若域名在 Cloudflare 上开了代理(橙云), 请先改为仅 DNS(灰云), 否则证书无法签发。"
        read -rp "仍要继续? [y/N]: " yn
        [[ ! $yn =~ ^[Yy]$ ]] && return 1
    fi

    # 80 端口用于 ACME HTTP-01 挑战, 必须空闲
    if ss -tlnp 2>/dev/null | awk '{print $4}' | grep -qE ':(80)$'; then
        err "80 端口已被占用, ACME 证书签发需要 80 端口, 请先停掉占用它的程序。"
    fi

    uuid=$(gen_uuid)
    path="/$uuid"
    name="vless-ws-tls-$domain"

    cat >"$is_conf_dir/${name}.json" <<EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "$name",
      "listen": "::",
      "listen_port": $port,
      $inbound_perf,
      "users": [ { "uuid": "$uuid" } ],
      "tls": {
        "enabled": true,
        "server_name": "$domain",
        "acme": {
          "domain": ["$domain"],
          "email": "acme@$domain",
          "data_directory": "$is_cert_dir/acme"
        }
      },
      "transport": { "type": "ws", "path": "$path" }
    }
  ]
}
EOF
    restart_core "$is_conf_dir/${name}.json" || return 1
    open_port 80 tcp
    open_port 443 tcp

    # 等待首次证书签发
    yellow "正在等待 Let's Encrypt 证书签发 (首次约 10~60 秒)..."
    local i ok=
    for i in $(seq 1 30); do
        if echo | timeout 5 openssl s_client -connect 127.0.0.1:443 \
            -servername "$domain" 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
            ok=1; break
        fi
        sleep 2
    done
    if [[ $ok ]]; then
        green "证书签发成功。"
    else
        yellow "暂未检测到有效证书, 可能仍在签发中或已失败。"
        yellow "排查: tail -n 50 $is_log_dir/box.log ; 确认 80/443 已在云厂商安全组放行、域名为灰云直连。"
    fi

    enc_path=$(echo "$path" | sed 's:/:%2F:g')
    url="vless://$uuid@$domain:443?encryption=none&security=tls&sni=$domain&type=ws&host=$domain&path=$enc_path#$name"
    mkdir -p "$is_link_dir"
    echo "$url" >"$is_link_dir/$name.txt"    green "\nVLESS-WS-TLS 节点已创建:"
    echo "$url"
}

# ---------------- systemd 服务 ----------------
install_service() {
    cat >/etc/systemd/system/sing-box.service <<EOF
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
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
}

# ---------------- 快捷命令 / 自更新 ----------------
install_shortcut() {
    mkdir -p "$is_dir"
    cp -f "$0" "$is_sh_self" 2>/dev/null
    chmod +x "$is_sh_self"
    ln -sf "$is_sh_self" "$is_sh_file"
    chmod +x "$is_sh_file"
}

# jsb 安装后是"冻结"在安装那一刻的脚本副本, GitHub 上后续的修复不会自动生效。
# 用这个命令强制拉取最新脚本并原地替换 (会先做语法校验, 校验不过不会替换)。
update_script() {
    check_root
    green "正在从 GitHub 拉取最新脚本..."
    local tmp
    tmp=$(mktemp)
    if ! _wget "${is_repo_raw}?t=$RANDOM" -o "$tmp"; then
        rm -f "$tmp"
        err "下载最新脚本失败, 请检查网络."
    fi
    if ! bash -n "$tmp"; then
        rm -f "$tmp"
        err "下载到的脚本语法校验未通过, 已放弃更新 (可能是仓库还没改完, 或网络被劫持)."
    fi
    install -m 755 "$tmp" "$is_sh_self"
    ln -sf "$is_sh_self" "$is_sh_file"
    rm -f "$tmp"
    green "脚本已更新, 重新进入菜单:"
    exec "$is_sh_file" menu
}

# ---------------- 卸载 ----------------
uninstall_all() {
    yellow "即将完整卸载 sing-box、所有配置及优化设置。"
    read -rp "确认卸载? [y/N]: " yn
    [[ ! $yn =~ ^[Yy]$ ]] && {
        msg "已取消."
        return
    }
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

# ---------------- 状态 / 节点管理 ----------------
show_status() {
    systemctl status sing-box --no-pager -l | head -n 15
}

list_nodes() {
    green "已安装节点:"
    local f found=
    for f in "$is_link_dir"/*.txt; do
        [[ -f $f ]] || continue
        found=1
        echo "  $(basename "$f" .txt)"
    done
    [[ ! $found ]] && echo "  (暂无节点)"
}

show_node() {
    local name=$1
    [[ ! $name ]] && {
        list_nodes
        read -rp "请输入节点名称: " name
    }
    local f="$is_link_dir/$name.txt"
    [[ ! -f $f ]] && err "未找到节点: $name"
    local url
    url=$(cat "$f")
    echo
    green "$name:"
    echo "$url"
    if command -v qrencode >/dev/null 2>&1; then
        echo
        qrencode -t ANSIUTF8 "$url"
    else
        yellow "(未安装 qrencode, 仅显示链接文本, 可自行安装: apt install qrencode)"
    fi
}

del_node() {
    check_root
    local name=$1
    [[ ! $name ]] && {
        list_nodes
        read -rp "请输入要删除的节点名称: " name
    }
    local f="$is_conf_dir/$name.json"
    [[ ! -f $f ]] && err "未找到节点: $name"
    rm -f "$f" "$is_link_dir/$name.txt" \
        "$is_cert_dir/$name.cert.pem" "$is_cert_dir/$name.key.pem"
    restart_core
    green "已删除节点: $name"
}

# ---------------- 安装主流程 ----------------
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
    green "以后输入 jsb 打开菜单 (jsb update 可随时拉取最新脚本).\n"
    get_ip
    menu
}

# ---------------- 菜单 ----------------
menu_pick_reality_sni() {
    echo
    echo "选择 Reality 伪装站 (默认: $is_reality_sni_default):"
    local i=1 s
    for s in "${is_reality_sni_pool[@]}"; do
        echo "  $i) $s"
        ((i++))
    done
    read -rp "输入编号选择, 或直接输入自定义域名, 留空使用默认: " sni_choice
    if [[ $sni_choice =~ ^[0-9]+$ ]] && [[ ${is_reality_sni_pool[$((sni_choice - 1))]} ]]; then
        is_reality_sni_input=${is_reality_sni_pool[$((sni_choice - 1))]}
    elif [[ $sni_choice ]]; then
        is_reality_sni_input=$sni_choice
    else
        is_reality_sni_input=
    fi
}

menu() {
    check_root
    check_arch
    get_core_ver
    get_ip
    while true; do
        echo
        green "===== sing-box 精简管理菜单 ====="
        echo "   1) 添加 AnyTLS       (自动端口/密码, 无伪装域名)"
        echo "   2) 添加 Reality      (自动端口/密钥, 可选伪装站)"
        echo "   3) 添加 VLESS-WS-TLS (需域名)"
        echo "   4) 查看节点列表"
        echo "   5) 查看节点链接/二维码"
        echo "   6) 删除节点"
        echo "   7) 运行状态"
        echo "   8) 重启服务"
        echo "   9) 重建基础配置 (修复 00base.json 过期字段)"
        echo "  10) 更新脚本 (拉取 GitHub 最新 jsb.sh)"
        echo "  99) 完整卸载"
        echo "   0) 退出"
        echo "=================================="
        read -rp "请选择: " opt
        case $opt in
            1) add_anytls ;;
            2)
                menu_pick_reality_sni
                add_reality
                ;;
            3) add_vless_ws_tls ;;
            4) list_nodes ;;
            5) show_node ;;
            6) del_node ;;
            7) show_status ;;
            8) systemctl restart sing-box && green "已重启." ;;
            9) repair_base ;;
            10) update_script ;;
            99)
                uninstall_all
                break
                ;;
            0) exit 0 ;;
            *) red "无效选项" ;;
        esac
        echo
        read -rp "按回车键返回菜单..." _
    done
}

show_help() {
    cat <<EOF
用法: jsb [命令] [参数]

  install [版本号]   首次安装 (未安装时), 或打开菜单 (已安装时)
  menu | add          打开管理菜单 (默认行为)
  anytls              直接添加一个 AnyTLS 节点
  reality [伪装域名]  直接添加一个 Reality 节点
  ws | vless          直接添加一个 VLESS-WS-TLS 节点 (会询问域名)
  list | ls           查看节点列表
  qr | info <名称>    查看节点链接与二维码
  del | rm <名称>     删除指定节点
  status | s           查看运行状态
  restart              重启服务
  repair                重建 00base.json (修复过期字段导致的启动失败)
  update                从 GitHub 拉取最新脚本并原地替换
  uninstall | un        完整卸载

不带参数直接运行 jsb 即打开交互菜单。
EOF
}

# ---------------- 入口 ----------------
case "$1" in
    install)
        if [[ -x $is_core_bin ]]; then
            menu
        else
            is_core_ver_override=$2
            do_install
        fi
        ;;
    "" | menu | add)
        if [[ -x $is_core_bin ]]; then
            menu
        else
            do_install
        fi
        ;;
    anytls)
        check_root
        check_arch
        get_core_ver
        get_ip
        add_anytls
        ;;
    reality)
        check_root
        check_arch
        get_core_ver
        get_ip
        is_reality_sni_input=$2
        add_reality
        ;;
    ws | vless)
        check_root
        check_arch
        get_core_ver
        get_ip
        add_vless_ws_tls
        ;;
    status | s) show_status ;;
    list | ls) list_nodes ;;
    qr | info | show) show_node "$2" ;;
    del | rm) del_node "$2" ;;
    repair) repair_base ;;
    update) update_script ;;
    restart)
        check_root
        systemctl restart sing-box && green "已重启."
        ;;
    uninstall | un) uninstall_all ;;
    h | help | --help | -h) show_help ;;
    *)
        red "无法识别的参数: $1"
        show_help
        ;;
esac
