#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=""
NODE_ID=""
DISPLAY_NAME=""
WG_PREFIX="10.88.0"
VPS_WG_PORT="51830"
HOME_WG_PORT="51830"
VPS_ENDPOINT=""
REPLACE_NODE="0"

usage() {
  cat <<'EOF'
双 SSH 窗口 WireGuard 多节点配对向导

窗口 A（公网/优化 VPS）：
  sudo volwg key --role vps

窗口 B（家宽机）：
  sudo volwg key --role home

两个窗口输入相同的节点 ID、线路名称、网段和端口。每个节点使用独立
WireGuard 接口、密钥和配置，默认不会覆盖其他节点。占用的本地监听端口
会自动向后寻找可用端口，并在写入前显示最终结果。

支持：
  VPS：Debian、Ubuntu
  家宽机：OpenWrt/ImmortalWrt、Debian 11/12/13、Ubuntu

选项：
  --role vps|home
  --node ID               1-8 位小写字母/数字/_
  --name NAME             自定义线路显示名称
  --wg-prefix A.B.C       默认 10.88.0
  --vps-wg-port PORT      VPS 公网 UDP 起始端口，默认 51830
  --home-wg-port PORT     家宽机本地 UDP 起始端口，默认 51830
  --wg-port PORT          兼容选项：同时设置两端起始端口
  --endpoint HOST         VPS 公网 IP/域名
  --replace               明确替换相同节点 ID；替换前自动备份
  -h, --help

说明：此向导只完成 WireGuard 配对。需要自动安装 SS2022、生成公网/私网
SS 链接时，请使用“全自动部署新线路”。
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

prompt_default() {
  local prompt="$1" default_value="$2" answer
  read -r -p "$prompt [$default_value]：" answer
  printf '%s' "${answer:-$default_value}"
}

prompt_required() {
  local prompt="$1" answer=""
  while [[ -z "$answer" ]]; do
    read -r -p "${prompt}：" answer
  done
  printf '%s' "$answer"
}

valid_wg_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

encode() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

next_node_id() {
  local number candidate iface
  for number in {1..99}; do
    candidate="home$number"
    iface="wgh_$candidate"
    if [[ ! -e "/etc/wireguard/$iface.conf" && ! -e "/etc/wg-home-exit/manual/$candidate.conf" ]] && \
       ! ip link show "$iface" >/dev/null 2>&1 && \
       ! { command -v uci >/dev/null 2>&1 && uci -q get "network.$iface" >/dev/null 2>&1; }; then
      printf '%s' "$candidate"
      return
    fi
  done
  printf '%s' home1
}

port_in_use() {
  local port="$1" iface listen_port hex table
  while read -r iface; do
    [[ -n "$iface" && "$iface" != "$WG_IFACE" ]] || continue
    listen_port="$(wg show "$iface" listen-port 2>/dev/null || true)"
    [[ "$listen_port" == "$port" ]] && return 0
  done < <(wg show interfaces 2>/dev/null | tr ' ' '\n')
  printf -v hex '%04X' "$port"
  for table in /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$table" ]] || continue
    grep -Eqi "[[:space:]][0-9A-F]+:${hex}[[:space:]]" "$table" && return 0
  done
  return 1
}

next_free_port() {
  local port="$1"
  valid_port "$port" || die "端口无效：$port"
  while port_in_use "$port"; do
    ((port++))
    ((port <= 65535)) || die "从指定起始值开始没有可用端口"
  done
  printf '%s' "$port"
}

detect_public_ipv4() {
  local address="" url
  for url in https://api.ipify.org https://ipv4.icanhazip.com; do
    if command -v curl >/dev/null 2>&1; then
      address="$(curl -4fsS --max-time 5 "$url" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
      address="$(wget -4qO- -T 5 "$url" 2>/dev/null || true)"
    fi
    address="${address//$'\r'/}"
    address="${address//$'\n'/}"
    if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$address"
      return
    fi
  done
  address="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  [[ -n "$address" ]] && printf '%s' "$address"
}

line_exists() {
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    uci -q get "network.$WG_IFACE" >/dev/null 2>&1 || \
      [[ -e "/etc/wg-home-exit/manual/$NODE_ID.conf" ]]
  else
    [[ -e "$WG_CONFIG" || -e "/etc/wg-home-exit/manual/$NODE_ID.conf" ]]
  fi
}

check_linux_network_collision() {
  local file existing_address
  shopt -s nullglob
  for file in /etc/wireguard/wgh_*.conf; do
    [[ "$file" == "$WG_CONFIG" ]] && continue
    existing_address="$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$file" | head -n 1)"
    if [[ "$existing_address" == "$WG_PREFIX.1/24" || "$existing_address" == "$WG_PREFIX.2/24" ]]; then
      die "WireGuard 网段 $WG_PREFIX.0/24 已被 $(basename "$file" .conf) 使用，请更换网段"
    fi
  done
}

