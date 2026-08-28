#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu 公网 VPS + 家宽机一键部署。
# 家宽端支持 OpenWrt/ImmortalWrt、Debian 11/12/13、Ubuntu。
#   relay  - 推荐使用公网 SS 链接，同时也生成 WireGuard 私网链接
#   direct - 推荐使用 WireGuard 私网链接，同时也可生成公网 SS 链接

MODE=""
VPS_TARGET=""
VPS_SSH_PORT="22"
VPS_PUBLIC_HOST=""
OPENWRT_TARGET=""
OPENWRT_SSH_PORT="22"
IDENTITY=""
VPS_IDENTITY=""
HOME_IDENTITY=""
VPS_WG_PORT="51830"
HOME_WG_PORT="51830"
VPS_SS_PORT="31000"
HOME_SS_PORT="31000"
HOME_BACKEND="ss-rust"
SS_RUST_VERSION="v1.25.0"
PUBLIC_SS_ENABLED="1"
WG_PREFIX="10.88.0"
NODE_ID="home1"
DISPLAY_NAME="家宽线路 1"
REPLACE_NODE="0"
ASSUME_YES="0"
GUIDED="0"
AUTO_NODE_ID="0"
AUTO_DISPLAY_NAME="0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法：
  volwg deploy --mode relay|direct \
    --node 节点ID --name "线路显示名称" \
    --vps root@VPS地址 --vps-public-host VPS公网IP或域名 \
    --home root@家宽机地址 [选项]

必需参数：
  --mode relay|direct       选择推荐入口；默认都生成公网和私网 SS 链接
  --vps USER@HOST          可 SSH/root 的 Debian 或 Ubuntu VPS
  --vps-public-host HOST   WireGuard endpoint，也是公网 SS 链接地址
  --home USER@HOST         可 SSH/root 的家宽机
                            支持 OpenWrt/ImmortalWrt、Debian 11/12/13、Ubuntu

选项：
  --node ID                 节点 ID，1-8 位小写字母/数字/_，默认 home1
  --name NAME               SS 链接和管理后台显示名称，默认“家宽线路 1”
  --vps-ssh-port PORT       VPS SSH 端口，默认 22
  --home-ssh-port PORT      家宽机 SSH 端口，默认 22
  --openwrt USER@HOST       --home 的兼容别名
  --openwrt-ssh-port PORT   --home-ssh-port 的兼容别名
  --vps-identity PATH       登录 VPS 的 SSH 私钥；省略则使用 ssh-agent/SSH config
  --home-identity PATH      登录家宽机的 SSH 私钥；省略则使用 ssh-agent/SSH config
  --identity PATH           兼容选项：两端使用同一个 SSH 私钥
  --vps-wg-port PORT        VPS WireGuard 公网 UDP 起始端口，默认 51830
  --home-wg-port PORT       家宽机 WireGuard 本地 UDP 起始端口，默认 51830
  --vps-ss-port PORT        VPS 公网 SS 起始端口，默认 31000
  --home-ss-port PORT       家宽机 SS2022 起始端口，默认 31000
  --public-ss on|off        是否开放公网 SS，默认 on
  --home-backend TYPE       家宽服务端：ss-rust（默认）或 xray
  --wg-port PORT            兼容选项：同时设置两端 WireGuard 端口
  --ss-port PORT            兼容选项：同时设置两端 SS 端口
  --wg-prefix A.B.C         隧道前缀，默认 10.88.0
  --replace                 明确替换同一节点 ID 的已有配置
  --yes                     跳过确认
  --guided                  进入全自动部署问答向导
  -h, --help                显示帮助

示例（公网中转）：
  volwg deploy --mode relay \
    --node line1 --name "家宽线路 A" \
    --vps root@203.0.113.10 --vps-public-host 203.0.113.10 \
    --home root@home-a.example.net --home-ssh-port 1090 \
    --vps-wg-port 51830 --home-wg-port 45000 \
    --vps-ss-port 31000 --home-ss-port 32000 \
    --home-backend ss-rust \
    --identity ~/.ssh/id_ed25519 --yes

示例（优化机直连家宽）：
  volwg deploy --mode direct \
    --node line2 --name "家宽线路 B" \
    --vps root@198.51.100.20 --vps-public-host 198.51.100.20 \
    --home root@home-b.example.net --home-ssh-port 1090 \
    --vps-wg-port 51831 --home-wg-port 45001 \
    --vps-ss-port 31001 --home-ss-port 32001 \
    --home-backend ss-rust \
    --identity ~/.ssh/id_ed25519 --yes

如需在两个 SSH 窗口手动复制/粘贴 WireGuard 公钥，请使用：
  volwg key --help
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

check_remote_wireguard() {
  local label="$1" ssh_function="$2" result
  # 下面的变量必须在远程机器展开。
  # shellcheck disable=SC2016
  if ! result="$($ssh_function 'set -u
test_iface="vwgcap$$"
cleanup_test_iface() {
  ip link del "$test_iface" >/dev/null 2>&1 || true
}
trap cleanup_test_iface EXIT INT TERM
virt="$(systemd-detect-virt 2>/dev/null || true)"
if ! ip link add "$test_iface" type wireguard 2>&1; then
  echo "virtualization=${virt:-none}"
  exit 1
fi
ip link del "$test_iface"
trap - EXIT INT TERM' 2>&1)"; then
    die "$label 无法创建 WireGuard 接口。若它是 LXC，请确认容器拥有 NET_ADMIN，且宿主机内核已启用 WireGuard。原始输出：$result"
  fi
}

prompt_required() {
  local prompt="$1" answer=""
  while [[ -z "$answer" ]]; do
    read -r -p "${prompt}：" answer
  done
  printf '%s' "$answer"
}

prompt_with_default() {
  local prompt="$1" default_value="$2" answer=""
  read -r -p "$prompt [$default_value]：" answer
  printf '%s' "${answer:-$default_value}"
}

confirm_wireguard_only() {
  local role_label="$1" answer
  echo
  echo "------------------------------------------------------------"
  echo "当前选择：仅 WireGuard 手动配对（$role_label）"
  echo "此模式不会安装 ss-rust/Xray，不会生成 SS 链接或公网转发。"
  echo "需要完整线路，请返回选择 [完整部署：WireGuard + SS2022]。"
  echo "------------------------------------------------------------"
  read -r -p "输入 1 继续仅 WireGuard，输入 0 返回 [0]：" answer
  [[ "$answer" == "1" ]]
}

guided_full_deploy() {
  local mode_choice backend_choice public_ss_choice default_public_host node_answer name_answer

  echo
  echo "完整部署的连接要求："
  echo "  - 当前运行 VolWG 的机器必须能够 SSH 到 VPS 和家宽机。"
  echo "  - 家宽机不需要公网 IP，可以填写 FRP、端口映射、LAN 或 VPN/Tailscale 地址。"
  echo "  - 如果当前机器完全无法 SSH 到家宽机，请不要继续此远程部署流程。"
  echo "  - VPS 与家宽机可以分别使用不同的 SSH 私钥。"

  echo
  echo "[1/4] 线路基本信息"
  echo "------------------------------------------------------------"
  read -r -p "节点 ID（留空自动选择未使用 ID） [$NODE_ID]：" node_answer
  if [[ -z "$node_answer" ]]; then
    AUTO_NODE_ID="1"
  else
    NODE_ID="$node_answer"
  fi
  read -r -p "线路显示名称/SS 链接名称（留空自动生成） [$DISPLAY_NAME]：" name_answer
  if [[ -z "$name_answer" ]]; then
    AUTO_DISPLAY_NAME="1"
  else
    DISPLAY_NAME="$name_answer"
  fi
  echo
  echo "部署结构："
  echo "  1) relay：推荐公网 SS 入口（同时生成私网入口）"
  echo "  2) direct：推荐 WireGuard 私网入口（同时生成公网入口）"
  read -r -p "请选择 [1-2，默认 1]：" mode_choice
  case "${mode_choice:-1}" in
    1) MODE="relay" ;;
    2) MODE="direct" ;;
    *) die "部署结构选择无效" ;;
  esac
  echo
  echo "选择安装在家宽机上的 SS2022 服务端："
  echo "  1) ss-rust ssserver（推荐，轻量；只安装在家宽机）"
  echo "  2) Xray Core（兼容模式；只安装在家宽机）"
  echo "  提示：VPS 只安装 WireGuard + nftables，不运行 SS 服务端。"
  read -r -p "请选择 [1-2，默认 1]：" backend_choice
  case "${backend_choice:-1}" in
    1) HOME_BACKEND="ss-rust" ;;
    2) HOME_BACKEND="xray" ;;
    *) die "家宽服务端后端选择无效" ;;
  esac

  echo
  echo "[2/4] SSH 连接信息"
  echo "------------------------------------------------------------"
  VPS_TARGET="$(prompt_required "公网/优化 VPS SSH，例如 root@203.0.113.10")"
  VPS_SSH_PORT="$(prompt_with_default "VPS SSH 端口" "$VPS_SSH_PORT")"
  read -r -p "VPS SSH 私钥路径（留空使用 ssh-agent/SSH config）：" VPS_IDENTITY
  default_public_host="${VPS_TARGET#*@}"
  VPS_PUBLIC_HOST="$(prompt_with_default "VPS 公网 IP 或域名" "$default_public_host")"
  echo
  echo "家宽机位于 NAT/CGNAT 后面时，请填写可达的 FRP、映射端口、LAN 或 VPN 地址。"
  OPENWRT_TARGET="$(prompt_required "家宽机可达 SSH 地址，例如 root@frp.example.com")"
  OPENWRT_SSH_PORT="$(prompt_with_default "家宽机可达 SSH 端口（例如 FRP 映射端口）" "$OPENWRT_SSH_PORT")"
  read -r -p "家宽机 SSH 私钥路径（留空使用 ssh-agent/SSH config）：" HOME_IDENTITY

  echo
  echo "[3/4] WireGuard 网络"
  echo "------------------------------------------------------------"
  WG_PREFIX="$(prompt_with_default "WireGuard 网段前缀" "$WG_PREFIX")"
  VPS_WG_PORT="$(prompt_with_default "VPS WireGuard 公网 UDP 端口" "$VPS_WG_PORT")"
  HOME_WG_PORT="$(prompt_with_default "家宽机 WireGuard 本地 UDP 端口" "$HOME_WG_PORT")"

  echo
  echo "[4/4] Shadowsocks 入口"
  echo "------------------------------------------------------------"
  HOME_SS_PORT="$(prompt_with_default "家宽机 SS2022 TCP/UDP 端口" "$HOME_SS_PORT")"
  echo "  1) 同时生成公网和私网 SS（推荐）"
  echo "  2) 仅生成 WireGuard 私网 SS"
  read -r -p "请选择 [1-2，默认 1]：" public_ss_choice
  case "${public_ss_choice:-1}" in
    1) PUBLIC_SS_ENABLED="1" ;;
    2) PUBLIC_SS_ENABLED="0" ;;
    *) die "SS 入口选择无效" ;;
  esac
  if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
    VPS_SS_PORT="$(prompt_with_default "VPS 公网 SS TCP/UDP 端口" "$VPS_SS_PORT")"
  fi
}

