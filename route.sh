#!/usr/bin/env bash
# 233boy Xray / sing-box 分流管理：direct、WARP、Shadowsocks。
# 纯 Bash，仅依赖 jq；不创建备份，不自动回滚。

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CORE=""
CONFIG=""
SERVICE=""
CORE_BIN=""
CONF_DIR=""
WARP_PORT=40000
NO_RESTART=0

DIRECT_TAG="direct"
WARP_TAG="warp"
SS_TAG="shadowsocks"
SS_METHOD="aes-128-gcm"
RULESET_BASE="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set"
HTTP_CLIENT_TAG="route-manager-direct"

WORKDIR=""
INSTALL_TMP=""
ACTION="configure"
USE_WARP=false
USE_SS=false
SS_ADDRESS=""
SS_PORT=1
RULE_ERROR=""
NORMALIZED_RULE=""
LAST_TEST_LOG=""

# shellcheck disable=SC2034
declare -a ROUTE_ORDER=()
declare -a WARP_RULES=()
declare -a SS_RULES=()
declare -a HIGHER_RULES=()

cleanup() {
  [[ -n "${INSTALL_TMP:-}" && -f "${INSTALL_TMP:-}" ]] && rm -f -- "$INSTALL_TMP"
  [[ -n "${WORKDIR:-}" && -d "${WORKDIR:-}" ]] && rm -rf -- "$WORKDIR"
}
trap cleanup EXIT
trap 'printf "\n已中断。\n" >&2; exit 130' INT TERM

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法：route.sh [选项]

交互管理 233boy Xray / sing-box 的 direct、WARP、Shadowsocks 分流。
不创建备份；候选配置检查通过后直接覆盖并重启。

选项：
  --core xray|singbox   跳过核心选择
  --config PATH         自定义配置路径
  --service NAME        自定义 systemd 服务名
  --bin PATH            自定义核心可执行文件
  --conf-dir PATH       sing-box 配置目录（默认 /etc/sing-box/conf）
  --warp-port PORT      WARP SOCKS5 端口（默认 40000）
  --no-restart          只写配置，不重启
  -h, --help            显示帮助
