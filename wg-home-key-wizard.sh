#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=""
WG_PREFIX="10.88.0"
VPS_WG_PORT="51830"
HOME_WG_PORT="51830"
VPS_ENDPOINT=""

usage() {
  cat <<'EOF'
双 SSH 窗口 WireGuard 密钥交换向导

窗口 A（公网/优化 VPS）：
  sudo ./wg-home-key-wizard.sh --role vps

窗口 B（家宽机）：
  sudo ./wg-home-key-wizard.sh --role home

支持：
  VPS：Debian、Ubuntu
  家宽机：OpenWrt/ImmortalWrt、Debian 12/13、Ubuntu

选项：
  --role vps|home
  --wg-prefix A.B.C       默认 10.88.0
  --vps-wg-port PORT      VPS 公网 UDP 端口，默认 51830
  --home-wg-port PORT     家宽机本地 UDP 端口，默认 51830
  --wg-port PORT          兼容选项：同时设置两端端口
  --endpoint HOST         home 角色使用的 VPS 公网 IP/域名
  -h, --help
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

valid_wg_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

while (($#)); do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --wg-prefix) WG_PREFIX="${2:-}"; shift 2 ;;
    --vps-wg-port) VPS_WG_PORT="${2:-}"; shift 2 ;;
    --home-wg-port) HOME_WG_PORT="${2:-}"; shift 2 ;;
    --wg-port) VPS_WG_PORT="${2:-}"; HOME_WG_PORT="${2:-}"; shift 2 ;;
    --endpoint) VPS_ENDPOINT="${2:-}"; shift 2 ;;
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
[[ "$WG_PREFIX" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "网段前缀格式无效"
if ! [[ "$VPS_WG_PORT" =~ ^[0-9]+$ ]] || ((VPS_WG_PORT < 1 || VPS_WG_PORT > 65535)); then
  die "VPS WireGuard 端口无效"
fi
if ! [[ "$HOME_WG_PORT" =~ ^[0-9]+$ ]] || ((HOME_WG_PORT < 1 || HOME_WG_PORT > 65535)); then
  die "家宽机 WireGuard 端口无效"
fi

if command -v uci >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
  SYSTEM_KIND="openwrt"
elif [[ -r /etc/os-release ]] && command -v systemctl >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:12|debian:13|ubuntu:*) SYSTEM_KIND="linux" ;;
    *) die "Linux 仅支持 Debian 12/13 或 Ubuntu" ;;
  esac
else
  die "不支持当前系统"
fi

[[ "$ROLE" != "vps" || "$SYSTEM_KIND" == "linux" ]] || die "VPS 角色仅支持 Debian/Ubuntu"

echo
echo "[1/4] 检测系统：$SYSTEM_KIND"
wg_was_installed="1"
if ! command -v wg >/dev/null 2>&1; then
  wg_was_installed="0"
  echo "[2/4] 正在自动安装 WireGuard"
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    opkg update
    opkg install wireguard-tools
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard-tools
  fi
else
  echo "[2/4] WireGuard 已安装"
fi
command -v wg >/dev/null || die "WireGuard 安装失败"

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
umask 077
if [[ ! -s /etc/wireguard/wg-home.key ]]; then
  wg genkey > /etc/wireguard/wg-home.key
fi
wg pubkey < /etc/wireguard/wg-home.key > /etc/wireguard/wg-home.pub
chmod 600 /etc/wireguard/wg-home.key /etc/wireguard/wg-home.pub

local_public_key="$(cat /etc/wireguard/wg-home.pub)"

