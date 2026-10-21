#!/usr/bin/env bash
set -Eeuo pipefail

STATE_DIR="${WG_HOME_STATE_DIR:-/etc/wg-home-exit/nodes}"
MANUAL_STATE_DIR="${WG_HOME_MANUAL_STATE_DIR:-/etc/wg-home-exit/manual}"
WG_CONF_DIR="${WG_HOME_WG_DIR:-/etc/wireguard}"
OPENWRT_RELEASE="${VOLWG_OPENWRT_RELEASE:-/etc/openwrt_release}"
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
  files=()
  manual_files=()
  files+=("$STATE_DIR"/*.conf)
  manual_files+=("$MANUAL_STATE_DIR"/*.conf)
  count="${#files[@]}"
  if ((${#manual_files[@]} > 0)); then
    for file in "${manual_files[@]}"; do
      id="$(field "$file" NODE_ID)"
      [[ -f "$STATE_DIR/$id.conf" ]] || ((count++)) || true
    done
  fi
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
  volwg manager show 节点ID      查看单条线路详情（含 WireGuard 运行信息）
  volwg manager mode ID relay|direct
                                 切换推荐入口：relay 公网链接 / direct 私网链接（在 VPS 执行）
  volwg manager wg-port ID [端口]
                                 修改家宽机本地 WireGuard 端口（在家宽机执行）
  volwg manager status           查看 WireGuard 握手状态
  volwg manager diagnose ID      诊断 WG、SS、转发与家宽 SSH
  volwg manager ssh ID           通过 WireGuard 进入家宽机 SSH
  volwg manager node ID [格式]   生成图形化 Xray 可导入节点
  volwg manager rename ID 名称   修改线路名称和 SS 链接备注
  volwg manager delete ID        删除 VPS 端指定线路并归档配置
  volwg manager delete-menu      列出现有线路，按序号或节点 ID 删除
  volwg manager register         登记旧版本或手工创建的 SS 线路
  volwg manager                  打开交互式管理菜单

说明：
  每条线路彼此独立，不会自动配置负载均衡。
  新部署默认同时保存公网和 WireGuard 私网 SS 链接；relay/direct 仅代表推荐入口。
  私网链接只能在已连接对应 WireGuard 隧道的 VPS/Xray 中使用。
  线路专用密钥启用后，ssh 命令会自动读取该节点登记的私钥，不再询问密码。
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

base64_encode_stream() {
  if command -v base64 >/dev/null 2>&1; then
    base64
  elif command -v openssl >/dev/null 2>&1; then
    openssl base64 -A
  else
    return 127
  fi
}

base64_decode_stream() {
  if command -v base64 >/dev/null 2>&1; then
    if printf '' | base64 -d >/dev/null 2>&1; then
      base64 -d
    elif printf '' | base64 --decode >/dev/null 2>&1; then
      base64 --decode
    else
      base64 -D
    fi
  elif command -v openssl >/dev/null 2>&1; then
    openssl base64 -d -A
  else
    return 127
  fi
}

decode() {
  local value="$1"
  [[ -n "$value" ]] || return 0
  printf '%s' "$value" | base64_decode_stream 2>/dev/null || true
}

encode() {
  printf '%s' "$1" | base64_encode_stream | tr -d '\r\n'
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
  files=()
  files+=("$STATE_DIR"/*.conf)
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
  files=()
  selected_files=()
  files+=("$STATE_DIR"/*.conf "$MANUAL_STATE_DIR"/*.conf)
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
  ((${#selected_files[@]} > 0)) || { echo "尚未登记可删除的线路。"; pause_screen; return 1; }
  echo "  0) 返回线路菜单"
  read -r -p "输入序号或节点 ID（0 返回） [0-$((${#selected_files[@]}))]：" choice
  [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]] && return 1
  if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#selected_files[@]})); then
    SELECTED_NODE="$(field "${selected_files[choice-1]}" NODE_ID)"
    return 0
  fi
  for file in "${selected_files[@]}"; do
    id="$(field "$file" NODE_ID)"
    if [[ "$choice" == "$id" ]]; then
      SELECTED_NODE="$id"
      return 0
    fi
  done
  echo "选择无效：请输入列表序号或现有节点 ID。"
  pause_screen
  return 1
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
  local -a files
  shopt -s nullglob
  files=()
  files+=("$STATE_DIR"/*.conf)
  if ((${#files[@]} == 0)) && [[ -f /etc/wireguard/wg-home.conf ]]; then
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
    if [[ "$(field "$file" ROLE)" == home && "$(field "$file" FULL_STACK)" == 1 ]]; then
      backend="$(field "$file" HOME_BACKEND)"
      endpoint="$(field "$file" WG_PREFIX).2:$(field "$file" HOME_SS_PORT)"
      printf '%-10s %-24.24s %-8s %-9s %-18s %-22s %s\n' "$id" "$name" "家宽端" "${backend:-ss-rust}" "$iface" "$endpoint" "$(node_status "$iface")"
      continue
    fi
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
  local file="$1" id name mode backend iface vps_wg_port home_wg_port prefix vps_ss_port home_ss_port remote_ssh ssh_port ssh_auth ssh_identity public_endpoint private_endpoint public_link private_link public_outbound private_outbound
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
  remote_ssh="$(field "$file" REMOTE_SSH_ENABLED)"
  ssh_port="$(field "$file" HOME_SSH_PORT)"
  ssh_auth="$(field "$file" REMOTE_SSH_AUTH)"
  ssh_identity="$(field "$file" HOME_SSH_IDENTITY)"
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
  if [[ "$remote_ssh" == "1" ]]; then
    echo "隧道内 SSH：开启，root@${prefix}.2:${ssh_port:-22}（认证：${ssh_auth:-password}）"
    [[ -z "$ssh_identity" ]] || echo "  VPS 线路私钥：$ssh_identity"
    echo "  连接：volwg ssh $id"
  else
    echo "隧道内 SSH：关闭"
  fi
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

tcp_probe() {
  local host="$1" port="$2"
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
  elif command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    return 2
  fi
}

diagnose_node() {
  local file="$1" ssh_port="${2:-}" id name iface prefix home_ip home_ss_port vps_ss_port
  local public_enabled handshake now age failures=0 nft_service ssh_auth ssh_identity
  id="$(field "$file" NODE_ID)"
  name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
  iface="$(field "$file" WG_INTERFACE)"
  prefix="$(field "$file" WG_PREFIX)"
  home_ss_port="$(field_fallback "$file" HOME_SS_PORT SS_PORT)"
  vps_ss_port="$(field_fallback "$file" VPS_SS_PORT SS_PORT)"
  public_enabled="$(public_ss_enabled "$file")"
  ssh_port="${ssh_port:-$(field "$file" HOME_SSH_PORT)}"
  ssh_port="${ssh_port:-22}"
  ssh_auth="$(field "$file" REMOTE_SSH_AUTH)"
  ssh_identity="$(field "$file" HOME_SSH_IDENTITY)"
  [[ "$prefix" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "线路缺少有效 WireGuard 网段"
  [[ "$home_ss_port" =~ ^[0-9]+$ ]] || die "线路缺少有效家宽 SS 端口"
  if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || ((ssh_port < 1 || ssh_port > 65535)); then
    die "家宽 SSH 端口无效"
  fi
  home_ip="$prefix.2"
  nft_service="wgh-nft-$id.service"

  echo "线路：$name ($id)"
  echo "目标：$home_ip"
  echo
  if ip link show "$iface" >/dev/null 2>&1; then
    echo "[通过] WireGuard 接口：$iface"
  else
    echo "[失败] WireGuard 接口不存在：$iface"
    ((failures++)) || true
  fi
  handshake="$(wg show "$iface" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
  if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" != "0" ]]; then
    now="$(date +%s)"
    age=$((now - handshake))
    if ((age <= 180)); then
      echo "[通过] WireGuard 握手：${age} 秒前"
    else
      echo "[失败] WireGuard 握手已过期：${age} 秒前"
      ((failures++)) || true
    fi
  else
    echo "[失败] WireGuard 尚未握手"
    ((failures++)) || true
  fi
  if ping -c 1 -W 2 "$home_ip" >/dev/null 2>&1; then
    echo "[通过] 隧道 Ping：$home_ip"
  else
    echo "[失败] 隧道 Ping：$home_ip"
    ((failures++)) || true
  fi
  if tcp_probe "$home_ip" "$home_ss_port"; then
    echo "[通过] 家宽 SS TCP：$home_ip:$home_ss_port"
  else
    echo "[失败] 家宽 SS TCP：$home_ip:$home_ss_port（检查 ss-rust/Xray 服务）"
    ((failures++)) || true
  fi
  if [[ "$public_enabled" == "1" ]]; then
    if command -v systemctl >/dev/null 2>&1 \
      && systemctl is-active --quiet "$nft_service" \
      && nft list table ip "$iface" 2>/dev/null | grep -q "dport $vps_ss_port"; then
      echo "[通过] VPS 公网转发：$vps_ss_port/TCP+UDP"
    else
      echo "[失败] VPS 公网转发规则或服务异常：$vps_ss_port"
      ((failures++)) || true
    fi
  else
    echo "[提示] 本线路未开启公网 SS 转发"
  fi
  if tcp_probe "$home_ip" "$ssh_port"; then
    echo "[通过] 家宽 SSH：$home_ip:$ssh_port"
    echo "       连接命令：ssh -p $ssh_port root@$home_ip"
  else
    echo "[提示] 家宽 SSH 未开放：$home_ip:$ssh_port"
    echo "       若安装时开启了隧道内 SSH，请确认填写的是家宽实际 SSH 端口。"
  fi
  if [[ "$ssh_auth" == "key" ]]; then
    if [[ -n "$ssh_identity" && -s "$ssh_identity" ]]; then
      echo "[通过] 线路 SSH 私钥：$ssh_identity"
    else
      echo "[失败] 已登记密钥认证，但 VPS 私钥不存在：${ssh_identity:-未记录}"
      ((failures++)) || true
    fi
  fi
  echo
  if ((failures == 0)); then
    echo "诊断结果：核心链路正常。"
  else
    echo "诊断结果：发现 $failures 项核心异常。"
    return 1
  fi
}

interactive_diagnose() {
  local file ssh_port saved_port
  choose_node || return 0
  file="$(node_file "$SELECTED_NODE")"
  saved_port="$(field "$file" HOME_SSH_PORT)"
  read -r -p "家宽 SSH 端口 [${saved_port:-22}]：" ssh_port
  clear_screen
  manager_header "线路诊断 · $SELECTED_NODE"
  diagnose_node "$file" "${ssh_port:-${saved_port:-22}}" || true
}

ssh_to_home() {
  local file="$1" ssh_port="${2:-}" id prefix home_ip enabled ssh_auth ssh_identity
  local -a ssh_args
  id="$(field "$file" NODE_ID)"
  prefix="$(field "$file" WG_PREFIX)"
  enabled="$(field "$file" REMOTE_SSH_ENABLED)"
  ssh_auth="$(field "$file" REMOTE_SSH_AUTH)"
  ssh_identity="$(field "$file" HOME_SSH_IDENTITY)"
  ssh_port="${ssh_port:-$(field "$file" HOME_SSH_PORT)}"
  ssh_port="${ssh_port:-22}"
  home_ip="$prefix.2"
  [[ "$enabled" == "1" ]] || die "该线路未登记开启隧道内 SSH；可先运行 volwg diagnose $id $ssh_port 检查"
  ssh_args=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -p "$ssh_port")
  if [[ "$ssh_auth" == "key" ]]; then
    [[ -n "$ssh_identity" && -s "$ssh_identity" ]] || die "线路 SSH 私钥不存在：${ssh_identity:-未记录}"
    ssh_args+=(-i "$ssh_identity" -o IdentitiesOnly=yes)
  fi
  echo "正在通过 WireGuard 进入 $id：root@$home_ip:$ssh_port"
  if [[ "$ssh_auth" == "key" ]]; then
    echo "认证：线路专用密钥（私钥：$ssh_identity）"
  else
    echo "认证：家宽机密码或系统 SSH 配置"
  fi
  echo "退出家宽 SSH 后会返回 SG/VPS 的 VolWG 菜单。"
  ssh "${ssh_args[@]}" "root@$home_ip"
}

interactive_ssh() {
  local file ssh_port saved_port
  choose_node || return 0
  file="$(node_file "$SELECTED_NODE")"
  saved_port="$(field "$file" HOME_SSH_PORT)"
  read -r -p "家宽 SSH 端口 [${saved_port:-22}]：" ssh_port
  ssh_to_home "$file" "${ssh_port:-${saved_port:-22}}"
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
  local file="$1" id name role confirmation
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
  read -r -p "输入 yes 确认删除，其他内容取消：" confirmation
  if [[ "$confirmation" != "yes" ]]; then
    echo "已取消删除。"
    return 0
  fi
  bash "$SCRIPT_DIR/wg-home-remove.sh" --node "$id" --role "$role" --yes
}

interactive_delete() {
  choose_removable_node || return 0
  clear_screen
  manager_header "删除线路 · $SELECTED_NODE"
  delete_node "$(removable_file "$SELECTED_NODE")"
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

is_openwrt() {
  command -v uci >/dev/null 2>&1 && { [[ -f "$OPENWRT_RELEASE" ]] || command -v opkg >/dev/null 2>&1; }
}

valid_node_id() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]]
}

local_wg_interfaces() {
  # 远程部署的家宽端没有本机线路记录，只能从接口、UCI 和 wg-quick 配置发现。
  local conf
  {
    wg show interfaces 2>/dev/null | tr ' ' '\n'
    if command -v uci >/dev/null 2>&1; then
      uci -q show network 2>/dev/null | sed -n 's/^network\.\(wgh_[a-z0-9_]*\)=interface$/\1/p'
    fi
    for conf in "$WG_CONF_DIR"/wgh_*.conf; do
      [[ -e "$conf" ]] && basename "$conf" .conf
    done
  } | grep '^wgh_' | sort -u || true
}

collect_local_nodes() {
  # 输出“节点ID|记录文件”；记录优先 nodes/，其次 manual/，最后是没有记录的 wgh_* 接口。
  local file id iface seen=" "
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf "$MANUAL_STATE_DIR"/*.conf; do
    id="$(field "$file" NODE_ID)"
    valid_node_id "$id" && [[ "$seen" != *" $id "* ]] || continue
    seen+="$id "
    printf '%s|%s\n' "$id" "$file"
  done
  while IFS= read -r iface; do
    id="${iface#wgh_}"
    valid_node_id "$id" && [[ "$seen" != *" $id "* ]] || continue
    seen+="$id "
    printf '%s|\n' "$id"
  done < <(local_wg_interfaces)
}

node_kind_label() {
  local file="$1" role full
  if [[ -z "$file" ]]; then
    printf '未登记接口'
  elif [[ "$file" == "$STATE_DIR"/* ]]; then
    printf 'VPS 完整线路'
  else
    role="$(field "$file" ROLE)"
    full="$(field "$file" FULL_STACK)"
    if [[ "$role" == home && "$full" == 1 ]]; then
      printf '家宽端'
    elif [[ "$role" == home ]]; then
      printf '仅 WireGuard/家宽端'
    else
      printf '仅 WireGuard/%s' "${role:-未知端}"
    fi
  fi
}

choose_any_node() {
  # 列出本机全部线路（含家宽端与未登记接口），支持序号或节点 ID。
  local title="$1" entry id file name choice index=1
  local -a entries
  SELECTED_NODE="" SELECTED_FILE=""
  mapfile -t entries < <(collect_local_nodes)
  clear_screen
  manager_header "$title"
  if ((${#entries[@]} == 0)); then
    echo "本机没有 VolWG 线路。"
    pause_screen
    return 1
  fi
  for entry in "${entries[@]}"; do
    id="${entry%%|*}" file="${entry#*|}"
    name="$id"
    [[ -z "$file" ]] || name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
    printf '  %d) %-24.24s  [%s / %s]\n' "$index" "${name:-$id}" "$id" "$(node_kind_label "$file")"
    ((index++))
  done
  echo "  0) 返回线路菜单"
  read -r -p "输入序号或节点 ID（0 返回） [0-${#entries[@]}]：" choice || return 1
  [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" || -z "$choice" ]] && return 1
  if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#entries[@]})); then
    entry="${entries[choice-1]}"
  else
    entry=""
    for file in "${entries[@]}"; do
      [[ "${file%%|*}" == "$choice" ]] && entry="$file"
    done
  fi
  [[ -n "$entry" ]] || { echo "选择无效：请输入列表序号或现有节点 ID。"; pause_screen; return 1; }
  SELECTED_NODE="${entry%%|*}" SELECTED_FILE="${entry#*|}"
}

local_node_file() {
  # 打印节点记录路径；没有记录但存在接口时返回空，找不到时报错。
  local id="$1" entry
  valid_node_id "$id" || die "节点 ID 无效"
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == "$id" ]] || continue
    printf '%s' "${entry#*|}"
    return 0
  done < <(collect_local_nodes)
  die "找不到节点：$id"
}

human_bytes() {
  awk -v bytes="$1" 'BEGIN {
    split("B KiB MiB GiB TiB", unit, " "); i = 1
    while (bytes >= 1024 && i < 5) { bytes /= 1024; i++ }
    if (i == 1) printf "%d %s", bytes, unit[i]; else printf "%.1f %s", bytes, unit[i]
  }'
}

handshake_text() {
  local stamp="$1" age
  [[ "$stamp" =~ ^[0-9]+$ && "$stamp" != 0 ]] || { printf '尚未握手'; return; }
  age=$(($(date +%s) - stamp))
  ((age >= 0)) || age=0
  if ((age < 120)); then
    printf '%s 秒前' "$age"
  elif ((age < 7200)); then
    printf '%s 分钟前' "$((age / 60))"
  else
    printf '%s 小时前' "$((age / 3600))"
  fi
}

show_wg_runtime() {
  # 只读取 wg 运行状态；dump 第一行第一列是本机私钥，绝不输出。
  local iface="$1" first=1 col1 col2 col3 col4 col5 col6 col7 col8 configured
  echo "WireGuard 运行信息（$iface）："
  if ! command -v wg >/dev/null 2>&1 || ! wg show "$iface" >/dev/null 2>&1; then
    echo "  接口未运行"
    configured="$(configured_listen_port "$iface")"
    [[ -z "$configured" ]] || echo "  配置的本机监听 UDP：$configured"
    return 0
  fi
  while IFS=$'\t' read -r col1 col2 col3 col4 col5 col6 col7 col8; do
    if ((first)); then
      first=0
      echo "  本机公钥：$col2"
      echo "  本机监听 UDP：$col3"
      continue
    fi
    echo "  对端公钥：$col1"
    if [[ "$col3" == "(none)" ]]; then
      echo "  对端 endpoint：未知（等待对端主动连接）"
    else
      echo "  对端 endpoint：$col3"
    fi
    echo "  AllowedIPs：$col4"
    echo "  最近握手：$(handshake_text "$col5")"
    echo "  流量：接收 $(human_bytes "$col6")，发送 $(human_bytes "$col7")"
    if [[ "$col8" == off || -z "$col8" ]]; then
      echo "  保活：关闭"
    else
      echo "  保活：$col8 秒"
    fi
  done < <(wg show "$iface" dump 2>/dev/null)
  ((first == 0)) || echo "  无法读取运行状态（需要 root）"
}

configured_listen_port() {
  local iface="$1"
  if is_openwrt; then
    uci -q get "network.$iface.listen_port" 2>/dev/null || true
  elif [[ -f "$WG_CONF_DIR/$iface.conf" ]]; then
    sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$WG_CONF_DIR/$iface.conf" | head -n 1
  fi
}

show_manual_node() {
  local file="$1" id name role iface prefix full backend vps_endpoint vps_wg_port home_wg_port vps_ss_port home_ss_port public_ss remote_ssh ssh_port ssh_auth
  id="$(field "$file" NODE_ID)"
  name="$(decode "$(field "$file" DISPLAY_NAME_B64)")"
  role="$(field "$file" ROLE)"
  iface="$(field "$file" WG_INTERFACE)"; iface="${iface:-wgh_$id}"
  prefix="$(field "$file" WG_PREFIX)"
  full="$(field "$file" FULL_STACK)"
  backend="$(field "$file" HOME_BACKEND)"
  vps_endpoint="$(field "$file" VPS_ENDPOINT)"
  vps_wg_port="$(field "$file" VPS_WG_PORT)"
  home_wg_port="$(configured_listen_port "$iface")"
  home_wg_port="${home_wg_port:-$(field "$file" HOME_WG_PORT)}"
  vps_ss_port="$(field "$file" VPS_SS_PORT)"
  home_ss_port="$(field "$file" HOME_SS_PORT)"
  public_ss="$(field "$file" PUBLIC_SS_ENABLED)"
  remote_ssh="$(field "$file" REMOTE_SSH_ENABLED)"
  ssh_port="$(field "$file" HOME_SSH_PORT)"
  ssh_auth="$(field "$file" REMOTE_SSH_AUTH)"

  echo "线路名称：${name:-$id}"
  echo "节点 ID：$id"
  if [[ "$role" == home ]]; then
    echo "本机角色：家宽端"
  else
    echo "本机角色：${role:-未知}"
  fi
  if [[ "$full" == 1 ]]; then
    echo "部署类型：完整部署（WireGuard + SS2022）"
  else
    echo "部署类型：仅 WireGuard"
  fi
  echo "WireGuard：${iface}，${prefix:-?}.1（VPS）↔ ${prefix:-?}.2（家宽）"
  echo "  VPS endpoint：${vps_endpoint:-未记录}:${vps_wg_port:-未记录}/UDP"
  echo "  家宽机本地 UDP：${home_wg_port:-未记录}"
  if [[ "$full" == 1 ]]; then
    echo "家宽服务端：${backend:-ss-rust}，监听 ${prefix:-?}.2:${home_ss_port:-未记录}（TCP+UDP，仅隧道内可访问）"
    if [[ "$public_ss" == 1 ]]; then
      echo "VPS 公网 SS：${vps_endpoint:-未记录}:${vps_ss_port:-未记录}"
    else
      echo "VPS 公网 SS：未开放（仅私网）"
    fi
    if [[ "$remote_ssh" == 1 ]]; then
      echo "隧道内 SSH：开启，端口 ${ssh_port:-22}（认证：${ssh_auth:-password}）"
    else
      echo "隧道内 SSH：关闭"
    fi
    [[ "$role" != home ]] || echo "SS 链接保存在 VPS：在 VPS 执行 volwg manager links 查看。"
  fi
  echo "状态：$(node_status "$iface")"
}

show_unregistered_node() {
  local id="$1" iface="wgh_$1" endpoint=""
  echo "节点 ID：$id"
  echo "本机记录：未登记（通常是远程部署的家宽端）"
  echo "WireGuard 接口：$iface"
  if is_openwrt; then
    endpoint="$(uci -q get "network.${iface}_vps.endpoint_host" 2>/dev/null || true)"
    [[ -z "$endpoint" ]] || endpoint="$endpoint:$(uci -q get "network.${iface}_vps.endpoint_port" 2>/dev/null || true)"
  elif [[ -f "$WG_CONF_DIR/$iface.conf" ]]; then
    endpoint="$(sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$WG_CONF_DIR/$iface.conf" | head -n 1)"
  fi
  [[ -z "$endpoint" ]] || echo "  配置的 VPS endpoint：$endpoint"
  echo "状态：$(node_status "$iface")"
}

show_line_details() {
  local id="$1" file="$2" iface
  if [[ -n "$file" && "$file" == "$STATE_DIR"/* ]]; then
    show_node "$file"
    iface="$(field "$file" WG_INTERFACE)"
  elif [[ -n "$file" ]]; then
    show_manual_node "$file"
    iface="$(field "$file" WG_INTERFACE)"
  else
    show_unregistered_node "$id"
  fi
  echo
  show_wg_runtime "${iface:-wgh_$id}"
}

home_port_in_use() {
  # 家宽本机端口是否被占用：其他 WG 接口、系统 UDP 监听、其他线路记录与 UCI 配置。
  local port="$1" iface="$2" node="$3" other listen_port hex table file state_node value line
  while IFS= read -r other; do
    [[ -n "$other" && "$other" != "$iface" ]] || continue
    listen_port="$(wg show "$other" listen-port 2>/dev/null || true)"
    [[ "$listen_port" == "$port" ]] && return 0
  done < <(wg show interfaces 2>/dev/null | tr ' ' '\n')
  printf -v hex '%04X' "$port"
  for table in /proc/net/udp /proc/net/udp6; do
    [[ -r "$table" ]] || continue
    grep -Eqi "^[[:space:]]*[0-9]+:[[:space:]][0-9A-F]+:${hex}[[:space:]]" "$table" && return 0
  done
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf "$MANUAL_STATE_DIR"/*.conf; do
    state_node="$(field "$file" NODE_ID)"
    [[ "$state_node" != "$node" ]] || continue
    for value in "$(field "$file" HOME_WG_PORT)" "$(field "$file" HOME_SS_PORT)"; do
      [[ "$value" == "$port" ]] && return 0
    done
  done
  if command -v uci >/dev/null 2>&1; then
    while IFS= read -r line; do
      [[ "$line" == "network.$iface.listen_port="* ]] && continue
      [[ "$line" == *".listen_port='$port'" || "$line" == *".listen_port=$port" ]] && return 0
    done < <(uci -q show network 2>/dev/null | grep '\.listen_port=' || true)
  fi
  return 1
}

next_free_home_port() {
  local port="$1" iface="$2" node="$3"
  while home_port_in_use "$port" "$iface" "$node"; do
    ((port++))
    ((port <= 65535)) || die "没有找到可用端口，请手动指定"
  done
  printf '%s' "$port"
}

set_home_wg_port() {
  # 修改家宽机本地 WireGuard 监听端口。家宽主动连接 VPS，VPS 会自动学习新的源端口，无需修改。
  local id="$1" port="${2:-}" interactive=0 iface conf file="" kind current suggestion answer stamp tmp_file
  valid_node_id "$id" || die "节点 ID 无效"
  [[ "$(id -u)" == 0 ]] || die "修改端口需要 root，请使用 sudo"
  iface="wgh_$id"
  conf="$WG_CONF_DIR/$iface.conf"
  [[ ! -f "$MANUAL_STATE_DIR/$id.conf" ]] || file="$MANUAL_STATE_DIR/$id.conf"
  if [[ -n "$file" && "$(field "$file" ROLE)" == vps ]] || [[ -f "$STATE_DIR/$id.conf" ]]; then
    die "线路 $id 在本机是 VPS 端；家宽 WireGuard 端口需要在家宽机上修改"
  fi
  if is_openwrt; then
    [[ "$(uci -q get "network.$iface.proto" 2>/dev/null || true)" == wireguard ]] || die "本机没有家宽线路接口 $iface"
    kind=openwrt
  elif [[ -f "$conf" ]]; then
    grep -Eq '^[[:space:]]*Endpoint[[:space:]]*=' "$conf" || die "$iface 没有 VPS Endpoint，不是家宽端配置"
    kind=linux
  else
    die "本机没有家宽线路 $id"
  fi
  current="$(configured_listen_port "$iface")"
  if [[ -z "$port" ]]; then
    interactive=1
    if [[ "$current" =~ ^[0-9]+$ ]] && ((current < 65535)); then
      suggestion="$(next_free_home_port "$((current + 1))" "$iface" "$id")"
    else
      suggestion="$(next_free_home_port 51830 "$iface" "$id")"
    fi
    echo "线路 $id 当前家宽 WireGuard 本地端口：${current:-未设置（随机）}"
    while true; do
      read -r -p "新的本地 UDP 端口（直接 Enter 采用可用端口） [$suggestion]：" answer || die "输入已结束，未修改"
      port="${answer:-$suggestion}"
      if ! [[ "$port" =~ ^[0-9]+$ ]] || ((10#$port < 1 || 10#$port > 65535)); then
        echo "端口必须是 1-65535 的数字。" >&2
        continue
      fi
      port=$((10#$port))
      if [[ "$port" != "$current" ]] && home_port_in_use "$port" "$iface" "$id"; then
        echo "UDP $port 已被占用，请换一个；建议 ${suggestion}。" >&2
        continue
      fi
      break
    done
  else
    [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || die "端口必须是 1-65535 的数字"
    port=$((10#$port))
    if [[ "$port" != "$current" ]] && home_port_in_use "$port" "$iface" "$id"; then
      die "UDP $port 已被占用；不带端口运行可自动选择可用端口"
    fi
  fi
  if [[ "$port" == "$current" ]]; then
    echo "端口未变化：$port"
    return 0
  fi
  if ((interactive)); then
    read -r -p "确认把线路 $id 的家宽本地端口从 ${current:-随机} 改为 ${port}？输入 yes 确认：" answer || die "输入已结束，未修改"
    [[ "$answer" == yes ]] || { echo "已取消，未修改。"; return 0; }
  fi

  if [[ "$kind" == openwrt ]]; then
    # 只提交本次修改；network 已有未保存的改动时拒绝，避免一并提交用户的其他配置。
    [[ -z "$(uci changes network 2>/dev/null || true)" ]] || \
      die "network 配置有未保存的修改（例如 LuCI 中未应用的更改）。请先保存或还原后再修改端口"
    uci set "network.$iface.listen_port=$port"
    uci commit network
  else
    stamp="$(date +%Y%m%d-%H%M%S)"
    cp -p "$conf" "$conf.before.$stamp"
    tmp_file="$(mktemp "$conf.volwg.XXXXXX")"
    if grep -Eq '^[[:space:]]*ListenPort[[:space:]]*=' "$conf"; then
      sed "s/^[[:space:]]*ListenPort[[:space:]]*=.*/ListenPort = $port/" "$conf" >"$tmp_file"
    else
      awk -v port="$port" '{print} /^\[Interface\]/ && !done {print "ListenPort = " port; done=1}' "$conf" >"$tmp_file"
    fi
    cat "$tmp_file" >"$conf"
    rm -f "$tmp_file"
  fi
  if [[ -n "$file" ]]; then
    tmp_file="$(mktemp "$file.volwg.XXXXXX")"
    if grep -q '^HOME_WG_PORT=' "$file"; then
      sed "s/^HOME_WG_PORT=.*/HOME_WG_PORT=$port/" "$file" >"$tmp_file"
    else
      { cat "$file"; printf 'HOME_WG_PORT=%s\n' "$port"; } >"$tmp_file"
    fi
    cat "$tmp_file" >"$file"
    rm -f "$tmp_file"
  fi

  # 运行中的接口直接切换监听端口，不重启隧道；未运行时按新配置启动本线路。
  if command -v wg >/dev/null 2>&1 && wg show "$iface" >/dev/null 2>&1; then
    wg set "$iface" listen-port "$port" || die "已保存新端口，但运行中的接口切换失败；可执行 ifup $iface 或重启该线路"
    echo "已切换线路 $id 的家宽本地端口为 UDP ${port}，隧道未重启。"
  elif [[ "$kind" == openwrt ]]; then
    ifup "$iface" >/dev/null 2>&1 || true
    echo "已保存端口 UDP ${port}，并重新启动接口 ${iface}。"
  else
    systemctl restart "wg-quick@$iface.service" || die "已保存端口，但 wg-quick@$iface 启动失败，请检查 journalctl -u wg-quick@$iface"
    echo "已保存端口 UDP ${port}，并重新启动 wg-quick@${iface}。"
  fi
  echo "VPS 无需修改：家宽主动连接 VPS，VPS 会自动使用新的来源端口。"
  echo "VPS 线路详情中的「家宽机本地 UDP」是创建时的记录，仅供参考。"
  [[ -n "$file" ]] || echo "提示：本机没有该线路记录（远程部署），已只修改接口配置。"
}