if (($# == 0)); then
  if [[ -f "$SCRIPT_DIR/volwg" ]]; then
    exec bash "$SCRIPT_DIR/volwg"
  fi
  usage
  exit 0
fi

while (($#)); do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --node) NODE_ID="${2:-}"; shift 2 ;;
    --name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --vps) VPS_TARGET="${2:-}"; shift 2 ;;
    --vps-ssh-port) VPS_SSH_PORT="${2:-}"; shift 2 ;;
    --vps-public-host) VPS_PUBLIC_HOST="${2:-}"; shift 2 ;;
    --home|--openwrt) OPENWRT_TARGET="${2:-}"; shift 2 ;;
    --home-ssh-port|--openwrt-ssh-port) OPENWRT_SSH_PORT="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --vps-identity) VPS_IDENTITY="${2:-}"; shift 2 ;;
    --home-identity) HOME_IDENTITY="${2:-}"; shift 2 ;;
    --vps-wg-port) VPS_WG_PORT="${2:-}"; shift 2 ;;
    --home-wg-port) HOME_WG_PORT="${2:-}"; shift 2 ;;
    --vps-ss-port) VPS_SS_PORT="${2:-}"; shift 2 ;;
    --home-ss-port) HOME_SS_PORT="${2:-}"; shift 2 ;;
    --public-ss)
      case "${2:-}" in
        on) PUBLIC_SS_ENABLED="1" ;;
        off) PUBLIC_SS_ENABLED="0" ;;
        *) die "--public-ss 必须是 on 或 off" ;;
      esac
      shift 2
      ;;
    --home-backend) HOME_BACKEND="${2:-}"; shift 2 ;;
    --wg-port) VPS_WG_PORT="${2:-}"; HOME_WG_PORT="${2:-}"; shift 2 ;;
    --ss-port) VPS_SS_PORT="${2:-}"; HOME_SS_PORT="${2:-}"; shift 2 ;;
    --wg-prefix) WG_PREFIX="${2:-}"; shift 2 ;;
    --replace) REPLACE_NODE="1"; shift ;;
    --yes) ASSUME_YES="1"; shift ;;
    --guided) GUIDED="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [[ "$GUIDED" == "1" ]]; then
  guided_full_deploy
fi
if [[ -n "$IDENTITY" ]]; then
  [[ -n "$VPS_IDENTITY" ]] || VPS_IDENTITY="$IDENTITY"
  [[ -n "$HOME_IDENTITY" ]] || HOME_IDENTITY="$IDENTITY"
fi
if [[ "$AUTO_DISPLAY_NAME" == "1" ]]; then
  DISPLAY_NAME="家宽线路 $NODE_ID"
fi

[[ "$MODE" == "relay" || "$MODE" == "direct" ]] || die "--mode 必须是 relay 或 direct"
[[ "$HOME_BACKEND" == "ss-rust" || "$HOME_BACKEND" == "xray" ]] || die "--home-backend 必须是 ss-rust 或 xray"
[[ "$PUBLIC_SS_ENABLED" == "0" || "$PUBLIC_SS_ENABLED" == "1" ]] || die "公网 SS 开关无效"
[[ "$NODE_ID" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "--node 必须是 1-8 位小写字母、数字或下划线"
[[ -n "$DISPLAY_NAME" ]] || die "--name 不能为空"
[[ -n "$VPS_TARGET" ]] || die "缺少 --vps"
[[ -n "$VPS_PUBLIC_HOST" ]] || die "缺少 --vps-public-host"
[[ -n "$OPENWRT_TARGET" ]] || die "缺少 --home"
if ! [[ "$VPS_WG_PORT" =~ ^[0-9]+$ ]] || ((VPS_WG_PORT < 1 || VPS_WG_PORT > 65535)); then
  die "VPS WireGuard 端口无效"
fi
if ! [[ "$HOME_WG_PORT" =~ ^[0-9]+$ ]] || ((HOME_WG_PORT < 1 || HOME_WG_PORT > 65535)); then
  die "家宽机 WireGuard 端口无效"
fi
if ! [[ "$VPS_SS_PORT" =~ ^[0-9]+$ ]] || ((VPS_SS_PORT < 1 || VPS_SS_PORT > 65535)); then
  die "VPS 公网 SS 端口无效"
fi
if ! [[ "$HOME_SS_PORT" =~ ^[0-9]+$ ]] || ((HOME_SS_PORT < 1 || HOME_SS_PORT > 65535)); then
  die "家宽机 SS 端口无效"
fi
if ! [[ "$VPS_SSH_PORT" =~ ^[0-9]+$ ]] || ((VPS_SSH_PORT < 1 || VPS_SSH_PORT > 65535)); then
  die "VPS SSH 端口无效"
fi
if ! [[ "$OPENWRT_SSH_PORT" =~ ^[0-9]+$ ]] || ((OPENWRT_SSH_PORT < 1 || OPENWRT_SSH_PORT > 65535)); then
  die "家宽机 SSH 端口无效"
fi
[[ "$WG_PREFIX" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "--wg-prefix 应为 A.B.C，例如 10.88.0"

WG_IFACE="wgh_$NODE_ID"
XRAY_SERVICE="xray-wgh-$NODE_ID"
SS_RUST_SERVICE="ssrust-wgh-$NODE_ID"
if [[ "$HOME_BACKEND" == "ss-rust" ]]; then
  HOME_SERVICE="$SS_RUST_SERVICE"
else
  HOME_SERVICE="$XRAY_SERVICE"
fi
NFT_SERVICE="wgh-nft-$NODE_ID"

for command_name in ssh scp openssl mktemp sed awk base64; do
  command -v "$command_name" >/dev/null || die "本机缺少命令：$command_name"
done

if [[ -n "$VPS_IDENTITY" ]]; then
  [[ -f "$VPS_IDENTITY" ]] || die "VPS SSH 私钥不存在：$VPS_IDENTITY"
fi
if [[ -n "$HOME_IDENTITY" ]]; then
  [[ -f "$HOME_IDENTITY" ]] || die "家宽机 SSH 私钥不存在：$HOME_IDENTITY"
fi
[[ -f "$SCRIPT_DIR/wg-home-manager.sh" ]] || die "缺少 wg-home-manager.sh；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/wg-home-key-wizard.sh" ]] || die "缺少 wg-home-key-wizard.sh；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/wg-home-remove.sh" ]] || die "缺少 wg-home-remove.sh；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/wg-home-purge.sh" ]] || die "缺少 wg-home-purge.sh；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/volwg" ]] || die "缺少 volwg 快捷入口；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/VERSION" ]] || die "缺少 VERSION；请使用仓库完整版或一键安装命令"