save_metadata() {
  local state_dir=/etc/wg-home-exit/manual state_file
  state_file="$state_dir/$NODE_ID.conf"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  if [[ -e "$state_file" && "$REPLACE_NODE" == "1" ]]; then
    cp "$state_file" "$state_file.before.$(date +%Y%m%d-%H%M%S)"
  fi
  cat >"$state_file" <<EOF
NODE_ID=$NODE_ID
DISPLAY_NAME_B64=$(encode "$DISPLAY_NAME")
ROLE=$ROLE
WG_INTERFACE=$WG_IFACE
WG_PREFIX=$WG_PREFIX
VPS_WG_PORT=$VPS_WG_PORT
HOME_WG_PORT=$HOME_WG_PORT
VPS_ENDPOINT=$VPS_ENDPOINT
EOF
  chmod 600 "$state_file"
}

while (($#)); do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --node) NODE_ID="${2:-}"; shift 2 ;;
    --name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --wg-prefix) WG_PREFIX="${2:-}"; shift 2 ;;
    --vps-wg-port) VPS_WG_PORT="${2:-}"; shift 2 ;;
    --home-wg-port) HOME_WG_PORT="${2:-}"; shift 2 ;;
    --wg-port) VPS_WG_PORT="${2:-}"; HOME_WG_PORT="${2:-}"; shift 2 ;;
    --endpoint) VPS_ENDPOINT="${2:-}"; shift 2 ;;
    --replace) REPLACE_NODE="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [[ -z "$ROLE" ]]; then
  echo "请选择当前 SSH 窗口的机器角色："
  echo "  1) 公网/优化 VPS"
  echo "  2) 家宽机"
  read -r -p "输入 1 或 2：" role_choice
  case "$role_choice" in
    1) ROLE="vps" ;;
    2) ROLE="home" ;;
    *) die "角色选择无效" ;;
  esac
fi

[[ "$ROLE" == "vps" || "$ROLE" == "home" ]] || die "--role 必须是 vps 或 home"
[[ "$(id -u)" == "0" ]] || die "请使用 root 或 sudo 运行"

if command -v uci >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
  SYSTEM_KIND="openwrt"
elif [[ -r /etc/os-release ]] && command -v systemctl >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:11|debian:12|debian:13|ubuntu:*) SYSTEM_KIND="linux" ;;
    *) die "Linux 仅支持 Debian 11/12/13 或 Ubuntu" ;;
  esac
else
  die "不支持当前系统"
fi
[[ "$ROLE" != "vps" || "$SYSTEM_KIND" == "linux" ]] || die "VPS 角色仅支持 Debian/Ubuntu"