set_node_mode() {
  # 只切换默认推荐的入口（默认链接、默认 Xray outbound）；公网与私网链接、
  # WireGuard、转发规则和 SS 密钥都不变，两套链接继续可用。
  local id="$1" mode="$2" file manual prefix endpoint port link outbound current stamp tmp_file
  valid_node_id "$id" || die "节点 ID 无效"
  [[ "$mode" == relay || "$mode" == direct ]] || die "模式必须是 relay 或 direct"
  file="$STATE_DIR/$id.conf"
  [[ -f "$file" ]] || die "本机没有线路 $id 的 VPS 记录；推荐入口需要在 VPS 上切换"
  [[ -w "$file" ]] || die "没有写入权限，请使用 root 运行"
  current="$(field "$file" MODE)"
  if [[ "$current" == "$mode" ]]; then
    echo "线路 $id 已是 $mode 模式，未修改。"
    return 0
  fi
  if [[ "$mode" == relay ]]; then
    prefix=PUBLIC
    [[ "$(field "$file" PUBLIC_SS_ENABLED)" == 1 ]] || die "线路 $id 未开放公网 SS，不能切换为 relay"
    port="$(field_fallback "$file" VPS_SS_PORT SS_PORT)"
  else
    prefix=PRIVATE
    port="$(field_fallback "$file" HOME_SS_PORT SS_PORT)"
  fi
  endpoint="$(field "$file" "${prefix}_SS_ENDPOINT")"
  link="$(field "$file" "${prefix}_SS_LINK_B64")"
  outbound="$(decode "$(field "$file" "${prefix}_XRAY_OUTBOUND_B64")")"
  [[ -n "$endpoint" && -n "$link" && -n "$outbound" && -n "$port" ]] || \
    die "线路 $id 的记录缺少 ${prefix} 链接信息（旧版记录），请用 volwg manager register 重新登记"
  # 默认 outbound 使用不带 -public/-private 后缀的 tag，与新建线路一致。
  outbound="${outbound/\"home-$id-public\"/\"home-$id\"}"
  outbound="${outbound/\"home-$id-private\"/\"home-$id\"}"
  outbound="$(encode "$outbound")"

  stamp="$(date +%Y%m%d-%H%M%S)"
  cp -p "$file" "$file.before-mode.$stamp"
  tmp_file="$(mktemp "$file.volwg.XXXXXX")"
  awk -v mode="$mode" -v ep="$endpoint" -v port="$port" -v link="$link" -v out="$outbound" -F= '
    $1 == "MODE" {print "MODE=" mode; next}
    $1 == "SS_ENDPOINT" {print "SS_ENDPOINT=" ep; next}
    $1 == "SS_PORT" {print "SS_PORT=" port; next}
    $1 == "SS_LINK_B64" {print "SS_LINK_B64=" link; next}
    $1 == "XRAY_OUTBOUND_B64" {print "XRAY_OUTBOUND_B64=" out; next}
    {print}' "$file" >"$tmp_file"
  chmod 600 "$tmp_file"
  mv -f "$tmp_file" "$file"
  manual="$MANUAL_STATE_DIR/$id.conf"
  if [[ -f "$manual" ]] && grep -q '^MODE=' "$manual"; then
    tmp_file="$(mktemp "$manual.volwg.XXXXXX")"
    sed "s/^MODE=.*/MODE=$mode/" "$manual" >"$tmp_file"
    chmod 600 "$tmp_file"
    mv -f "$tmp_file" "$manual"
  fi
  echo "线路 $id 已切换为 ${mode}，默认入口：$endpoint"
  echo "原记录已备份：$file.before-mode.$stamp"
  echo "公网和私网链接都继续可用；WireGuard、转发和 SS 密钥未改动。"
  echo "查看链接：volwg manager links"
}

