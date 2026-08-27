#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${WG_HOME_STATE_DIR:-/etc/wg-home-exit/nodes}"

die() {
  echo "错误：$*" >&2
  exit 1
}

clear_screen() {
  [[ -t 1 ]] || return 0
  if command -v clear >/dev/null 2>&1; then
    clear
  else
    printf '\033[2J\033[H'
  fi
}

pause_screen() {
  [[ -t 0 ]] || return 0
  echo
  read -r -p "按 Enter 返回线路菜单..." _
}

usage() {
  cat <<'EOF'
用法：
  volwg manager list             查看所有线路
  volwg manager links            查看所有线路的 SS 链接
  volwg manager show 节点ID      查看单条线路详情
  volwg manager status           查看 WireGuard 握手状态
  volwg manager node ID [格式]   生成图形化 Xray 可导入节点
  volwg manager rename ID 名称   修改线路名称和 SS 链接备注
  volwg manager register         登记旧版本或手工创建的 SS 线路
  volwg manager                  打开交互式管理菜单

说明：
  每条线路彼此独立，不会自动配置负载均衡。
  relay 显示公网 SS 链接；direct 显示仅 VPS 本机可达的隧道 SS 链接和 Xray outbound。
  node 格式可选：ss、xray、routing、all（默认 all）。
EOF
}