EOF
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || return 1
  ((${#1} <= 5)) || return 1
  ((10#$1 >= 1 && 10#$1 <= 65535))
}

while (($#)); do
  case "$1" in
    --core) (($# >= 2)) || die '--core 缺少参数'; CORE="${2,,}"; shift 2 ;;
    --config) (($# >= 2)) || die '--config 缺少参数'; CONFIG="$2"; shift 2 ;;
    --service) (($# >= 2)) || die '--service 缺少参数'; SERVICE="$2"; shift 2 ;;
    --bin) (($# >= 2)) || die '--bin 缺少参数'; CORE_BIN="$2"; shift 2 ;;
    --conf-dir) (($# >= 2)) || die '--conf-dir 缺少参数'; CONF_DIR="$2"; shift 2 ;;
    --warp-port)
      (($# >= 2)) || die '--warp-port 缺少参数'
      valid_port "$2" || die 'WARP 端口必须在 1-65535 之间'
      WARP_PORT=$((10#$2)); shift 2
      ;;
    --no-restart) NO_RESTART=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知选项：$1" ;;
  esac
done

read_line() {
  local __name="$1" __prompt="$2" __value=""
  IFS= read -r -p "$__prompt" __value || die '无法读取输入'
  printf -v "$__name" '%s' "$__value"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

choose_core() {
  local choice=""
  [[ -n "$CORE" ]] && return
  printf '选择要修改的核心：\n  1) Xray\n  2) sing-box\n'
  while true; do
    read_line choice '请输入 1 或 2: '
    case "$choice" in
      1) CORE="xray"; return ;;
      2) CORE="singbox"; return ;;
      *) printf '输入无效。\n' ;;
    esac
  done
}

choose_core
case "$CORE" in
  xray)
    CONFIG="${CONFIG:-/etc/xray/config.json}"
    SERVICE="${SERVICE:-xray}"
    ;;
  singbox|sing-box)
    CORE="singbox"
    CONFIG="${CONFIG:-/etc/sing-box/config.json}"
    SERVICE="${SERVICE:-sing-box}"
    CONF_DIR="${CONF_DIR:-/etc/sing-box/conf}"
    ;;
  *) die '--core 只能是 xray 或 singbox' ;;
esac

((EUID == 0)) || die '请使用 root 运行'
[[ -f "$CONFIG" ]] || die "配置不存在：$CONFIG"

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return
  local answer=""
  printf '未找到 jq，脚本需要 jq 修改 JSON。\n'
  read_line answer '是否自动安装 jq？[Y/n]: '
  case "${answer:-Y}" in y|Y|yes|YES|'') ;; *) die '已取消' ;; esac
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y jq
  elif command -v dnf >/dev/null 2>&1; then dnf install -y jq
  elif command -v yum >/dev/null 2>&1; then yum install -y jq
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache jq
  else die '无法识别包管理器，请手动安装 jq'
  fi
  command -v jq >/dev/null 2>&1 || die 'jq 安装失败'
}

find_core_bin() {
  [[ -n "$CORE_BIN" ]] && { [[ -x "$CORE_BIN" ]] || die "不可执行：$CORE_BIN"; return; }
  if [[ "$CORE" == xray ]]; then
    for p in "$(command -v xray 2>/dev/null || true)" /usr/local/bin/xray /usr/bin/xray /etc/xray/bin/xray; do
      [[ -n "$p" && -x "$p" ]] && { CORE_BIN="$p"; return; }
    done
  else
    for p in /etc/sing-box/bin/sing-box "$(command -v sing-box 2>/dev/null || true)" /usr/local/bin/sing-box /usr/bin/sing-box; do
      [[ -n "$p" && -x "$p" ]] && { CORE_BIN="$p"; return; }
    done
  fi
  die "找不到 $CORE 可执行文件，可用 --bin 指定"
}

ensure_jq
jq empty "$CONFIG" >/dev/null 2>&1 || die "配置不是有效 JSON：$CONFIG"
find_core_bin
if (( ! NO_RESTART )); then command -v systemctl >/dev/null 2>&1 || die '找不到 systemctl'; fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/route-manager.XXXXXXXX")" || die '无法创建临时目录'
SS_PASSWORD_FILE="$WORKDIR/ss-password"
: > "$SS_PASSWORD_FILE"; chmod 600 "$SS_PASSWORD_FILE"

choose_action() {
  local choice=""
  printf '\n选择操作：\n  1) 配置/重建分流\n  2) 删除分流并恢复仅直连\n'
  while true; do
    read_line choice '请输入 1 或 2 [1]: '
    case "${choice:-1}" in
      1) ACTION="configure"; return ;;
      2) ACTION="delete"; USE_WARP=false; USE_SS=false; ROUTE_ORDER=(); return ;;
      *) printf '输入无效。\n' ;;
    esac
  done
}

choose_mode() {
  local choice=""
  printf '\n选择出站模式（未命中始终 direct）：\n'
  printf '  1) 仅直连\n  2) direct + WARP（127.0.0.1:%s）\n' "$WARP_PORT"
  printf '  3) direct + Shadowsocks\n  4) direct + WARP + Shadowsocks\n'
  while true; do
    read_line choice '请输入 1-4 [1]: '
    case "${choice:-1}" in
      1) USE_WARP=false; USE_SS=false; return ;;
      2) USE_WARP=true;  USE_SS=false; return ;;
      3) USE_WARP=false; USE_SS=true;  return ;;
      4) USE_WARP=true;  USE_SS=true;  return ;;
      *) printf '输入无效。\n' ;;
    esac
  done
}