interactive_set_mode() {
  local mode_choice current
  choose_node || return 0
  clear_screen
  manager_header "切换推荐入口 · $SELECTED_NODE"
  current="$(field "$STATE_DIR/$SELECTED_NODE.conf" MODE)"
  echo "当前模式：${current:-未记录}"
  echo "  1) relay：推荐公网 SS，手机/电脑/其他 VPS 都能用"
  echo "  2) direct：推荐 WireGuard 私网 SS，只有本 VPS 上的 Xray 能用"
  echo "  0) 返回"
  read -r -p "请选择 [0-2]：" mode_choice || return 0
  case "$mode_choice" in
    1) ( set_node_mode "$SELECTED_NODE" relay ) || true ;;
    2) ( set_node_mode "$SELECTED_NODE" direct ) || true ;;
    *) return 0 ;;
  esac
}

interactive_set_home_port() {
  choose_any_node "修改家宽 WireGuard 端口" || return 0
  clear_screen
  manager_header "修改家宽 WireGuard 端口 · $SELECTED_NODE"
  # 在子 shell 中执行：出错时只结束本次操作，回到菜单。
  ( set_home_wg_port "$SELECTED_NODE" ) || true
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
    echo "  4) 查看单条线路详情（含 WireGuard 运行信息）"
    echo "  5) 诊断线路（WG / SS / 转发 / SSH）"
    echo "  6) 通过 WireGuard 进入家宽机 SSH"
    echo "  7) 查看 WireGuard 握手状态"
    echo "  8) 修改线路/链接名称"
    echo "  9) 删除线路（停止服务并归档）"
    echo " 10) 登记旧版或手工线路"
    echo " 11) 修改家宽 WireGuard 本地端口（在家宽机执行）"
    echo " 12) 切换推荐入口 relay（公网）/ direct（私网）"
    echo "  0) 返回上级菜单    q) 退出"
    read -r -p "请选择 [0-12/q]：" choice
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
        choose_any_node "选择线路" || continue
        clear_screen
        manager_header "线路详情 · $SELECTED_NODE"
        show_line_details "$SELECTED_NODE" "$SELECTED_FILE"
        pause_screen
        ;;
      5) interactive_diagnose; pause_screen ;;
      6) interactive_ssh; pause_screen ;;
      7) clear_screen; manager_header "WireGuard 状态"; show_status; pause_screen ;;
      8)
        choose_node || continue
        clear_screen
        manager_header "修改线路名称 · $SELECTED_NODE"
        read -r -p "输入新的线路名称（留空取消）：" new_name
        [[ -n "$new_name" ]] || continue
        rename_node "$(node_file "$SELECTED_NODE")" "$new_name"
        pause_screen
        ;;
      9) interactive_delete; pause_screen ;;
      10) clear_screen; manager_header "登记已有线路"; register_node; pause_screen ;;
      11) interactive_set_home_port; pause_screen ;;
      12) interactive_set_mode; pause_screen ;;
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
  show) [[ -n "${2:-}" ]] || die "请提供节点 ID"; show_line_details "$2" "$(local_node_file "$2")" ;;
  details-menu)
    if choose_any_node "选择线路"; then
      clear_screen
      manager_header "线路详情 · $SELECTED_NODE"
      show_line_details "$SELECTED_NODE" "$SELECTED_FILE"
    fi
    ;;
  wg-port) [[ -n "${2:-}" ]] || die "用法：volwg manager wg-port ID [端口]"; set_home_wg_port "$2" "${3:-}" ;;
  wg-port-menu) interactive_set_home_port ;;
  mode) [[ -n "${2:-}" && -n "${3:-}" ]] || die "用法：volwg manager mode ID relay|direct"; set_node_mode "$2" "$3" ;;
  mode-menu) interactive_set_mode ;;
  status) show_status ;;
  diagnose) [[ -n "${2:-}" ]] || die "用法：volwg manager diagnose ID [SSH端口]"; diagnose_node "$(node_file "$2")" "${3:-}" ;;
  diagnose-menu) interactive_diagnose ;;
  ssh) [[ -n "${2:-}" ]] || die "用法：volwg manager ssh ID [SSH端口]"; ssh_to_home "$(node_file "$2")" "${3:-}" ;;
  ssh-menu) interactive_ssh ;;
  node|export) [[ -n "${2:-}" ]] || die "用法：volwg manager node ID [ss|xray|routing|all]"; export_node "$(node_file "$2")" "${3:-all}" ;;
  rename) [[ -n "${2:-}" && -n "${3:-}" ]] || die "用法：volwg manager rename ID 新名称"; rename_node "$(node_file "$2")" "$3" ;;
  delete|remove) [[ -n "${2:-}" ]] || die "用法：volwg manager delete ID"; delete_node "$(removable_file "$2")" ;;
  delete-menu|remove-menu) interactive_delete ;;
  register) register_node ;;
  menu) menu ;;
  -h|--help|help) usage ;;
  *) die "未知命令：$command_name" ;;
esac
