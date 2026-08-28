#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${WG_HOME_STATE_DIR:-/etc/wg-home-exit/nodes}"
MANUAL_STATE_DIR="${WG_HOME_MANUAL_STATE_DIR:-/etc/wg-home-exit/manual}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

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

manager_header() {
  local title="$1" file id count=0
  local -a files manual_files
  shopt -s nullglob
  files=("$STATE_DIR"/*.conf)
  manual_files=("$MANUAL_STATE_DIR"/*.conf)
  count="${#files[@]}"
  for file in "${manual_files[@]}"; do
    id="$(field "$file" NODE_ID)"
    [[ -f "$STATE_DIR/$id.conf" ]] || ((count++)) || true
  done
  echo "============================================================"
  echo " VolWG 线路管理 · $title"
  echo " 已登记线路：$count 条"
  echo "============================================================"
  echo
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
  volwg manager delete ID        删除 VPS 端指定线路并归档配置
  volwg manager register         登记旧版本或手工创建的 SS 线路
  volwg manager                  打开交互式管理菜单

说明：
  每条线路彼此独立，不会自动配置负载均衡。
  新部署默认同时保存公网和 WireGuard 私网 SS 链接；relay/direct 仅代表推荐入口。
  私网链接只能在已连接对应 WireGuard 隧道的 VPS/Xray 中使用。
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

set_field_value() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
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

public_ss_enabled() {
  local file="$1" value mode
  value="$(field "$file" PUBLIC_SS_ENABLED)"
  if [[ -z "$value" ]]; then
    mode="$(field "$file" MODE)"
    [[ "$mode" == "relay" ]] && value="1" || value="0"
  fi
  printf '%s' "$value"
}

rewrite_ss_endpoint() {
  local link="$1" endpoint="$2" base fragment=""
  [[ -n "$link" && -n "$endpoint" ]] || return 0
  if [[ "$link" == *#* ]]; then
    base="${link%%#*}"
    fragment="#${link#*#}"
  else
    base="$link"
  fi
  if [[ "$base" != ss://*@* ]]; then
    printf '%s' "$link"
    return
  fi
  printf '%s@%s%s' "${base%@*}" "$endpoint" "$fragment"
}

rewrite_ss_name() {
  local link="$1" name="$2"
  [[ -n "$link" ]] || return 0
  printf '%s#%s' "${link%%#*}" "$(urlencode "$name")"
}

private_ss_endpoint() {
  local file="$1" endpoint prefix port
  endpoint="$(field "$file" PRIVATE_SS_ENDPOINT)"
  if [[ -z "$endpoint" ]]; then
    prefix="$(field "$file" WG_PREFIX)"
    port="$(field_fallback "$file" HOME_SS_PORT SS_PORT)"
    [[ -n "$prefix" && -n "$port" ]] && endpoint="$prefix.2:$port"
  fi
  printf '%s' "$endpoint"
}

public_ss_endpoint() {
  local file="$1" endpoint mode
  [[ "$(public_ss_enabled "$file")" == "1" ]] || return 0
  endpoint="$(field "$file" PUBLIC_SS_ENDPOINT)"
  if [[ -z "$endpoint" ]]; then
    mode="$(field "$file" MODE)"
    [[ "$mode" == "relay" ]] && endpoint="$(field "$file" SS_ENDPOINT)"
  fi
  printf '%s' "$endpoint"
}

private_ss_link() {
  local file="$1" link legacy endpoint
  link="$(decode "$(field "$file" PRIVATE_SS_LINK_B64)")"
  if [[ -z "$link" ]]; then
    legacy="$(decode "$(field "$file" SS_LINK_B64)")"
    endpoint="$(private_ss_endpoint "$file")"
    link="$(rewrite_ss_endpoint "$legacy" "$endpoint")"
  fi
  printf '%s' "$link"
}

public_ss_link() {
  local file="$1" link legacy endpoint mode
  [[ "$(public_ss_enabled "$file")" == "1" ]] || return 0
  link="$(decode "$(field "$file" PUBLIC_SS_LINK_B64)")"
  if [[ -z "$link" ]]; then
    mode="$(field "$file" MODE)"
    legacy="$(decode "$(field "$file" SS_LINK_B64)")"
    endpoint="$(public_ss_endpoint "$file")"
    if [[ "$mode" == "relay" && -n "$endpoint" ]]; then
      link="$(rewrite_ss_endpoint "$legacy" "$endpoint")"
    fi
  fi
  printf '%s' "$link"
}

outbound_for() {
  local file="$1" kind="$2" id mode saved legacy endpoint host port
  id="$(field "$file" NODE_ID)"
  mode="$(field "$file" MODE)"
  if [[ "$kind" == "public" ]]; then
    saved="$(decode "$(field "$file" PUBLIC_XRAY_OUTBOUND_B64)")"
    endpoint="$(public_ss_endpoint "$file")"
  else
    saved="$(decode "$(field "$file" PRIVATE_XRAY_OUTBOUND_B64)")"
    endpoint="$(private_ss_endpoint "$file")"
  fi
  if [[ -n "$saved" ]]; then
    printf '%s' "$saved"
    return
  fi
  legacy="$(decode "$(field "$file" XRAY_OUTBOUND_B64)")"
  [[ -n "$legacy" && -n "$endpoint" ]] || return 0
  host="${endpoint%:*}"
  port="${endpoint##*:}"
  printf '%s\n' "$legacy" | sed -E \
    -e "s/\"tag\"[[:space:]]*:[[:space:]]*\"home-$id\"/\"tag\": \"home-$id-$kind\"/" \
    -e "s/\"address\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"address\": \"$host\"/" \
    -e "s/\"port\"[[:space:]]*:[[:space:]]*[0-9]+/\"port\": $port/"
}

node_file() {
  local node_id="$1"
  [[ "$node_id" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "节点 ID 无效"
  [[ -f "$STATE_DIR/$node_id.conf" ]] || die "找不到节点：$node_id"
  printf '%s' "$STATE_DIR/$node_id.conf"
}

removable_file() {
  local node_id="$1"
  [[ "$node_id" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "节点 ID 无效"
  if [[ -f "$STATE_DIR/$node_id.conf" ]]; then
    printf '%s' "$STATE_DIR/$node_id.conf"
  elif [[ -f "$MANUAL_STATE_DIR/$node_id.conf" ]]; then
    printf '%s' "$MANUAL_STATE_DIR/$node_id.conf"
  else
    die "找不到节点：$node_id"
  fi
}

SELECTED_NODE=""
choose_node() {
  local file choice index=1 id name mode
  local -a files
  SELECTED_NODE=""
  shopt -s nullglob
  files=("$STATE_DIR"/*.conf)
  clear_screen
  manager_header "选择线路"
  if ((${#files[@]} == 0)); then
    echo "尚未登记可选择的线路。"
    echo "可返回菜单使用：登记旧版或手工线路。"
    pause_screen
    return 1
  fi
  for file in "${files[@]}"; do
    id="$(field "$file" NODE_ID)"
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    mode="$(field "$file" MODE)"
    printf '  %d) %-24.24s  [%s / %s]\n' "$index" "$name" "$id" "$mode"
    ((index++))
  done
  echo "  0) 返回线路菜单"
  read -r -p "请选择线路 [0-$((${#files[@]}))]：" choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo "选择无效。"; pause_screen; return 1; }
  ((choice == 0)) && return 1
  ((choice >= 1 && choice <= ${#files[@]})) || { echo "选择无效。"; pause_screen; return 1; }
  SELECTED_NODE="$(field "${files[choice-1]}" NODE_ID)"
}

choose_removable_node() {
  local file choice index=1 id name role source
  local -a files selected_files
  SELECTED_NODE=""
  shopt -s nullglob
  files=("$STATE_DIR"/*.conf "$MANUAL_STATE_DIR"/*.conf)
  clear_screen
  manager_header "选择要删除的线路"
  if ((${#files[@]} == 0)); then
    echo "尚未登记可删除的线路。"
    pause_screen
    return 1
  fi
  for file in "${files[@]}"; do
    id="$(field "$file" NODE_ID)"
    if [[ "$file" == "$MANUAL_STATE_DIR"/* && -f "$STATE_DIR/$id.conf" ]]; then
      continue
    fi
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    role="$(field "$file" ROLE)"
    source="完整线路"
    [[ "$file" == "$MANUAL_STATE_DIR"/* ]] && source="仅 WireGuard/${role:-未知端}"
    printf '  %d) %-24.24s  [%s / %s]\n' "$index" "$name" "$id" "$source"
    selected_files+=("$file")
    ((index++))
  done
  echo "  0) 返回线路菜单"
  read -r -p "请选择线路 [0-$((${#selected_files[@]}))]：" choice
  [[ "$choice" =~ ^[0-9]+$ ]] || { echo "选择无效。"; pause_screen; return 1; }
  ((choice == 0)) && return 1
  ((choice >= 1 && choice <= ${#selected_files[@]})) || { echo "选择无效。"; pause_screen; return 1; }
  SELECTED_NODE="$(field "${selected_files[choice-1]}" NODE_ID)"
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
  for file in "$MANUAL_STATE_DIR"/*.conf; do
    id="$(field "$file" NODE_ID)"
    [[ -f "$STATE_DIR/$id.conf" ]] && continue
    found=1
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    iface="$(field "$file" WG_INTERFACE)"
    printf '%-10s %-24.24s %-8s %-9s %-18s %-22s %s\n' "$id" "$name" "manual" "WG-only" "$iface" "未配置 SS" "$(node_status "$iface")"
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
  local file id name mode public_link private_link found=0
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    found=1
    id="$(field "$file" NODE_ID)"
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    mode="$(field "$file" MODE)"
    public_link="$(public_ss_link "$file")"
    private_link="$(private_ss_link "$file")"
    echo "[$id] $name ($mode)"
    if [[ -n "$public_link" ]]; then
      echo "  [公网 SS] $public_link"
    else
      echo "  [公网 SS] 未开放或旧配置未记录"
    fi
    echo "  [私网 SS] $private_link"
    echo "  私网链接仅在已连接该 WireGuard 隧道的 VPS/Xray 中可达。"
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
  local file="$1" id name mode backend iface vps_wg_port home_wg_port prefix vps_ss_port home_ss_port public_endpoint private_endpoint public_link private_link public_outbound private_outbound
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
  public_endpoint="$(public_ss_endpoint "$file")"
  private_endpoint="$(private_ss_endpoint "$file")"
  public_link="$(public_ss_link "$file")"
  private_link="$(private_ss_link "$file")"
  public_outbound="$(outbound_for "$file" public)"
  private_outbound="$(outbound_for "$file" private)"

  echo "线路名称：$name"
  echo "节点 ID：$id"
  echo "模式：$mode"
  echo "家宽服务端：$backend"
  echo "WireGuard：${iface}，${prefix}.1 ↔ ${prefix}.2"
  echo "  VPS 公网 UDP：${vps_wg_port:-未记录}"
  echo "  家宽机本地 UDP：${home_wg_port:-未记录}"
  echo "SS 端口：VPS ${vps_ss_port:-未记录}，家宽机 ${home_ss_port:-未记录}"
  echo "状态：$(node_status "$iface")"
  if [[ -n "$public_link" ]]; then
    echo "公网 SS 地址：${public_endpoint:-未记录}"
    echo "公网 SS 链接：$public_link"
  else
    echo "公网 SS：未开放或旧配置未记录"
  fi
  echo "私网 SS 地址：${private_endpoint:-未记录}"
  echo "私网 SS 链接：$private_link"
  echo "注意：私网链接仅供已连接该 WireGuard 隧道的 VPS/Xray 使用。"
  echo
  if [[ -n "$public_outbound" ]]; then
    echo "公网 Xray outbound："
    echo "$public_outbound"
    echo
  fi
  echo "私网 Xray outbound："
  if [[ -n "$private_outbound" ]]; then
    echo "$private_outbound"
  else
    echo "该旧版登记节点没有保存 outbound JSON，请使用上面的私网 SS 链接导入。"
  fi
}

export_node() {
  local file="$1" format="${2:-all}" id name mode public_link private_link public_outbound private_outbound
  id="$(field "$file" NODE_ID)"
  name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
  mode="$(field "$file" MODE)"
  public_link="$(public_ss_link "$file")"
  private_link="$(private_ss_link "$file")"
  public_outbound="$(outbound_for "$file" public)"
  private_outbound="$(outbound_for "$file" private)"
  [[ "$format" == "ss" || "$format" == "xray" || "$format" == "routing" || "$format" == "all" ]] || die "导出格式必须是 ss、xray、routing 或 all"

  echo "线路：$name ($id)"
  echo "模式：$mode"
  echo "说明：公网入口适合外部设备；私网入口适合已连接该隧道的线路机 Xray。"
  echo

  if [[ "$format" == "ss" || "$format" == "all" ]]; then
    echo "[公网 SS 导入链接]"
    echo "${public_link:-未开放或旧配置未记录}"
    echo
    echo "[私网 SS 导入链接]"
    echo "$private_link"
    echo
  fi
  if [[ "$format" == "xray" || "$format" == "all" ]]; then
    if [[ -n "$public_outbound" ]]; then
      echo "[公网 Xray outbound JSON：home-$id-public]"
      echo "$public_outbound"
      echo
    fi
    echo "[私网 Xray outbound JSON：home-$id-private]"
    if [[ -n "$private_outbound" ]]; then
      echo "$private_outbound"
    else
      echo "该旧版登记节点没有保存 outbound JSON，请使用上面的私网 SS 链接导入。"
    fi
    echo
  fi
  if [[ "$format" == "routing" || "$format" == "all" ]]; then
    echo "[Xray routing 规则：默认推荐私网入口]"
    cat <<EOF
{
  "type": "field",
  "inboundTag": ["替换为你的入站tag"],
  "outboundTag": "home-$id-private"
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
  for file in "$MANUAL_STATE_DIR"/*.conf; do
    id="$(field "$file" NODE_ID)"
    [[ -f "$STATE_DIR/$id.conf" ]] && continue
    found=1
    name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    iface="$(field "$file" WG_INTERFACE)"
    printf '%-10s %-24.24s %s\n' "$id" "$name" "$(node_status "$iface")"
  done
  if ((found == 0)) && [[ -f /etc/wireguard/wg-home.conf ]]; then
    printf '%-10s %-24.24s %s\n' "legacy" "旧版未登记线路" "$(node_status wg-home)"
  fi
}

rename_node() {
  local file="$1" new_name="$2" old_link new_link public_link private_link
  [[ "$(id -u)" == "0" ]] || die "修改线路名称需要 root，请使用 sudo"
  [[ -n "$new_name" ]] || die "新名称不能为空"
  old_link="$(decode "$(field "$file" SS_LINK_B64)")"
  new_link="$(rewrite_ss_name "$old_link" "$new_name")"
  public_link="$(rewrite_ss_name "$(public_ss_link "$file")" "$new_name-外网")"
  private_link="$(rewrite_ss_name "$(private_ss_link "$file")" "$new_name-内网")"
  set_field_value "$file" DISPLAY_NAME_B64 "$(encode "$new_name")"
  set_field_value "$file" SS_LINK_B64 "$(encode "$new_link")"
  set_field_value "$file" PUBLIC_SS_LINK_B64 "$(encode "$public_link")"
  set_field_value "$file" PRIVATE_SS_LINK_B64 "$(encode "$private_link")"
  chmod 600 "$file"
  echo "已更新线路名称：$new_name"
  [[ -n "$public_link" ]] && echo "公网 SS：$public_link"
  echo "私网 SS：$private_link"
}

delete_node() {
  local file="$1" id name role
  [[ "$(id -u)" == "0" ]] || die "删除线路需要 root，请使用 sudo"
  [[ -x "$SCRIPT_DIR/wg-home-remove.sh" ]] || die "缺少 wg-home-remove.sh，请先运行 volwg update"
  id="$(field "$file" NODE_ID)"
  name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
  role="$(field "$file" ROLE)"
  role="${role:-vps}"
  echo "即将删除本机 $role 端线路：$name ($id)"
  if [[ "$role" == "vps" ]]; then
    echo "删除后该线路及 SS 链接会从管理后台消失。"
  fi
  echo "配置文件将先归档，可恢复。"
  echo
  bash "$SCRIPT_DIR/wg-home-remove.sh" --node "$id" --role "$role"
}

register_node() {
  local node_id name mode backend iface wg_port home_wg_port prefix endpoint endpoint_port vps_ss_port home_ss_port link outbound answer file public_enabled public_endpoint private_endpoint public_link private_link
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

  private_endpoint="$prefix.2:$home_ss_port"
  private_link="$(rewrite_ss_name "$(rewrite_ss_endpoint "$link" "$private_endpoint")" "$name-内网")"
  public_enabled="0"
  public_endpoint=""
  public_link=""
  if [[ "$mode" == "relay" ]]; then
    public_enabled="1"
    public_endpoint="$endpoint"
    public_link="$(rewrite_ss_name "$(rewrite_ss_endpoint "$link" "$public_endpoint")" "$name-外网")"
  fi

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
PUBLIC_SS_ENABLED=$public_enabled
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
PUBLIC_SS_ENDPOINT=$public_endpoint
PRIVATE_SS_ENDPOINT=$private_endpoint
PUBLIC_SS_LINK_B64=$(encode "$public_link")
PRIVATE_SS_LINK_B64=$(encode "$private_link")
PUBLIC_XRAY_OUTBOUND_B64=
PRIVATE_XRAY_OUTBOUND_B64=
EOF
  chmod 600 "$file"
  echo "已登记线路：$name ($node_id)"
  [[ -n "$public_link" ]] && echo "公网 SS：$public_link"
  echo "私网 SS：$private_link"
}

menu() {
  local choice new_name export_choice export_format
  while true; do
    clear_screen
    manager_header "主菜单"
    legacy_notice
    echo "  1) 查看全部公网/私网 SS 链接"
    echo "  2) 查看线路概览与状态"
    echo "  3) 导出 SS / Xray 图形化节点"
    echo "  4) 查看单条线路详细配置"
    echo "  5) 查看 WireGuard 握手状态"
    echo "  6) 修改线路/链接名称"
    echo "  7) 删除线路（停止服务并归档）"
    echo "  8) 登记旧版或手工线路"
    echo "  0) 返回上级菜单    q) 退出"
    read -r -p "请选择 [0-8/q]：" choice
    echo
    case "$choice" in
      1) clear_screen; manager_header "全部 SS 链接"; list_links; pause_screen ;;
      2) clear_screen; manager_header "线路概览"; list_nodes; pause_screen ;;
      3)
        choose_node || continue
        clear_screen
        manager_header "导出节点 · $SELECTED_NODE"
        echo "格式：1) 全部  2) SS 链接  3) Xray outbound  4) routing"
        read -r -p "请选择 [1-4，默认 1]：" export_choice
        case "$export_choice" in
          1|"") export_format="all" ;;
          2) export_format="ss" ;;
          3) export_format="xray" ;;
          4) export_format="routing" ;;
          *) echo "格式选择无效。"; pause_screen; continue ;;
        esac
        clear_screen
        manager_header "节点导出 · $SELECTED_NODE"
        export_node "$(node_file "$SELECTED_NODE")" "$export_format"
        pause_screen
        ;;
      4)
        choose_node || continue
        clear_screen
        manager_header "线路详情 · $SELECTED_NODE"
        show_node "$(node_file "$SELECTED_NODE")"
        pause_screen
        ;;
      5) clear_screen; manager_header "WireGuard 状态"; show_status; pause_screen ;;
      6)
        choose_node || continue
        clear_screen
        manager_header "修改线路名称 · $SELECTED_NODE"
        read -r -p "输入新的线路名称（留空取消）：" new_name
        [[ -n "$new_name" ]] || continue
        rename_node "$(node_file "$SELECTED_NODE")" "$new_name"
        pause_screen
        ;;
      7)
        choose_removable_node || continue
        clear_screen
        manager_header "删除线路 · $SELECTED_NODE"
        delete_node "$(removable_file "$SELECTED_NODE")"
        pause_screen
        ;;
      8) clear_screen; manager_header "登记已有线路"; register_node; pause_screen ;;
      0) return ;;
      q|Q) clear_screen; exit 0 ;;
      *) echo "选择无效。"; pause_screen ;;
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
  delete|remove) [[ -n "${2:-}" ]] || die "用法：volwg manager delete ID"; delete_node "$(removable_file "$2")" ;;
  register) register_node ;;
  menu) menu ;;
  -h|--help|help) usage ;;
  *) die "未知命令：$command_name" ;;
esac
