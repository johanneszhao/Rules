#!/usr/bin/env bash

# Safely rebuild Xray direct/WARP/Shadowsocks outbounds and domain routing.
# Requires Bash 4+ and jq. If jq is missing, the script can install it.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CONFIG="/etc/xray/config.json"
SERVICE="xray"
WARP_PORT=40000
XRAY_BIN=""
NO_RESTART=0

DIRECT_TAG="direct"
WARP_TAG="warp"
SS_TAG="shadowsocks"
SS_METHOD="aes-128-gcm"

WORKDIR=""
WORKDIR_PARENT=""
INSTALL_TMP=""
RULE_ERROR=""
NORMALIZED_RULE=""
LAST_TEST_LOG=""

declare -a ROUTE_ORDER=()
declare -a WARP_RULES=()
declare -a SS_RULES=()
declare -a HIGHER_RULES=()


cleanup() {
  if [[ -n "${INSTALL_TMP:-}" && -f "${INSTALL_TMP:-}" ]]; then
    rm -f -- "$INSTALL_TMP"
  fi
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]]; then
    case "$WORKDIR" in
      "${WORKDIR_PARENT:-/tmp}"/xray-route-manager.*)
        rm -rf -- "$WORKDIR"
        ;;
    esac
  fi
}


on_interrupt() {
  printf '\n已中断。\n' >&2
  exit 130
}


trap cleanup EXIT
trap on_interrupt INT TERM


die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}


usage() {
  cat <<'EOF'
用法：route.sh [选项]

安全重建 Xray 直连/WARP/Shadowsocks 出站与域名分流。

选项：
  --config PATH       Xray JSON 配置路径（默认 /etc/xray/config.json）
  --service NAME      systemd 服务名（默认 xray）
  --warp-port PORT    本地 WARP SOCKS5 端口（默认 40000）
  --xray-bin PATH     Xray 可执行文件路径
  --no-restart        写入后不重启服务
  -h, --help          显示帮助
EOF
}