prompt_ss() {
  local value="" password=""
  printf '\nShadowsocks 加密固定为 %s。\n' "$SS_METHOD"
  while true; do
    read_line value '服务器 IP/域名: '; value="$(trim "$value")"
    [[ "$value" == \[*\] ]] && value="${value:1:${#value}-2}"
    if [[ -n "$value" && ! "$value" =~ [[:space:]] && "$value" != *"://"* && "$value" != */* ]]; then
      SS_ADDRESS="$value"; break
    fi
    printf '地址格式无效。\n'
  done
  while true; do
    read_line value '服务器端口: '; value="$(trim "$value")"
    valid_port "$value" && { SS_PORT=$((10#$value)); break; }
    printf '端口必须在 1-65535。\n'
  done
  while true; do
    IFS= read -r -s -p '密码（不回显）: ' password || die '无法读取密码'
    printf '\n'; [[ -n "$password" ]] && break; printf '密码不能为空。\n'
  done
  printf '%s' "$password" > "$SS_PASSWORD_FILE"; unset password
}

choose_priority() {
  local choice=""
  printf '\n规则重叠时优先使用：\n  1) WARP\n  2) Shadowsocks\n'
  while true; do
    read_line choice '请输入 1 或 2 [1]: '
    case "${choice:-1}" in
      1) ROUTE_ORDER=("$WARP_TAG" "$SS_TAG"); return ;;
      2) ROUTE_ORDER=("$SS_TAG" "$WARP_TAG"); return ;;
      *) printf '输入无效。\n' ;;
    esac
  done
}

normalize_rule() {
  local value lower body
  RULE_ERROR=""; NORMALIZED_RULE=""
  value="$(trim "$1")"; lower="${value,,}"
  [[ -n "$value" ]] || { RULE_ERROR='空规则'; return 1; }
  [[ ! "$value" =~ [[:cntrl:]] ]] || { RULE_ERROR='含控制字符'; return 1; }

  if [[ "$lower" == geosite:* ]]; then
    body="$(trim "${value#*:}")"
    if [[ -z "$body" || "$body" == *'..'* || ! "$body" =~ ^[A-Za-z0-9_@.!+-]+$ ]]; then
      RULE_ERROR='geosite 名称格式无效'; return 1
    fi
    NORMALIZED_RULE="geosite:$body"; return
  fi

  for prefix in domain_suffix: domain-suffix: domain:; do
    if [[ "$lower" == "$prefix"* ]]; then value="${value#*:}"; break; fi
  done
  value="$(trim "$value")"
  [[ "$value" == \*.* ]] && value="${value#*.}"
  value="${value#.}"
  if [[ -z "$value" || "$value" =~ [[:space:]] || "$value" == *"://"* || "$value" == */* || "$value" == *:* || "$value" == *. ]]; then
    RULE_ERROR='域名后缀格式无效'; return 1
  fi
  NORMALIZED_RULE="domain_suffix:${value,,}"
}

contains_rule() {
  local wanted="$1" item; shift || true
  for item in "$@"; do [[ "$item" == "$wanted" ]] && return 0; done
  return 1
}

