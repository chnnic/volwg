#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/nodes" "$TEST_DIR/manual"
full_name="$(printf '%s' '主线路' | base64 | tr -d '\r\n')"
manual_name="$(printf '%s' '备用家宽' | base64 | tr -d '\r\n')"

printf '%s\n' \
  'NODE_ID=line1' \
  "DISPLAY_NAME_B64=$full_name" \
  'MODE=relay' \
  'HOME_BACKEND=ss-rust' \
  'WG_INTERFACE=wgh_line1' \
  'WG_PREFIX=10.88.1' \
  'HOME_SS_PORT=31000' \
  'VPS_SS_PORT=31000' \
  'REMOTE_SSH_ENABLED=1' \
  'HOME_SSH_PORT=2222' \
  'SS_ENDPOINT=198.51.100.10:31000' \
  >"$TEST_DIR/nodes/line1.conf"

printf '%s\n' \
  'NODE_ID=home2' \
  "DISPLAY_NAME_B64=$manual_name" \
  'ROLE=vps' \
  'WG_INTERFACE=wgh_home2' \
  'WG_PREFIX=10.88.2' \
  >"$TEST_DIR/manual/home2.conf"

manager_output="$(WG_HOME_STATE_DIR="$TEST_DIR/nodes" WG_HOME_MANUAL_STATE_DIR="$TEST_DIR/manual" bash "$ROOT_DIR/wg-home-manager.sh" list)"
grep -Fq 'line1' <<<"$manager_output"
grep -Fq '主线路' <<<"$manager_output"
grep -Fq 'home2' <<<"$manager_output"
grep -Fq '备用家宽' <<<"$manager_output"
grep -Fq 'WG-only' <<<"$manager_output"

grep -Fq -- '--node ID' < <(bash "$ROOT_DIR/wg-home-key-wizard.sh" --help)
grep -Fq '自动向后寻找可用端口' < <(bash "$ROOT_DIR/wg-home-key-wizard.sh" --help)
grep -Fq 'volwg remove --node' < <(bash "$ROOT_DIR/wg-home-remove.sh" --help)
grep -Fq 'wg-home-remove.sh' "$ROOT_DIR/install.sh"
grep -Fq 'wg-home-purge.sh' "$ROOT_DIR/install.sh"
grep -Fq 'atomic_install "$TMP_DIR/volwg" "$INSTALL_BIN_DIR/volwg" 755' "$ROOT_DIR/install.sh"
grep -Fq '不处理 wg-id' < <(bash "$ROOT_DIR/wg-home-purge.sh" --help)
grep -Fq 'volwg purge' "$ROOT_DIR/volwg"
grep -Fq '双 SSH 窗口完整部署（推荐）' "$ROOT_DIR/volwg"
grep -Fq '控制端远程全自动部署' "$ROOT_DIR/volwg"
grep -Fq 'volwg pair [参数]' "$ROOT_DIR/volwg"
grep -Fq -- '--full' < <(bash "$ROOT_DIR/wg-home-key-wizard.sh" --help)
grep -Fq '不需要两端互相 SSH' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq 'SS2022 AES-128 密钥' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq 'VPS 一行配对码' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '【必须复制回 VPS】家宽 WireGuard 公钥' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '确认已复制家宽公钥，按 Enter 继续配置本机' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '粘贴家宽机窗口标出的完整公钥' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '【VPS 端尚未完成时】复制下面家宽公钥到 VPS 窗口' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '建议节点 ID' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '请重新输入；线路显示名称稍后仍可使用大写字母和连字符' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '/etc/wg-home-exit/nodes/$candidate.conf' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '在显示网段和端口输入框之前先扫描一次' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq 'WireGuard 网段 ${WG_PREFIX}.0/24 已占用' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '当前系统需要 base64 或 openssl' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '请重新粘贴完整配对码' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq 'openssl base64 -d -A' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq 'openssl base64 -d -A' "$ROOT_DIR/wg-home-manager.sh"
grep -Fq 'VOLWG1.' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '/etc/wireguard/*.conf' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq 'find_working_ssserver' "$ROOT_DIR/wg-home-key-wizard.sh"
if grep -Fq 'unknown-linux-gnu' "$ROOT_DIR/wg-home-key-wizard.sh" "$ROOT_DIR/wg-home-deploy.sh"; then
  exit 1
fi
grep -Fq '不安装 ss-rust' "$ROOT_DIR/volwg"
grep -Fq '当前模式：仅 WireGuard 手动配对' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '组件安装位置' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq -- '--vps-identity PATH' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq -- '--home-identity PATH' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq 'FRP、端口映射、LAN 或 VPN/Tailscale 地址' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq 'VPS SSH 私钥路径' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq '家宽机 SSH 私钥路径' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq '输入序号或节点 ID' "$ROOT_DIR/wg-home-manager.sh"
grep -Fq 'delete-menu|remove-menu' "$ROOT_DIR/wg-home-manager.sh"
grep -Fq '按序号删除本机线路' "$ROOT_DIR/volwg"
grep -Fq 'volwg diagnose ID' "$ROOT_DIR/volwg"
grep -Fq 'volwg ssh ID' "$ROOT_DIR/volwg"
grep -Fq '通过 WireGuard 进入家宽机 SSH' "$ROOT_DIR/wg-home-manager.sh"
grep -Fq -- '--remote-ssh on|off' < <(bash "$ROOT_DIR/wg-home-key-wizard.sh" --help)
grep -Fq 'REMOTE_SSH_ENABLED=$REMOTE_SSH_ENABLED' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '/usr/bin/ssserver /usr/local/bin/ssserver' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '/usr/bin/ssserver /usr/local/bin/ssserver' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq 'BUILTIN_VERSION="1.4.15"' "$ROOT_DIR/volwg"
grep -Fxq '1.4.15' "$ROOT_DIR/VERSION"