SSH_BASE=(
  -o BatchMode=yes
  -o ConnectTimeout=12
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
)
VPS_SSH_ARGS=("${SSH_BASE[@]}")
HOME_SSH_ARGS=("${SSH_BASE[@]}")
if [[ -n "$VPS_IDENTITY" ]]; then
  VPS_SSH_ARGS+=(-i "$VPS_IDENTITY" -o IdentitiesOnly=yes)
fi
if [[ -n "$HOME_IDENTITY" ]]; then
  HOME_SSH_ARGS+=(-i "$HOME_IDENTITY" -o IdentitiesOnly=yes)
fi

ssh_vps() {
  ssh "${VPS_SSH_ARGS[@]}" -p "$VPS_SSH_PORT" "$VPS_TARGET" "$@"
}

ssh_openwrt() {
  ssh "${HOME_SSH_ARGS[@]}" -p "$OPENWRT_SSH_PORT" "$OPENWRT_TARGET" "$@"
}

find_remote_free_node_id() {
  # shellcheck disable=SC2016
  ssh_vps 'set -eu; number=1; while test "$number" -le 99; do candidate="home$number"; iface="wgh_$candidate"; if test ! -e "/etc/wireguard/$iface.conf" && test ! -e "/etc/wg-home-exit/nodes/$candidate.conf" && ! ip link show "$iface" >/dev/null 2>&1; then printf "%s" "$candidate"; exit 0; fi; number=$((number + 1)); done; exit 1'
}

