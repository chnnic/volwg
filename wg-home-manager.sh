#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${WG_HOME_STATE_DIR:-/etc/wg-home-exit/nodes}"

die() {
  echo "错误：$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  wg-home-manager list             查看所有线路
  wg-home-manager links            查看所有线路的 SS 链接
  wg-home-manager show 节点ID      查看单条线路详情
  wg-home-manager status           查看 WireGuard 握手状态
  wg-home-manager rename ID 名称   修改线路名称和 SS 链接备注
  wg-home-manager register         登记旧版本或手工创建的 SS 线路
  wg-home-manager menu             打开交互式管理菜单

说明：
  每条线路彼此独立，不会自动配置负载均衡。
  relay 显示公网 SS 链接；direct 显示仅 VPS 本机可达的隧道 SS 链接和 Xray outbound。
EOF
}

field() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

decode() {
  local value="$1"
  [[ -n "$value" ]] || return 0
  printf '%s' "$value" | base64 -d 2>/dev/null || true
}

encode() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

urlencode() {
  local LC_ALL=C input="$1" output="" char hex index
  for ((index=0; index<${#input}; index++)); do
    char="${input:index:1}"
    case "$char" in
      [a-zA-Z0-9.~_-]) output+="$char" ;;
      *)
        printf -v hex '%%%02X' "'$char"
        output+="$hex"
        ;;
    esac
  done
  printf '%s' "$output"
}

node_file() {
  local node_id="$1"
  [[ "$node_id" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "节点 ID 无效"
  [[ -f "$STATE_DIR/$node_id.conf" ]] || die "找不到节点：$node_id"
  printf '%s' "$STATE_DIR/$node_id.conf"
}

node_status() {
  local iface="$1" handshake now age
  if ! command -v wg >/dev/null 2>&1 || ! ip link show "$iface" >/dev/null 2>&1; then
    printf '未运行'
    return
  fi
  handshake="$(wg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
  if [[ -z "$handshake" || "$handshake" == "0" ]]; then
    printf '等待握手'
    return
  fi
  now="$(date +%s)"
  age=$((now - handshake))
  if ((age <= 180)); then
    printf '在线(%ss)' "$age"
  else
    printf '离线(%ss)' "$age"
  fi
}

list_nodes() {
  local file id name mode iface endpoint status found=0
  printf '%-10s %-24s %-8s %-18s %-22s %s\n' "节点ID" "线路名称" "模式" "WG接口" "SS地址" "状态"
  printf '%-10s %-24s %-8s %-18s %-22s %s\n' "----------" "------------------------" "--------" "------------------" "----------------------" "----------"
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    found=1
    id="$(field "$file" NODE_ID)"
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    mode="$(field "$file" MODE)"
    iface="$(field "$file" WG_INTERFACE)"
    endpoint="$(field "$file" SS_ENDPOINT)"
    status="$(node_status "$iface")"
    printf '%-10s %-24.24s %-8s %-18s %-22s %s\n' "$id" "$name" "$mode" "$iface" "$endpoint" "$status"
  done
  ((found == 1)) || echo "尚未登记线路。"
}

list_links() {
  local file id name mode link found=0
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    found=1
    id="$(field "$file" NODE_ID)"
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    mode="$(field "$file" MODE)"
    link="$(decode "$(field "$file" SS_LINK_B64)")"
    echo "[$id] $name ($mode)"
    echo "$link"
    [[ "$mode" == "relay" ]] || echo "  注意：direct 链接仅在该 VPS/WireGuard 网络内可达。"
    echo
  done
  ((found == 1)) || echo "尚未登记线路。"
}

show_node() {
  local file="$1" id name mode iface wg_port prefix endpoint link outbound
  id="$(field "$file" NODE_ID)"
  name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
  mode="$(field "$file" MODE)"
  iface="$(field "$file" WG_INTERFACE)"
  wg_port="$(field "$file" WG_PORT)"
  prefix="$(field "$file" WG_PREFIX)"
  endpoint="$(field "$file" SS_ENDPOINT)"
  link="$(decode "$(field "$file" SS_LINK_B64)")"
  outbound="$(decode "$(field "$file" XRAY_OUTBOUND_B64)")"

  echo "线路名称：$name"
  echo "节点 ID：$id"
  echo "模式：$mode"
  echo "WireGuard：${iface}，UDP ${wg_port}，${prefix}.1 ↔ ${prefix}.2"
  echo "状态：$(node_status "$iface")"
  echo "SS 地址：$endpoint"
  echo "SS 链接：$link"
  if [[ "$mode" == "direct" ]]; then
    echo "注意：该 SS 链接是隧道私网地址，仅供这台 VPS 的 Xray 使用。"
  fi
  echo
  echo "Xray outbound："
  echo "$outbound"
}

show_status() {
  local file id name iface
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    id="$(field "$file" NODE_ID)"
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    iface="$(field "$file" WG_INTERFACE)"
    printf '%-10s %-24.24s %s\n' "$id" "$name" "$(node_status "$iface")"
  done
}

rename_node() {
  local file="$1" new_name="$2" old_link new_link
  [[ "$(id -u)" == "0" ]] || die "修改线路名称需要 root，请使用 sudo"
  [[ -n "$new_name" ]] || die "新名称不能为空"
  old_link="$(decode "$(field "$file" SS_LINK_B64)")"
  new_link="${old_link%%#*}#$(urlencode "$new_name")"
  sed -i "s|^DISPLAY_NAME_B64=.*|DISPLAY_NAME_B64=$(encode "$new_name")|" "$file"
  sed -i "s|^SS_LINK_B64=.*|SS_LINK_B64=$(encode "$new_link")|" "$file"
  chmod 600 "$file"
  echo "已更新线路名称：$new_name"
  echo "$new_link"
}

register_node() {
  local node_id name mode iface wg_port prefix endpoint link outbound answer file
  [[ "$(id -u)" == "0" ]] || die "登记线路需要 root，请使用 sudo"
  read -r -p "节点 ID（1-8 位小写字母/数字/_）：" node_id
  [[ "$node_id" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "节点 ID 无效"
  read -r -p "线路显示名称：" name
  [[ -n "$name" ]] || die "线路名称不能为空"
  read -r -p "模式 relay/direct [relay]：" mode
  mode="${mode:-relay}"
  [[ "$mode" == "relay" || "$mode" == "direct" ]] || die "模式无效"
  read -r -p "WireGuard 接口 [wg-home]：" iface
  iface="${iface:-wg-home}"
  [[ "$iface" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,14}$ ]] || die "WireGuard 接口名无效"
  read -r -p "WireGuard UDP 端口 [51830]：" wg_port
  wg_port="${wg_port:-51830}"
  if ! [[ "$wg_port" =~ ^[0-9]+$ ]] || ((wg_port < 1 || wg_port > 65535)); then
    die "WireGuard 端口无效"
  fi
  read -r -p "WireGuard 网段前缀 [10.88.0]：" prefix
  prefix="${prefix:-10.88.0}"
  [[ "$prefix" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "WireGuard 网段前缀无效"
  read -r -p "SS 地址（例如 203.0.113.10:31000）：" endpoint
  [[ -n "$endpoint" ]] || die "SS 地址不能为空"
  read -r -p "粘贴现有 SS 链接：" link
  [[ "$link" == ss://* ]] || die "SS 链接无效"
  link="${link%%#*}#$(urlencode "$name")"
  read -r -p "Xray outbound JSON（可留空）：" outbound

  install -d -m 700 "$STATE_DIR"
  file="$STATE_DIR/$node_id.conf"
  if [[ -e "$file" ]]; then
    read -r -p "节点已存在，输入 yes 覆盖：" answer
    [[ "$answer" == "yes" ]] || die "用户取消"
  fi
  cat >"$file" <<EOF
NODE_ID=$node_id
DISPLAY_NAME_B64=$(encode "$name")
MODE=$mode
WG_INTERFACE=$iface
WG_PORT=$wg_port
WG_PREFIX=$prefix
SS_PORT=${endpoint##*:}
SS_ENDPOINT=$endpoint
SS_LINK_B64=$(encode "$link")
XRAY_OUTBOUND_B64=$(encode "$outbound")
EOF
  chmod 600 "$file"
  echo "已登记线路：$name ($node_id)"
  echo "$link"
}

menu() {
  local choice node_id new_name
  while true; do
    echo "============================================================"
    echo " WG Home Exit 线路管理"
    echo "============================================================"
    echo "  1) 查看所有线路"
    echo "  2) 查看所有 SS 链接"
    echo "  3) 查看单条线路详情"
    echo "  4) 查看握手状态"
    echo "  5) 修改线路/链接名称"
    echo "  6) 登记已有 SS 线路"
    echo "  0) 退出"
    read -r -p "请选择 [0-6]：" choice
    echo
    case "$choice" in
      1) list_nodes ;;
      2) list_links ;;
      3)
        read -r -p "输入节点 ID：" node_id
        show_node "$(node_file "$node_id")"
        ;;
      4) show_status ;;
      5)
        read -r -p "输入节点 ID：" node_id
        read -r -p "输入新的线路名称：" new_name
        rename_node "$(node_file "$node_id")" "$new_name"
        ;;
      6) register_node ;;
      0) return ;;
      *) echo "选择无效。" ;;
    esac
    echo
  done
}

command_name="${1:-menu}"
case "$command_name" in
  list) list_nodes ;;
  links) list_links ;;
  show) [[ -n "${2:-}" ]] || die "请提供节点 ID"; show_node "$(node_file "$2")" ;;
  status) show_status ;;
  rename) [[ -n "${2:-}" && -n "${3:-}" ]] || die "用法：wg-home-manager rename ID 新名称"; rename_node "$(node_file "$2")" "$3" ;;
  register) register_node ;;
  menu) menu ;;
  -h|--help|help) usage ;;
  *) die "未知命令：$command_name" ;;
esac
