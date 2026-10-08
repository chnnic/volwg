#!/usr/bin/env bash
set -Eeuo pipefail

NODE_ID=""
WG_IFACE=""
VPS_ENDPOINT=""
VPS_WG_PORT=""
ACTION="status"

STATE_ROOT="${VOLWG_WAN_STATE_DIR:-/etc/wg-home-exit/wan-follow}"
MANUAL_ROOT="${WG_HOME_MANUAL_DIR:-/etc/wg-home-exit/manual}"
CHECK_INTERVAL="${VOLWG_WAN_CHECK_INTERVAL:-3}"
KEEPALIVE="${VOLWG_WAN_KEEPALIVE:-5}"
FAILURE_LIMIT=3
RECOVERY_COOLDOWN=60
RUNTIME_ROOT="${VOLWG_WAN_RUNTIME_DIR:-/var/run/volwg-wan}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="" INIT_SCRIPT="" MANUAL_STATE="" RUNTIME_FILE="" LOCK_DIR=""
LAST_EGRESS="" LAST_RX="" LAST_RECOVERY=-60 FAILURES=0 PING_CONFIRMED=0
PENDING_EGRESS_CHANGE=0 RECOVERING=0 RESUME_IFUP=0 STOP_REQUESTED=0
HEALTH="等待探测" LAST_EVENT="尚未触发恢复"

