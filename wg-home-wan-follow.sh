#!/usr/bin/env bash
set -Eeuo pipefail

NODE_ID=""
WG_IFACE=""
VPS_ENDPOINT=""
VPS_WG_PORT=""
ACTION="${1:-status}"
[[ $# -eq 0 ]] || shift

STATE_ROOT="${VOLWG_WAN_STATE_DIR:-/etc/wg-home-exit/wan-follow}"
MANUAL_ROOT="${WG_HOME_MANUAL_DIR:-/etc/wg-home-exit/manual}"
CHECK_INTERVAL="${VOLWG_WAN_CHECK_INTERVAL:-3}"

usage() {
  cat <<'EOF'
用法：
  volwg wan-follow enable --node ID [--interface IFACE] [--endpoint HOST] [--port PORT]
  volwg wan-follow status --node ID
  volwg wan-follow once --node ID
  volwg wan-follow disable --node ID

说明：
  仅用于 OpenWrt/ImmortalWrt 家宽机。
  自动让 WireGuard endpoint 跟随当前优先级最高且链路在线的默认出口。
  网线可用时走低 metric 的 WAN；网线断开后自动切到 5G/备用 WAN。
EOF
}

if [[ "$ACTION" == "-h" || "$ACTION" == "--help" || "$ACTION" == "help" ]]; then
  usage
  exit 0
fi

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

while (($#)); do
  case "$1" in
    --node) NODE_ID="${2:-}"; shift 2 ;;
    --interface) WG_IFACE="${2:-}"; shift 2 ;;
    --endpoint) VPS_ENDPOINT="${2:-}"; shift 2 ;;
    --port) VPS_WG_PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ "$ACTION" == "enable" || "$ACTION" == "disable" || "$ACTION" == "status" || "$ACTION" == "once" || "$ACTION" == "run" ]] || die "操作必须是 enable、disable、status 或 once"
valid_node "$NODE_ID" || die "--node 必须是 1-8 位小写字母、数字或下划线"

CONFIG_FILE="$STATE_ROOT/$NODE_ID.conf"
INIT_SCRIPT="/etc/init.d/wgh-wan-$NODE_ID"
MANUAL_STATE="$MANUAL_ROOT/$NODE_ID.conf"

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
  local endpoint_pair endpoint_ip endpoint_port default_pair device gateway metric current peer desired
  endpoint_pair="$(endpoint_from_wireguard 2>/dev/null || resolve_endpoint 2>/dev/null || true)"
  [[ -n "$endpoint_pair" ]] || return 1
  IFS='|' read -r endpoint_ip endpoint_port <<<"$endpoint_pair"
  default_pair="$(select_best_default 2>/dev/null || true)"
  [[ -n "$default_pair" ]] || return 1
  IFS='|' read -r device gateway metric <<<"$default_pair"
  current="$(ip -4 route show "$endpoint_ip/32" 2>/dev/null | head -n 1)"
  desired="dev $device"
  if [[ "$current" == *"$desired"* ]]; then
    if [[ -z "$gateway" || "$current" == *"via $gateway"* ]]; then
      return 0
    fi
  fi
  if [[ -n "$gateway" ]]; then
    ip -4 route replace "$endpoint_ip/32" via "$gateway" dev "$device" metric "$metric"
  else
    ip -4 route replace "$endpoint_ip/32" dev "$device" metric "$metric"
  fi
  # 多 WAN 切换后仅替换主机路由不够：WireGuard 的 UDP socket 和上游 NAT
  # 可能继续保留旧出口状态，表现为 endpoint 看似正确但隧道大量丢包。
  # 重建单条 VolWG 接口以刷新 socket/握手；不重启 network，也不影响其他节点。
  if [[ "$(uci -q get "network.$WG_IFACE.proto" 2>/dev/null || true)" == "wireguard" ]]; then
    ifdown "$WG_IFACE" >/dev/null 2>&1 || true
    sleep 1
    ifup "$WG_IFACE" >/dev/null 2>&1 || true
    sleep 1
    if [[ -n "$gateway" ]]; then
      ip -4 route replace "$endpoint_ip/32" via "$gateway" dev "$device" metric "$metric"
    else
      ip -4 route replace "$endpoint_ip/32" dev "$device" metric "$metric"
    fi
  fi
  peer="$(wg show "$WG_IFACE" peers 2>/dev/null | head -n 1)"
  if [[ -n "$peer" ]]; then
    wg set "$WG_IFACE" peer "$peer" endpoint "$endpoint_ip:$endpoint_port" >/dev/null 2>&1 || true
  fi
  logger -t volwg-wan-follow "线路 $NODE_ID 的 WireGuard endpoint 已切换到 $device${gateway:+ via $gateway}，接口会话已刷新"
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
  procd_set_param command /bin/bash /usr/lib/volwg/wg-home-wan-follow.sh run --node '$NODE_ID'
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
  write_init_script
  "$INIT_SCRIPT" enable >/dev/null
  "$INIT_SCRIPT" restart >/dev/null 2>&1 || "$INIT_SCRIPT" start >/dev/null
  sleep 1
  apply_route_once || true
  echo "已开启线路 $NODE_ID 的 WAN 自动跟随。"
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
  if [[ -n "$default_pair" ]]; then
    IFS='|' read -r device gateway metric <<<"$default_pair"
    echo "当前首选出口：$device${gateway:+ via $gateway}（metric $metric）"
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
  while true; do
    apply_route_once || true
    sleep "$CHECK_INTERVAL"
  done
}

case "$ACTION" in
  enable) enable_follow ;;
  disable) disable_follow ;;
  status) require_openwrt; show_status ;;
  once) require_openwrt; load_values; apply_route_once; show_status ;;
  run) run_loop ;;
esac