menu_output="$(printf '2\n2\n0\n0\n0\n' | "$ROOT_DIR/volwg")"
grep -Fq '此模式只会' <<<"$menu_output"
grep -Fq '不安装 ss-rust' <<<"$menu_output"
grep -Fq '需要完整家宽落地线路' <<<"$menu_output"

deploy_menu_output="$(printf '2\n0\n0\n' | "$ROOT_DIR/volwg")"
pair_line="$(grep -n -m1 '双 SSH 窗口完整部署（推荐）' <<<"$deploy_menu_output" | cut -d: -f1)"
remote_line="$(grep -n -m1 '控制端远程全自动部署' <<<"$deploy_menu_output" | cut -d: -f1)"
[[ -n "$pair_line" && -n "$remote_line" && "$pair_line" -lt "$remote_line" ]]
if grep -Fq '控制端远程全自动部署（推荐）' <<<"$deploy_menu_output"; then
  exit 1
fi

delete_menu_output="$(printf '0\n' | WG_HOME_STATE_DIR="$TEST_DIR/nodes" WG_HOME_MANUAL_STATE_DIR="$TEST_DIR/manual" bash "$ROOT_DIR/wg-home-manager.sh" delete-menu)"
grep -Fq '主线路' <<<"$delete_menu_output"
grep -Fq '[line1 / 完整线路]' <<<"$delete_menu_output"
grep -Fq '备用家宽' <<<"$delete_menu_output"
grep -Fq '[home2 / 仅 WireGuard/vps]' <<<"$delete_menu_output"

pair_functions="$(awk '/^while \(\(\$#\)\); do/{exit} {print}' "$ROOT_DIR/wg-home-key-wizard.sh")"
(
  eval "$pair_functions"
  VOLWG_FORCE_OPENSSL_BASE64="1"
  [[ "$(printf SGVsbG8= | base64_decode_stream)" == "Hello" ]]
  [[ "$(printf Hello | base64_encode_stream)" == "SGVsbG8=" ]]
  VOLWG_FORCE_OPENSSL_BASE64="0"
  NODE_ID=""
  prompt_node_id "home1" <<< $'LINE-ABC\n\n' 2>/dev/null
  [[ "$NODE_ID" == "line_abc" ]]
  port_in_use() {
    [[ "$1" == "51830" || "$1" == "31000" ]]
  }
  ROLE="vps" FULL_STACK="1" REPLACE_NODE="0" PUBLIC_SS_ENABLED="1"
  VPS_WG_PORT="51830" VPS_SS_PORT="31000" WG_IFACE="wgh_test1"
  select_available_local_ports >/dev/null
  [[ "$VPS_WG_PORT" == "51831" && "$VPS_SS_PORT" == "31001" ]]
  wg_prefix_in_use() {
    [[ "$1" == "10.88.0" ]]
  }
  WG_PREFIX="10.88.0"
  select_available_wg_prefix >/dev/null
  [[ "$WG_PREFIX" == "10.88.1" ]]
  NODE_ID="test1"
  DISPLAY_NAME="测试线路"
  WG_PREFIX="10.99.7"
  VPS_ENDPOINT="example.com"
  VPS_WG_PORT="52001"
  HOME_WG_PORT="52002"
  VPS_SS_PORT="32001"
  HOME_SS_PORT="32002"
  HOME_BACKEND="ss-rust"
  MODE="relay"
  PUBLIC_SS_ENABLED="1"
  REMOTE_SSH_ENABLED="1"
  HOME_SSH_PORT="2222"
  SS_PASSWORD="AAAAAAAAAAAAAAAAAAAAAA=="
  local_public_key="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  [[ -n "$local_public_key" ]]
  pair_code="$(make_pair_code)"
  NODE_ID="" DISPLAY_NAME="" WG_PREFIX="" VPS_ENDPOINT=""
  VPS_WG_PORT="" HOME_WG_PORT="" VPS_SS_PORT="" HOME_SS_PORT=""
  HOME_BACKEND="" MODE="" PUBLIC_SS_ENABLED="" REMOTE_SSH_ENABLED="" HOME_SSH_PORT="" SS_PASSWORD="" PAIR_PEER_PUBLIC_KEY=""
  load_pair_code "$pair_code"
  [[ "$PAIR_CODE_LOADED" == "1" ]]
  [[ "$NODE_ID" == "test1" && "$DISPLAY_NAME" == "测试线路" ]]
  [[ "$WG_PREFIX" == "10.99.7" && "$VPS_ENDPOINT" == "example.com" ]]
  [[ "$VPS_WG_PORT" == "52001" && "$HOME_SS_PORT" == "32002" ]]
  [[ "$HOME_WG_PORT" == "52002" && "$VPS_SS_PORT" == "32001" ]]
  [[ "$HOME_BACKEND" == "ss-rust" && "$MODE" == "relay" && "$PUBLIC_SS_ENABLED" == "1" ]]
  [[ "$REMOTE_SSH_ENABLED" == "1" && "$HOME_SSH_PORT" == "2222" ]]
  [[ "$SS_PASSWORD" == "AAAAAAAAAAAAAAAAAAAAAA==" ]]
  [[ "$PAIR_PEER_PUBLIC_KEY" == "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]]
)

echo "VolWG tests: PASS"