default_node="$(next_node_id)"
[[ -n "$NODE_ID" ]] || NODE_ID="$(prompt_default "节点 ID（两个窗口填写相同 ID）" "$default_node")"
[[ "$NODE_ID" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "节点 ID 必须是 1-8 位小写字母、数字或下划线"
[[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$(prompt_default "线路显示名称（两个窗口建议相同）" "家宽线路 $NODE_ID")"
[[ -n "$DISPLAY_NAME" ]] || die "线路名称不能为空"

WG_IFACE="wgh_$NODE_ID"
WG_CONFIG="/etc/wireguard/$WG_IFACE.conf"
WG_KEY="/etc/wireguard/$WG_IFACE.key"
WG_PUB="/etc/wireguard/$WG_IFACE.pub"

if line_exists && [[ "$REPLACE_NODE" != "1" ]]; then
  die "节点 $NODE_ID 已存在。为防止覆盖，请换一个节点 ID；确需替换时明确添加 --replace"
fi

echo
echo "[1/5] 系统与线路"
echo "  系统：$SYSTEM_KIND"
echo "  角色：$ROLE"
echo "  名称：$DISPLAY_NAME"
echo "  节点：$NODE_ID"
echo "  接口：$WG_IFACE"

wg_was_installed="1"
if ! command -v wg >/dev/null 2>&1; then
  wg_was_installed="0"
  echo "[2/5] 正在自动安装 WireGuard"
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    opkg update
    opkg install wireguard-tools
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard-tools
  fi
else
  echo "[2/5] WireGuard 已安装"
fi
command -v wg >/dev/null || die "WireGuard 安装失败"

if [[ "$SYSTEM_KIND" == "linux" ]]; then
  test_iface="vwgcap$$"
  cleanup_test_iface() {
    ip link del "$test_iface" >/dev/null 2>&1 || true
  }
  trap cleanup_test_iface EXIT INT TERM
  if ! wg_capability_error="$(ip link add "$test_iface" type wireguard 2>&1)"; then
    virtualization="$(systemd-detect-virt 2>/dev/null || true)"
    die "无法创建 WireGuard 接口。LXC 请确认 NET_ADMIN 和宿主机 WireGuard。虚拟化：${virtualization:-none}；原始输出：$wg_capability_error"
  fi
  ip link del "$test_iface"
  trap - EXIT INT TERM
fi

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
umask 077
if [[ ! -s "$WG_KEY" ]]; then
  wg genkey >"$WG_KEY"
fi
wg pubkey <"$WG_KEY" >"$WG_PUB"
chmod 600 "$WG_KEY" "$WG_PUB"
local_public_key="$(<"$WG_PUB")"

if [[ "$ROLE" == "vps" ]]; then
  detected_endpoint="$(detect_public_ipv4)"
  if [[ -z "$VPS_ENDPOINT" ]]; then
    if [[ -n "$detected_endpoint" ]]; then
      VPS_ENDPOINT="$(prompt_default "VPS 公网 IP/域名（复制到家宽窗口）" "$detected_endpoint")"
    else
      VPS_ENDPOINT="$(prompt_required "VPS 公网 IP/域名（复制到家宽窗口）")"
    fi
  fi
  echo "  VPS 公网地址：$VPS_ENDPOINT"
fi

echo
echo "============================================================"
echo "线路：$DISPLAY_NAME ($NODE_ID)"
if [[ "$ROLE" == "vps" ]]; then
  echo "VPS endpoint：$VPS_ENDPOINT:$VPS_WG_PORT"
  echo "这是 VPS 公钥，请复制到家宽机窗口："
else
  echo "这是家宽机公钥，请复制到 VPS 窗口："
fi
echo
echo "$local_public_key"
echo "============================================================"
echo

if [[ "$ROLE" == "vps" ]]; then
  read -r -p "粘贴家宽机公钥：" peer_public_key
else
  read -r -p "粘贴 VPS 公钥：" peer_public_key
fi
valid_wg_key "$peer_public_key" || die "粘贴的 WireGuard 公钥格式无效"

WG_PREFIX="$(prompt_default "WireGuard 网段前缀" "$WG_PREFIX")"
VPS_WG_PORT="$(prompt_default "VPS WireGuard 公网 UDP 起始端口" "$VPS_WG_PORT")"
HOME_WG_PORT="$(prompt_default "家宽机 WireGuard 本地 UDP 起始端口" "$HOME_WG_PORT")"
[[ "$WG_PREFIX" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "网段前缀格式无效"
valid_port "$VPS_WG_PORT" || die "VPS WireGuard 端口无效"
valid_port "$HOME_WG_PORT" || die "家宽机 WireGuard 端口无效"

if [[ "$ROLE" == "vps" && "$REPLACE_NODE" != "1" ]]; then
  selected_port="$(next_free_port "$VPS_WG_PORT")"
  if [[ "$selected_port" != "$VPS_WG_PORT" ]]; then
    echo "VPS UDP $VPS_WG_PORT 已占用，自动改用 $selected_port。请在家宽窗口填写 $selected_port。"
    VPS_WG_PORT="$selected_port"
  fi
elif [[ "$ROLE" == "home" && "$REPLACE_NODE" != "1" ]]; then
  selected_port="$(next_free_port "$HOME_WG_PORT")"
  if [[ "$selected_port" != "$HOME_WG_PORT" ]]; then
    echo "家宽本地 UDP $HOME_WG_PORT 已占用，自动改用 $selected_port。"
    HOME_WG_PORT="$selected_port"
  fi
fi

if [[ "$ROLE" == "home" && -z "$VPS_ENDPOINT" ]]; then
  VPS_ENDPOINT="$(prompt_required "输入 VPS 窗口显示的公网 IP 或域名")"
fi
if [[ "$SYSTEM_KIND" == "linux" ]]; then
  check_linux_network_collision
fi

echo
echo "[3/5] 配置确认"
echo "  名称/节点：$DISPLAY_NAME ($NODE_ID)"
echo "  WireGuard：$WG_IFACE，$WG_PREFIX.1 ↔ $WG_PREFIX.2"
echo "  VPS endpoint：${VPS_ENDPOINT:-本机}:$VPS_WG_PORT"
echo "  家宽本地端口：$HOME_WG_PORT"
echo "  其他节点不会被修改。"
read -r -p "输入 yes 写入配置：" confirm
[[ "$confirm" == "yes" ]] || die "用户取消"

if [[ "$ROLE" == "vps" ]]; then
  echo "[4/5] 写入 VPS WireGuard 配置"
  if [[ -f "$WG_CONFIG" ]]; then
    cp "$WG_CONFIG" "$WG_CONFIG.before.$(date +%Y%m%d-%H%M%S)"
  fi
  private_key="$(<"$WG_KEY")"
  cat >"$WG_CONFIG" <<EOF
# VolWG: $DISPLAY_NAME ($NODE_ID)
[Interface]
Address = $WG_PREFIX.1/24
ListenPort = $VPS_WG_PORT
PrivateKey = $private_key

[Peer]
PublicKey = $peer_public_key
AllowedIPs = $WG_PREFIX.2/32
EOF
  chmod 600 "$WG_CONFIG"
  systemctl enable "wg-quick@$WG_IFACE.service" >/dev/null
  systemctl restart "wg-quick@$WG_IFACE.service"
else
  echo "[4/5] 写入家宽端 WireGuard 配置"
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    config_stamp="$(date +%Y%m%d-%H%M%S)"
    cp /etc/config/network "/etc/config/network.before-volwg.$config_stamp"
    cp /etc/config/firewall "/etc/config/firewall.before-volwg.$config_stamp"
    private_key="$(<"$WG_KEY")"
    uci -q delete "network.$WG_IFACE" || true
    uci -q delete "network.${WG_IFACE}_vps" || true
    uci set "network.$WG_IFACE=interface"
    uci set "network.$WG_IFACE.proto=wireguard"
    uci set "network.$WG_IFACE.private_key=$private_key"
    uci set "network.$WG_IFACE.description=$DISPLAY_NAME"
    uci add_list "network.$WG_IFACE.addresses=$WG_PREFIX.2/24"
    uci set "network.$WG_IFACE.listen_port=$HOME_WG_PORT"
    uci set "network.${WG_IFACE}_vps=wireguard_$WG_IFACE"
    uci set "network.${WG_IFACE}_vps.public_key=$peer_public_key"
    uci set "network.${WG_IFACE}_vps.endpoint_host=$VPS_ENDPOINT"
    uci set "network.${WG_IFACE}_vps.endpoint_port=$VPS_WG_PORT"
    uci set "network.${WG_IFACE}_vps.persistent_keepalive=25"
    uci set "network.${WG_IFACE}_vps.route_allowed_ips=1"
    uci add_list "network.${WG_IFACE}_vps.allowed_ips=$WG_PREFIX.1/32"
    uci -q delete "firewall.fw_$NODE_ID" || true
    uci set "firewall.fw_$NODE_ID=zone"
    uci set "firewall.fw_$NODE_ID.name=$WG_IFACE"
    uci add_list "firewall.fw_$NODE_ID.network=$WG_IFACE"
    uci set "firewall.fw_$NODE_ID.input=ACCEPT"
    uci set "firewall.fw_$NODE_ID.output=ACCEPT"
    uci set "firewall.fw_$NODE_ID.forward=REJECT"
    uci commit network
    uci commit firewall
    if [[ "$wg_was_installed" == "0" ]]; then
      echo "WireGuard 刚安装。配置已保存，请退出向导后运行：/etc/init.d/network restart"
    else
      /etc/init.d/network reload
      sleep 2
      ifup "$WG_IFACE"
      /etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart
    fi
  else
    if [[ -f "$WG_CONFIG" ]]; then
      cp "$WG_CONFIG" "$WG_CONFIG.before.$(date +%Y%m%d-%H%M%S)"
    fi
    private_key="$(<"$WG_KEY")"
    cat >"$WG_CONFIG" <<EOF
# VolWG: $DISPLAY_NAME ($NODE_ID)
[Interface]
Address = $WG_PREFIX.2/24
ListenPort = $HOME_WG_PORT
PrivateKey = $private_key

[Peer]
PublicKey = $peer_public_key
Endpoint = $VPS_ENDPOINT:$VPS_WG_PORT
AllowedIPs = $WG_PREFIX.1/32
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_CONFIG"
    systemctl enable "wg-quick@$WG_IFACE.service" >/dev/null
    systemctl restart "wg-quick@$WG_IFACE.service"
  fi
fi

save_metadata

echo
echo "[5/5] 配对完成"
echo "线路名称：$DISPLAY_NAME"
echo "节点 ID：$NODE_ID"
echo "WireGuard 接口：$WG_IFACE"
echo "VPS 地址：$WG_PREFIX.1"
echo "家宽地址：$WG_PREFIX.2"
echo "VPS endpoint：$VPS_ENDPOINT:$VPS_WG_PORT"
echo "私钥：$WG_KEY"
echo "公钥：$WG_PUB"
if [[ "$ROLE" == "vps" ]]; then
  echo "测试：ping $WG_PREFIX.2"
  echo "请确认云防火墙允许：$VPS_WG_PORT/UDP"
else
  echo "测试：ping $WG_PREFIX.1"
fi
echo "删除本机这条线路：volwg remove --node $NODE_ID"
echo "私钥不要复制或发送，只交换上面显示的公钥。"
echo
wg show "$WG_IFACE" 2>/dev/null || true