valid_port() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  ((${#value} <= 5)) || return 1
  (( 10#$value >= 1 && 10#$value <= 65535 ))
}


while (($#)); do
  case "$1" in
    --config)
      (($# >= 2)) || die "--config 缺少参数"
      CONFIG="$2"
      shift 2
      ;;
    --service)
      (($# >= 2)) || die "--service 缺少参数"
      SERVICE="$2"
      shift 2
      ;;
    --warp-port)
      (($# >= 2)) || die "--warp-port 缺少参数"
      valid_port "$2" || die "WARP 端口必须在 1-65535 之间"
      WARP_PORT=$((10#$2))
      shift 2
      ;;
    --xray-bin)
      (($# >= 2)) || die "--xray-bin 缺少参数"
      XRAY_BIN="$2"
      shift 2
      ;;
    --no-restart)
      NO_RESTART=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知选项：$1（使用 --help 查看帮助）"
      ;;
  esac
done


(( EUID == 0 )) || die "请使用 root 运行"
[[ -f "$CONFIG" ]] || die "配置不存在：$CONFIG"

if command -v readlink >/dev/null 2>&1; then
  RESOLVED_CONFIG="$(readlink -f -- "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$RESOLVED_CONFIG" ]]; then
    CONFIG="$RESOLVED_CONFIG"
  fi
fi


read_line() {
  local __target="$1"
  local __prompt="$2"
  local __input=""
  if ! IFS= read -r -p "$__prompt" __input; then
    die "无法读取输入"
  fi
  printf -v "$__target" '%s' "$__input"
}


ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0

  printf '没有找到 jq。Bash 需要 jq 才能安全修改 JSON。\n'
  local answer=""
  read_line answer "是否自动安装 jq？[Y/n]: "
  case "${answer:-Y}" in
    y|Y|yes|YES|Yes|"") ;;
    *) die "已取消；请先手动安装 jq" ;;
  esac

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update || die "apt-get update 失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq || die "安装 jq 失败"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y jq || die "安装 jq 失败"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq || die "安装 jq 失败"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq || die "安装 jq 失败"
  else
    die "无法识别包管理器，请手动安装 jq"
  fi

  command -v jq >/dev/null 2>&1 || die "jq 安装后仍不可用"
}


ensure_jq
jq empty "$CONFIG" >/dev/null 2>&1 || die "原配置不是有效 JSON：$CONFIG"

if (( ! NO_RESTART )) && ! command -v systemctl >/dev/null 2>&1; then
  die "找不到 systemctl；如只想写配置，可加 --no-restart"
fi

if [[ -n "$XRAY_BIN" ]]; then
  [[ -x "$XRAY_BIN" ]] || die "Xray 文件不存在或不可执行：$XRAY_BIN"
elif command -v xray >/dev/null 2>&1; then
  XRAY_BIN="$(command -v xray)"
elif [[ -x /usr/local/bin/xray ]]; then
  XRAY_BIN="/usr/local/bin/xray"
elif [[ -x /usr/bin/xray ]]; then
  XRAY_BIN="/usr/bin/xray"
else
  die "找不到 xray 可执行文件；可用 --xray-bin /实际路径 指定"
fi

WORKDIR_PARENT="${TMPDIR:-/tmp}"
if [[ ! -d "$WORKDIR_PARENT" || ! -w "$WORKDIR_PARENT" ]]; then
  WORKDIR_PARENT="$(dirname -- "$CONFIG")"
fi
WORKDIR="$(mktemp -d "$WORKDIR_PARENT/xray-route-manager.XXXXXXXX")" \
  || die "无法创建临时目录"
chmod 700 "$WORKDIR"
SS_PASSWORD_FILE="$WORKDIR/ss-password"
: > "$SS_PASSWORD_FILE"
chmod 600 "$SS_PASSWORD_FILE"


trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}


choose_mode() {
  local choice=""
  printf '\n选择出站模式（未命中的流量始终直连）：\n'
  printf '  1) 仅直连\n'
  printf '  2) 直连 + WARP（SOCKS5 127.0.0.1:%s）\n' "$WARP_PORT"
  printf '  3) 直连 + Shadowsocks\n'
  printf '  4) 直连 + WARP + Shadowsocks\n'
  while true; do
    read_line choice "请输入 1-4 [1]: "
    choice="${choice:-1}"
    case "$choice" in
      1) USE_WARP=false; USE_SS=false; return ;;
      2) USE_WARP=true;  USE_SS=false; return ;;
      3) USE_WARP=false; USE_SS=true;  return ;;
      4) USE_WARP=true;  USE_SS=true;  return ;;
      *) printf '输入无效，请输入 1、2、3 或 4。\n' ;;
    esac
  done
}


prompt_ss() {
  local value=""
  local password=""
  printf '\nShadowsocks 加密方式固定为 %s。\n' "$SS_METHOD"

  while true; do
    read_line value "Shadowsocks IP/域名: "
    value="$(trim "$value")"
    if [[ "$value" == \[*\] ]]; then
      value="${value:1:${#value}-2}"
    fi
    if [[ -z "$value" || "$value" =~ [[:space:]] || "$value" == *"://"* || "$value" == */* ]]; then
      printf '地址只能是 IP 或域名，不能含空格、协议头或路径。\n'
      continue
    fi
    SS_ADDRESS="$value"
    break
  done

  while true; do
    read_line value "Shadowsocks 端口: "
    value="$(trim "$value")"
    if valid_port "$value"; then
      SS_PORT=$((10#$value))
      break
    fi
    printf '端口必须在 1-65535 之间。\n'
  done

  while true; do
    if ! IFS= read -r -s -p "Shadowsocks 密码（输入不回显）: " password; then
      die "无法读取密码"
    fi
    printf '\n'
    [[ -n "$password" ]] && break
    printf '密码不能为空。\n'
  done
  printf '%s' "$password" > "$SS_PASSWORD_FILE"
  unset password
}


choose_priority() {
  local choice=""
  printf '\nWARP 与 Shadowsocks 的规则可能重叠，请选择匹配优先级：\n'
  printf '  1) WARP 优先\n'
  printf '  2) Shadowsocks 优先\n'
  while true; do
    read_line choice "请输入 1 或 2 [1]: "
    choice="${choice:-1}"
    case "$choice" in
      1) ROUTE_ORDER=("$WARP_TAG" "$SS_TAG"); return ;;
      2) ROUTE_ORDER=("$SS_TAG" "$WARP_TAG"); return ;;
      *) printf '输入无效，请输入 1 或 2。\n' ;;
    esac
  done
}


normalize_rule() {
  local value=""
  local lower=""
  local prefix=""
  local body=""
  RULE_ERROR=""
  NORMALIZED_RULE=""

  value="$(trim "$1")"
  if [[ -z "$value" ]]; then
    RULE_ERROR="空规则"
    return 1
  fi
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    RULE_ERROR="规则不能包含控制字符"
    return 1
  fi

  lower="${value,,}"
  for prefix in domain geosite full regexp keyword dotless ext; do
    if [[ "$lower" == "$prefix:"* ]]; then
      body="$(trim "${value#*:}")"
      if [[ -z "$body" ]]; then
        RULE_ERROR="$prefix: 后面缺少内容"
        return 1
      fi
      NORMALIZED_RULE="$prefix:$body"
      return 0
    fi
  done

  if [[ "$value" == \*.* ]]; then
    value="${value#*.}"
  fi
  if [[ "$value" == *"://"* || "$value" == */* ]]; then
    RULE_ERROR="这里只填写域名/规则，不要填写 URL 路径"
    return 1
  fi
  if [[ "$value" =~ [[:space:]] || "$value" == .* || "$value" == *. || "$value" == *:* ]]; then
    RULE_ERROR="域名格式无效"
    return 1
  fi
  NORMALIZED_RULE="domain:$value"
}


contains_rule() {
  local wanted="$1"
  shift || true
  local item=""
  for item in "$@"; do
    [[ "$item" == "$wanted" ]] && return 0
  done
  return 1
}


collect_rules() {
  local tag="$1"
  local label="$2"
  local line=""
  local raw=""
  local rule=""
  local -a parts=()
  local -a collected=()

  printf '\n输入走 %s 的域名规则，空行结束。\n' "$label"
  printf '可用：geosite:google、domain:example.com、full:example.com\n'
  printf '也可直接输入 example.com 或 *.example.com，会转成 domain:example.com。\n'
  printf '同一行可用英文/中文逗号分隔多个规则。\n'

  while true; do
    read_line line "$label 规则: "
    line="$(trim "$line")"
    if [[ -z "$line" ]]; then
      if ((${#collected[@]})); then
        break
      fi
      printf '至少需要一条规则；若不需要此出口，请重新运行并选择其他模式。\n'
      continue
    fi

    line="${line//，/,}"
    if [[ "${line,,}" == regexp:* ]]; then
      parts=("$line")
    else
      IFS=',' read -r -a parts <<< "$line"
    fi

    for raw in "${parts[@]}"; do
      if ! normalize_rule "$raw"; then
        printf "  跳过 %q：%s\n" "$raw" "$RULE_ERROR"
        continue
      fi
      rule="$NORMALIZED_RULE"
      if contains_rule "$rule" "${HIGHER_RULES[@]}"; then
        printf '  跳过 %s：已属于优先级更高的出口\n' "$rule"
        continue
      fi
      if contains_rule "$rule" "${collected[@]}"; then
        printf '  跳过 %s：重复\n' "$rule"
        continue
      fi
      collected+=("$rule")
      printf '  已添加：%s\n' "$rule"
    done
  done

  if [[ "$tag" == "$WARP_TAG" ]]; then
    WARP_RULES=("${collected[@]}")
  else
    SS_RULES=("${collected[@]}")
  fi
  HIGHER_RULES+=("${collected[@]}")
}


check_warp_listener() {
  command -v timeout >/dev/null 2>&1 || return 0
  if ! timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$WARP_PORT" 2>/dev/null; then
    printf '\n警告：当前无法连接 127.0.0.1:%s；配置仍可生成，但 WARP 可能不可用。\n' "$WARP_PORT"
  fi
}


choose_mode
if [[ "$USE_SS" == true ]]; then
  prompt_ss
fi
if [[ "$USE_WARP" == true ]]; then
  check_warp_listener
fi

if [[ "$USE_WARP" == true && "$USE_SS" == true ]]; then
  choose_priority
elif [[ "$USE_WARP" == true ]]; then
  ROUTE_ORDER=("$WARP_TAG")
elif [[ "$USE_SS" == true ]]; then
  ROUTE_ORDER=("$SS_TAG")
else
  ROUTE_ORDER=()
fi

for ROUTE_TAG in "${ROUTE_ORDER[@]}"; do
  if [[ "$ROUTE_TAG" == "$WARP_TAG" ]]; then
    collect_rules "$ROUTE_TAG" "WARP"
  else
    collect_rules "$ROUTE_TAG" "Shadowsocks"
  fi
done


current_outbound_summary() {
  jq -r '
    if (.outbounds | type) != "array" then
      "原 outbounds 格式异常（将重建）"
    elif (.outbounds | length) == 0 then
      "<无>"
    else
      [.outbounds[] | "\(.tag // "<无 tag>")(\(.protocol // "<无协议>"))"]
      | join(", ")
    end
  ' "$CONFIG"
}


printf '\n========== 修改预览 ==========\n'
printf '原出站：%s\n' "$(current_outbound_summary)"
printf '新出站：direct(freedom，默认)'
if [[ "$USE_WARP" == true ]]; then
  printf ', warp(socks5 127.0.0.1:%s)' "$WARP_PORT"
fi
if [[ "$USE_SS" == true ]]; then
  printf ', shadowsocks(%s:%s，%s，密码已隐藏)' "$SS_ADDRESS" "$SS_PORT" "$SS_METHOD"
fi
printf '\n未匹配规则：direct\n'

if ((${#ROUTE_ORDER[@]} == 0)); then
  printf '代理规则：无（全部直连）\n'
else
  printf '代理规则（由上到下优先匹配）：\n'
  for ROUTE_TAG in "${ROUTE_ORDER[@]}"; do
    printf '  %s:\n' "$ROUTE_TAG"
    if [[ "$ROUTE_TAG" == "$WARP_TAG" ]]; then
      for RULE in "${WARP_RULES[@]}"; do printf '    - %s\n' "$RULE"; done
    else
      for RULE in "${SS_RULES[@]}"; do printf '    - %s\n' "$RULE"; done
    fi
  done
fi
printf '会删除：原有其他 outbounds、原有 routing.rules、routing.balancers\n'
printf '会保留：log/dns/api/stats/policy/inbounds 等其他顶层配置\n'
printf '================================\n'

CONFIRM=""
read_line CONFIRM "确认执行请输入 YES："
if [[ "$CONFIRM" != YES ]]; then
  printf '已取消，配置未修改。\n'
  exit 0
fi


write_rules_json() {
  local output="$1"
  shift || true
  local plain="$output.txt"
  : > "$plain"
  if (($#)); then
    printf '%s\n' "$@" > "$plain"
  fi
  jq -Rsc 'split("\n") | map(select(length > 0))' "$plain" > "$output"
}


WARP_DOMAINS_JSON="$WORKDIR/warp-domains.json"
SS_DOMAINS_JSON="$WORKDIR/ss-domains.json"
PROXY_RULES_JSON="$WORKDIR/proxy-rules.json"
write_rules_json "$WARP_DOMAINS_JSON" "${WARP_RULES[@]}"
write_rules_json "$SS_DOMAINS_JSON" "${SS_RULES[@]}"
printf '[]\n' > "$PROXY_RULES_JSON"

for ROUTE_TAG in "${ROUTE_ORDER[@]}"; do
  if [[ "$ROUTE_TAG" == "$WARP_TAG" ]]; then
    DOMAIN_FILE="$WARP_DOMAINS_JSON"
  else
    DOMAIN_FILE="$SS_DOMAINS_JSON"
  fi
  jq \
    --arg tag "$ROUTE_TAG" \
    --slurpfile domains "$DOMAIN_FILE" \
    '. + [{"type":"field", "domain":$domains[0], "outboundTag":$tag}]' \
    "$PROXY_RULES_JSON" > "$PROXY_RULES_JSON.next"
  mv -f "$PROXY_RULES_JSON.next" "$PROXY_RULES_JSON"
done


make_outbounds() {
  local schema="$1"
  local output="$2"
  jq -n \
    --arg schema "$schema" \
    --argjson use_warp "$USE_WARP" \
    --argjson warp_port "$WARP_PORT" \
    --argjson use_ss "$USE_SS" \
    --arg ss_address "${SS_ADDRESS:-}" \
    --argjson ss_port "${SS_PORT:-1}" \
    --arg ss_method "$SS_METHOD" \
    --rawfile ss_password "$SS_PASSWORD_FILE" '
      [{"tag":"direct", "protocol":"freedom"}]
      + (if $use_warp then [
          {
            "tag":"warp",
            "protocol":"socks",
            "settings":(
              if $schema == "modern"
              then {"address":"127.0.0.1", "port":$warp_port}
              else {"servers":[{"address":"127.0.0.1", "port":$warp_port}]}
              end
            )
          }
        ] else [] end)
      + (if $use_ss then [
          {
            "tag":"shadowsocks",
            "protocol":"shadowsocks",
            "settings":(
              if $schema == "modern"
              then {
                "address":$ss_address,
                "port":$ss_port,
                "method":$ss_method,
                "password":$ss_password
              }
              else {"servers":[{
                "address":$ss_address,
                "port":$ss_port,
                "method":$ss_method,
                "password":$ss_password
              }]}
              end
            )
          }
        ] else [] end)
    ' > "$output"
}


make_candidate() {
  local schema="$1"
  local output="$2"
  local outbounds="$WORKDIR/outbounds-$schema.json"
  make_outbounds "$schema" "$outbounds"

  jq \
    --slurpfile outbounds "$outbounds" \
    --slurpfile proxy_rules "$PROXY_RULES_JSON" '
      . as $root
      | (if (.routing | type) == "object" then .routing else {} end) as $old_routing
      | (if (($root.api | type) == "object"
             and ($root.api.tag | type) == "string"
             and ($root.api.tag | length) > 0)
         then [{
           "type":"field",
           "inboundTag":[$root.api.tag],
           "outboundTag":$root.api.tag
         }]
         else []
         end) as $api_rules
      | .outbounds = $outbounds[0]
      | .routing = (
          {
            "domainStrategy":($old_routing.domainStrategy // "IPIfNonMatch"),
            "rules":($api_rules + $proxy_rules[0])
          }
          + (if ($old_routing | has("domainMatcher"))
             then {"domainMatcher":$old_routing.domainMatcher}
             else {}
             end)
        )
    ' "$CONFIG" > "$output"
}


run_xray_test() {
  local candidate="$1"
  local output=""
  local status=0
  local first_log=""

  if output="$("$XRAY_BIN" run -test -config "$candidate" 2>&1)"; then
    LAST_TEST_LOG="$output"
    return 0
  else
    status=$?
    first_log="$XRAY_BIN run -test -config $candidate\n退出码 $status\n$output"
  fi

  if output="$("$XRAY_BIN" -test -config "$candidate" 2>&1)"; then
    LAST_TEST_LOG="$output"
    return 0
  else
    status=$?
    LAST_TEST_LOG="$first_log\n\n$XRAY_BIN -test -config $candidate\n退出码 $status\n$output"
    return 1
  fi
}


MODERN_CANDIDATE="$WORKDIR/candidate-modern.json"
LEGACY_CANDIDATE="$WORKDIR/candidate-legacy.json"
make_candidate modern "$MODERN_CANDIDATE"
make_candidate legacy "$LEGACY_CANDIDATE"

printf '正在用本机 Xray 检查候选配置……\n'
if run_xray_test "$MODERN_CANDIDATE"; then
  SELECTED_CANDIDATE="$MODERN_CANDIDATE"
  SCHEMA_NAME="新版扁平格式"
else
  MODERN_LOG="$LAST_TEST_LOG"
  if run_xray_test "$LEGACY_CANDIDATE"; then
    SELECTED_CANDIDATE="$LEGACY_CANDIDATE"
    SCHEMA_NAME="旧版 servers 格式"
  else
    LEGACY_LOG="$LAST_TEST_LOG"
    printf '新版和旧版出站格式都未通过 Xray 检查，原配置未修改。\n\n' >&2
    printf '[modern]\n%b\n\n[legacy]\n%b\n' "$MODERN_LOG" "$LEGACY_LOG" >&2
    exit 1
  fi
fi
printf 'Xray 配置检查通过：%s\n' "$SCHEMA_NAME"


unique_backup_path() {
  local stamp=""
  local candidate=""
  local number=0
  stamp="$(date +%Y%m%d-%H%M%S)"
  candidate="$CONFIG.bak.$stamp"
  if [[ ! -e "$candidate" ]]; then
    printf '%s' "$candidate"
    return
  fi
  for ((number=1; number<1000; number++)); do
    candidate="$CONFIG.bak.$stamp.$number"
    if [[ ! -e "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done
  die "无法生成不重复的备份文件名"
}


atomic_replace_from() {
  local source="$1"
  local config_dir=""
  local config_base=""
  config_dir="$(dirname -- "$CONFIG")"
  config_base="$(basename -- "$CONFIG")"
  INSTALL_TMP="$(mktemp "$config_dir/.${config_base}.route.XXXXXXXX")" \
    || die "无法在 $config_dir 创建临时配置"
  cp -p "$CONFIG" "$INSTALL_TMP" || die "无法复制配置权限"
  if ! command cat "$source" > "$INSTALL_TMP"; then
    die "无法写入临时配置"
  fi
  mv -f "$INSTALL_TMP" "$CONFIG" || die "无法替换配置"
  INSTALL_TMP=""
}


restore_backup() {
  local backup="$1"
  local config_dir=""
  local config_base=""
  config_dir="$(dirname -- "$CONFIG")"
  config_base="$(basename -- "$CONFIG")"
  INSTALL_TMP="$(mktemp "$config_dir/.${config_base}.restore.XXXXXXXX")" \
    || return 1
  cp -p "$backup" "$INSTALL_TMP" || return 1
  mv -f "$INSTALL_TMP" "$CONFIG" || return 1
  INSTALL_TMP=""
}


BACKUP="$(unique_backup_path)"
cp -p "$CONFIG" "$BACKUP" || die "无法创建备份：$BACKUP"
atomic_replace_from "$SELECTED_CANDIDATE"

if (( NO_RESTART )); then
  printf '写入成功（未重启服务）。备份：%s\n' "$BACKUP"
  exit 0
fi

RESTART_OUTPUT=""
if RESTART_OUTPUT="$(systemctl restart "$SERVICE" 2>&1)"; then
  sleep 1
  if systemctl is-active --quiet "$SERVICE"; then
    printf '完成：%s 已重启，状态 active。\n' "$SERVICE"
    printf '配置：%s\n' "$CONFIG"
    printf '备份：%s\n' "$BACKUP"
    exit 0
  fi
fi

ACTIVE_OUTPUT="$(systemctl is-active "$SERVICE" 2>&1 || true)"
printf '新配置写入后服务未正常运行：%s %s\n' "$RESTART_OUTPUT" "$ACTIVE_OUTPUT" >&2
printf '正在自动恢复原配置并重启服务……\n' >&2

if ! restore_backup "$BACKUP"; then
  die "严重：自动恢复失败。请立即手动执行：cp '$BACKUP' '$CONFIG'"
fi

ROLLBACK_OUTPUT="$(systemctl restart "$SERVICE" 2>&1 || true)"
sleep 1
if systemctl is-active --quiet "$SERVICE"; then
  die "新配置未能启动，已自动恢复原配置；$SERVICE 当前 active。备份：$BACKUP"
fi

ROLLBACK_ACTIVE="$(systemctl is-active "$SERVICE" 2>&1 || true)"
die "严重：已恢复原配置，但服务仍未 active。$ROLLBACK_OUTPUT $ROLLBACK_ACTIVE；备份：$BACKUP"