collect_rules() {
  local tag="$1" label="$2" line raw rule
  local -a parts=() collected=()
  printf '\n输入走 %s 的规则，空行结束。\n' "$label"
  printf '支持：geosite:netflix、domain_suffix:example.com、example.com\n'
  printf '同一行可用英文或中文逗号分隔。\n'
  while true; do
    read_line line "$label 规则: "; line="$(trim "$line")"
    if [[ -z "$line" ]]; then
      ((${#collected[@]})) && break
      printf '至少输入一条；不需要该出口请重新运行。\n'; continue
    fi
    line="${line//，/,}"; IFS=',' read -r -a parts <<< "$line"
    for raw in "${parts[@]}"; do
      if ! normalize_rule "$raw"; then printf '  跳过 %s：%s\n' "$raw" "$RULE_ERROR"; continue; fi
      rule="$NORMALIZED_RULE"
      if contains_rule "$rule" "${HIGHER_RULES[@]}"; then printf '  跳过 %s：已属于高优先级出口\n' "$rule"; continue; fi
      if contains_rule "$rule" "${collected[@]}"; then printf '  跳过 %s：重复\n' "$rule"; continue; fi
      collected+=("$rule"); printf '  已添加：%s\n' "$rule"
    done
  done
  if [[ "$tag" == "$WARP_TAG" ]]; then WARP_RULES=("${collected[@]}"); else SS_RULES=("${collected[@]}"); fi
  HIGHER_RULES+=("${collected[@]}")
}

check_warp() {
  command -v timeout >/dev/null 2>&1 || return
  timeout 1 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$WARP_PORT" 2>/dev/null ||
    printf '警告：当前无法连接 127.0.0.1:%s，仍可继续生成配置。\n' "$WARP_PORT"
}

choose_action
if [[ "$ACTION" == configure ]]; then
  choose_mode
  [[ "$USE_SS" == true ]] && prompt_ss
  [[ "$USE_WARP" == true ]] && check_warp
  if [[ "$USE_WARP" == true && "$USE_SS" == true ]]; then choose_priority
  elif [[ "$USE_WARP" == true ]]; then ROUTE_ORDER=("$WARP_TAG")
  elif [[ "$USE_SS" == true ]]; then ROUTE_ORDER=("$SS_TAG")
  fi
  for tag in "${ROUTE_ORDER[@]}"; do
    [[ "$tag" == "$WARP_TAG" ]] && collect_rules "$tag" 'WARP' || collect_rules "$tag" 'Shadowsocks'
  done
fi

current_summary() {
  if [[ "$CORE" == xray ]]; then
    jq -r '[.outbounds[]? | "\(.tag // "?")(\(.protocol // "?"))"] | if length==0 then "<无>" else join(", ") end' "$CONFIG"
  else
    jq -r '[.outbounds[]? | "\(.tag // "?")(\(.type // "?"))"] | if length==0 then "<无>" else join(", ") end' "$CONFIG"
  fi
}

printf '\n========== 预览 ==========\n核心：%s\n配置：%s\n原出站：%s\n' "$CORE" "$CONFIG" "$(current_summary)"
if [[ "$ACTION" == delete ]]; then
  printf '操作：删除代理出口和分流，恢复仅 direct\n'
else
  printf '新出站：direct'
  [[ "$USE_WARP" == true ]] && printf ', warp(127.0.0.1:%s)' "$WARP_PORT"
  [[ "$USE_SS" == true ]] && printf ', shadowsocks(%s:%s, %s, 密码隐藏)' "$SS_ADDRESS" "$SS_PORT" "$SS_METHOD"
  printf '\n规则优先级：\n'
  if ((${#ROUTE_ORDER[@]} == 0)); then printf '  <无，全部直连>\n'; fi
  for tag in "${ROUTE_ORDER[@]}"; do
    printf '  %s:\n' "$tag"
    if [[ "$tag" == "$WARP_TAG" ]]; then rules=("${WARP_RULES[@]}"); else rules=("${SS_RULES[@]}"); fi
    for rule in "${rules[@]}"; do printf '    - %s\n' "$rule"; done
  done
fi
printf '未命中：direct\n不会备份，也不会失败回滚。\n==========================\n'
confirm=""; read_line confirm '确认执行请输入 YES: '
[[ "$confirm" == YES ]] || { printf '已取消。\n'; exit 0; }

array_to_json() {
  local output="$1"; shift || true
  if (($#)); then printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length>0))' > "$output"
  else printf '[]\n' > "$output"; fi
}
array_to_json "$WORKDIR/warp-rules.json" "${WARP_RULES[@]}"
array_to_json "$WORKDIR/ss-rules.json" "${SS_RULES[@]}"
array_to_json "$WORKDIR/order.json" "${ROUTE_ORDER[@]}"

make_xray_outbounds() {
  local schema="$1" output="$2"
  jq -n --arg schema "$schema" --argjson use_warp "$USE_WARP" --argjson warp_port "$WARP_PORT" \
    --argjson use_ss "$USE_SS" --arg addr "$SS_ADDRESS" --argjson port "$SS_PORT" \
    --arg method "$SS_METHOD" --rawfile password "$SS_PASSWORD_FILE" '
    [{tag:"direct",protocol:"freedom"}]
    + (if $use_warp then [{tag:"warp",protocol:"socks",settings:(if $schema=="modern" then {address:"127.0.0.1",port:$warp_port} else {servers:[{address:"127.0.0.1",port:$warp_port}]} end)}] else [] end)
    + (if $use_ss then [{tag:"shadowsocks",protocol:"shadowsocks",settings:(if $schema=="modern" then {address:$addr,port:$port,method:$method,password:$password} else {servers:[{address:$addr,port:$port,method:$method,password:$password}]} end)}] else [] end)
  ' > "$output"
}

make_xray_proxy_rules() {
  local output="$1"
  jq -n --slurpfile order "$WORKDIR/order.json" --slurpfile warp "$WORKDIR/warp-rules.json" --slurpfile ss "$WORKDIR/ss-rules.json" '
    def xr: map(if startswith("domain_suffix:") then "domain:" + ltrimstr("domain_suffix:") else . end);
    reduce $order[0][] as $tag ([];
      . + [{type:"field", domain:(if $tag=="warp" then ($warp[0]|xr) else ($ss[0]|xr) end), outboundTag:$tag}]
    )
  ' > "$output"
}

make_xray_candidate() {
  local schema="$1" output="$2"
  make_xray_outbounds "$schema" "$WORKDIR/xray-outbounds.json"
  make_xray_proxy_rules "$WORKDIR/xray-rules.json"
  jq --slurpfile out "$WORKDIR/xray-outbounds.json" --slurpfile proxy "$WORKDIR/xray-rules.json" '
    . as $root
    | (if (.routing|type)=="object" then .routing else {} end) as $old
    | (if (($root.api|type)=="object" and ($root.api.tag|type)=="string" and ($root.api.tag|length)>0)
       then [{type:"field",inboundTag:[$root.api.tag],outboundTag:$root.api.tag}] else [] end) as $api
    | .outbounds=$out[0]
    | .routing=(($old|del(.rules,.balancers)) + {domainStrategy:($old.domainStrategy // "IPIfNonMatch"),rules:($api+$proxy[0])})
  ' "$CONFIG" > "$output"
}

run_xray_test() {
  local file="$1" output status first
  if output="$("$CORE_BIN" run -test -config "$file" 2>&1)"; then LAST_TEST_LOG="$output"; return; fi
  status=$?; first="$CORE_BIN run -test -config $file\n退出码 $status\n$output"
  if output="$("$CORE_BIN" -test -config "$file" 2>&1)"; then LAST_TEST_LOG="$output"; return; fi
  status=$?; LAST_TEST_LOG="$first\n\n$CORE_BIN -test -config $file\n退出码 $status\n$output"; return 1
}

make_sing_outbounds() {
  jq -n --argjson use_warp "$USE_WARP" --argjson warp_port "$WARP_PORT" --argjson use_ss "$USE_SS" \
    --arg addr "$SS_ADDRESS" --argjson port "$SS_PORT" --arg method "$SS_METHOD" --rawfile password "$SS_PASSWORD_FILE" '
    [{tag:"direct",type:"direct"}]
    + (if $use_warp then [{tag:"warp",type:"socks",server:"127.0.0.1",server_port:$warp_port,version:"5"}] else [] end)
    + (if $use_ss then [{tag:"shadowsocks",type:"shadowsocks",server:$addr,server_port:$port,method:$method,password:$password}] else [] end)
  ' > "$WORKDIR/sing-outbounds.json"
}

make_sing_parts() {
  jq -n --slurpfile order "$WORKDIR/order.json" --slurpfile warp "$WORKDIR/warp-rules.json" --slurpfile ss "$WORKDIR/ss-rules.json" '
    def site: map(select(startswith("geosite:")) | "geosite-" + ltrimstr("geosite:"));
    def suffix: map(select(startswith("domain_suffix:")) | ltrimstr("domain_suffix:"));
    reduce $order[0][] as $tag ([{action:"sniff"}];
      (if $tag=="warp" then $warp[0] else $ss[0] end) as $r
      | . + (if ($r|site|length)>0 then [{rule_set:($r|site),action:"route",outbound:$tag}] else [] end)
          + (if ($r|suffix|length)>0 then [{domain_suffix:($r|suffix),action:"route",outbound:$tag}] else [] end)
    )
  ' > "$WORKDIR/sing-route-rules.json"

  jq -n --slurpfile warp "$WORKDIR/warp-rules.json" --slurpfile ss "$WORKDIR/ss-rules.json" --arg base "$RULESET_BASE" '
    (($warp[0]+$ss[0]) | map(select(startswith("geosite:")) | ltrimstr("geosite:")) | unique)
    | map({tag:("geosite-"+.),type:"remote",format:"binary",url:($base+"/geosite-"+.+".srs"),update_interval:"7d"})
  ' > "$WORKDIR/sing-rule-sets-base.json"
}

make_sing_candidate() {
  local style="$1" output="$2"
  make_sing_outbounds; make_sing_parts
  jq --arg style "$style" --arg client "$HTTP_CLIENT_TAG" \
    --slurpfile out "$WORKDIR/sing-outbounds.json" --slurpfile rules "$WORKDIR/sing-route-rules.json" \
    --slurpfile sets "$WORKDIR/sing-rule-sets-base.json" '
    (if (.route|type)=="object" then .route else {} end) as $old_route
    | ($sets[0] | map(if $style=="legacy" then .+{download_detour:"direct"} else . end)) as $rule_sets
    | .outbounds=$out[0]
    | .route=(($old_route|del(.rules,.rule_set,.final,.geoip,.geosite)) + {rules:$rules[0],rule_set:$rule_sets,final:"direct"})
    | if $style=="modern" and ($rule_sets|length)>0 then
        .http_clients=(((if (.http_clients|type)=="array" then .http_clients else [] end)
          | map(select(.tag != $client))) + [{tag:$client,detour:"direct"}])
        | .route.default_http_client=$client
      else
        (if (.http_clients|type)=="array" then .http_clients |= map(select(.tag != $client)) else . end)
        | if .route.default_http_client==$client then del(.route.default_http_client) else . end
      end
    | if ($rule_sets|length)>0 then
        .experimental=(if (.experimental|type)=="object" then .experimental else {} end)
        | .experimental.cache_file=(if (.experimental.cache_file|type)=="object" then .experimental.cache_file else {} end)
        | .experimental.cache_file.enabled=true
      else . end
  ' "$CONFIG" > "$output"
}

run_sing_test() {
  local file="$1"
  local -a cmd=("$CORE_BIN" check -c "$file")
  [[ -d "$CONF_DIR" ]] && cmd+=( -C "$CONF_DIR" )
  if LAST_TEST_LOG="$("${cmd[@]}" 2>&1)"; then return; fi
  return 1
}

SELECTED=""
if [[ "$CORE" == xray ]]; then
  make_xray_candidate modern "$WORKDIR/xray-modern.json"
  make_xray_candidate legacy "$WORKDIR/xray-legacy.json"
  printf '正在检查 Xray 配置……\n'
  if run_xray_test "$WORKDIR/xray-modern.json"; then SELECTED="$WORKDIR/xray-modern.json"; FORMAT='新版扁平格式'
  else modern_log="$LAST_TEST_LOG"; if run_xray_test "$WORKDIR/xray-legacy.json"; then SELECTED="$WORKDIR/xray-legacy.json"; FORMAT='旧版 servers 格式'
    else printf '[modern]\n%b\n\n[legacy]\n%b\n' "$modern_log" "$LAST_TEST_LOG" >&2; die '两种 Xray 格式都检查失败，原配置未修改'; fi
  fi
else
  make_sing_candidate legacy "$WORKDIR/sing-legacy.json"
  make_sing_candidate modern "$WORKDIR/sing-modern.json"
  printf '正在检查 sing-box 配置……\n'
  if run_sing_test "$WORKDIR/sing-legacy.json"; then SELECTED="$WORKDIR/sing-legacy.json"; FORMAT='rule-set download_detour 格式'
  else legacy_log="$LAST_TEST_LOG"; if run_sing_test "$WORKDIR/sing-modern.json"; then SELECTED="$WORKDIR/sing-modern.json"; FORMAT='HTTP Client 格式'
    else printf '[legacy]\n%b\n\n[modern]\n%b\n' "$legacy_log" "$LAST_TEST_LOG" >&2; die '两种 sing-box rule-set 格式都检查失败，原配置未修改'; fi
  fi
fi
printf '配置检查通过：%s\n' "$FORMAT"

atomic_replace() {
  local dir base
  dir="$(dirname -- "$CONFIG")"; base="$(basename -- "$CONFIG")"
  INSTALL_TMP="$(mktemp "$dir/.${base}.route.XXXXXXXX")" || die '无法创建临时配置'
  cp -p "$CONFIG" "$INSTALL_TMP" || die '无法复制原配置权限'
  cat "$SELECTED" > "$INSTALL_TMP" || die '无法写入配置'
  mv -f "$INSTALL_TMP" "$CONFIG" || die '无法替换配置'
  INSTALL_TMP=""
}
atomic_replace

if ((NO_RESTART)); then printf '写入完成（未重启）：%s\n' "$CONFIG"; exit 0; fi

if systemctl restart "$SERVICE"; then
  sleep 2
  if systemctl is-active --quiet "$SERVICE"; then
    printf '完成：%s 已重启，状态 active。\n配置：%s\n' "$SERVICE" "$CONFIG"
    exit 0
  fi
fi

printf '服务未正常运行；按要求未自动回滚。\n' >&2
systemctl --no-pager --full status "$SERVICE" >&2 || true
journalctl -u "$SERVICE" -n 50 --no-pager >&2 || true
exit 1