find_remote_free_port() {
  local ssh_function="$1" start_port="$2" primary_field="$3" legacy_field="$4"
  # 变量必须在远程机器展开；本地只注入已验证的数字、字段名和节点 ID。
  # shellcheck disable=SC2016
  "$ssh_function" "set -eu
port='$start_port'
port_used() {
  candidate=\"\$1\"
  hex=\$(printf '%04X' \"\$candidate\")
  for table in /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6; do
    test -r \"\$table\" || continue
    grep -Eqi \"[[:space:]][0-9A-F]+:\$hex[[:space:]]\" \"\$table\" && return 0
  done
  for file in /etc/wg-home-exit/nodes/*.conf; do
    test -f \"\$file\" || continue
    file_node=\$(sed -n 's/^NODE_ID=//p' \"\$file\" | head -n 1)
    test \"\$file_node\" = '$NODE_ID' && continue
    value=\$(sed -n 's/^$primary_field=//p' \"\$file\" | head -n 1)
    test -n \"\$value\" || value=\$(sed -n 's/^$legacy_field=//p' \"\$file\" | head -n 1)
    test \"\$value\" = \"\$candidate\" && return 0
  done
  return 1
}
while port_used \"\$port\"; do
  port=\$((port + 1))
  test \"\$port\" -le 65535 || exit 2
done
printf '%s' \"\$port\""
}

detect_remote_public_ipv4() {
  # shellcheck disable=SC2016
  ssh_vps 'address=""; if command -v curl >/dev/null 2>&1; then address=$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true); elif command -v wget >/dev/null 2>&1; then address=$(wget -4qO- -T 5 https://api.ipify.org 2>/dev/null || true); fi; case "$address" in *.*.*.*) printf "%s" "$address" ;; *) ip -4 route get 1.1.1.1 2>/dev/null | sed -n "s/.* src \([0-9.]*\).*/\1/p" | head -n 1 ;; esac'
}

scp_vps() {
  scp "${VPS_SSH_ARGS[@]}" -P "$VPS_SSH_PORT" "$1" "$VPS_TARGET:$2"
}

scp_openwrt() {
  scp -O "${HOME_SSH_ARGS[@]}" -P "$OPENWRT_SSH_PORT" "$1" "$OPENWRT_TARGET:$2"
}

echo "正在验证两端 SSH 密钥连接..."
ssh_vps "true" >/dev/null 2>&1 || die "无法使用指定密钥连接 VPS。请检查 VPS 地址、SSH 端口、私钥或 ssh-agent。"
ssh_openwrt "true" >/dev/null 2>&1 || die "当前机器无法通过 SSH 到达家宽机。家宽机不需要公网 IP，但必须提供可达的 FRP、端口映射、LAN 或 VPN 地址，并检查家宽机专用私钥。"

if [[ "$AUTO_NODE_ID" == "1" && "$REPLACE_NODE" != "1" ]]; then
  original_node="$NODE_ID"
  NODE_ID="$(find_remote_free_node_id)"
  if [[ "$AUTO_DISPLAY_NAME" == "1" ]]; then
    DISPLAY_NAME="家宽线路 $NODE_ID"
  fi
  WG_IFACE="wgh_$NODE_ID"
  XRAY_SERVICE="xray-wgh-$NODE_ID"
  SS_RUST_SERVICE="ssrust-wgh-$NODE_ID"
  if [[ "$HOME_BACKEND" == "ss-rust" ]]; then
    HOME_SERVICE="$SS_RUST_SERVICE"
  else
    HOME_SERVICE="$XRAY_SERVICE"
  fi
  NFT_SERVICE="wgh-nft-$NODE_ID"
  [[ "$NODE_ID" == "$original_node" ]] || echo "节点 ID $original_node 已使用或自动避让，改用 $NODE_ID。"
fi

if [[ "$REPLACE_NODE" != "1" ]]; then
  original_port="$VPS_WG_PORT"
  VPS_WG_PORT="$(find_remote_free_port ssh_vps "$VPS_WG_PORT" VPS_WG_PORT WG_PORT)"
  [[ "$VPS_WG_PORT" == "$original_port" ]] || echo "VPS WireGuard UDP $original_port 已占用，自动改用 $VPS_WG_PORT。"

  original_port="$HOME_WG_PORT"
  HOME_WG_PORT="$(find_remote_free_port ssh_openwrt "$HOME_WG_PORT" HOME_WG_PORT WG_PORT)"
  [[ "$HOME_WG_PORT" == "$original_port" ]] || echo "家宽 WireGuard UDP $original_port 已占用，自动改用 $HOME_WG_PORT。"

  original_port="$VPS_SS_PORT"
  VPS_SS_PORT="$(find_remote_free_port ssh_vps "$VPS_SS_PORT" VPS_SS_PORT SS_PORT)"
  [[ "$VPS_SS_PORT" == "$original_port" ]] || echo "VPS SS TCP/UDP $original_port 已占用，自动改用 $VPS_SS_PORT。"

  original_port="$HOME_SS_PORT"
  HOME_SS_PORT="$(find_remote_free_port ssh_openwrt "$HOME_SS_PORT" HOME_SS_PORT SS_PORT)"
  [[ "$HOME_SS_PORT" == "$original_port" ]] || echo "家宽 SS TCP/UDP $original_port 已占用，自动改用 $HOME_SS_PORT。"
fi
vps_detected_ipv4="$(detect_remote_public_ipv4 2>/dev/null || true)"

wait_for_openwrt() {
  local _
  for _ in {1..30}; do
    if ssh_openwrt "true" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  die "家宽机网络重启后 60 秒内未恢复 SSH"
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

base64_value() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

base64url_value() {
  printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\r\n'
}

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

echo "节点 ID：$NODE_ID"
echo "线路名称：$DISPLAY_NAME"
echo "部署模式：$MODE"
echo "公网/优化 VPS：${VPS_TARGET}（SSH ${VPS_SSH_PORT}）"
echo "VPS 公网地址（配置）：$VPS_PUBLIC_HOST"
if [[ -n "$vps_detected_ipv4" ]]; then
  echo "VPS 检测到的 IPv4：$vps_detected_ipv4"
fi
echo "家宽机：${OPENWRT_TARGET}（SSH ${OPENWRT_SSH_PORT}）"
echo "家宽服务端：$HOME_BACKEND"
echo "组件安装位置："
echo "  VPS：WireGuard + nftables 转发（不安装 SS 服务端）"
echo "  家宽机：WireGuard + $HOME_BACKEND SS2022 服务端"
echo "WireGuard：${WG_IFACE}，${WG_PREFIX}.1 ↔ ${WG_PREFIX}.2"
echo "  VPS 公网 UDP：$VPS_WG_PORT"
echo "  家宽机本地 UDP：$HOME_WG_PORT"
echo "家宽 SS2022：$WG_PREFIX.2:$HOME_SS_PORT"
if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
  echo "VPS 公网 SS：$VPS_PUBLIC_HOST:$VPS_SS_PORT/TCP+UDP"
else
  echo "VPS 公网 SS：已关闭"
fi
echo
echo "脚本会自动安装 WireGuard 和所选 SS2022 服务端。"
echo "每个节点使用独立 WireGuard、SS 服务和防火墙配置；不会配置负载均衡。"

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "输入 yes 继续：" answer
  [[ "$answer" == "yes" ]] || die "用户取消"
fi

echo "[1/8] 检查 SSH 与系统"
# shellcheck disable=SC2016
vps_os="$(ssh_vps '. /etc/os-release 2>/dev/null; printf "%s" "${ID:-unknown}"')"
[[ "$vps_os" == "debian" || "$vps_os" == "ubuntu" ]] || die "VPS 仅支持 Debian/Ubuntu，检测到：$vps_os"
# 系统变量必须在远程家宽机展开。
# shellcheck disable=SC2016
home_kind="$(ssh_openwrt 'if command -v uci >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then echo openwrt; elif test -r /etc/os-release && command -v systemctl >/dev/null 2>&1; then . /etc/os-release; case "${ID:-}:${VERSION_ID:-}" in debian:11|debian:12|debian:13|ubuntu:*) echo linux ;; *) echo unsupported ;; esac; else echo unsupported; fi')"
[[ "$home_kind" == "openwrt" || "$home_kind" == "linux" ]] || die "家宽端仅支持 OpenWrt/ImmortalWrt、Debian 11/12/13 或 Ubuntu"
echo "检测到家宽端类型：$home_kind"

if [[ "$REPLACE_NODE" != "1" ]] && ssh_vps "test -e '/etc/wireguard/$WG_IFACE.conf' || test -e '/etc/wg-home-exit/nodes/$NODE_ID.conf'"; then
  die "节点 $NODE_ID 已存在；换一个 --node，或确认覆盖后添加 --replace"
fi

# 同时检查 VolWG 新旧配置，避免相同隧道网段被两个 WireGuard 接口争用。
vps_network_conflict="$(ssh_vps "set -eu; for f in /etc/wireguard/*.conf; do test -f \"\$f\" || continue; test \"\$f\" = '/etc/wireguard/$WG_IFACE.conf' && continue; address=\$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' \"\$f\" | head -n 1); if test \"\$address\" = '$WG_PREFIX.1/24' || test \"\$address\" = '$WG_PREFIX.2/24'; then basename \"\$f\" .conf; fi; done" 2>/dev/null || true)"
[[ -z "$vps_network_conflict" ]] || die "WireGuard 网段 $WG_PREFIX.0/24 已被 VPS 接口 $vps_network_conflict 使用，请更换 --wg-prefix 或先运行 volwg purge"
if [[ "$home_kind" == "openwrt" ]]; then
  home_network_conflict="$(ssh_openwrt "uci show network 2>/dev/null | grep -E \"\\.addresses='?$WG_PREFIX\\.[12]/24'?\" | grep -v '^network\\.$WG_IFACE\\.' | head -n 1" 2>/dev/null || true)"
else
  home_network_conflict="$(ssh_openwrt "set -eu; for f in /etc/wireguard/*.conf; do test -f \"\$f\" || continue; test \"\$f\" = '/etc/wireguard/$WG_IFACE.conf' && continue; address=\$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' \"\$f\" | head -n 1); if test \"\$address\" = '$WG_PREFIX.1/24' || test \"\$address\" = '$WG_PREFIX.2/24'; then basename \"\$f\" .conf; fi; done" 2>/dev/null || true)"
fi
[[ -z "$home_network_conflict" ]] || die "WireGuard 网段 $WG_PREFIX.0/24 已被家宽机配置 $home_network_conflict 使用，请更换 --wg-prefix 或先运行 volwg purge"

# 不同接口必须使用不同 VPS WG 监听端口和隧道网段；已开放的 VPS 公网 SS 端口也必须唯一。
# 读取旧节点时回退到 WG_PORT/SS_PORT，保持向后兼容。
collision="$(ssh_vps "set -eu; for f in /etc/wg-home-exit/nodes/*.conf; do test -f \"\$f\" || continue; test \"\$f\" = '/etc/wg-home-exit/nodes/$NODE_ID.conf' && continue; FILE_NODE=\$(sed -n 's/^NODE_ID=//p' \"\$f\" | head -n1); FILE_VPS_WG_PORT=\$(sed -n 's/^VPS_WG_PORT=//p' \"\$f\" | head -n1); test -n \"\$FILE_VPS_WG_PORT\" || FILE_VPS_WG_PORT=\$(sed -n 's/^WG_PORT=//p' \"\$f\" | head -n1); FILE_WG_PREFIX=\$(sed -n 's/^WG_PREFIX=//p' \"\$f\" | head -n1); FILE_MODE=\$(sed -n 's/^MODE=//p' \"\$f\" | head -n1); FILE_PUBLIC_SS=\$(sed -n 's/^PUBLIC_SS_ENABLED=//p' \"\$f\" | head -n1); test -n \"\$FILE_PUBLIC_SS\" || { test \"\$FILE_MODE\" = relay && FILE_PUBLIC_SS=1 || FILE_PUBLIC_SS=0; }; FILE_VPS_SS_PORT=\$(sed -n 's/^VPS_SS_PORT=//p' \"\$f\" | head -n1); test -n \"\$FILE_VPS_SS_PORT\" || FILE_VPS_SS_PORT=\$(sed -n 's/^SS_PORT=//p' \"\$f\" | head -n1); if test \"\$FILE_VPS_WG_PORT\" = '$VPS_WG_PORT'; then echo VPS_WG_PORT:\$FILE_NODE; fi; if test \"\$FILE_WG_PREFIX\" = '$WG_PREFIX'; then echo WG_PREFIX:\$FILE_NODE; fi; if test '$PUBLIC_SS_ENABLED' = 1 && test \"\$FILE_PUBLIC_SS\" = 1 && test \"\$FILE_VPS_SS_PORT\" = '$VPS_SS_PORT'; then echo VPS_SS_PORT:\$FILE_NODE; fi; done" 2>/dev/null || true)"
[[ -z "$collision" ]] || die "端口或网段与已有节点冲突：$collision"

cat >"$TMP_DIR/install-ssserver" <<'SSINSTALL'
#!/bin/sh
set -eu

version="__SS_RUST_VERSION__"

download_file() {
  url=$1
  output=$2
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$output" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$output" "$url"
  else
    echo "缺少 curl/wget，无法下载 shadowsocks-rust" >&2
    exit 1
  fi
}

install_release() {
  target=$1
  archive="shadowsocks-${version}.${target}.tar.xz"
  base_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${version}"
  work_dir="$(mktemp -d)"
  trap 'rm -rf "$work_dir"' EXIT
  download_file "$base_url/$archive" "$work_dir/$archive"
  download_file "$base_url/$archive.sha256" "$work_dir/$archive.sha256"
  (cd "$work_dir" && sha256sum -c "$archive.sha256")
  tar -xJf "$work_dir/$archive" -C "$work_dir" ssserver
  "$work_dir/ssserver" --version >/dev/null 2>&1 || {
    echo "下载的 ssserver 无法在当前系统运行" >&2
    exit 1
  }
  install -m 755 "$work_dir/ssserver" /usr/local/bin/ssserver
  rm -rf "$work_dir"
  trap - EXIT
}

if command -v ssserver >/dev/null 2>&1 && ssserver --version >/dev/null 2>&1; then
  exit 0
fi
if command -v ssserver >/dev/null 2>&1; then
  echo "检测到无法运行的旧 ssserver，正在替换为静态兼容版本。"
fi

machine="$(uname -m)"
if command -v opkg >/dev/null 2>&1; then
  opkg update >/dev/null 2>&1 || true
  if opkg install shadowsocks-rust-ssserver >/dev/null 2>&1 && command -v ssserver >/dev/null 2>&1; then
    exit 0
  fi
  opkg install ca-bundle curl xz >/dev/null 2>&1 || opkg install ca-bundle curl xz-utils >/dev/null 2>&1 || true
  case "$machine" in
    x86_64) target="x86_64-unknown-linux-musl" ;;
    aarch64) target="aarch64-unknown-linux-musl" ;;
    armv7l) target="armv7-unknown-linux-musleabihf" ;;
    armv6l|armv5*) target="arm-unknown-linux-musleabi" ;;
    i386|i486|i586|i686) target="i686-unknown-linux-musl" ;;
    riscv64) target="riscv64gc-unknown-linux-musl" ;;
    *)
      echo "当前 OpenWrt 架构 $machine 的软件源没有 ssserver，官方也没有可用的静态包；请改选 --home-backend xray" >&2
      exit 1
      ;;
  esac
  install_release "$target"
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get install -y ca-certificates curl xz-utils >/dev/null
  case "$machine" in
    x86_64) target="x86_64-unknown-linux-musl" ;;
    aarch64) target="aarch64-unknown-linux-musl" ;;
    armv7l) target="armv7-unknown-linux-musleabihf" ;;
    armv6l|armv5*) target="arm-unknown-linux-musleabi" ;;
    i386|i486|i586|i686) target="i686-unknown-linux-musl" ;;
    riscv64) target="riscv64gc-unknown-linux-musl" ;;
    loongarch64) target="loongarch64-unknown-linux-musl" ;;
    *) echo "不支持自动安装 ssserver 的架构：$machine" >&2; exit 1 ;;
  esac
  install_release "$target"
fi

command -v ssserver >/dev/null 2>&1
ssserver --version >/dev/null 2>&1
SSINSTALL
sed -i "s/__SS_RUST_VERSION__/$SS_RUST_VERSION/" "$TMP_DIR/install-ssserver"
chmod 700 "$TMP_DIR/install-ssserver"

echo "[2/8] 安装 WireGuard 工具"
ssh_vps "export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null; apt-get install -y wireguard-tools nftables >/dev/null"
openwrt_had_wg="1"
if [[ "$home_kind" == "openwrt" ]]; then
  if ! ssh_openwrt "command -v wg >/dev/null"; then
    openwrt_had_wg="0"
    ssh_openwrt "opkg update >/dev/null && opkg install wireguard-tools >/dev/null"
  fi
  if [[ "$HOME_BACKEND" == "xray" ]] && ! ssh_openwrt "command -v xray >/dev/null"; then
    ssh_openwrt "opkg update >/dev/null && opkg install xray-core >/dev/null"
  fi
else
  ssh_openwrt "export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null; apt-get install -y wireguard-tools nftables iptables ca-certificates >/dev/null"
  if [[ "$HOME_BACKEND" == "xray" ]]; then
    ssh_openwrt "export DEBIAN_FRONTEND=noninteractive; apt-get install -y curl unzip >/dev/null"
    ssh_openwrt 'set -eu; if ! command -v xray >/dev/null 2>&1 && test ! -x /usr/local/bin/xray; then curl -fL --retry 3 -o /tmp/xray-install-release.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh; bash /tmp/xray-install-release.sh install --without-geodata; rm -f /tmp/xray-install-release.sh; systemctl disable --now xray.service >/dev/null 2>&1 || true; fi'
  fi
fi
ssh_openwrt "command -v wg >/dev/null" || die "家宽端 wireguard-tools 安装失败"
check_remote_wireguard "VPS" ssh_vps
if [[ "$home_kind" == "linux" ]]; then
  check_remote_wireguard "家宽端" ssh_openwrt
fi
if [[ "$HOME_BACKEND" == "ss-rust" ]]; then
  scp_openwrt "$TMP_DIR/install-ssserver" /tmp/volwg-install-ssserver
  ssh_openwrt "set -eu; chmod 700 /tmp/volwg-install-ssserver; /tmp/volwg-install-ssserver; rm -f /tmp/volwg-install-ssserver"
  ssh_openwrt "command -v ssserver >/dev/null || test -x /usr/local/bin/ssserver" || die "家宽端 ss-rust ssserver 安装失败"
else
  ssh_openwrt "command -v xray >/dev/null || test -x /usr/local/bin/xray" || die "家宽端 Xray Core 安装失败"
fi

if [[ "$REPLACE_NODE" != "1" ]]; then
  used_wg_iface="$(ssh_vps "for iface in \$(wg show interfaces 2>/dev/null); do test \"\$iface\" = '$WG_IFACE' && continue; test \"\$(wg show \"\$iface\" listen-port 2>/dev/null)\" = '$VPS_WG_PORT' && echo \"\$iface\"; done" || true)"
  [[ -z "$used_wg_iface" ]] || die "VPS WireGuard UDP $VPS_WG_PORT 已被接口 $used_wg_iface 使用，请更换 --vps-wg-port"
  used_home_wg_iface="$(ssh_openwrt "for iface in \$(wg show interfaces 2>/dev/null); do test \"\$iface\" = '$WG_IFACE' && continue; test \"\$(wg show \"\$iface\" listen-port 2>/dev/null)\" = '$HOME_WG_PORT' && echo \"\$iface\"; done" || true)"
  [[ -z "$used_home_wg_iface" ]] || die "家宽机 WireGuard UDP $HOME_WG_PORT 已被接口 $used_home_wg_iface 使用，请更换 --home-wg-port"
  if [[ "$PUBLIC_SS_ENABLED" == "1" ]] && ssh_vps "nft -a list ruleset 2>/dev/null | grep -Eq '(tcp|udp) dport $VPS_SS_PORT .*dnat'"; then
    die "VPS 公网 SS 端口 $VPS_SS_PORT 已存在 DNAT 规则，请更换 --vps-ss-port"
  fi
fi

echo "[3/8] 生成或复用 WireGuard 密钥"
vps_public_key="$(ssh_vps "set -eu; install -d -m 700 /etc/wireguard; umask 077; test -s '/etc/wireguard/$WG_IFACE.key' || wg genkey > '/etc/wireguard/$WG_IFACE.key'; wg pubkey < '/etc/wireguard/$WG_IFACE.key' > '/etc/wireguard/$WG_IFACE.pub'; cat '/etc/wireguard/$WG_IFACE.pub'")"
if [[ "$home_kind" == "openwrt" ]]; then
  openwrt_public_key="$(ssh_openwrt "set -eu; mkdir -p /etc/wireguard; chmod 700 /etc/wireguard; umask 077; test -s '/etc/wireguard/$WG_IFACE.key' || wg genkey > '/etc/wireguard/$WG_IFACE.key'; wg pubkey < '/etc/wireguard/$WG_IFACE.key' > '/etc/wireguard/$WG_IFACE.pub'; cat '/etc/wireguard/$WG_IFACE.pub'")"
else
  openwrt_public_key="$(ssh_openwrt "set -eu; install -d -m 700 /etc/wireguard; umask 077; test -s '/etc/wireguard/$WG_IFACE.key' || wg genkey > '/etc/wireguard/$WG_IFACE.key'; wg pubkey < '/etc/wireguard/$WG_IFACE.key' > '/etc/wireguard/$WG_IFACE.pub'; cat '/etc/wireguard/$WG_IFACE.pub'")"
fi
[[ -n "$vps_public_key" && -n "$openwrt_public_key" ]] || die "生成 WireGuard 公钥失败"

ss_password="$(openssl rand -base64 16 | tr -d '\r\n')"
[[ -n "$ss_password" ]] || die "生成 SS2022 密钥失败"

cat >"$TMP_DIR/wg-home.conf" <<EOF
[Interface]
Address = $WG_PREFIX.1/24
ListenPort = $VPS_WG_PORT
PrivateKey = __VPS_PRIVATE_KEY__

[Peer]
PublicKey = $openwrt_public_key
AllowedIPs = $WG_PREFIX.2/32
EOF
chmod 600 "$TMP_DIR/wg-home.conf"

cat >"$TMP_DIR/openwrt-xray.json" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "ss2022-$NODE_ID",
      "listen": "$WG_PREFIX.2",
      "port": $HOME_SS_PORT,
      "protocol": "shadowsocks",
      "settings": {
        "network": "tcp,udp",
        "method": "2022-blake3-aes-128-gcm",
        "password": "$ss_password"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "home-wan",
      "protocol": "freedom"
    }
  ]
}
EOF
chmod 600 "$TMP_DIR/openwrt-xray.json"

cat >"$TMP_DIR/openwrt-xray-init" <<EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /usr/local/bin/wg-home-xray-core run -c /etc/xray-wg-home/$NODE_ID/config.json
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
chmod 700 "$TMP_DIR/openwrt-xray-init"

cat >"$TMP_DIR/ssrust-config.json" <<EOF
{
  "server": "$WG_PREFIX.2",
  "server_port": $HOME_SS_PORT,
  "password": "$ss_password",
  "method": "2022-blake3-aes-128-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
chmod 600 "$TMP_DIR/ssrust-config.json"

cat >"$TMP_DIR/openwrt-ssrust-init" <<EOF
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /usr/local/bin/wg-home-ssserver -c /etc/ss-rust-wg-home/$NODE_ID/config.json
  procd_set_param respawn 3600 5 5
  procd_set_param limits nofile="1048576 1048576"
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
chmod 700 "$TMP_DIR/openwrt-ssrust-init"

cat >"$TMP_DIR/home-wg.conf" <<EOF
[Interface]
Address = $WG_PREFIX.2/24
ListenPort = $HOME_WG_PORT
PrivateKey = __HOME_PRIVATE_KEY__

[Peer]
PublicKey = $vps_public_key
Endpoint = $VPS_PUBLIC_HOST:$VPS_WG_PORT
AllowedIPs = $WG_PREFIX.1/32
PersistentKeepalive = 25
EOF
chmod 600 "$TMP_DIR/home-wg.conf"

cat >"$TMP_DIR/home-xray.service" <<EOF
[Unit]
Description=SS2022 home exit $NODE_ID over WireGuard
Requires=wg-quick@$WG_IFACE.service
After=network-online.target wg-quick@$WG_IFACE.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wg-home-xray-core run -c /etc/xray-wg-home/$NODE_ID/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat >"$TMP_DIR/home-ssrust.service" <<EOF
[Unit]
Description=ss-rust SS2022 home exit $NODE_ID over WireGuard
Requires=wg-quick@$WG_IFACE.service
After=network-online.target wg-quick@$WG_IFACE.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wg-home-ssserver -c /etc/ss-rust-wg-home/$NODE_ID/config.json
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat >"$TMP_DIR/home-input-firewall" <<EOF
#!/bin/sh
set -eu
case "\${1:-start}" in
  start)
    iptables -w -C INPUT -i $WG_IFACE -p tcp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i $WG_IFACE -p tcp --dport $HOME_SS_PORT -j ACCEPT
    iptables -w -C INPUT -i $WG_IFACE -p udp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i $WG_IFACE -p udp --dport $HOME_SS_PORT -j ACCEPT
    ;;
  stop)
    iptables -w -D INPUT -i $WG_IFACE -p tcp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || true
    iptables -w -D INPUT -i $WG_IFACE -p udp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || true
    ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$TMP_DIR/home-input-firewall"

cat >"$TMP_DIR/home-input-firewall.service" <<EOF
[Unit]
Description=Allow SS2022 input from $WG_IFACE
Requires=wg-quick@$WG_IFACE.service
After=wg-quick@$WG_IFACE.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wgh-input-$NODE_ID start
ExecStop=/usr/local/sbin/wgh-input-$NODE_ID stop

[Install]
WantedBy=multi-user.target
EOF

echo "[4/8] 配置 VPS WireGuard"
scp_vps "$TMP_DIR/wg-home.conf" /tmp/wg-home.conf
# 变量必须在远程 VPS 展开。
# shellcheck disable=SC2016
ssh_vps "set -eu; VPS_PRIVATE_KEY=\$(cat '/etc/wireguard/$WG_IFACE.key'); sed -i \"s|__VPS_PRIVATE_KEY__|\$VPS_PRIVATE_KEY|\" /tmp/wg-home.conf; install -m 600 /tmp/wg-home.conf '/etc/wireguard/$WG_IFACE.conf'; rm -f /tmp/wg-home.conf; systemctl enable 'wg-quick@$WG_IFACE.service' >/dev/null; systemctl restart 'wg-quick@$WG_IFACE.service'"

echo "[5/8] 配置家宽端 WireGuard、Firewall 和 SS2022"
if [[ "$HOME_BACKEND" == "ss-rust" ]]; then
  backend_config="$TMP_DIR/ssrust-config.json"
  openwrt_backend_init="$TMP_DIR/openwrt-ssrust-init"
  linux_backend_service="$TMP_DIR/home-ssrust.service"
else
  backend_config="$TMP_DIR/openwrt-xray.json"
  openwrt_backend_init="$TMP_DIR/openwrt-xray-init"
  linux_backend_service="$TMP_DIR/home-xray.service"
fi
scp_openwrt "$backend_config" /tmp/wg-home-backend.json
if [[ "$home_kind" == "openwrt" ]]; then
  scp_openwrt "$openwrt_backend_init" /tmp/wg-home-backend-init
  ssh_openwrt "set -eu
STAMP=\$(date +%Y%m%d-%H%M%S)
cp /etc/config/network /etc/config/network.before-wghome.\$STAMP
cp /etc/config/firewall /etc/config/firewall.before-wghome.\$STAMP
if test '$HOME_BACKEND' = ss-rust; then
  SS_BIN=\$(command -v ssserver || true)
  test -n \"\$SS_BIN\" || SS_BIN=/usr/local/bin/ssserver
  test -x \"\$SS_BIN\" || { echo 'OpenWrt 缺少 ss-rust ssserver' >&2; exit 1; }
  mkdir -p '/etc/ss-rust-wg-home/$NODE_ID'
  chmod 700 /etc/ss-rust-wg-home
  cp /tmp/wg-home-backend.json '/etc/ss-rust-wg-home/$NODE_ID/config.json'
  chmod 600 '/etc/ss-rust-wg-home/$NODE_ID/config.json'
  ln -sf \"\$SS_BIN\" /usr/local/bin/wg-home-ssserver
  test ! -x '/etc/init.d/$XRAY_SERVICE' || { '/etc/init.d/$XRAY_SERVICE' stop >/dev/null 2>&1 || true; '/etc/init.d/$XRAY_SERVICE' disable >/dev/null 2>&1 || true; }
else
  XRAY_BIN=\$(command -v xray || true)
  test -n \"\$XRAY_BIN\" || { echo 'OpenWrt 缺少 Xray Core' >&2; exit 1; }
  mkdir -p '/etc/xray-wg-home/$NODE_ID'
  chmod 700 /etc/xray-wg-home
  cp /tmp/wg-home-backend.json '/etc/xray-wg-home/$NODE_ID/config.json'
  chmod 600 '/etc/xray-wg-home/$NODE_ID/config.json'
  ln -sf \"\$XRAY_BIN\" /usr/local/bin/wg-home-xray-core
  /usr/local/bin/wg-home-xray-core run -test -c '/etc/xray-wg-home/$NODE_ID/config.json'
  test ! -x '/etc/init.d/$SS_RUST_SERVICE' || { '/etc/init.d/$SS_RUST_SERVICE' stop >/dev/null 2>&1 || true; '/etc/init.d/$SS_RUST_SERVICE' disable >/dev/null 2>&1 || true; }
fi
cp /tmp/wg-home-backend-init '/etc/init.d/$HOME_SERVICE'
chmod 755 '/etc/init.d/$HOME_SERVICE'
rm -f /tmp/wg-home-backend.json /tmp/wg-home-backend-init
OPENWRT_PRIVATE_KEY=\$(cat '/etc/wireguard/$WG_IFACE.key')
uci -q delete 'network.$WG_IFACE' || true
uci -q delete 'network.${WG_IFACE}_vps' || true
uci set 'network.$WG_IFACE=interface'
uci set 'network.$WG_IFACE.proto=wireguard'
uci set 'network.$WG_IFACE.private_key='\"\$OPENWRT_PRIVATE_KEY\"
uci add_list 'network.$WG_IFACE.addresses=$WG_PREFIX.2/24'
uci set 'network.$WG_IFACE.listen_port=$HOME_WG_PORT'
uci set 'network.${WG_IFACE}_vps=wireguard_$WG_IFACE'
uci set 'network.${WG_IFACE}_vps.public_key=$vps_public_key'
uci set 'network.${WG_IFACE}_vps.endpoint_host=$VPS_PUBLIC_HOST'
uci set 'network.${WG_IFACE}_vps.endpoint_port=$VPS_WG_PORT'
uci set 'network.${WG_IFACE}_vps.persistent_keepalive=25'
uci set 'network.${WG_IFACE}_vps.route_allowed_ips=1'
uci add_list 'network.${WG_IFACE}_vps.allowed_ips=$WG_PREFIX.1/32'
uci commit network
uci -q delete 'firewall.fw_$NODE_ID' || true
uci set 'firewall.fw_$NODE_ID=zone'
uci set 'firewall.fw_$NODE_ID.name=$WG_IFACE'
uci add_list 'firewall.fw_$NODE_ID.network=$WG_IFACE'
uci set 'firewall.fw_$NODE_ID.input=ACCEPT'
uci set 'firewall.fw_$NODE_ID.output=ACCEPT'
uci set 'firewall.fw_$NODE_ID.forward=REJECT'
uci commit firewall
'/etc/init.d/$HOME_SERVICE' enable"

  if [[ "$openwrt_had_wg" == "0" ]]; then
    echo "OpenWrt 首次安装 WireGuard，正在重启 network；SSH 短暂断开属于正常现象。"
    ssh_openwrt "/etc/init.d/network restart" || true
    wait_for_openwrt
  else
    ssh_openwrt "/etc/init.d/network reload; sleep 2; ifup '$WG_IFACE'"
  fi

  ssh_openwrt "/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart; '/etc/init.d/$HOME_SERVICE' restart || '/etc/init.d/$HOME_SERVICE' start"
else
  scp_openwrt "$TMP_DIR/home-wg.conf" /tmp/home-wg.conf
  scp_openwrt "$linux_backend_service" /tmp/wg-home-backend.service
  scp_openwrt "$TMP_DIR/home-input-firewall" "/tmp/wgh-input-$NODE_ID"
  scp_openwrt "$TMP_DIR/home-input-firewall.service" "/tmp/wgh-input-$NODE_ID.service"
  ssh_openwrt "set -eu
STAMP=\$(date +%Y%m%d-%H%M%S)
systemctl disable --now '$XRAY_SERVICE.service' >/dev/null 2>&1 || true
systemctl disable --now '$SS_RUST_SERVICE.service' >/dev/null 2>&1 || true
systemctl stop 'wgh-input-$NODE_ID.service' >/dev/null 2>&1 || true
test ! -f '/etc/wireguard/$WG_IFACE.conf' || cp '/etc/wireguard/$WG_IFACE.conf' '/etc/wireguard/$WG_IFACE.conf.before.'\$STAMP
test ! -f '/etc/xray-wg-home/$NODE_ID/config.json' || cp '/etc/xray-wg-home/$NODE_ID/config.json' '/etc/xray-wg-home/$NODE_ID/config.json.before.'\$STAMP
test ! -f '/etc/ss-rust-wg-home/$NODE_ID/config.json' || cp '/etc/ss-rust-wg-home/$NODE_ID/config.json' '/etc/ss-rust-wg-home/$NODE_ID/config.json.before.'\$STAMP
HOME_PRIVATE_KEY=\$(cat '/etc/wireguard/$WG_IFACE.key')
sed -i \"s|__HOME_PRIVATE_KEY__|\$HOME_PRIVATE_KEY|\" /tmp/home-wg.conf
install -m 600 /tmp/home-wg.conf '/etc/wireguard/$WG_IFACE.conf'
if test '$HOME_BACKEND' = ss-rust; then
  mkdir -p '/etc/ss-rust-wg-home/$NODE_ID'
  chmod 700 /etc/ss-rust-wg-home
  install -m 600 /tmp/wg-home-backend.json '/etc/ss-rust-wg-home/$NODE_ID/config.json'
  SS_BIN=\$(command -v ssserver || true)
  test -n \"\$SS_BIN\" || SS_BIN=/usr/local/bin/ssserver
  test -x \"\$SS_BIN\"
  ln -sf \"\$SS_BIN\" /usr/local/bin/wg-home-ssserver
else
  mkdir -p '/etc/xray-wg-home/$NODE_ID'
  chmod 700 /etc/xray-wg-home
  install -m 600 /tmp/wg-home-backend.json '/etc/xray-wg-home/$NODE_ID/config.json'
  XRAY_BIN=\$(command -v xray || true)
  test -n \"\$XRAY_BIN\" || XRAY_BIN=/usr/local/bin/xray
  test -x \"\$XRAY_BIN\"
  ln -sf \"\$XRAY_BIN\" /usr/local/bin/wg-home-xray-core
  /usr/local/bin/wg-home-xray-core run -test -c '/etc/xray-wg-home/$NODE_ID/config.json'
fi
install -m 644 /tmp/wg-home-backend.service '/etc/systemd/system/$HOME_SERVICE.service'
install -m 700 '/tmp/wgh-input-$NODE_ID' '/usr/local/sbin/wgh-input-$NODE_ID'
install -m 644 '/tmp/wgh-input-$NODE_ID.service' '/etc/systemd/system/wgh-input-$NODE_ID.service'
rm -f /tmp/home-wg.conf /tmp/wg-home-backend.json /tmp/wg-home-backend.service '/tmp/wgh-input-$NODE_ID' '/tmp/wgh-input-$NODE_ID.service'
systemctl daemon-reload
systemctl enable 'wg-quick@$WG_IFACE.service' >/dev/null
systemctl enable 'wgh-input-$NODE_ID.service' >/dev/null
systemctl enable '$HOME_SERVICE.service' >/dev/null
systemctl restart 'wg-quick@$WG_IFACE.service'
systemctl restart 'wgh-input-$NODE_ID.service'
systemctl restart '$HOME_SERVICE.service'"
fi

echo "[6/8] 配置数据路径"
if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
  vps_iface="$(ssh_vps 'ip route show default' | awk 'NR==1 {print $5}')"
  [[ -n "$vps_iface" ]] || die "无法识别 VPS 默认公网接口"

  cat >"$TMP_DIR/wg-home-nft" <<EOF
#!/bin/sh
set -eu
case "\${1:-start}" in
  start)
    nft list table ip $WG_IFACE >/dev/null 2>&1 && nft delete table ip $WG_IFACE || true
    nft -f - <<'NFT'
table ip $WG_IFACE {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$vps_iface" tcp dport $VPS_SS_PORT counter dnat to $WG_PREFIX.2:$HOME_SS_PORT
    iifname "$vps_iface" udp dport $VPS_SS_PORT counter dnat to $WG_PREFIX.2:$HOME_SS_PORT
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WG_IFACE" ip daddr $WG_PREFIX.2 tcp dport $HOME_SS_PORT counter masquerade
    oifname "$WG_IFACE" ip daddr $WG_PREFIX.2 udp dport $HOME_SS_PORT counter masquerade
  }
}
NFT
    ;;
  stop)
    nft list table ip $WG_IFACE >/dev/null 2>&1 && nft delete table ip $WG_IFACE || true
    ;;
  *) exit 2 ;;
esac
EOF
  chmod 700 "$TMP_DIR/wg-home-nft"

  cat >"$TMP_DIR/wg-home-nft.service" <<EOF
[Unit]
Description=Forward SS2022 $NODE_ID to home exit over WireGuard
Requires=wg-quick@$WG_IFACE.service
After=network-online.target wg-quick@$WG_IFACE.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/$NFT_SERVICE start
ExecStop=/usr/local/sbin/$NFT_SERVICE stop

[Install]
WantedBy=multi-user.target
EOF

  scp_vps "$TMP_DIR/wg-home-nft" "/tmp/$NFT_SERVICE"
  scp_vps "$TMP_DIR/wg-home-nft.service" "/tmp/$NFT_SERVICE.service"
  ssh_vps "set -eu; printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wg-home.conf; sysctl -p /etc/sysctl.d/99-wg-home.conf >/dev/null; install -m 700 '/tmp/$NFT_SERVICE' '/usr/local/sbin/$NFT_SERVICE'; install -m 644 '/tmp/$NFT_SERVICE.service' '/etc/systemd/system/$NFT_SERVICE.service'; rm -f '/tmp/$NFT_SERVICE' '/tmp/$NFT_SERVICE.service'; systemctl daemon-reload; systemctl enable '$NFT_SERVICE.service' >/dev/null; systemctl restart '$NFT_SERVICE.service'"
else
  ssh_vps "systemctl disable --now '$NFT_SERVICE.service' >/dev/null 2>&1 || true; nft list table ip '$WG_IFACE' >/dev/null 2>&1 && nft delete table ip '$WG_IFACE' || true"
  echo "公网 SS 已关闭；不创建公网转发规则，也不会修改其他节点。"
fi

echo "[7/8] 等待握手并验证服务"
sleep 3
ssh_openwrt "ping -c 2 -W 2 '$WG_PREFIX.1' >/dev/null" || die "家宽端无法通过 WireGuard ping VPS；检查 VPS UDP $VPS_WG_PORT 防火墙"
ssh_vps "ping -c 2 -W 2 '$WG_PREFIX.2' >/dev/null" || die "VPS 无法通过 WireGuard ping 家宽端"
if [[ "$home_kind" == "openwrt" ]]; then
  ssh_openwrt "ubus call service list '{\"name\":\"$HOME_SERVICE\"}' | grep -q '\"running\": true'" || die "家宽端 $HOME_BACKEND SS2022 服务未运行"
else
  ssh_openwrt "systemctl is-active --quiet '$HOME_SERVICE.service'" || die "家宽端 $HOME_BACKEND SS2022 服务未运行"
fi

echo "[8/8] 登记线路并完成"

ss_userinfo="$(base64url_value "2022-blake3-aes-128-gcm:$ss_password")"
public_ss_endpoint="$VPS_PUBLIC_HOST:$VPS_SS_PORT"
private_ss_endpoint="$WG_PREFIX.2:$HOME_SS_PORT"
public_ss_link=""
if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
  public_ss_link="ss://$ss_userinfo@$public_ss_endpoint#$(urlencode "$DISPLAY_NAME-外网")"
fi
private_ss_link="ss://$ss_userinfo@$private_ss_endpoint#$(urlencode "$DISPLAY_NAME-内网")"

if [[ "$MODE" == "relay" && "$PUBLIC_SS_ENABLED" == "1" ]]; then
  ss_host="$VPS_PUBLIC_HOST"
  ss_link_port="$VPS_SS_PORT"
  ss_endpoint="$public_ss_endpoint"
  ss_link="$public_ss_link"
else
  ss_host="$WG_PREFIX.2"
  ss_link_port="$HOME_SS_PORT"
  ss_endpoint="$private_ss_endpoint"
  ss_link="$private_ss_link"
fi

cat >"$TMP_DIR/xray-outbound.json" <<EOF
{
  "tag": "home-$NODE_ID",
  "protocol": "shadowsocks",
  "settings": {
    "address": "$ss_host",
    "port": $ss_link_port,
    "method": "2022-blake3-aes-128-gcm",
    "password": "$ss_password"
  }
}
EOF

cat >"$TMP_DIR/xray-outbound-private.json" <<EOF
{
  "tag": "home-$NODE_ID-private",
  "protocol": "shadowsocks",
  "settings": {
    "address": "$WG_PREFIX.2",
    "port": $HOME_SS_PORT,
    "method": "2022-blake3-aes-128-gcm",
    "password": "$ss_password"
  }
}
EOF

if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
  cat >"$TMP_DIR/xray-outbound-public.json" <<EOF
{
  "tag": "home-$NODE_ID-public",
  "protocol": "shadowsocks",
  "settings": {
    "address": "$VPS_PUBLIC_HOST",
    "port": $VPS_SS_PORT,
    "method": "2022-blake3-aes-128-gcm",
    "password": "$ss_password"
  }
}
EOF
else
  : >"$TMP_DIR/xray-outbound-public.json"
fi

cat >"$TMP_DIR/node.conf" <<EOF
NODE_ID=$NODE_ID
DISPLAY_NAME_B64=$(base64_value "$DISPLAY_NAME")
MODE=$MODE
PUBLIC_SS_ENABLED=$PUBLIC_SS_ENABLED
HOME_BACKEND=$HOME_BACKEND
WG_INTERFACE=$WG_IFACE
WG_PORT=$VPS_WG_PORT
VPS_WG_PORT=$VPS_WG_PORT
HOME_WG_PORT=$HOME_WG_PORT
WG_PREFIX=$WG_PREFIX
SS_PORT=$ss_link_port
VPS_SS_PORT=$VPS_SS_PORT
HOME_SS_PORT=$HOME_SS_PORT
SS_ENDPOINT=$ss_endpoint
SS_LINK_B64=$(base64_value "$ss_link")
XRAY_OUTBOUND_B64=$(base64_value "$(cat "$TMP_DIR/xray-outbound.json")")
PUBLIC_SS_ENDPOINT=$(if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then printf '%s' "$public_ss_endpoint"; fi)
PRIVATE_SS_ENDPOINT=$private_ss_endpoint
PUBLIC_SS_LINK_B64=$(base64_value "$public_ss_link")
PRIVATE_SS_LINK_B64=$(base64_value "$private_ss_link")
PUBLIC_XRAY_OUTBOUND_B64=$(base64_value "$(cat "$TMP_DIR/xray-outbound-public.json")")
PRIVATE_XRAY_OUTBOUND_B64=$(base64_value "$(cat "$TMP_DIR/xray-outbound-private.json")")
EOF
chmod 600 "$TMP_DIR/node.conf"

scp_vps "$SCRIPT_DIR/wg-home-manager.sh" /tmp/wg-home-manager
scp_vps "$SCRIPT_DIR/wg-home-deploy.sh" /tmp/volwg-deploy
scp_vps "$SCRIPT_DIR/wg-home-key-wizard.sh" /tmp/volwg-key-wizard
scp_vps "$SCRIPT_DIR/wg-home-remove.sh" /tmp/volwg-remove
scp_vps "$SCRIPT_DIR/wg-home-purge.sh" /tmp/volwg-purge
scp_vps "$SCRIPT_DIR/volwg" /tmp/volwg-launcher
scp_vps "$SCRIPT_DIR/VERSION" /tmp/volwg-version
scp_vps "$TMP_DIR/node.conf" "/tmp/$NODE_ID.conf"
ssh_vps "set -eu; install -d -m 755 /usr/local/lib/volwg /usr/local/bin; install -m 700 /tmp/volwg-deploy /usr/local/lib/volwg/wg-home-deploy.sh; install -m 700 /tmp/volwg-key-wizard /usr/local/lib/volwg/wg-home-key-wizard.sh; install -m 700 /tmp/volwg-remove /usr/local/lib/volwg/wg-home-remove.sh; install -m 700 /tmp/volwg-purge /usr/local/lib/volwg/wg-home-purge.sh; install -m 700 /tmp/wg-home-manager /usr/local/lib/volwg/wg-home-manager.sh; install -m 644 /tmp/volwg-version /usr/local/lib/volwg/VERSION; install -m 755 /tmp/volwg-launcher /usr/local/bin/volwg; install -m 755 /tmp/wg-home-manager /usr/local/sbin/wg-home-manager; install -d -m 700 /etc/wg-home-exit/nodes; install -m 600 '/tmp/$NODE_ID.conf' '/etc/wg-home-exit/nodes/$NODE_ID.conf'; rm -f /tmp/wg-home-manager /tmp/volwg-deploy /tmp/volwg-key-wizard /tmp/volwg-remove /tmp/volwg-purge /tmp/volwg-launcher /tmp/volwg-version '/tmp/$NODE_ID.conf'"

# 同步删除工具到家宽端，确保两端都能用同一个 volwg remove 命令清理本机线路。
scp_openwrt "$SCRIPT_DIR/wg-home-manager.sh" /tmp/wg-home-manager
scp_openwrt "$SCRIPT_DIR/wg-home-deploy.sh" /tmp/volwg-deploy
scp_openwrt "$SCRIPT_DIR/wg-home-key-wizard.sh" /tmp/volwg-key-wizard
scp_openwrt "$SCRIPT_DIR/wg-home-remove.sh" /tmp/volwg-remove
scp_openwrt "$SCRIPT_DIR/wg-home-purge.sh" /tmp/volwg-purge
scp_openwrt "$SCRIPT_DIR/volwg" /tmp/volwg-launcher
scp_openwrt "$SCRIPT_DIR/VERSION" /tmp/volwg-version
if [[ "$home_kind" == "openwrt" ]]; then
  ssh_openwrt "set -eu; mkdir -p /usr/lib/volwg /usr/bin; cp /tmp/volwg-deploy /usr/lib/volwg/wg-home-deploy.sh; cp /tmp/volwg-key-wizard /usr/lib/volwg/wg-home-key-wizard.sh; cp /tmp/volwg-remove /usr/lib/volwg/wg-home-remove.sh; cp /tmp/volwg-purge /usr/lib/volwg/wg-home-purge.sh; cp /tmp/wg-home-manager /usr/lib/volwg/wg-home-manager.sh; cp /tmp/volwg-version /usr/lib/volwg/VERSION; cp /tmp/volwg-launcher /usr/bin/volwg; chmod 700 /usr/lib/volwg/wg-home-deploy.sh /usr/lib/volwg/wg-home-key-wizard.sh /usr/lib/volwg/wg-home-remove.sh /usr/lib/volwg/wg-home-purge.sh /usr/lib/volwg/wg-home-manager.sh; chmod 644 /usr/lib/volwg/VERSION; chmod 755 /usr/bin/volwg; rm -f /tmp/wg-home-manager /tmp/volwg-deploy /tmp/volwg-key-wizard /tmp/volwg-remove /tmp/volwg-purge /tmp/volwg-launcher /tmp/volwg-version"
else
  ssh_openwrt "set -eu; install -d -m 755 /usr/local/lib/volwg /usr/local/bin; install -m 700 /tmp/volwg-deploy /usr/local/lib/volwg/wg-home-deploy.sh; install -m 700 /tmp/volwg-key-wizard /usr/local/lib/volwg/wg-home-key-wizard.sh; install -m 700 /tmp/volwg-remove /usr/local/lib/volwg/wg-home-remove.sh; install -m 700 /tmp/volwg-purge /usr/local/lib/volwg/wg-home-purge.sh; install -m 700 /tmp/wg-home-manager /usr/local/lib/volwg/wg-home-manager.sh; install -m 644 /tmp/volwg-version /usr/local/lib/volwg/VERSION; install -m 755 /tmp/volwg-launcher /usr/local/bin/volwg; rm -f /tmp/wg-home-manager /tmp/volwg-deploy /tmp/volwg-key-wizard /tmp/volwg-remove /tmp/volwg-purge /tmp/volwg-launcher /tmp/volwg-version"
fi

echo
echo "线路名称：$DISPLAY_NAME"
echo "节点 ID：$NODE_ID"
echo "家宽服务端：$HOME_BACKEND"
if [[ "$home_kind" == "openwrt" ]]; then
  echo "家宽 SS 服务：/etc/init.d/$HOME_SERVICE"
  echo "检查命令：/etc/init.d/$HOME_SERVICE status"
else
  echo "家宽 SS 服务：$HOME_SERVICE.service"
  echo "检查命令：systemctl status $HOME_SERVICE"
fi
echo "加密方式：2022-blake3-aes-128-gcm"
echo "密码：$ss_password"
if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
  echo "公网 SS 地址：$public_ss_endpoint"
  echo "公网 SS2022 链接："
  echo "$public_ss_link"
else
  echo "公网 SS：已关闭（可重新部署时使用 --public-ss on 开启）"
fi
echo "私网 SS 地址：$private_ss_endpoint"
echo "私网 SS2022 链接："
echo "$private_ss_link"
echo "注意：私网链接仅供已连接该 WireGuard 隧道的 VPS/Xray 使用。"
echo
if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
  echo "公网 Xray outbound（tag：home-$NODE_ID-public）："
  cat "$TMP_DIR/xray-outbound-public.json"
  echo
fi
echo "私网 Xray outbound（tag：home-$NODE_ID-private，推荐线路机使用）："
cat "$TMP_DIR/xray-outbound-private.json"
echo
echo "兼容输出：默认入口 Xray outbound（tag：home-${NODE_ID}）："
cat "$TMP_DIR/xray-outbound.json"
echo
echo "旧版 Xray 若提示 0 Shadowsocks server configured，默认入口改用 settings.servers："
cat <<EOF
{
  "tag": "home-$NODE_ID",
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "$ss_host",
        "port": $ss_link_port,
        "method": "2022-blake3-aes-128-gcm",
        "password": "$ss_password"
      }
    ]
  }
}
EOF
echo
echo "以后登录 VPS 可查看所有线路和链接："
echo "  volwg manager list"
echo "  volwg manager links"
echo "  volwg manager show $NODE_ID"
echo "  volwg manager node $NODE_ID"
echo "删除该线路时，请分别在 VPS 和对应家宽机执行："
echo "  volwg remove --node $NODE_ID"
if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
  echo
  echo "注意：确认 VPS 防火墙允许 $VPS_WG_PORT/UDP 和 $VPS_SS_PORT/TCP+UDP。"
fi
