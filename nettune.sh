#!/usr/bin/env bash
#
# proxy-net-tune.sh
# Dedicated Debian VPS network tuning for AnyTLS, VLESS/WS/TLS/CDN,
# sing-box/Xray and Hysteria/QUIC workloads.
#
# Design goals:
#   - Fast and stable proxy traffic without intentional bandwidth shaping.
#   - BBR + fq for locally generated TCP traffic when the kernel supports it.
#   - Dynamic TCP/UDP buffer ceilings from bandwidth, user-provided RTT and RAM.
#   - High, correctly applied file-descriptor limits for systemd services.
#   - Optional, separately confirmed XanMod LTS/BBRv3 kernel installation.
#   - Dedicated config files, backups, runtime validation and rollback.
#
# This script intentionally does NOT set panic-on-OOM, kernel panic timers,
# arbitrary TIME_WAIT limits, obsolete TCP knobs, ARP tuning, or CAKE shaping.

set -u
set -o pipefail

readonly SCRIPT_VERSION="1.1.0"
readonly PROGRAM_NAME="proxy-net-tune"
readonly SYSCTL_CONF="/etc/sysctl.d/99-zz-proxy-net-tune.conf"
readonly LIMITS_CONF="/etc/security/limits.d/99-zz-proxy-net-tune.conf"
readonly SYSTEMD_CONF="/etc/systemd/system.conf.d/99-zz-proxy-net-tune.conf"
readonly MODULES_CONF="/etc/modules-load.d/99-zz-proxy-net-tune.conf"
readonly STATE_DIR="/var/lib/proxy-net-tune"
readonly BACKUP_ROOT="/var/backups/proxy-net-tune"
readonly MIB=1048576
readonly XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly XANMOD_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_REPO_FILE="/etc/apt/sources.list.d/xanmod-release.list"

ACTION="apply"
DRY_RUN=0
ASSUME_YES=0
LOCAL_MBPS=""
SERVER_MBPS=""
IP_MODE=""
RTT_INPUT=""
APPLYING=0
ACTIVE_BACKUP=""

# Populated by detection/calculation.
MEM_MB=0
SWAP_MB=0
CPU_CORES=1
ARCH="unknown"
KERNEL_RELEASE="unknown"
VIRT_TYPE="unknown"
PRIMARY_IFACE=""
RTT_MS=0
RTT_SOURCE="用户提供的本机实测值"
EFFECTIVE_MBPS=0
BDP_BYTES=0
BUFFER_MIB=0
BUFFER_BYTES=0
BUFFER_CAP_MIB=0
BUFFER_WAS_CAPPED=0
NETDEV_BACKLOG=4096
SOMAXCONN=4096
SYN_BACKLOG=8192
NOTSENT_LOWAT=131072
NOFILE_LIMIT=1048576
SELECTED_CC="cubic"
SELECTED_QDISC="fq"
KERNEL_ADVICE=""
KERNEL_ADVICE_DETAIL=""
RECOMMEND_BBRV3=0
OFFER_BBRV3_INSTALL=0
XANMOD_PACKAGE=""
XANMOD_ABI=""
DEBIAN_CODENAME=""
KERNEL_INSTALLED=0
FUTURE_BBR_ONLY=0

declare -a SYSCTL_KEYS=()
declare -a SYSCTL_VALUES=()
declare -a SYSCTL_NOTES=()
declare -a SKIPPED_SETTINGS=()

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
else
    C_RESET=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_CYAN=""
    C_BOLD=""
fi

info() { printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[注意]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
heading() { printf '\n%s%s%s\n' "$C_BOLD$C_CYAN" "$*" "$C_RESET"; }

die() {
    error "$*"
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  sudo bash proxy-net-tune.sh [选项]

默认行为是交互式分析并应用配置。

选项:
  --local-mbps N     本地宽带，默认 1000 Mbps
  --server-mbps N    VPS 标称带宽，默认 1000 Mbps
  --ip-mode MODE     4、6 或 dual，默认 dual
  --rtt-ms N         本机到 VPS 的真实往返延迟（毫秒）
  --dry-run          只生成并显示配置，不修改系统
  --yes              跳过网络配置确认（不会跳过 BBRv3 内核确认）
  --status           显示当前网络调优状态
  --restore          恢复最近一次网络/FD 配置（不卸载内核）
  --self-test        执行内置计算测试
  --help             显示帮助

示例:
  sudo bash proxy-net-tune.sh
  bash proxy-net-tune.sh --dry-run --server-mbps 1000 --rtt-ms 100 --ip-mode dual
  sudo bash proxy-net-tune.sh --restore
EOF
}

is_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

clamp() {
    local value=$1 minimum=$2 maximum=$3
    ((value < minimum)) && value=$minimum
    ((value > maximum)) && value=$maximum
    printf '%s\n' "$value"
}

make_temp() {
    local base candidate
    for base in "${TMPDIR:-/tmp}" /var/tmp /run "$PWD"; do
        [[ -d $base && -w $base ]] || continue
        candidate=$(mktemp "$base/proxy-net-tune.XXXXXX" 2>/dev/null) || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

decimal_ge() {
    # Compare non-negative decimal integers without overflowing bash arithmetic.
    local a=${1:-0} b=${2:-0}
    while [[ $a == 0* && ${#a} -gt 1 ]]; do a=${a#0}; done
    while [[ $b == 0* && ${#b} -gt 1 ]]; do b=${b#0}; done
    if ((${#a} != ${#b})); then
        ((${#a} > ${#b}))
    else
        [[ $a == "$b" || $a > "$b" ]]
    fi
}

version_ge() {
    local have=$1 want=$2 first
    first=$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)
    [[ $first == "$want" ]]
}

sysctl_path() {
    printf '/proc/sys/%s\n' "${1//./\/}"
}

sysctl_exists() {
    [[ -e $(sysctl_path "$1") ]]
}

get_sysctl() {
    sysctl -n "$1" 2>/dev/null || true
}

word_in_list() {
    local needle=$1 list=$2 word
    for word in $list; do
        [[ $word == "$needle" ]] && return 0
    done
    return 1
}

prompt_uint() {
    local label=$1 default=$2 minimum=$3 maximum=$4 value
    while true; do
        read -r -p "$label [$default]: " value
        value=${value:-$default}
        if is_uint "$value" && ((value >= minimum && value <= maximum)); then
            printf '%s\n' "$value"
            return 0
        fi
        warn "请输入 ${minimum}-${maximum} 范围内的整数。"
    done
}

prompt_required_uint() {
    local label=$1 minimum=$2 maximum=$3 value
    while true; do
        read -r -p "$label: " value || return 1
        if is_uint "$value" && ((value >= minimum && value <= maximum)); then
            printf '%s\n' "$value"
            return 0
        fi
        warn "此项没有自动估算值，请输入 ${minimum}-${maximum} 范围内的整数。"
    done
}

prompt_ip_mode() {
    local answer
    while true; do
        cat >&2 <<'EOF'
IP 网络类型:
  1) 仅 IPv4
  2) 仅 IPv6
  3) IPv4 + IPv6 双栈（默认）
EOF
        read -r -p "请选择 [3]: " answer
        case ${answer:-3} in
            1 | 4 | ipv4 | IPv4) printf '4\n'; return 0 ;;
            2 | 6 | ipv6 | IPv6) printf '6\n'; return 0 ;;
            3 | dual | Dual | both) printf 'dual\n'; return 0 ;;
            *) warn "请选择 1、2 或 3。" ;;
        esac
    done
}

confirm_apply() {
    ((ASSUME_YES == 1)) && return 0
    local answer
    read -r -p "确认写入并应用以上配置？输入 YES 继续: " answer
    [[ $answer == "YES" ]]
}

parse_args() {
    while (($#)); do
        case $1 in
            --local-mbps)
                (($# >= 2)) || die "--local-mbps 缺少数值"
                LOCAL_MBPS=$2
                shift 2
                ;;
            --server-mbps)
                (($# >= 2)) || die "--server-mbps 缺少数值"
                SERVER_MBPS=$2
                shift 2
                ;;
            --ip-mode)
                (($# >= 2)) || die "--ip-mode 缺少模式"
                IP_MODE=$2
                shift 2
                ;;
            --rtt-ms)
                (($# >= 2)) || die "--rtt-ms 缺少数值"
                RTT_INPUT=$2
                shift 2
                ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes | -y) ASSUME_YES=1; shift ;;
            --status) ACTION="status"; shift ;;
            --restore) ACTION="restore"; shift ;;
            --self-test) ACTION="self-test"; shift ;;
            --help | -h) ACTION="help"; shift ;;
            *) die "未知选项: $1（使用 --help 查看帮助）" ;;
        esac
    done
}

require_commands() {
    local missing=() command_name
    for command_name in awk sed sort head grep sysctl ip tc uname nproc; do
        command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
    done
    ((${#missing[@]} == 0)) || die "缺少必要命令: ${missing[*]}。请安装 procps、iproute2 和 coreutils。"
}

require_debian() {
    local os_id=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id=${ID:-}
    fi
    if [[ $os_id != "debian" ]]; then
        ((DRY_RUN == 1)) && warn "当前不是 Debian；试运行继续，但不会保证配置兼容。" && return 0
        die "此版本只支持 Debian VPS。"
    fi
}

require_root() {
    ((EUID == 0)) || die "应用或恢复配置需要 root 权限，请使用 sudo。"
}

detect_system() {
    local detected_mem
    detected_mem=$(( $(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '0') / 1024 ))
    MEM_MB=${PROXY_TUNE_TEST_MEM_MB:-$detected_mem}
    ((MEM_MB > 0)) || MEM_MB=512

    SWAP_MB=$(( $(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '0') / 1024 ))
    CPU_CORES=${PROXY_TUNE_TEST_CPU:-$(nproc 2>/dev/null || printf '1')}
    is_uint "$CPU_CORES" || CPU_CORES=1
    ((CPU_CORES > 0)) || CPU_CORES=1
    ARCH=$(uname -m 2>/dev/null || printf 'unknown')
    KERNEL_RELEASE=$(uname -r 2>/dev/null || printf 'unknown')
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DEBIAN_CODENAME=${VERSION_CODENAME:-}
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        VIRT_TYPE=$(systemd-detect-virt 2>/dev/null) || VIRT_TYPE="none"
    else
        VIRT_TYPE="unknown"
    fi
    PRIMARY_IFACE=$(detect_primary_iface) || PRIMARY_IFACE=""
    return 0
}

detect_primary_iface() {
    local iface=""
    case ${IP_MODE:-dual} in
        4) iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}') ;;
        6) iface=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}') ;;
        *)
            iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
            [[ -n $iface ]] || iface=$(ip -6 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
            ;;
    esac
    [[ $iface =~ ^[[:alnum:]_.:-]+$ ]] && printf '%s\n' "$iface"
}

set_rtt_input() {
    if [[ -z $RTT_INPUT ]]; then
        if [[ -t 0 ]]; then
            printf '\n请在本机 ping 这台 VPS，填写大致的 avg/平均延迟。\n' >&2
            RTT_INPUT=$(prompt_required_uint "本机到 VPS 的真实往返延迟 RTT（ms）" 1 1000) \
                || die "未读取到 RTT，已取消。"
        else
            die "非交互运行必须提供 --rtt-ms N（本机到 VPS 的真实往返延迟）"
        fi
    fi
    is_uint "$RTT_INPUT" && ((RTT_INPUT >= 1 && RTT_INPUT <= 1000)) \
        || die "RTT 必须是 1-1000 ms 的整数"
    RTT_MS=$RTT_INPUT
    RTT_SOURCE="用户提供的本机实测值"
}

calculate_tuning() {
    if ((LOCAL_MBPS <= SERVER_MBPS)); then EFFECTIVE_MBPS=$LOCAL_MBPS; else EFFECTIVE_MBPS=$SERVER_MBPS; fi
    BDP_BYTES=$((EFFECTIVE_MBPS * 125 * RTT_MS))

    # 2.4x BDP provides receive-window overhead plus headroom while retaining
    # Linux autotuning. Round to a 4 MiB boundary for predictable output.
    local target_bytes target_mib rounded_mib
    target_bytes=$(((BDP_BYTES * 24 + 9) / 10))
    ((target_bytes < 8 * MIB)) && target_bytes=$((8 * MIB))
    target_mib=$(((target_bytes + MIB - 1) / MIB))
    rounded_mib=$((((target_mib + 3) / 4) * 4))

    BUFFER_CAP_MIB=$((MEM_MB / 16))
    BUFFER_CAP_MIB=$(clamp "$BUFFER_CAP_MIB" 16 256)
    BUFFER_WAS_CAPPED=0
    if ((rounded_mib > BUFFER_CAP_MIB)); then
        rounded_mib=$BUFFER_CAP_MIB
        BUFFER_WAS_CAPPED=1
    fi
    BUFFER_MIB=$rounded_mib
    BUFFER_BYTES=$((BUFFER_MIB * MIB))

    if ((EFFECTIVE_MBPS <= 200)); then
        NETDEV_BACKLOG=2048
        NOTSENT_LOWAT=65536
    elif ((EFFECTIVE_MBPS <= 1000)); then
        NETDEV_BACKLOG=8192
        NOTSENT_LOWAT=131072
    elif ((EFFECTIVE_MBPS <= 2500)); then
        NETDEV_BACKLOG=16384
        NOTSENT_LOWAT=131072
    else
        NETDEV_BACKLOG=32768
        NOTSENT_LOWAT=262144
    fi
    ((CPU_CORES == 1 && NETDEV_BACKLOG > 8192)) && NETDEV_BACKLOG=8192
    ((MEM_MB <= 512 && NETDEV_BACKLOG > 4096)) && NETDEV_BACKLOG=4096
    ((MEM_MB <= 1024 && NETDEV_BACKLOG > 8192)) && NETDEV_BACKLOG=8192

    if ((MEM_MB <= 512)); then
        SOMAXCONN=2048
    elif ((MEM_MB <= 2048)); then
        SOMAXCONN=4096
    else
        SOMAXCONN=8192
    fi
    SYN_BACKLOG=$((SOMAXCONN * 2))
    ((SYN_BACKLOG > 65536)) && SYN_BACKLOG=65536
    return 0
}

select_algorithms() {
    local available="" qdisc_loaded=0 bbr_module_present=0
    if ((DRY_RUN == 0)) && command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >/dev/null 2>&1 || true
        if modprobe sch_fq >/dev/null 2>&1; then qdisc_loaded=1; fi
    fi
    available=$(get_sysctl net.ipv4.tcp_available_congestion_control)
    if ((DRY_RUN == 1)); then
        if command -v modinfo >/dev/null 2>&1 && modinfo tcp_bbr >/dev/null 2>&1; then
            bbr_module_present=1
        elif compgen -G "/lib/modules/$KERNEL_RELEASE/kernel/net/ipv4/tcp_bbr.ko*" >/dev/null; then
            bbr_module_present=1
        fi
    fi
    if word_in_list bbr "$available"; then
        SELECTED_CC="bbr"
    elif ((bbr_module_present == 1)); then
        SELECTED_CC="bbr"
    elif word_in_list cubic "$available"; then
        SELECTED_CC="cubic"
    else
        SELECTED_CC="reno"
    fi

    if ((qdisc_loaded == 1)) || [[ -d /sys/module/sch_fq ]] || [[ $(get_sysctl net.core.default_qdisc) == "fq" ]]; then
        SELECTED_QDISC="fq"
    elif ((DRY_RUN == 0)) && command -v modprobe >/dev/null 2>&1 && modprobe sch_fq_codel >/dev/null 2>&1; then
        SELECTED_QDISC="fq_codel"
    else
        # Modern Debian kernels include sch_fq; retaining fq in dry-run also
        # makes the intended result clear.
        SELECTED_QDISC="fq"
    fi
}

is_container_guest() {
    case $VIRT_TYPE in
        docker | lxc | lxc-libvirt | openvz | podman | systemd-nspawn | wsl | proot | container-other)
            return 0
            ;;
    esac
    [[ -e /.dockerenv || -e /run/.containerenv ]]
}

detect_xanmod_abi() {
    local loader output="" flags=""
    XANMOD_ABI="x64v1"
    for loader in /lib64/ld-linux-x86-64.so.2 /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2; do
        [[ -x $loader ]] || continue
        output=$($loader --help 2>/dev/null || true)
        if printf '%s\n' "$output" | grep -Eq 'x86-64-v3.*\(supported'; then
            XANMOD_ABI="x64v3"
            return 0
        fi
        if printf '%s\n' "$output" | grep -Eq 'x86-64-v2.*\(supported'; then
            XANMOD_ABI="x64v2"
            return 0
        fi
    done

    # Fallback for unusual layouts without a directly executable glibc loader.
    flags=$(awk -F: '/^flags[[:space:]]*:/ {print " " $2 " "; exit}' /proc/cpuinfo 2>/dev/null || true)
    if [[ $flags == *" avx "* && $flags == *" avx2 "* && $flags == *" bmi1 "* \
        && $flags == *" bmi2 "* && $flags == *" f16c "* && $flags == *" fma "* \
        && $flags == *" movbe "* && ( $flags == *" abm "* || $flags == *" lzcnt "* ) ]]; then
        XANMOD_ABI="x64v3"
    elif [[ $flags == *" cx16 "* && $flags == *" popcnt "* && $flags == *" ssse3 "* \
        && $flags == *" sse4_1 "* && $flags == *" sse4_2 "* ]]; then
        XANMOD_ABI="x64v2"
    fi
}

installed_xanmod_package() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    dpkg-query -W -f='${binary:Package}\t${Status}\n' 'linux-xanmod*' 2>/dev/null \
        | awk '$2 == "install" && $3 == "ok" && $4 == "installed" {print $1; exit}' \
        || true
}

xanmod_codename_supported() {
    case $DEBIAN_CODENAME in
        bookworm | trixie | forky | sid) return 0 ;;
        *) return 1 ;;
    esac
}

build_kernel_advice() {
    local numeric_version=${KERNEL_RELEASE%%-*} installed_package="" high_bdp_path=0
    RECOMMEND_BBRV3=0
    OFFER_BBRV3_INSTALL=0
    KERNEL_ADVICE_DETAIL=""
    detect_xanmod_abi
    XANMOD_PACKAGE="linux-xanmod-lts-${XANMOD_ABI}"

    # Conservative recommendation gate: BBRv3 is only proposed for a genuinely
    # long-haul, high-throughput TCP path, not merely because it exists.
    if ((RTT_MS >= 70 && EFFECTIVE_MBPS >= 500 && BDP_BYTES >= 4 * MIB)); then
        high_bdp_path=1
    elif ((RTT_MS >= 100 && EFFECTIVE_MBPS >= 200 && BDP_BYTES >= 8 * MIB)); then
        high_bdp_path=1
    fi

    if [[ $KERNEL_RELEASE == *xanmod* ]] && version_ge "$numeric_version" "6.7"; then
        KERNEL_ADVICE="保留当前 XanMod 内核；已属于官方集成 BBRv3 的版本范围。"
        KERNEL_ADVICE_DETAIL="无需重复安装；sysctl 中的 bbr 会调用当前内核实现。"
        return 0
    fi
    if [[ $KERNEL_RELEASE == *bbr3* ]]; then
        KERNEL_ADVICE="检测到标记为 BBRv3 的定制内核，保留当前内核。"
        KERNEL_ADVICE_DETAIL="脚本无法仅从运行时名称验证第三方补丁来源。"
        return 0
    fi

    installed_package=$(installed_xanmod_package)
    if [[ -n $installed_package && $KERNEL_RELEASE != *xanmod* ]]; then
        KERNEL_ADVICE="检测到已安装的 $installed_package，但当前没有运行它。"
        KERNEL_ADVICE_DETAIL="建议先重启并用 uname -r 确认；不会重复安装内核。"
        return 0
    fi

    if ((high_bdp_path == 1)); then
        RECOMMEND_BBRV3=1
        KERNEL_ADVICE="推荐 XanMod LTS/BBRv3（${XANMOD_PACKAGE}）。"
        KERNEL_ADVICE_DETAIL="依据：${EFFECTIVE_MBPS} Mbps、${RTT_MS} ms 的高 BDP 长距离路径；这是偏性能的建议，不保证比普通 BBR 更快。BBRv3 只影响 TCP；Hysteria/QUIC 不受它控制，CDN 模式也只影响 VPS 到 CDN 节点这一段。"

        if [[ $ARCH != "x86_64" ]]; then
            KERNEL_ADVICE_DETAIL+=" 当前架构 ${ARCH} 不在 XanMod 官方 amd64 仓库范围内，因此不提供自动安装。"
        elif is_container_guest; then
            KERNEL_ADVICE_DETAIL+=" 当前是 ${VIRT_TYPE} 容器，无法自行更换宿主机内核，因此不提供自动安装。"
        elif ! xanmod_codename_supported; then
            KERNEL_ADVICE_DETAIL+=" Debian 代号 ${DEBIAN_CODENAME:-未知} 不在脚本核验的官方支持列表内，因此不提供自动安装。"
        else
            OFFER_BBRV3_INSTALL=1
        fi
        return 0
    fi

    if [[ $SELECTED_CC != "bbr" ]]; then
        if [[ $ARCH == "x86_64" ]]; then
            KERNEL_ADVICE="当前路径规模无需冒险换第三方内核；先更新 Debian 官方 linux-image-amd64 以获得普通 BBR。"
        elif [[ $ARCH == "aarch64" || $ARCH == "arm64" ]]; then
            KERNEL_ADVICE="当前路径规模无需换第三方内核；先更新 Debian 官方 arm64 内核以获得普通 BBR。"
        else
            KERNEL_ADVICE="使用 Debian 为 ${ARCH} 提供的受维护内核；当前暂用 ${SELECTED_CC}。"
        fi
    elif ! version_ge "$numeric_version" "5.10"; then
        KERNEL_ADVICE="BBR 可用但内核较旧，建议升级 Debian 官方受维护内核。"
    else
        KERNEL_ADVICE="普通 BBR + fq 已适合当前带宽/延迟规模，不建议仅为版本号更换内核。"
    fi
}

add_setting() {
    SYSCTL_KEYS+=("$1")
    SYSCTL_VALUES+=("$2")
    SYSCTL_NOTES+=("${3:-}")
}

prepare_settings() {
    SYSCTL_KEYS=()
    SYSCTL_VALUES=()
    SYSCTL_NOTES=()

    local current_file_max current_nr_open desired_file_max
    current_file_max=$(get_sysctl fs.file-max)
    current_nr_open=$(get_sysctl fs.nr_open)
    desired_file_max=$((NOFILE_LIMIT * 2))
    if [[ -z $current_file_max ]] || ! decimal_ge "$current_file_max" "$desired_file_max"; then
        add_setting fs.file-max "$desired_file_max" "全局文件句柄上限（只增不减）"
    fi
    if [[ -z $current_nr_open ]] || ! decimal_ge "$current_nr_open" "$NOFILE_LIMIT"; then
        add_setting fs.nr_open "$NOFILE_LIMIT" "单进程 FD 硬上限"
    fi

    add_setting net.core.default_qdisc "$SELECTED_QDISC" "本机代理流量的公平队列与 pacing"
    add_setting net.core.rmem_max "$BUFFER_BYTES" "TCP/UDP 接收缓冲区上限"
    add_setting net.core.wmem_max "$BUFFER_BYTES" "TCP/UDP 发送缓冲区上限"
    add_setting net.core.rmem_default 262144 "非 TCP 套接字默认接收缓冲区"
    add_setting net.core.wmem_default 262144 "非 TCP 套接字默认发送缓冲区"
    add_setting net.core.netdev_max_backlog "$NETDEV_BACKLOG" "虚拟网卡突发队列"
    add_setting net.core.somaxconn "$SOMAXCONN" "监听 accept 队列上限"

    add_setting net.ipv4.tcp_congestion_control "$SELECTED_CC" "TCP 拥塞控制"
    add_setting net.ipv4.tcp_rmem "4096 262144 $BUFFER_BYTES" "TCP 自动接收缓冲区"
    add_setting net.ipv4.tcp_wmem "4096 65536 $BUFFER_BYTES" "TCP 自动发送缓冲区"
    add_setting net.ipv4.tcp_max_syn_backlog "$SYN_BACKLOG" "SYN 队列上限"
    add_setting net.ipv4.tcp_fastopen 3 "允许支持 TFO 的代理应用使用客户端/服务端 TFO"
    add_setting net.ipv4.tcp_fastopen_blackhole_timeout_sec 3600 "TFO 黑洞路径自动退避"
    add_setting net.ipv4.tcp_mtu_probing 1 "仅在发现 PMTU 黑洞时探测 MSS"
    add_setting net.ipv4.tcp_slow_start_after_idle 0 "持久代理连接空闲后保留爬升结果"
    add_setting net.ipv4.tcp_notsent_lowat "$NOTSENT_LOWAT" "限制应用在拥塞窗口外堆积的未发送数据"
    add_setting net.ipv4.tcp_moderate_rcvbuf 1 "启用 TCP 接收缓冲区自动调节"
    add_setting net.ipv4.tcp_window_scaling 1 "允许高 BDP 路径扩大 TCP 窗口"
    add_setting net.ipv4.tcp_timestamps 1 "RTT 测量和 PAWS"
    add_setting net.ipv4.tcp_sack 1 "选择确认以改善丢包恢复"
    add_setting net.ipv4.tcp_syncookies 1 "SYN 队列溢出保护"
    add_setting net.ipv4.ip_local_port_range "10240 65535" "扩大代理出站临时端口范围"

    # Hysteria/QUIC uses application-level congestion control, not TCP BBR.
    # These values guarantee a reasonable minimum while core rmem/wmem_max
    # lets quic-go request a larger SO_RCVBUF/SO_SNDBUF when needed.
    add_setting net.ipv4.udp_rmem_min 16384 "UDP/QUIC 最小接收缓冲区"
    add_setting net.ipv4.udp_wmem_min 16384 "UDP/QUIC 最小发送缓冲区"
}

filter_supported_settings() {
    local -a keys=() values=() notes=()
    local i key current
    SKIPPED_SETTINGS=()
    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        if ! sysctl_exists "$key"; then
            if ((DRY_RUN == 0)); then
                SKIPPED_SETTINGS+=("$key（当前内核不存在）")
                continue
            fi
        fi
        if ((DRY_RUN == 0)); then
            current=$(get_sysctl "$key")
            if [[ -z $current ]] || ! sysctl -q -w "$key=$current" >/dev/null 2>&1; then
                SKIPPED_SETTINGS+=("$key（当前环境禁止写入）")
                continue
            fi
        fi
        keys+=("$key")
        values+=("${SYSCTL_VALUES[$i]}")
        notes+=("${SYSCTL_NOTES[$i]}")
    done
    SYSCTL_KEYS=("${keys[@]}")
    SYSCTL_VALUES=("${values[@]}")
    SYSCTL_NOTES=("${notes[@]}")
}

render_sysctl_config() {
    local destination=$1 i
    {
        printf '# Generated by %s v%s\n' "$PROGRAM_NAME" "$SCRIPT_VERSION"
        printf '# Workload: AnyTLS, VLESS/WS/TLS/CDN, Xray/sing-box, Hysteria/QUIC\n'
        printf '# Inputs: local=%s Mbps, server=%s Mbps, effective=%s Mbps\n' "$LOCAL_MBPS" "$SERVER_MBPS" "$EFFECTIVE_MBPS"
        printf '# RTT input: %s ms (%s); BDP=%s bytes; buffer=%s MiB\n' "$RTT_MS" "$RTT_SOURCE" "$BDP_BYTES" "$BUFFER_MIB"
        printf '# This file may be removed safely, then run: sysctl --system\n\n'
        for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
            [[ -n ${SYSCTL_NOTES[$i]} ]] && printf '# %s\n' "${SYSCTL_NOTES[$i]}"
            printf '%s = %s\n\n' "${SYSCTL_KEYS[$i]}" "${SYSCTL_VALUES[$i]}"
        done
    } >"$destination"
}

print_plan() {
    local bdp_mib
    bdp_mib=$(awk -v bytes="$BDP_BYTES" 'BEGIN {printf "%.2f", bytes / 1048576}')
    heading "代理网络调优计划"
    printf '系统             : Debian / %s / %s / %s vCPU / %s MiB RAM / %s MiB Swap\n' \
        "$ARCH" "$KERNEL_RELEASE" "$CPU_CORES" "$MEM_MB" "$SWAP_MB"
    printf '虚拟化           : %s\n' "$VIRT_TYPE"
    printf '主网卡           : %s\n' "${PRIMARY_IFACE:-未检测到}"
    printf 'IP 模式          : %s\n' "$IP_MODE"
    printf '本地/VPS 带宽    : %s / %s Mbps（有效 %s Mbps）\n' "$LOCAL_MBPS" "$SERVER_MBPS" "$EFFECTIVE_MBPS"
    printf '本机实测 RTT     : %s ms\n' "$RTT_MS"
    printf 'BDP              : %s MiB\n' "$bdp_mib"
    printf 'TCP/UDP 最大缓冲 : %s MiB（RAM 安全上限 %s MiB）\n' "$BUFFER_MIB" "$BUFFER_CAP_MIB"
    printf '拥塞控制 / 队列  : %s + %s\n' "$SELECTED_CC" "$SELECTED_QDISC"
    printf 'FD 上限          : %s（PAM、systemd 和运行中代理进程）\n' "$NOFILE_LIMIT"
    printf '主动带宽限制     : 无\n'
    ((BUFFER_WAS_CAPPED == 1)) && warn "所需窗口超过内存安全上限，已自动裁剪；极端高 BDP 单流可能受内存限制。"
    printf '\n内核建议         : %s\n' "$KERNEL_ADVICE"
    [[ -n $KERNEL_ADVICE_DETAIL ]] && printf '建议说明         : %s\n' "$KERNEL_ADVICE_DETAIL"
    if ((OFFER_BBRV3_INSTALL == 1)); then
        printf '自动安装         : 可选；应用前会单独要求输入 INSTALL BBRV3\n'
    fi
    if ((${#SKIPPED_SETTINGS[@]})); then
        printf '\n跳过的参数:\n'
        printf '  - %s\n' "${SKIPPED_SETTINGS[@]}"
    fi
}

print_config_preview() {
    local temp
    temp=$(make_temp) || die "无法创建临时文件"
    if ! render_sysctl_config "$temp"; then
        rm -f -- "$temp"
        die "无法生成 sysctl 配置预览"
    fi
    heading "将生成的 sysctl 配置"
    sed 's/^/  /' "$temp"
    rm -f -- "$temp"
}

backup_path() {
    local backup_dir=$1 path=$2 relative=${2#/}
    if [[ -e $path || -L $path ]]; then
        mkdir -p -- "$backup_dir/files/$(dirname "$relative")" || return 1
        cp -a -- "$path" "$backup_dir/files/$relative" || return 1
        printf 'present\t%s\n' "$path" >>"$backup_dir/files.manifest" || return 1
    else
        printf 'absent\t%s\n' "$path" >>"$backup_dir/files.manifest" || return 1
    fi
}

create_backup() {
    local timestamp backup_dir i key value root_qdisc=""
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="$BACKUP_ROOT/$timestamp"
    [[ -e $backup_dir ]] && backup_dir="${backup_dir}_$$"
    mkdir -p -- "$backup_dir" || return 1
    : >"$backup_dir/files.manifest" || return 1
    : >"$backup_dir/sysctl.runtime" || return 1

    backup_path "$backup_dir" "$SYSCTL_CONF" || return 1
    backup_path "$backup_dir" "$LIMITS_CONF" || return 1
    backup_path "$backup_dir" "$SYSTEMD_CONF" || return 1
    backup_path "$backup_dir" "$MODULES_CONF" || return 1

    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        value=$(get_sysctl "$key")
        if [[ -n $value ]]; then
            printf '%s\t%s\n' "$key" "$value" >>"$backup_dir/sysctl.runtime" || return 1
        fi
    done

    if [[ -n $PRIMARY_IFACE ]]; then
        root_qdisc=$(tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | awk '/ root / {print $2; exit}')
        tc qdisc show dev "$PRIMARY_IFACE" >"$backup_dir/qdisc.txt" 2>/dev/null || true
    fi
    {
        printf 'IFACE=%s\n' "$PRIMARY_IFACE"
        printf 'ROOT_QDISC=%s\n' "$root_qdisc"
        printf 'QDISC_TOUCHED=0\n'
    } >"$backup_dir/runtime.state" || return 1

    mkdir -p -- "$STATE_DIR" || return 1
    printf '%s\n' "$backup_dir" | write_atomic_file "$STATE_DIR/latest-backup" 0600 || return 1
    ACTIVE_BACKUP=$backup_dir
    info "已备份到 $backup_dir"
}

allowed_managed_path() {
    case $1 in
        "$SYSCTL_CONF" | "$LIMITS_CONF" | "$SYSTEMD_CONF" | "$MODULES_CONF") return 0 ;;
        *) return 1 ;;
    esac
}

restore_backup_internal() {
    local backup_dir=$1 status path relative value key failures=0
    local iface="" root_qdisc="" qdisc_touched=0
    [[ $backup_dir == "$BACKUP_ROOT"/* && -f $backup_dir/files.manifest ]] || {
        error "备份目录无效: $backup_dir"
        return 1
    }

    while IFS=$'\t' read -r status path; do
        [[ -n $status && -n $path ]] || continue
        allowed_managed_path "$path" || {
            warn "忽略备份中的未知路径: $path"
            continue
        }
        relative=${path#/}
        case $status in
            present)
                if [[ ! -e $backup_dir/files/$relative && ! -L $backup_dir/files/$relative ]]; then
                    warn "备份内容缺失: $path"
                    failures=$((failures + 1))
                    continue
                fi
                mkdir -p -- "$(dirname "$path")" || { failures=$((failures + 1)); continue; }
                rm -f -- "$path" || { failures=$((failures + 1)); continue; }
                cp -a -- "$backup_dir/files/$relative" "$path" || failures=$((failures + 1))
                ;;
            absent) rm -f -- "$path" || failures=$((failures + 1)) ;;
        esac
    done <"$backup_dir/files.manifest"

    if [[ -f $backup_dir/sysctl.runtime ]]; then
        while IFS=$'\t' read -r key value; do
            [[ -n $key ]] || continue
            if ! sysctl -q -w "$key=$value" >/dev/null 2>&1; then
                warn "未能恢复运行时参数 $key"
                failures=$((failures + 1))
            fi
        done <"$backup_dir/sysctl.runtime"
    fi

    if [[ -f $backup_dir/runtime.state ]]; then
        while IFS='=' read -r key value; do
            case $key in
                IFACE) iface=$value ;;
                ROOT_QDISC) root_qdisc=$value ;;
                QDISC_TOUCHED) qdisc_touched=$value ;;
            esac
        done <"$backup_dir/runtime.state"
    fi
    if [[ $qdisc_touched == 1 && $iface =~ ^[[:alnum:]_.:-]+$ && -d /sys/class/net/$iface ]]; then
        case $root_qdisc in
            fq | fq_codel | pfifo_fast | cake)
                tc qdisc replace dev "$iface" root "$root_qdisc" >/dev/null 2>&1 \
                    || { warn "未能恢复 $iface 的 $root_qdisc 队列"; failures=$((failures + 1)); }
                ;;
            noqueue | "")
                tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
                ;;
            *) warn "原队列 $root_qdisc 属于复杂配置，脚本此前未应触碰；请检查 tc qdisc show。" ;;
        esac
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    ((failures == 0))
}

rollback_on_failure() {
    local reason=$1
    error "$reason"
    if [[ -n $ACTIVE_BACKUP ]]; then
        warn "正在自动恢复应用前配置……"
        restore_backup_internal "$ACTIVE_BACKUP" || warn "自动恢复不完整，请手动运行 --restore。"
    fi
    APPLYING=0
}

write_atomic_file() {
    local destination=$1 mode=$2 temp
    temp=$(make_temp) || return 1
    cat >"$temp" || { rm -f -- "$temp"; return 1; }
    mkdir -p -- "$(dirname "$destination")" || { rm -f -- "$temp"; return 1; }
    install -m "$mode" "$temp" "$destination"
    local rc=$?
    rm -f -- "$temp"
    return $rc
}

key_fingerprint() {
    local key_file=$1
    gpg --batch --show-keys --with-colons --fingerprint "$key_file" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}'
}

kernel_install_preflight() {
    local free_mb="" root_free_mb=""
    command -v apt-get >/dev/null 2>&1 || {
        error "没有 apt-get，无法使用 XanMod 官方仓库。"
        return 1
    }
    [[ $ARCH == "x86_64" ]] || {
        error "XanMod 自动安装仅支持官方 amd64 包。"
        return 1
    }
    xanmod_codename_supported || {
        error "Debian 代号 ${DEBIAN_CODENAME:-未知} 不在已核验支持列表。"
        return 1
    }
    is_container_guest && {
        error "容器不能自行更换宿主机内核。"
        return 1
    }
    free_mb=$(df -Pm /boot 2>/dev/null | awk 'NR == 2 {print $4}')
    if is_uint "$free_mb" && ((free_mb < 350)); then
        error "/boot 可用空间仅 ${free_mb} MiB；至少预留 350 MiB 后再安装内核。"
        return 1
    fi
    root_free_mb=$(df -Pm / 2>/dev/null | awk 'NR == 2 {print $4}')
    if is_uint "$root_free_mb" && ((root_free_mb < 700)); then
        error "根分区可用空间仅 ${root_free_mb} MiB；至少预留 700 MiB 后再安装内核。"
        return 1
    fi
    if [[ ! -e /boot/grub/grub.cfg && ! -e /boot/extlinux/extlinux.conf \
        && ! -d /boot/loader/entries && ! -e /etc/default/grub ]]; then
        warn "未识别到常见本地引导器配置；内核包可能安装成功但 VPS 未必会从它启动。"
    fi
    return 0
}

install_xanmod_bbrv3() {
    local temp_key="" fingerprint="" expected_repo existing_repo="" installed_status="" official_http_repo="" package_policy=""
    kernel_install_preflight || return 1

    heading "安装 XanMod LTS / BBRv3"
    info "将安装依赖、登记 XanMod 官方签名仓库，并安装 $XANMOD_PACKAGE。"
    info "不会自动重启，也不会删除当前 Debian 内核。"

    expected_repo="deb [signed-by=$XANMOD_KEYRING] https://deb.xanmod.org $DEBIAN_CODENAME main"
    official_http_repo="deb [signed-by=$XANMOD_KEYRING] http://deb.xanmod.org $DEBIAN_CODENAME main"
    if [[ -f $XANMOD_REPO_FILE ]]; then
        existing_repo=$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$XANMOD_REPO_FILE")
        if [[ $existing_repo != "$expected_repo" && $existing_repo != "$official_http_repo" ]]; then
            error "$XANMOD_REPO_FILE 已有不同内容，拒绝覆盖；请人工检查后重试。"
            return 1
        fi
    fi

    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get update || { error "Debian 软件源更新失败。"; return 1; }
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get install -y --no-install-recommends ca-certificates wget gnupg \
        || { error "安装仓库验证依赖失败。"; return 1; }

    mkdir -p -- /etc/apt/keyrings /etc/apt/sources.list.d || return 1
    if [[ -f $XANMOD_KEYRING ]]; then
        fingerprint=$(key_fingerprint "$XANMOD_KEYRING")
        if [[ $fingerprint != "$XANMOD_KEY_FINGERPRINT" ]]; then
            error "$XANMOD_KEYRING 已存在但指纹不是脚本核验的 XanMod 密钥，拒绝覆盖。"
            return 1
        fi
    else
        temp_key=$(make_temp) || { error "无法创建临时密钥文件。"; return 1; }
        if ! wget -qO "$temp_key" "$XANMOD_KEY_URL"; then
            rm -f -- "$temp_key"
            error "下载 XanMod 官方签名密钥失败。"
            return 1
        fi
        fingerprint=$(key_fingerprint "$temp_key")
        if [[ $fingerprint != "$XANMOD_KEY_FINGERPRINT" ]]; then
            rm -f -- "$temp_key"
            error "XanMod 密钥指纹校验失败；为防止供应链风险，已停止安装。"
            return 1
        fi
        if ! gpg --batch --yes --dearmor --output "$XANMOD_KEYRING" "$temp_key"; then
            rm -f -- "$temp_key"
            error "无法写入 XanMod keyring。"
            return 1
        fi
        chmod 0644 "$XANMOD_KEYRING" || {
            rm -f -- "$temp_key" "$XANMOD_KEYRING"
            error "无法设置 XanMod keyring 权限。"
            return 1
        }
        rm -f -- "$temp_key"
    fi

    if [[ ! -f $XANMOD_REPO_FILE ]]; then
        printf '%s\n' "$expected_repo" | write_atomic_file "$XANMOD_REPO_FILE" 0644 \
            || { error "无法写入 XanMod 仓库配置。"; return 1; }
    fi

    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get update || { error "XanMod 软件源更新失败。"; return 1; }
    package_policy=$(apt-cache policy "$XANMOD_PACKAGE" 2>/dev/null || true)
    if [[ $package_policy != *deb.xanmod.org* ]]; then
        error "APT 没有从 deb.xanmod.org 看到 $XANMOD_PACKAGE，拒绝继续。"
        return 1
    fi
    DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get install -y "$XANMOD_PACKAGE" \
        || { error "XanMod 内核安装失败；网络调优仍可使用当前内核继续。"; return 1; }

    installed_status=$(dpkg-query -W -f='${Status}' "$XANMOD_PACKAGE" 2>/dev/null || true)
    if [[ $installed_status != "install ok installed" ]]; then
        error "APT 返回成功，但未能确认 $XANMOD_PACKAGE 已安装。"
        return 1
    fi
    KERNEL_INSTALLED=1
    compgen -G '/boot/vmlinuz-*xanmod*' >/dev/null \
        || warn "没有在 /boot 发现常规 XanMod vmlinuz；请在重启前检查 VPS 引导方式。"
    info "$XANMOD_PACKAGE 已安装；必须稍后重启才会切换到 BBRv3。"
    return 0
}

maybe_install_recommended_kernel() {
    local answer available
    ((RECOMMEND_BBRV3 == 1 && OFFER_BBRV3_INSTALL == 1)) || return 0
    if [[ ! -t 0 ]]; then
        warn "非交互运行不会安装内核；请交互运行并明确确认。"
        return 0
    fi

    heading "可选内核操作（独立确认）"
    printf '建议包           : %s\n' "$XANMOD_PACKAGE"
    printf '官方密钥指纹     : %s\n' "$XANMOD_KEY_FINGERPRINT"
    printf '影响             : 新增官方 APT 仓库并安装内核；不自动重启，不删除旧内核。\n'
    printf '风险             : BBRv3 仍属扩大测试中的第三方内核补丁，DKMS/引导兼容性可能变化。\n'
    read -r -p "确认立即安装请输入 INSTALL BBRV3；其他输入跳过: " answer
    if [[ $answer != "INSTALL BBRV3" ]]; then
        info "已跳过 BBRv3 内核安装，继续使用当前内核。"
        return 0
    fi
    if ! install_xanmod_bbrv3; then
        warn "BBRv3 安装未完成，继续按当前内核应用网络配置。"
        return 0
    fi

    SELECTED_CC="bbr"
    available=$(get_sysctl net.ipv4.tcp_available_congestion_control)
    if ! word_in_list bbr "$available"; then
        FUTURE_BBR_ONLY=1
        warn "当前运行内核尚无 BBR；配置会在重启进入 XanMod 后使用 BBR，当前会暂时保留原拥塞控制。"
    fi
    prepare_settings
    filter_supported_settings
}

write_supporting_configs() {
    write_atomic_file "$LIMITS_CONF" 0644 <<EOF || return 1
# Generated by $PROGRAM_NAME v$SCRIPT_VERSION
*    soft nofile $NOFILE_LIMIT
*    hard nofile $NOFILE_LIMIT
root soft nofile $NOFILE_LIMIT
root hard nofile $NOFILE_LIMIT
EOF
    write_atomic_file "$SYSTEMD_CONF" 0644 <<EOF || return 1
# Generated by $PROGRAM_NAME v$SCRIPT_VERSION
[Manager]
DefaultLimitNOFILE=$NOFILE_LIMIT:$NOFILE_LIMIT
EOF

    local module_lines=""
    [[ $SELECTED_CC == "bbr" && -d /sys/module/tcp_bbr ]] && module_lines+=$'tcp_bbr\n'
    [[ $SELECTED_QDISC == "fq" && -d /sys/module/sch_fq ]] && module_lines+=$'sch_fq\n'
    [[ $SELECTED_QDISC == "fq_codel" && -d /sys/module/sch_fq_codel ]] && module_lines+=$'sch_fq_codel\n'
    if [[ -n $module_lines ]]; then
        printf '# Generated by %s v%s\n%s' "$PROGRAM_NAME" "$SCRIPT_VERSION" "$module_lines" \
            | write_atomic_file "$MODULES_CONF" 0644 || return 1
    else
        rm -f -- "$MODULES_CONF"
    fi
}

apply_live_qdisc() {
    local iface=$PRIMARY_IFACE old_root="" state_file="$ACTIVE_BACKUP/runtime.state"
    [[ -n $iface && -d /sys/class/net/$iface ]] || {
        warn "未检测到可用主网卡，默认 qdisc 将在网卡下次创建或重启后生效。"
        return 0
    }
    old_root=$(tc qdisc show dev "$iface" 2>/dev/null | awk '/ root / {print $2; exit}')
    case $old_root in
        "$SELECTED_QDISC") return 0 ;;
        "" | noqueue | pfifo_fast | fq | fq_codel)
            if ! sed -i 's/^QDISC_TOUCHED=.*/QDISC_TOUCHED=1/' "$state_file"; then
                error "无法记录 qdisc 回滚状态，已取消即时替换。"
                return 1
            fi
            if tc qdisc replace dev "$iface" root "$SELECTED_QDISC" >/dev/null 2>&1; then
                info "已在 $iface 即时应用 $SELECTED_QDISC"
            else
                sed -i 's/^QDISC_TOUCHED=.*/QDISC_TOUCHED=0/' "$state_file" || true
                warn "无法在 $iface 即时替换 qdisc；持久配置仍已写入。"
            fi
            ;;
        mq)
            warn "$iface 使用多队列 mq，未破坏现有队列；默认 $SELECTED_QDISC 将用于后续创建的叶子队列。"
            ;;
        *)
            warn "$iface 已有自定义队列 $old_root，为避免破坏现有限速/QoS，未即时替换。"
            ;;
    esac
}

raise_live_proxy_limits() {
    command -v prlimit >/dev/null 2>&1 || {
        warn "未找到 prlimit；FD 新上限将在代理服务下次重启时生效。"
        return 0
    }
    local pid command_line process_name raised=0
    while read -r pid; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        ((pid == $$ || pid == PPID)) && continue
        command_line=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
        process_name=${command_line%% *}
        process_name=${process_name##*/}
        case $process_name in
            xray | xray-* | v2ray | v2ray-* | sing-box | sing-box-* | singbox | singbox-* \
                | hysteria | hysteria-* | hysteria2 | hysteria2-* | hysteria3 | hysteria3-* \
                | anytls | anytls-*) ;;
            *) continue ;;
        esac
        if prlimit --pid "$pid" --nofile="$NOFILE_LIMIT:$NOFILE_LIMIT" >/dev/null 2>&1; then
            raised=$((raised + 1))
        fi
    done < <(find /proc -maxdepth 1 -type d -name '[0-9]*' -printf '%f\n' 2>/dev/null)
    if ((raised > 0)); then
        info "已即时提升 $raised 个运行中代理进程的 FD 上限"
    else
        info "未发现可即时调整的代理进程；新 FD 上限将在服务下次启动时生效"
    fi
}

apply_runtime_sysctls() {
    local i key value failures=0
    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        value=${SYSCTL_VALUES[$i]}
        if ((FUTURE_BBR_ONLY == 1)) && [[ $key == "net.ipv4.tcp_congestion_control" ]]; then
            continue
        fi
        if ! sysctl -q -w "$key=$value" >/dev/null 2>&1; then
            error "无法应用 $key = $value"
            failures=$((failures + 1))
        fi
    done
    ((failures == 0))
}

apply_configuration() {
    local temp
    [[ -n $ACTIVE_BACKUP ]] || create_backup || die "无法创建备份"
    APPLYING=1

    temp=$(make_temp) || {
        rollback_on_failure "无法创建临时文件"
        return 1
    }
    if ! render_sysctl_config "$temp"; then
        rm -f -- "$temp"
        rollback_on_failure "无法生成 sysctl 配置"
        return 1
    fi
    mkdir -p -- "$(dirname "$SYSCTL_CONF")"
    if ! install -m 0644 "$temp" "$SYSCTL_CONF"; then
        rm -f -- "$temp"
        rollback_on_failure "无法写入 $SYSCTL_CONF"
        return 1
    fi
    rm -f -- "$temp"

    if ! apply_runtime_sysctls; then
        rollback_on_failure "sysctl 应用失败"
        return 1
    fi

    if ! write_supporting_configs; then
        rollback_on_failure "写入 FD/systemd 配置失败"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 \
            || warn "systemd 未能重新加载；FD 默认值将在重启后生效。"
    fi

    if ! apply_live_qdisc; then
        rollback_on_failure "qdisc 应用前的回滚状态记录失败"
        return 1
    fi
    raise_live_proxy_limits
    APPLYING=0
    return 0
}

validate_result() {
    local failures=0 actual key expected i
    heading "本机生效检查"
    for key in net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max net.ipv4.tcp_fastopen fs.nr_open; do
        if sysctl_exists "$key"; then
            actual=$(get_sysctl "$key")
            printf '  %-42s %s\n' "$key" "$actual"
        fi
    done

    for ((i = 0; i < ${#SYSCTL_KEYS[@]}; i++)); do
        key=${SYSCTL_KEYS[$i]}
        expected=${SYSCTL_VALUES[$i]}
        if ((FUTURE_BBR_ONLY == 1)) && [[ $key == "net.ipv4.tcp_congestion_control" ]]; then
            continue
        fi
        actual=$(get_sysctl "$key")
        [[ $actual == "$expected" ]] || failures=$((failures + 1))
    done
    if [[ -n $PRIMARY_IFACE ]]; then
        printf '  %-42s %s\n' "tc qdisc ($PRIMARY_IFACE)" \
            "$(tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null | head -n1)"
    fi
    ((FUTURE_BBR_ONLY == 1)) && info "BBR 项已写入持久配置，待重启进入 XanMod 后生效。"
    if ((failures == 0)); then
        info "配置值已全部通过本机检查（未执行带宽测速）。"
    else
        warn "$failures 个参数与目标值不同，可能被宿主机或其他配置覆盖。"
    fi
}

show_status() {
    require_commands
    IP_MODE=${IP_MODE:-dual}
    detect_system
    heading "当前代理网络状态"
    printf '脚本版本         : %s\n' "$SCRIPT_VERSION"
    printf '系统             : %s / %s / %s vCPU / %s MiB RAM\n' "$ARCH" "$KERNEL_RELEASE" "$CPU_CORES" "$MEM_MB"
    printf '主网卡           : %s\n' "${PRIMARY_IFACE:-未检测到}"
    local key installed_kernel=""
    for key in net.ipv4.tcp_available_congestion_control net.ipv4.tcp_congestion_control \
        net.core.default_qdisc net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem \
        net.ipv4.tcp_wmem net.ipv4.tcp_fastopen fs.file-max fs.nr_open; do
        sysctl_exists "$key" && printf '%-43s %s\n' "$key" "$(get_sysctl "$key")"
    done
    installed_kernel=$(installed_xanmod_package)
    [[ -n $installed_kernel ]] && printf '%-43s %s\n' "已安装 XanMod 元包" "$installed_kernel"
    [[ -n $PRIMARY_IFACE ]] && tc qdisc show dev "$PRIMARY_IFACE" 2>/dev/null || true
    [[ -f $SYSCTL_CONF ]] && printf '\n配置文件: %s\n' "$SYSCTL_CONF"
    return 0
}

restore_latest() {
    require_root
    local backup_dir=""
    [[ -r $STATE_DIR/latest-backup ]] && read -r backup_dir <"$STATE_DIR/latest-backup"
    [[ $backup_dir == "$BACKUP_ROOT"/* && -d $backup_dir ]] || die "没有找到可恢复的最近备份。"
    if ((ASSUME_YES == 0)); then
        printf '将恢复备份: %s\n' "$backup_dir"
        local answer
        read -r -p "输入 RESTORE 继续: " answer
        [[ $answer == "RESTORE" ]] || die "已取消恢复"
    fi
    restore_backup_internal "$backup_dir" || die "恢复失败"
    info "已恢复应用前的配置。正在运行的服务会在下次重启时继承恢复后的 FD 默认值。"
    if [[ -n $(installed_xanmod_package) ]]; then
        warn "恢复操作不会卸载你曾单独确认安装的 XanMod 内核，也不会删除其 APT 仓库。"
    fi
}

run_self_test() {
    local failures=0
    heading "内置计算测试"

    MEM_MB=1024 CPU_CORES=1 LOCAL_MBPS=1000 SERVER_MBPS=1000 RTT_MS=100
    calculate_tuning
    if ((BDP_BYTES == 12500000 && BUFFER_MIB == 32 && BUFFER_CAP_MIB == 64)); then
        printf '  PASS  1 Gbps / 100 ms / 1 GiB -> 32 MiB\n'
    else
        printf '  FAIL  场景 1: BDP=%s buffer=%s cap=%s\n' "$BDP_BYTES" "$BUFFER_MIB" "$BUFFER_CAP_MIB"
        failures=$((failures + 1))
    fi

    MEM_MB=512 CPU_CORES=1 LOCAL_MBPS=1000 SERVER_MBPS=100 RTT_MS=30
    calculate_tuning
    if ((BDP_BYTES == 375000 && BUFFER_MIB == 8 && NETDEV_BACKLOG == 2048)); then
        printf '  PASS  100 Mbps / 30 ms / 512 MiB -> 8 MiB\n'
    else
        printf '  FAIL  场景 2: BDP=%s buffer=%s backlog=%s\n' "$BDP_BYTES" "$BUFFER_MIB" "$NETDEV_BACKLOG"
        failures=$((failures + 1))
    fi

    MEM_MB=1024 CPU_CORES=2 LOCAL_MBPS=10000 SERVER_MBPS=10000 RTT_MS=200
    calculate_tuning
    if ((BUFFER_MIB == 64 && BUFFER_WAS_CAPPED == 1)); then
        printf '  PASS  10 Gbps / 200 ms / 1 GiB -> RAM cap 64 MiB\n'
    else
        printf '  FAIL  场景 3: buffer=%s capped=%s\n' "$BUFFER_MIB" "$BUFFER_WAS_CAPPED"
        failures=$((failures + 1))
    fi

    ((failures == 0)) || return 1
    info "全部计算测试通过。"
}

on_signal() {
    printf '\n' >&2
    if ((APPLYING == 1)) && [[ -n $ACTIVE_BACKUP ]]; then
        rollback_on_failure "收到中断信号"
    fi
    exit 130
}

main_apply() {
    require_commands
    require_debian
    ((DRY_RUN == 1)) || require_root

    if [[ -z $LOCAL_MBPS ]]; then
        if [[ -t 0 ]]; then LOCAL_MBPS=$(prompt_uint "本地宽带 Mbps" 1000 10 100000); else LOCAL_MBPS=1000; fi
    fi
    if [[ -z $SERVER_MBPS ]]; then
        if [[ -t 0 ]]; then SERVER_MBPS=$(prompt_uint "VPS 标称带宽 Mbps" 1000 10 100000); else SERVER_MBPS=1000; fi
    fi
    is_uint "$LOCAL_MBPS" && ((LOCAL_MBPS >= 10 && LOCAL_MBPS <= 100000)) || die "本地带宽必须是 10-100000 Mbps"
    is_uint "$SERVER_MBPS" && ((SERVER_MBPS >= 10 && SERVER_MBPS <= 100000)) || die "VPS 带宽必须是 10-100000 Mbps"

    if [[ -z $IP_MODE ]]; then
        if [[ -t 0 ]]; then IP_MODE=$(prompt_ip_mode); else IP_MODE=dual; fi
    fi
    case $IP_MODE in
        4 | ipv4 | IPv4) IP_MODE=4 ;;
        6 | ipv6 | IPv6) IP_MODE=6 ;;
        dual | Dual | both | 46 | 64) IP_MODE=dual ;;
        *) die "IP 模式必须是 4、6 或 dual" ;;
    esac

    detect_system
    set_rtt_input
    calculate_tuning
    select_algorithms
    build_kernel_advice
    prepare_settings
    filter_supported_settings
    print_plan
    print_config_preview

    if ((DRY_RUN == 1)); then
        info "试运行完成，未修改任何系统文件。"
        return 0
    fi
    confirm_apply || die "已取消应用"
    maybe_install_recommended_kernel
    apply_configuration || return 1
    validate_result
    printf '\n%s完成。%s 恢复命令: sudo bash %s --restore\n' "$C_GREEN" "$C_RESET" "$0"
    if ((KERNEL_INSTALLED == 1)); then
        printf '%s内核已安装但尚未启用。%s 请在方便时执行 sudo reboot；重连后用 uname -r 确认含 xanmod。\n' \
            "$C_YELLOW" "$C_RESET"
        printf '恢复命令只恢复本脚本的网络/FD 配置，不卸载已确认安装的内核或仓库。\n'
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    trap on_signal INT TERM
    parse_args "$@"

    case $ACTION in
        apply) main_apply ;;
        status) show_status ;;
        restore) require_commands; restore_latest ;;
        self-test) run_self_test ;;
        help) usage ;;
    esac
fi