echo
echo "============================================================"
if [[ "$ROLE" == "vps" ]]; then
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
VPS_WG_PORT="$(prompt_default "VPS WireGuard 公网 UDP 端口" "$VPS_WG_PORT")"
HOME_WG_PORT="$(prompt_default "家宽机 WireGuard 本地 UDP 端口" "$HOME_WG_PORT")"
[[ "$WG_PREFIX" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "网段前缀格式无效"
if ! [[ "$VPS_WG_PORT" =~ ^[0-9]+$ ]] || ((VPS_WG_PORT < 1 || VPS_WG_PORT > 65535)); then
  die "VPS WireGuard 端口无效"
fi
if ! [[ "$HOME_WG_PORT" =~ ^[0-9]+$ ]] || ((HOME_WG_PORT < 1 || HOME_WG_PORT > 65535)); then
  die "家宽机 WireGuard 端口无效"
fi

if [[ "$ROLE" == "vps" ]]; then
  echo
  echo "[3/4] 写入 VPS WireGuard 配置"
  private_key="$(cat /etc/wireguard/wg-home.key)"
  if [[ -f /etc/wireguard/wg-home.conf ]]; then
    cp /etc/wireguard/wg-home.conf "/etc/wireguard/wg-home.conf.before.$(date +%Y%m%d-%H%M%S)"
  fi
  cat >/etc/wireguard/wg-home.conf <<EOF
[Interface]
Address = $WG_PREFIX.1/24
ListenPort = $VPS_WG_PORT
PrivateKey = $private_key

[Peer]
PublicKey = $peer_public_key
AllowedIPs = $WG_PREFIX.2/32
EOF
  chmod 600 /etc/wireguard/wg-home.conf
  systemctl enable wg-quick@wg-home.service >/dev/null
  systemctl restart wg-quick@wg-home.service

  echo
  echo "[4/4] VPS 端完成"
  echo "请确认云防火墙和系统防火墙允许：$VPS_WG_PORT/UDP"
  echo "等待家宽端完成后测试：ping $WG_PREFIX.2"
  echo
  wg show wg-home
else
  if [[ -z "$VPS_ENDPOINT" ]]; then
    read -r -p "输入 VPS 公网 IP 或域名：" VPS_ENDPOINT
  fi
  [[ -n "$VPS_ENDPOINT" ]] || die "VPS endpoint 不能为空"

  echo
  echo "[3/4] 写入家宽端 WireGuard 配置"
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    config_stamp="$(date +%Y%m%d-%H%M%S)"
    cp /etc/config/network "/etc/config/network.before-wghome.$config_stamp"
    cp /etc/config/firewall "/etc/config/firewall.before-wghome.$config_stamp"
    private_key="$(cat /etc/wireguard/wg-home.key)"
    uci -q delete network.wghome || true
    uci -q delete network.wghome_vps || true
    uci set network.wghome=interface
    uci set network.wghome.proto='wireguard'
    uci set network.wghome.private_key="$private_key"
    uci add_list network.wghome.addresses="$WG_PREFIX.2/24"
    uci set network.wghome.listen_port="$HOME_WG_PORT"
    uci set network.wghome_vps=wireguard_wghome
    uci set network.wghome_vps.public_key="$peer_public_key"
    uci set network.wghome_vps.endpoint_host="$VPS_ENDPOINT"
    uci set network.wghome_vps.endpoint_port="$VPS_WG_PORT"
    uci set network.wghome_vps.persistent_keepalive='25'
    uci set network.wghome_vps.route_allowed_ips='1'
    uci add_list network.wghome_vps.allowed_ips="$WG_PREFIX.1/32"
    uci commit network
    uci -q delete firewall.wghome || true
    uci set firewall.wghome=zone
    uci set firewall.wghome.name='wghome'
    uci add_list firewall.wghome.network='wghome'
    uci set firewall.wghome.input='ACCEPT'
    uci set firewall.wghome.output='ACCEPT'
    uci set firewall.wghome.forward='REJECT'
    uci commit firewall

    if [[ "$wg_was_installed" == "0" ]]; then
      echo
      echo "WireGuard 刚安装，netifd 需要重启后才能识别协议。"
      echo "配置已经保存。请在本向导退出后运行："
      echo
      echo "  /etc/init.d/network restart"
      echo
      echo "SSH 可能短暂断开，重新连接后运行：wg show"
    else
      /etc/init.d/network reload
      sleep 2
      ifup wghome
      /etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart
    fi
  else
    private_key="$(cat /etc/wireguard/wg-home.key)"
    if [[ -f /etc/wireguard/wg-home.conf ]]; then
      cp /etc/wireguard/wg-home.conf "/etc/wireguard/wg-home.conf.before.$(date +%Y%m%d-%H%M%S)"
    fi
    cat >/etc/wireguard/wg-home.conf <<EOF
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
    chmod 600 /etc/wireguard/wg-home.conf
    systemctl enable wg-quick@wg-home.service >/dev/null
    systemctl restart wg-quick@wg-home.service
  fi

  echo
  echo "[4/4] 家宽端配置完成"
  echo "隧道地址：$WG_PREFIX.2"
  echo "VPS 地址：$WG_PREFIX.1"
  echo "测试命令：ping $WG_PREFIX.1"
  echo
  if [[ "$SYSTEM_KIND" == "linux" || "$wg_was_installed" == "1" ]]; then
    wg show
  fi
fi

echo
echo "私钥位置：/etc/wireguard/wg-home.key"
echo "公钥位置：/etc/wireguard/wg-home.pub"
echo "私钥不要复制或发送，只交换上面显示的公钥。"