field() {
  local file="$1" key="$2"
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

field_fallback() {
  local file="$1" primary="$2" legacy="$3" value
  value="$(field "$file" "$primary")"
  [[ -n "$value" ]] || value="$(field "$file" "$legacy")"
  printf '%s' "$value"
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

legacy_notice() {
  local files=("$STATE_DIR"/*.conf)
  if [[ ! -e "${files[0]}" && -f /etc/wireguard/wg-home.conf ]]; then
    echo "检测到旧版单线路配置：/etc/wireguard/wg-home.conf"
    echo "旧版没有在 VPS 保存 SS 密钥/链接，因此无法自动重建链接。"
    echo '请执行“登记已有 SS 线路”，粘贴原 SS 链接后即可在后台查看。'
    echo
  fi
}

list_nodes() {
  local file id name mode backend iface endpoint status found=0
  printf '%-10s %-24s %-8s %-9s %-18s %-22s %s\n' "节点ID" "线路名称" "模式" "服务端" "WG接口" "SS地址" "状态"
  printf '%-10s %-24s %-8s %-9s %-18s %-22s %s\n' "----------" "------------------------" "--------" "---------" "------------------" "----------------------" "----------"
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    found=1
    id="$(field "$file" NODE_ID)"
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    mode="$(field "$file" MODE)"
    backend="$(field "$file" HOME_BACKEND)"
    backend="${backend:-xray}"
    iface="$(field "$file" WG_INTERFACE)"
    endpoint="$(field "$file" SS_ENDPOINT)"
    status="$(node_status "$iface")"
    printf '%-10s %-24.24s %-8s %-9s %-18s %-22s %s\n' "$id" "$name" "$mode" "$backend" "$iface" "$endpoint" "$status"
  done
  if ((found == 0)) && [[ -f /etc/wireguard/wg-home.conf ]]; then
    mode="direct"
    endpoint="未保存"
    if command -v nft >/dev/null 2>&1 && nft list table ip wg_home >/dev/null 2>&1; then
      mode="relay"
      endpoint="$(nft list table ip wg_home 2>/dev/null | sed -n 's/.*dnat to \([^ ]*\).*/\1/p' | head -n 1)"
      endpoint="${endpoint:-未保存}"
    fi
    printf '%-10s %-24.24s %-8s %-9s %-18s %-22s %s\n' "legacy" "旧版未登记线路" "$mode" "xray" "wg-home" "$endpoint" "$(node_status wg-home)"
    found=1
  fi
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
  if ((found == 0)) && [[ -f /etc/wireguard/wg-home.conf ]]; then
    echo "[legacy] 检测到旧版线路，但旧版 VPS 没有保存 SS 密钥/链接。"
    echo "请使用：volwg manager register"
    echo
    found=1
  fi
  ((found == 1)) || echo "尚未登记线路。"
}

show_node() {
  local file="$1" id name mode backend iface vps_wg_port home_wg_port prefix vps_ss_port home_ss_port endpoint link outbound
  id="$(field "$file" NODE_ID)"
  name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
  mode="$(field "$file" MODE)"
  backend="$(field "$file" HOME_BACKEND)"
  backend="${backend:-xray}"
  iface="$(field "$file" WG_INTERFACE)"
  vps_wg_port="$(field_fallback "$file" VPS_WG_PORT WG_PORT)"
  home_wg_port="$(field_fallback "$file" HOME_WG_PORT WG_PORT)"
  prefix="$(field "$file" WG_PREFIX)"
  vps_ss_port="$(field_fallback "$file" VPS_SS_PORT SS_PORT)"
  home_ss_port="$(field_fallback "$file" HOME_SS_PORT SS_PORT)"
  endpoint="$(field "$file" SS_ENDPOINT)"
  link="$(decode "$(field "$file" SS_LINK_B64)")"
  outbound="$(decode "$(field "$file" XRAY_OUTBOUND_B64)")"

  echo "线路名称：$name"
  echo "节点 ID：$id"
  echo "模式：$mode"
  echo "家宽服务端：$backend"
  echo "WireGuard：${iface}，${prefix}.1 ↔ ${prefix}.2"
  echo "  VPS 公网 UDP：${vps_wg_port:-未记录}"
  echo "  家宽机本地 UDP：${home_wg_port:-未记录}"
  echo "SS 端口：VPS ${vps_ss_port:-未记录}，家宽机 ${home_ss_port:-未记录}"
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

export_node() {
  local file="$1" format="${2:-all}" id name mode link outbound
  id="$(field "$file" NODE_ID)"
  name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
  mode="$(field "$file" MODE)"
  link="$(decode "$(field "$file" SS_LINK_B64)")"
  outbound="$(decode "$(field "$file" XRAY_OUTBOUND_B64)")"
  [[ "$format" == "ss" || "$format" == "xray" || "$format" == "routing" || "$format" == "all" ]] || die "导出格式必须是 ss、xray、routing 或 all"

  echo "线路：$name ($id)"
  echo "模式：$mode"
  if [[ "$mode" == "direct" ]]; then
    echo "注意：这是 WireGuard 私网节点，只能导入到已连接该隧道的优化 VPS/Xray。"
  else
    echo "说明：这是公网 relay 节点，可导入支持 ss:// 的图形化客户端或面板。"
  fi
  echo

  if [[ "$format" == "ss" || "$format" == "all" ]]; then
    echo "[SS 导入链接]"
    echo "$link"
    echo
  fi
  if [[ "$format" == "xray" || "$format" == "all" ]]; then
    echo "[Xray outbound JSON]"
    if [[ -n "$outbound" ]]; then
      echo "$outbound"
    else
      echo "该旧版登记节点没有保存 outbound JSON，请使用上面的 SS 链接导入。"
    fi
    echo
  fi
  if [[ "$format" == "routing" || "$format" == "all" ]]; then
    echo "[Xray routing 规则]"
    cat <<EOF
{
  "type": "field",
  "inboundTag": ["替换为你的入站tag"],
  "outboundTag": "home-$id"
}
EOF
  fi
}

show_status() {
  local file id name iface found=0
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    found=1
    id="$(field "$file" NODE_ID)"
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    iface="$(field "$file" WG_INTERFACE)"
    printf '%-10s %-24.24s %s\n' "$id" "$name" "$(node_status "$iface")"
  done
  if ((found == 0)) && [[ -f /etc/wireguard/wg-home.conf ]]; then
    printf '%-10s %-24.24s %s\n' "legacy" "旧版未登记线路" "$(node_status wg-home)"
  fi
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
  local node_id name mode backend iface wg_port home_wg_port prefix endpoint endpoint_port vps_ss_port home_ss_port link outbound answer file
  [[ "$(id -u)" == "0" ]] || die "登记线路需要 root，请使用 sudo"
  read -r -p "节点 ID（1-8 位小写字母/数字/_）：" node_id
  [[ "$node_id" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "节点 ID 无效"
  read -r -p "线路显示名称：" name
  [[ -n "$name" ]] || die "线路名称不能为空"
  read -r -p "模式 relay/direct [relay]：" mode
  mode="${mode:-relay}"
  [[ "$mode" == "relay" || "$mode" == "direct" ]] || die "模式无效"
  read -r -p "家宽服务端 ss-rust/xray [xray]：" backend
  backend="${backend:-xray}"
  [[ "$backend" == "ss-rust" || "$backend" == "xray" ]] || die "家宽服务端无效"
  read -r -p "WireGuard 接口 [wg-home]：" iface
  iface="${iface:-wg-home}"
  [[ "$iface" =~ ^[a-zA-Z0-9_][a-zA-Z0-9_.-]{0,14}$ ]] || die "WireGuard 接口名无效"
  read -r -p "WireGuard UDP 端口 [51830]：" wg_port
  wg_port="${wg_port:-51830}"
  if ! [[ "$wg_port" =~ ^[0-9]+$ ]] || ((wg_port < 1 || wg_port > 65535)); then
    die "WireGuard 端口无效"
  fi
  read -r -p "家宽机 WireGuard 本地 UDP 端口 [$wg_port]：" home_wg_port
  home_wg_port="${home_wg_port:-$wg_port}"
  if ! [[ "$home_wg_port" =~ ^[0-9]+$ ]] || ((home_wg_port < 1 || home_wg_port > 65535)); then
    die "家宽机 WireGuard 端口无效"
  fi
  read -r -p "WireGuard 网段前缀 [10.88.0]：" prefix
  prefix="${prefix:-10.88.0}"
  [[ "$prefix" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "WireGuard 网段前缀无效"
  read -r -p "SS 地址（例如 203.0.113.10:31000）：" endpoint
  [[ -n "$endpoint" ]] || die "SS 地址不能为空"
  endpoint_port="${endpoint##*:}"
  read -r -p "VPS 公网 SS 端口 [$endpoint_port]：" vps_ss_port
  vps_ss_port="${vps_ss_port:-$endpoint_port}"
  read -r -p "家宽机 SS 服务端口 [$endpoint_port]：" home_ss_port
  home_ss_port="${home_ss_port:-$endpoint_port}"
  if ! [[ "$vps_ss_port" =~ ^[0-9]+$ ]] || ((vps_ss_port < 1 || vps_ss_port > 65535)); then
    die "VPS SS 端口无效"
  fi
  if ! [[ "$home_ss_port" =~ ^[0-9]+$ ]] || ((home_ss_port < 1 || home_ss_port > 65535)); then
    die "家宽机 SS 端口无效"
  fi
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
HOME_BACKEND=$backend
WG_INTERFACE=$iface
WG_PORT=$wg_port
VPS_WG_PORT=$wg_port
HOME_WG_PORT=$home_wg_port
WG_PREFIX=$prefix
SS_PORT=$endpoint_port
VPS_SS_PORT=$vps_ss_port
HOME_SS_PORT=$home_ss_port
SS_ENDPOINT=$endpoint
SS_LINK_B64=$(encode "$link")
XRAY_OUTBOUND_B64=$(encode "$outbound")
EOF
  chmod 600 "$file"
  echo "已登记线路：$name ($node_id)"
  echo "$link"
}

menu() {
  local choice node_id new_name export_choice export_format
  while true; do
    clear_screen
    echo "============================================================"
    echo " VolWG 线路管理"
    echo "============================================================"
    legacy_notice
    echo "  1) 查看所有线路"
    echo "  2) 查看所有 SS 链接"
    echo "  3) 查看单条线路详情"
    echo "  4) 查看握手状态"
    echo "  5) 修改线路/链接名称"
    echo "  6) 登记已有 SS 线路"
    echo "  7) 生成/导出图形化 Xray 节点"
    echo "  0) 退出"
    read -r -p "请选择 [0-7]：" choice
    echo
    case "$choice" in
      1) clear_screen; list_nodes; pause_screen ;;
      2) clear_screen; list_links; pause_screen ;;
      3)
        clear_screen
        read -r -p "输入节点 ID：" node_id
        show_node "$(node_file "$node_id")"
        pause_screen
        ;;
      4) clear_screen; show_status; pause_screen ;;
      5)
        clear_screen
        read -r -p "输入节点 ID：" node_id
        read -r -p "输入新的线路名称：" new_name
        rename_node "$(node_file "$node_id")" "$new_name"
        pause_screen
        ;;
      6) clear_screen; register_node; pause_screen ;;
      7)
        clear_screen
        read -r -p "输入节点 ID：" node_id
        echo "格式：1) 全部  2) SS 链接  3) Xray outbound  4) routing"
        read -r -p "请选择 [1-4]：" export_choice
        case "$export_choice" in
          1|"") export_format="all" ;;
          2) export_format="ss" ;;
          3) export_format="xray" ;;
          4) export_format="routing" ;;
          *) echo "格式选择无效。"; pause_screen; continue ;;
        esac
        export_node "$(node_file "$node_id")" "$export_format"
        pause_screen
        ;;
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
  node|export) [[ -n "${2:-}" ]] || die "用法：volwg manager node ID [ss|xray|routing|all]"; export_node "$(node_file "$2")" "${3:-all}" ;;
  rename) [[ -n "${2:-}" && -n "${3:-}" ]] || die "用法：volwg manager rename ID 新名称"; rename_node "$(node_file "$2")" "$3" ;;
  register) register_node ;;
  menu) menu ;;
  -h|--help|help) usage ;;
  *) die "未知命令：$command_name" ;;
esac