usage() {
  cat <<'EOF'
用法：
  volwg wan-follow enable --node ID [--interface IFACE] [--endpoint HOST] [--port PORT]
  volwg wan-follow status --node ID
  volwg wan-follow once --node ID
  volwg wan-follow disable --node ID
  volwg wan-follow refresh-all

说明：
  仅用于 OpenWrt/ImmortalWrt 家宽机。
  自动让 WireGuard endpoint 跟随当前优先级最高且链路在线的默认出口。
  网线可用时走低 metric 的 WAN；网线断开后自动切到 5G/备用 WAN。
  每 3 秒主动探测隧道，保活 5 秒；公网 IP/NAT 变化后自动学习新端点。
  连续 3 次确认故障才刷新单条线路，恢复操作至少间隔 60 秒。
  refresh-all 用于升级后刷新已启用的服务，并为活动的旧家宽线路补开功能。
  显式关闭的自动恢复服务、手动停用的 WireGuard 接口不会被重新开启。
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

field() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

valid_node() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

set_paths() {
  CONFIG_FILE="$STATE_ROOT/$NODE_ID.conf"
  INIT_SCRIPT="/etc/init.d/wgh-wan-$NODE_ID"
  MANUAL_STATE="$MANUAL_ROOT/$NODE_ID.conf"
  RUNTIME_FILE="$RUNTIME_ROOT/$NODE_ID.status"
  LOCK_DIR="$RUNTIME_ROOT/$NODE_ID.lock"
}

load_values() {
  if [[ -r "$CONFIG_FILE" ]]; then
    [[ -n "$WG_IFACE" ]] || WG_IFACE="$(field "$CONFIG_FILE" WG_INTERFACE)"
    [[ -n "$VPS_ENDPOINT" ]] || VPS_ENDPOINT="$(field "$CONFIG_FILE" VPS_ENDPOINT)"
    [[ -n "$VPS_WG_PORT" ]] || VPS_WG_PORT="$(field "$CONFIG_FILE" VPS_WG_PORT)"
  fi
  if [[ -r "$MANUAL_STATE" ]]; then
    [[ -n "$WG_IFACE" ]] || WG_IFACE="$(field "$MANUAL_STATE" WG_INTERFACE)"
    [[ -n "$VPS_ENDPOINT" ]] || VPS_ENDPOINT="$(field "$MANUAL_STATE" VPS_ENDPOINT)"
    [[ -n "$VPS_WG_PORT" ]] || VPS_WG_PORT="$(field "$MANUAL_STATE" VPS_WG_PORT)"
  fi
  [[ -n "$WG_IFACE" ]] || WG_IFACE="wgh_$NODE_ID"
  [[ "$WG_IFACE" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] || die "WireGuard 接口名称无效"
}

require_openwrt() {
  command -v uci >/dev/null 2>&1 && [[ -x /etc/init.d/network ]] || die "WAN 自动跟随目前仅支持 OpenWrt/ImmortalWrt 家宽机"
}

endpoint_from_wireguard() {
  local raw endpoint_ip endpoint_port
  raw="$(wg show "$WG_IFACE" endpoints 2>/dev/null | awk 'NR == 1 {print $2}')"
  [[ -n "$raw" && "$raw" != "(none)" ]] || return 1
  case "$raw" in
    \[*\]:*) return 1 ;;
    *:*)
      endpoint_ip="${raw%:*}"
      endpoint_port="${raw##*:}"
      ;;
    *) return 1 ;;
  esac
  [[ "$endpoint_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  valid_port "$endpoint_port" || return 1
  printf '%s|%s' "$endpoint_ip" "$endpoint_port"
}

resolve_endpoint() {
  local endpoint_ip=""
  if [[ "$VPS_ENDPOINT" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    endpoint_ip="$VPS_ENDPOINT"
  elif command -v resolveip >/dev/null 2>&1; then
    endpoint_ip="$(resolveip -4 -t 3 "$VPS_ENDPOINT" 2>/dev/null | awk 'NR == 1 {print $1}')"
  elif command -v getent >/dev/null 2>&1; then
    endpoint_ip="$(getent ahostsv4 "$VPS_ENDPOINT" 2>/dev/null | awk 'NR == 1 {print $1}')"
  fi
  [[ "$endpoint_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  valid_port "$VPS_WG_PORT" || return 1
  printf '%s|%s' "$endpoint_ip" "$VPS_WG_PORT"
}

interface_has_carrier() {
  local device="$1" carrier_file="/sys/class/net/$1/carrier" state_file="/sys/class/net/$1/operstate" carrier state
  [[ -e "/sys/class/net/$device" ]] || return 1
  if [[ -r "$carrier_file" ]]; then
    carrier="$(<"$carrier_file")"
    [[ "$carrier" == "1" ]] || return 1
  elif [[ -r "$state_file" ]]; then
    state="$(<"$state_file")"
    [[ "$state" != "down" && "$state" != "lowerlayerdown" ]] || return 1
  fi
}

select_best_default() {
  local route device gateway metric
  local best_device="" best_gateway="" best_metric=2147483647
  while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    device="$(sed -n 's/.* dev \([^ ]*\).*/\1/p' <<<"$route")"
    gateway="$(sed -n 's/^default via \([^ ]*\).*/\1/p' <<<"$route")"
    metric="$(sed -n 's/.* metric \([0-9][0-9]*\).*/\1/p' <<<"$route")"
    [[ -n "$metric" ]] || metric=0
    [[ -n "$device" && "$device" != "$WG_IFACE" ]] || continue
    interface_has_carrier "$device" || continue
    if ((10#$metric < best_metric)); then
      best_device="$device"
      best_gateway="$gateway"
      best_metric=$((10#$metric))
    fi
  done < <(ip -4 route show default 2>/dev/null)
  [[ -n "$best_device" ]] || return 1
  printf '%s|%s|%s' "$best_device" "$best_gateway" "$best_metric"
}

apply_route_once() {
  local endpoint_pair endpoint_ip endpoint_port default_pair device gateway metric current peer
  local current_device current_gateway source_ip signature path_changed=0 rx_before rx_after target
  # ifdown 是用户的停用操作；守护进程不可因健康检查而把接口重新打开。
  # 唯一例外：上一个守护进程在自己的 ifdown/ifup 之间被结束，接口是被自动恢复关掉的。
  if ! wg show "$WG_IFACE" >/dev/null 2>&1; then
    if ((RESUME_IFUP)); then
      RESUME_IFUP=0
      if [[ "$(uci -q get "network.$WG_IFACE.proto" 2>/dev/null || true)" == "wireguard" ]]; then
        ifup "$WG_IFACE" >/dev/null 2>&1 || true
        LAST_EVENT="上次自动恢复被中断，已重新启动本线路"
        logger -t volwg-wan-follow "线路 ${NODE_ID}：$LAST_EVENT"
        HEALTH="已重新启动，等待隧道回包"
        FAILURES=0 LAST_EGRESS="" LAST_RX="" PENDING_EGRESS_CHANGE=0
        return 0
      fi
    fi
    HEALTH="接口未运行，等待手动启动"
    FAILURES=0 LAST_EGRESS="" LAST_RX="" PENDING_EGRESS_CHANGE=0
    return 0
  fi
  RESUME_IFUP=0
  endpoint_pair="$(endpoint_from_wireguard 2>/dev/null || resolve_endpoint 2>/dev/null || true)"
  [[ -n "$endpoint_pair" ]] || { HEALTH="等待 VPS 地址解析"; return 0; }
  IFS='|' read -r endpoint_ip endpoint_port <<<"$endpoint_pair"
  default_pair="$(select_best_default 2>/dev/null || true)"
  if [[ -z "$default_pair" ]]; then
    HEALTH="等待 WAN 联网"
    FAILURES=0
    return 0
  fi
  IFS='|' read -r device gateway metric <<<"$default_pair"
  current="$(ip -4 route show "$endpoint_ip/32" 2>/dev/null | head -n 1)"
  current_device="$(awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' <<<"$current")"
  current_gateway="$(awk '{for(i=1;i<NF;i++) if($i=="via") print $(i+1)}' <<<"$current")"
  if [[ "$current_device" != "$device" || "$current_gateway" != "$gateway" ]]; then
    replace_endpoint_route "$endpoint_ip" "$device" "$gateway" "$metric" || {
      HEALTH="endpoint 路由更新失败，稍后重试"; return 0;
    }
    path_changed=1
  fi
  source_ip="$(ip -4 route get "$endpoint_ip" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="src") {print $(i+1); exit}}')"
  signature="$device|$gateway|$source_ip"
  if [[ -n "$LAST_EGRESS" && "$LAST_EGRESS" != "$signature" ]]; then
    path_changed=1
  fi
  LAST_EGRESS="$signature"
  peer="$(wg show "$WG_IFACE" peers 2>/dev/null | head -n 1)"
  [[ -n "$peer" ]] || { HEALTH="未配置 WireGuard 对端"; return 0; }
  set_live_keepalive "$peer" || { HEALTH="保活设置失败，稍后重试"; return 0; }
  if ((path_changed)); then
    # 先清理缓存的 endpoint 路由并发探测，保留可用会话；无响应才进入恢复流程。
    wg set "$WG_IFACE" peer "$peer" endpoint "$endpoint_ip:$endpoint_port" >/dev/null 2>&1 || true
    LAST_EVENT="已跟随 $device${gateway:+ via $gateway}${source_ip:+，源地址 $source_ip}"
    PENDING_EGRESS_CHANGE=1
    logger -t volwg-wan-follow "线路 ${NODE_ID}：${LAST_EVENT}，正在验证隧道"
  fi
  target="$(probe_target "$peer")"
  [[ -n "$target" ]] || { HEALTH="缺少对端 IPv4 /32，仅维持保活"; return 0; }
  rx_before="$(received_bytes "$peer")"
  if ping -I "$WG_IFACE" -c 1 -W 1 "$target" >/dev/null 2>&1; then
    PING_CONFIRMED=1
    FAILURES=0 PENDING_EGRESS_CHANGE=0
    HEALTH="正常"
  else
    rx_after="$(received_bytes "$peer")"
    if ((rx_after > rx_before)) || { [[ -n "$LAST_RX" ]] && ((rx_after > LAST_RX)); }; then
      # ICMP 受限但仍有经认证的数据返回时，不能误判并重启健康的隧道。
      FAILURES=0 PENDING_EGRESS_CHANGE=0
      HEALTH="有隧道回包（Ping 无响应）"
    else
      FAILURES=$((FAILURES + 1))
      HEALTH="探测无回包（$FAILURES/${FAILURE_LIMIT}）"
      # 从未收到过 ICMP 应答时，不能区分屏蔽 Ping 和故障。保持主动探测，
      # 不对未知防火墙策略进行无限重启；出口变化时允许一次保守恢复。
      if ((FAILURES >= FAILURE_LIMIT && (PING_CONFIRMED || PENDING_EGRESS_CHANGE))); then
        recover_interface "$endpoint_ip" "$endpoint_port" "$device" "$gateway" "$metric"
      fi
    fi
  fi
  LAST_RX="$(received_bytes "$peer")"
}

replace_endpoint_route() {
  local endpoint_ip="$1" device="$2" gateway="$3" metric="$4"
  if [[ -n "$gateway" ]]; then
    ip -4 route replace "$endpoint_ip/32" via "$gateway" dev "$device" metric "$metric"
  else
    ip -4 route replace "$endpoint_ip/32" dev "$device" metric "$metric"
  fi
}

probe_target() {
  # 每条 VolWG 线路只有一个 VPS /32；从实际 AllowedIPs 读取，兼容早期元数据。
  wg show "$WG_IFACE" allowed-ips 2>/dev/null | awk -v peer="$1" '
    $1==peer {for(i=2;i<=NF;i++) {gsub(/,/, "", $i); if($i ~ /^[0-9.]+\/32$/) {sub(/\/32$/, "", $i); print $i; exit}}}'
}

received_bytes() {
  local value
  value="$(wg show "$WG_IFACE" transfer 2>/dev/null | awk -v peer="$1" '$1==peer {print $2; exit}')"
  printf '%s' "${value:-0}"
}

set_live_keepalive() {
  local peer="$1" current
  current="$(wg show "$WG_IFACE" persistent-keepalive 2>/dev/null | awk -v peer="$peer" '$1==peer {print $2; exit}')"
  if [[ "$current" != "$KEEPALIVE" ]]; then
    wg set "$WG_IFACE" peer "$peer" persistent-keepalive "$KEEPALIVE"
  fi
}

monotonic_seconds() {
  local uptime rest
  read -r uptime rest </proc/uptime
  printf '%s' "${uptime%%.*}"
}

recover_interface() {
  local endpoint_ip="$1" endpoint_port="$2" device="$3" gateway="$4" metric="$5" now peer fresh_pair saved_traps
  now="$(monotonic_seconds)"
  if ((now - LAST_RECOVERY < RECOVERY_COOLDOWN)); then
    HEALTH="等待自动恢复冷却（$((RECOVERY_COOLDOWN - now + LAST_RECOVERY)) 秒）"
    return 0
  fi
  [[ "$(uci -q get "network.$WG_IFACE.proto" 2>/dev/null || true)" == "wireguard" ]] || return 0
  wg show "$WG_IFACE" >/dev/null 2>&1 || return 0
  LAST_RECOVERY="$now"
  FAILURES=0 PENDING_EGRESS_CHANGE=0
  LAST_EVENT="隧道无回包，已刷新本线路会话"
  logger -t volwg-wan-follow "线路 ${NODE_ID}：$LAST_EVENT"
  # ifdown/ifup 必须成对完成：停止信号延后到 ifup 之后处理；同时在 RAM 中记录恢复进行中，
  # 进程即使被强制结束，重启后的守护进程也会重新启动本线路，而不会误当成用户停用。
  saved_traps="$(trap -p TERM INT)"
  STOP_REQUESTED=0
  trap 'STOP_REQUESTED=1' TERM INT
  RECOVERING=1
  save_runtime
  ifdown "$WG_IFACE" >/dev/null 2>&1 || true
  sleep 1
  ifup "$WG_IFACE" >/dev/null 2>&1 || true
  sleep 1
  RECOVERING=0
  # ifup 时 netifd 会重新解析 endpoint 域名；采用新地址，不能把恢复前缓存的旧 IP 写回。
  fresh_pair="$(resolve_endpoint 2>/dev/null || endpoint_from_wireguard 2>/dev/null || true)"
  [[ -z "$fresh_pair" ]] || IFS='|' read -r endpoint_ip endpoint_port <<<"$fresh_pair"
  replace_endpoint_route "$endpoint_ip" "$device" "$gateway" "$metric" >/dev/null 2>&1 || true
  peer="$(wg show "$WG_IFACE" peers 2>/dev/null | head -n 1)"
  if [[ -n "$peer" ]]; then
    wg set "$WG_IFACE" peer "$peer" endpoint "$endpoint_ip:$endpoint_port" >/dev/null 2>&1 || true
    set_live_keepalive "$peer" || true
  fi
  HEALTH="已刷新会话，等待隧道回包"
  save_runtime
  trap - TERM INT
  [[ -z "$saved_traps" ]] || eval "$saved_traps"
  ((STOP_REQUESTED == 0)) || exit 0
}

save_runtime() {
  # 状态仅写入 RAM，不在每次探测时写闪存。
  [[ -n "$RUNTIME_FILE" ]] || return 0
  printf 'HEALTH=%s\nLAST_EVENT=%s\nEGRESS=%s\nPING_CONFIRMED=%s\nLAST_RECOVERY=%s\nRECOVERING=%s\nCHECKED_AT=%s\n' \
    "$HEALTH" "$LAST_EVENT" "$LAST_EGRESS" "$PING_CONFIRMED" "$LAST_RECOVERY" "$RECOVERING" "$(date +%s)" >"$RUNTIME_FILE.tmp"
  mv -f "$RUNTIME_FILE.tmp" "$RUNTIME_FILE"
}

acquire_lock() {
  local owner=""
  mkdir -p "$RUNTIME_ROOT"
  chmod 700 "$RUNTIME_ROOT"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    [[ ! -r "$LOCK_DIR/pid" ]] || read -r owner <"$LOCK_DIR/pid" || true
    [[ "$owner" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$owner" 2>/dev/null && return 1
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null && mkdir "$LOCK_DIR" 2>/dev/null || return 1
  fi
  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  trap release_lock EXIT
  trap 'exit 0' TERM INT
  # 保留冷却和已验证过的探测能力，避免升级/手动 once 绕过节流。
  owner="$(field "$RUNTIME_FILE" LAST_RECOVERY)"
  [[ ! "$owner" =~ ^-?[0-9]+$ ]] || LAST_RECOVERY="$owner"
  [[ "$(field "$RUNTIME_FILE" PING_CONFIRMED)" != 1 ]] || PING_CONFIRMED=1
  [[ "$(field "$RUNTIME_FILE" RECOVERING)" != 1 ]] || RESUME_IFUP=1
}

release_lock() {
  local owner=""
  [[ ! -r "$LOCK_DIR/pid" ]] || read -r owner <"$LOCK_DIR/pid" || true
  if [[ "$owner" == "$$" ]]; then
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

write_config() {
  mkdir -p "$STATE_ROOT"
  chmod 700 "$STATE_ROOT"
  cat >"$CONFIG_FILE" <<EOF
NODE_ID=$NODE_ID
WG_INTERFACE=$WG_IFACE
VPS_ENDPOINT=$VPS_ENDPOINT
VPS_WG_PORT=$VPS_WG_PORT
EOF
  chmod 600 "$CONFIG_FILE"
}

write_init_script() {
  cat >"$INIT_SCRIPT" <<EOF
#!/bin/sh /etc/rc.common
START=19
STOP=89
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /bin/bash '$SCRIPT_DIR/wg-home-wan-follow.sh' run --node '$NODE_ID'
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
  chmod 755 "$INIT_SCRIPT"
}

enable_follow() {
  require_openwrt
  load_values
  [[ -n "$VPS_ENDPOINT" ]] || die "缺少 VPS endpoint；请使用 --endpoint 指定"
  valid_port "$VPS_WG_PORT" || die "缺少或无效的 VPS WireGuard 端口"
  [[ "$WG_IFACE" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "WireGuard 接口名称无效"
  [[ "$VPS_ENDPOINT" =~ ^[a-zA-Z0-9._-]+$ ]] || die "VPS endpoint 仅支持 IPv4 或域名"
  write_config
  # 旧线路仅在运行时设置保活，服务重启后会再次应用；不提交用户的 UCI 网络配置。
  write_init_script
  "$INIT_SCRIPT" enable >/dev/null
  "$INIT_SCRIPT" restart >/dev/null 2>&1 || "$INIT_SCRIPT" start >/dev/null
  sleep 1
  echo "已开启线路 $NODE_ID 的 WAN/IP 自动恢复（$CHECK_INTERVAL 秒探测、$KEEPALIVE 秒保活）。"
}

disable_follow() {
  require_openwrt
  if [[ -x "$INIT_SCRIPT" ]]; then
    "$INIT_SCRIPT" stop >/dev/null 2>&1 || true
    "$INIT_SCRIPT" disable >/dev/null 2>&1 || true
  fi
  echo "已关闭线路 $NODE_ID 的 WAN 自动跟随；配置保留，可再次启用。"
}

show_status() {
  local endpoint_pair endpoint_ip endpoint_port default_pair device gateway metric current service_state="未启用"
  load_values
  [[ -x "$INIT_SCRIPT" ]] && service_state="$($INIT_SCRIPT status 2>/dev/null || true)"
  endpoint_pair="$(endpoint_from_wireguard 2>/dev/null || resolve_endpoint 2>/dev/null || true)"
  default_pair="$(select_best_default 2>/dev/null || true)"
  echo "线路：$NODE_ID"
  echo "服务：${service_state:-未运行}"
  echo "自动恢复：${CHECK_INTERVAL} 秒探测、${KEEPALIVE} 秒保活；连续 $FAILURE_LIMIT 次无回包后恢复，冷却 $RECOVERY_COOLDOWN 秒"
  if [[ -r "$RUNTIME_FILE" ]]; then
    echo "最近探测：$(field "$RUNTIME_FILE" HEALTH)"
    echo "最近事件：$(field "$RUNTIME_FILE" LAST_EVENT)"
    echo "探测记录时间（Unix）：$(field "$RUNTIME_FILE" CHECKED_AT)"
  fi
  if [[ -n "$default_pair" ]]; then
    IFS='|' read -r device gateway metric <<<"$default_pair"
    echo "当前首选出口：$device${gateway:+ via $gateway}（metric ${metric}）"
  else
    echo "当前首选出口：未找到可用默认路由"
  fi
  if [[ -n "$endpoint_pair" ]]; then
    IFS='|' read -r endpoint_ip endpoint_port <<<"$endpoint_pair"
    current="$(ip -4 route show "$endpoint_ip/32" 2>/dev/null | head -n 1)"
    echo "WireGuard endpoint：$endpoint_ip:$endpoint_port"
    echo "endpoint 路由：${current:-未建立}"
  fi
}

run_loop() {
  require_openwrt
  load_values
  acquire_lock || { echo "线路 $NODE_ID 已有自动恢复进程运行。"; return 0; }
  while true; do
    apply_route_once || true
    save_runtime
    sleep "$CHECK_INTERVAL"
  done
}

should_refresh_follow() {
  local iface="$1" service="$2" config="$3"
  [[ "$(uci -q get "network.$iface.proto" 2>/dev/null || true)" == wireguard ]] || return 1
  if [[ -e "$service" ]]; then
    "$service" enabled >/dev/null 2>&1
  elif [[ -e "$config" ]]; then
    return 1
  else
    wg show "$iface" >/dev/null 2>&1
  fi
}

refresh_all() {
  local record node service iface failed=0
  require_openwrt
  for record in "$MANUAL_ROOT"/*.conf; do
    [[ -r "$record" && "$(field "$record" ROLE)" == home ]] || continue
    node="${record##*/}"; node="${node%.conf}"
    valid_node "$node" || continue
    service="/etc/init.d/wgh-wan-$node"
    iface="$(field "$record" WG_INTERFACE)"; iface="${iface:-wgh_$node}"
    should_refresh_follow "$iface" "$service" "$STATE_ROOT/$node.conf" || continue
    bash "$SCRIPT_DIR/wg-home-wan-follow.sh" enable --node "$node" || failed=1
  done
  return "$failed"
}

main() {
  ACTION="${1:-status}"
  [[ $# -eq 0 ]] || shift
  case "$ACTION" in -h|--help|help) usage; return 0 ;; esac
  while (($#)); do
    case "$1" in
      --node|--interface|--endpoint|--port)
        (($# >= 2)) || die "$1 缺少值"
        case "$1" in
          --node) NODE_ID="$2" ;;
          --interface) WG_IFACE="$2" ;;
          --endpoint) VPS_ENDPOINT="$2" ;;
          --port) VPS_WG_PORT="$2" ;;
        esac
        shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ "$CHECK_INTERVAL" =~ ^[1-9][0-9]?$ && "$KEEPALIVE" =~ ^[1-9][0-9]?$ ]] || die "探测/保活间隔必须为 1-99 秒"
  if [[ "$ACTION" == refresh-all ]]; then refresh_all; return; fi
  valid_node "$NODE_ID" || die "--node 必须是 1-8 位小写字母、数字或下划线"
  set_paths
  case "$ACTION" in
    enable) enable_follow ;;
    disable) disable_follow ;;
    status) require_openwrt; show_status ;;
    once)
      require_openwrt; load_values
      if acquire_lock; then apply_route_once; save_runtime; fi
      show_status ;;
    run) run_loop ;;
    *) die "操作必须是 enable、disable、status、once 或 refresh-all" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
