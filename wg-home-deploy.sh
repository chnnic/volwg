#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu 公网 VPS + 家宽机一键部署。
# 家宽端支持 OpenWrt/ImmortalWrt、Debian 12/13、Ubuntu。
#   relay  - 公网 VPS 转发 SS 端口到家宽机，并输出公网 SS2022 链接
#   direct - 优化 VPS 原生 WireGuard 直连家宽机，并输出 Xray SS outbound

MODE=""
VPS_TARGET=""
VPS_SSH_PORT="22"
VPS_PUBLIC_HOST=""
OPENWRT_TARGET=""
OPENWRT_SSH_PORT="22"
IDENTITY=""
WG_PORT="51830"
SS_PORT="31000"
WG_PREFIX="10.88.0"
ASSUME_YES="0"
GUIDED="0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法：
  wg-home-deploy.sh --mode relay|direct \
    --vps root@VPS地址 --vps-public-host VPS公网IP或域名 \
    --home root@家宽机地址 [选项]

必需参数：
  --mode relay|direct       relay 输出公网 SS 链接；direct 输出私网 Xray outbound
  --vps USER@HOST          可 SSH/root 的 Debian 或 Ubuntu VPS
  --vps-public-host HOST   WireGuard endpoint；relay 模式也是 SS 链接地址
  --home USER@HOST         可 SSH/root 的家宽机
                            支持 OpenWrt/ImmortalWrt、Debian 12/13、Ubuntu

选项：
  --vps-ssh-port PORT       VPS SSH 端口，默认 22
  --home-ssh-port PORT      家宽机 SSH 端口，默认 22
  --openwrt USER@HOST       --home 的兼容别名
  --openwrt-ssh-port PORT   --home-ssh-port 的兼容别名
  --identity PATH           SSH 私钥路径；省略则使用 ssh-agent/~/.ssh/config
  --wg-port PORT            VPS WireGuard UDP 端口，默认 51830
  --ss-port PORT            SS2022 端口，默认 31000
  --wg-prefix A.B.C         隧道前缀，默认 10.88.0
  --yes                     跳过确认
  --guided                  进入全自动部署问答向导
  -h, --help                显示帮助

示例（公网中转）：
  ./wg-home-deploy.sh --mode relay \
    --vps root@203.0.113.10 --vps-public-host 203.0.113.10 \
    --home root@home.example.com --home-ssh-port 1090 \
    --identity ~/.ssh/id_ed25519 --yes

示例（优化机直连家宽）：
  ./wg-home-deploy.sh --mode direct \
    --vps root@198.51.100.20 --vps-public-host 198.51.100.20 \
    --home root@home.example.com --home-ssh-port 1090 \
    --identity ~/.ssh/id_ed25519 --yes

如需在两个 SSH 窗口手动复制/粘贴 WireGuard 公钥，请使用：
  ./wg-home-key-wizard.sh --help
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

prompt_required() {
  local prompt="$1" answer=""
  while [[ -z "$answer" ]]; do
    read -r -p "$prompt：" answer
  done
  printf '%s' "$answer"
}

prompt_with_default() {
  local prompt="$1" default_value="$2" answer=""
  read -r -p "$prompt [$default_value]：" answer
  printf '%s' "${answer:-$default_value}"
}

guided_full_deploy() {
  local mode_choice identity_answer default_public_host

  echo
  echo "请选择部署结构："
  echo "  1) relay：可 SSH 公网 VPS 中转，输出公网 SS2022 链接"
  echo "  2) direct：可 SSH 优化 VPS 直连家宽，输出 Xray outbound"
  read -r -p "输入 1 或 2：" mode_choice
  case "$mode_choice" in
    1) MODE="relay" ;;
    2) MODE="direct" ;;
    *) die "部署结构选择无效" ;;
  esac

  VPS_TARGET="$(prompt_required "公网/优化 VPS SSH，例如 root@203.0.113.10")"
  VPS_SSH_PORT="$(prompt_with_default "VPS SSH 端口" "$VPS_SSH_PORT")"
  default_public_host="${VPS_TARGET#*@}"
  VPS_PUBLIC_HOST="$(prompt_with_default "VPS 公网 IP 或域名" "$default_public_host")"
  OPENWRT_TARGET="$(prompt_required "家宽机 SSH，例如 root@home.example.com")"
  OPENWRT_SSH_PORT="$(prompt_with_default "家宽机 SSH 端口" "$OPENWRT_SSH_PORT")"
  read -r -p "SSH 私钥路径（留空使用 ssh-agent/~/.ssh/config）：" identity_answer
  IDENTITY="$identity_answer"
  WG_PREFIX="$(prompt_with_default "WireGuard 网段前缀" "$WG_PREFIX")"
  WG_PORT="$(prompt_with_default "WireGuard UDP 端口" "$WG_PORT")"
  SS_PORT="$(prompt_with_default "SS2022 TCP/UDP 端口" "$SS_PORT")"
}

if (($# == 0)); then
  echo "============================================================"
  echo " WireGuard 家宽落地部署向导"
  echo "============================================================"
  echo "  1) 全自动远程部署"
  echo "  2) 双 SSH 窗口：当前机器是 VPS"
  echo "  3) 双 SSH 窗口：当前机器是家宽机"
  echo "  4) 查看帮助"
  read -r -p "请选择 [1-4]：" entry_choice
  case "$entry_choice" in
    1) GUIDED="1" ;;
    2)
      [[ -f "$SCRIPT_DIR/wg-home-key-wizard.sh" ]] || die "缺少 wg-home-key-wizard.sh"
      exec bash "$SCRIPT_DIR/wg-home-key-wizard.sh" --role vps
      ;;
    3)
      [[ -f "$SCRIPT_DIR/wg-home-key-wizard.sh" ]] || die "缺少 wg-home-key-wizard.sh"
      exec bash "$SCRIPT_DIR/wg-home-key-wizard.sh" --role home
      ;;
    4) usage; exit 0 ;;
    *) die "入口选择无效" ;;
  esac
fi

while (($#)); do
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --vps) VPS_TARGET="${2:-}"; shift 2 ;;
    --vps-ssh-port) VPS_SSH_PORT="${2:-}"; shift 2 ;;
    --vps-public-host) VPS_PUBLIC_HOST="${2:-}"; shift 2 ;;
    --home|--openwrt) OPENWRT_TARGET="${2:-}"; shift 2 ;;
    --home-ssh-port|--openwrt-ssh-port) OPENWRT_SSH_PORT="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    --wg-port) WG_PORT="${2:-}"; shift 2 ;;
    --ss-port) SS_PORT="${2:-}"; shift 2 ;;
    --wg-prefix) WG_PREFIX="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES="1"; shift ;;
    --guided) GUIDED="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [[ "$GUIDED" == "1" ]]; then
  guided_full_deploy
fi

[[ "$MODE" == "relay" || "$MODE" == "direct" ]] || die "--mode 必须是 relay 或 direct"
[[ -n "$VPS_TARGET" ]] || die "缺少 --vps"
[[ -n "$VPS_PUBLIC_HOST" ]] || die "缺少 --vps-public-host"
[[ -n "$OPENWRT_TARGET" ]] || die "缺少 --home"
if ! [[ "$WG_PORT" =~ ^[0-9]+$ ]] || ((WG_PORT < 1 || WG_PORT > 65535)); then
  die "WireGuard 端口无效"
fi
if ! [[ "$SS_PORT" =~ ^[0-9]+$ ]] || ((SS_PORT < 1 || SS_PORT > 65535)); then
  die "SS 端口无效"
fi
if ! [[ "$VPS_SSH_PORT" =~ ^[0-9]+$ ]] || ((VPS_SSH_PORT < 1 || VPS_SSH_PORT > 65535)); then
  die "VPS SSH 端口无效"
fi
if ! [[ "$OPENWRT_SSH_PORT" =~ ^[0-9]+$ ]] || ((OPENWRT_SSH_PORT < 1 || OPENWRT_SSH_PORT > 65535)); then
  die "家宽机 SSH 端口无效"
fi
[[ "$WG_PREFIX" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "--wg-prefix 应为 A.B.C，例如 10.88.0"

for command_name in ssh scp openssl mktemp sed awk; do
  command -v "$command_name" >/dev/null || die "本机缺少命令：$command_name"
done

if [[ -n "$IDENTITY" ]]; then
  [[ -f "$IDENTITY" ]] || die "SSH 私钥不存在：$IDENTITY"
fi

SSH_COMMON=(
  -o BatchMode=yes
  -o ConnectTimeout=12
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=accept-new
)
if [[ -n "$IDENTITY" ]]; then
  SSH_COMMON+=(-i "$IDENTITY" -o IdentitiesOnly=yes)
fi

ssh_vps() {
  ssh "${SSH_COMMON[@]}" -p "$VPS_SSH_PORT" "$VPS_TARGET" "$@"
}

ssh_openwrt() {
  ssh "${SSH_COMMON[@]}" -p "$OPENWRT_SSH_PORT" "$OPENWRT_TARGET" "$@"
}

scp_vps() {
  scp "${SSH_COMMON[@]}" -P "$VPS_SSH_PORT" "$1" "$VPS_TARGET:$2"
}

scp_openwrt() {
  scp -O "${SSH_COMMON[@]}" -P "$OPENWRT_SSH_PORT" "$1" "$OPENWRT_TARGET:$2"
}

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

echo "部署模式：$MODE"
echo "公网/优化 VPS：$VPS_TARGET（SSH $VPS_SSH_PORT）"
echo "家宽机：$OPENWRT_TARGET（SSH $OPENWRT_SSH_PORT）"
echo "WireGuard：$WG_PREFIX.1 ↔ $WG_PREFIX.2，VPS UDP $WG_PORT"
echo "SS2022：$WG_PREFIX.2:$SS_PORT"
if [[ "$MODE" == "relay" ]]; then
  echo "公网 SS：$VPS_PUBLIC_HOST:$SS_PORT/TCP+UDP"
fi
echo
echo "脚本会自动安装 WireGuard；缺少 Xray 时也会自动安装。"
echo "已有同名配置会先备份，再更新独立的 wg-home/xray-wg-home 服务。"

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
home_kind="$(ssh_openwrt 'if command -v uci >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then echo openwrt; elif test -r /etc/os-release && command -v systemctl >/dev/null 2>&1; then . /etc/os-release; case "${ID:-}:${VERSION_ID:-}" in debian:12|debian:13|ubuntu:*) echo linux ;; *) echo unsupported ;; esac; else echo unsupported; fi')"
[[ "$home_kind" == "openwrt" || "$home_kind" == "linux" ]] || die "家宽端仅支持 OpenWrt/ImmortalWrt、Debian 12/13 或 Ubuntu"
echo "检测到家宽端类型：$home_kind"

echo "[2/8] 安装 WireGuard 工具"
ssh_vps "export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null; apt-get install -y wireguard-tools nftables >/dev/null"
openwrt_had_wg="1"
if [[ "$home_kind" == "openwrt" ]]; then
  if ! ssh_openwrt "command -v wg >/dev/null"; then
    openwrt_had_wg="0"
    ssh_openwrt "opkg update >/dev/null && opkg install wireguard-tools >/dev/null"
  fi
  if ! ssh_openwrt "command -v xray >/dev/null"; then
    ssh_openwrt "opkg update >/dev/null && opkg install xray-core >/dev/null"
  fi
else
  ssh_openwrt "export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null; apt-get install -y wireguard-tools nftables iptables curl unzip ca-certificates >/dev/null"
  ssh_openwrt 'set -eu; if ! command -v xray >/dev/null 2>&1 && test ! -x /usr/local/bin/xray; then curl -fL --retry 3 -o /tmp/xray-install-release.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh; bash /tmp/xray-install-release.sh install --without-geodata; rm -f /tmp/xray-install-release.sh; systemctl disable --now xray.service >/dev/null 2>&1 || true; fi'
fi
ssh_openwrt "command -v wg >/dev/null" || die "家宽端 wireguard-tools 安装失败"
ssh_openwrt "command -v xray >/dev/null || test -x /usr/local/bin/xray" || die "家宽端 Xray Core 安装失败"

echo "[3/8] 生成或复用 WireGuard 密钥"
vps_public_key="$(ssh_vps 'set -eu; install -d -m 700 /etc/wireguard; umask 077; test -s /etc/wireguard/wg-home.key || wg genkey > /etc/wireguard/wg-home.key; wg pubkey < /etc/wireguard/wg-home.key > /etc/wireguard/wg-home.pub; cat /etc/wireguard/wg-home.pub')"
if [[ "$home_kind" == "openwrt" ]]; then
  openwrt_public_key="$(ssh_openwrt 'set -eu; mkdir -p /etc/wireguard; chmod 700 /etc/wireguard; umask 077; test -s /etc/wireguard/wg-home.key || wg genkey > /etc/wireguard/wg-home.key; wg pubkey < /etc/wireguard/wg-home.key > /etc/wireguard/wg-home.pub; cat /etc/wireguard/wg-home.pub')"
else
  openwrt_public_key="$(ssh_openwrt 'set -eu; install -d -m 700 /etc/wireguard; umask 077; test -s /etc/wireguard/wg-home.key || wg genkey > /etc/wireguard/wg-home.key; wg pubkey < /etc/wireguard/wg-home.key > /etc/wireguard/wg-home.pub; cat /etc/wireguard/wg-home.pub')"
fi
[[ -n "$vps_public_key" && -n "$openwrt_public_key" ]] || die "生成 WireGuard 公钥失败"

TMP_DIR="$(mktemp -d)"
chmod 700 "$TMP_DIR"
cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

ss_password="$(openssl rand -base64 32 | tr -d '\r\n')"
[[ -n "$ss_password" ]] || die "生成 SS2022 密钥失败"

cat >"$TMP_DIR/wg-home.conf" <<EOF
[Interface]
Address = $WG_PREFIX.1/24
ListenPort = $WG_PORT
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
      "tag": "ss2022-wg-home",
      "listen": "$WG_PREFIX.2",
      "port": $SS_PORT,
      "protocol": "shadowsocks",
      "settings": {
        "network": "tcp,udp",
        "method": "2022-blake3-aes-256-gcm",
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

cat >"$TMP_DIR/openwrt-xray-init" <<'EOF'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command /usr/local/bin/wg-home-xray-core run -c /etc/xray-wg-home/config.json
  procd_set_param respawn 3600 5 5
  procd_set_param stdout 1
  procd_set_param stderr 1
  procd_close_instance
}
EOF
chmod 700 "$TMP_DIR/openwrt-xray-init"

cat >"$TMP_DIR/home-wg.conf" <<EOF
[Interface]
Address = $WG_PREFIX.2/24
PrivateKey = __HOME_PRIVATE_KEY__

[Peer]
PublicKey = $vps_public_key
Endpoint = $VPS_PUBLIC_HOST:$WG_PORT
AllowedIPs = $WG_PREFIX.1/32
PersistentKeepalive = 25
EOF
chmod 600 "$TMP_DIR/home-wg.conf"

cat >"$TMP_DIR/home-xray.service" <<'EOF'
[Unit]
Description=SS2022 home exit over WireGuard
Requires=wg-quick@wg-home.service
After=network-online.target wg-quick@wg-home.service

[Service]
Type=simple
ExecStart=/usr/local/bin/wg-home-xray-core run -c /etc/xray-wg-home/config.json
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
    iptables -w -C INPUT -i wg-home -p tcp --dport $SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i wg-home -p tcp --dport $SS_PORT -j ACCEPT
    iptables -w -C INPUT -i wg-home -p udp --dport $SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i wg-home -p udp --dport $SS_PORT -j ACCEPT
    ;;
  stop)
    iptables -w -D INPUT -i wg-home -p tcp --dport $SS_PORT -j ACCEPT 2>/dev/null || true
    iptables -w -D INPUT -i wg-home -p udp --dport $SS_PORT -j ACCEPT 2>/dev/null || true
    ;;
  *) exit 2 ;;
esac
EOF
chmod 700 "$TMP_DIR/home-input-firewall"

cat >"$TMP_DIR/home-input-firewall.service" <<'EOF'
[Unit]
Description=Allow SS2022 input from wg-home
Requires=wg-quick@wg-home.service
After=wg-quick@wg-home.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wg-home-input-firewall start
ExecStop=/usr/local/sbin/wg-home-input-firewall stop

[Install]
WantedBy=multi-user.target
EOF

echo "[4/8] 配置 VPS WireGuard"
scp_vps "$TMP_DIR/wg-home.conf" /tmp/wg-home.conf
# 变量必须在远程 VPS 展开。
# shellcheck disable=SC2016
ssh_vps 'set -eu; VPS_PRIVATE_KEY=$(cat /etc/wireguard/wg-home.key); sed -i "s|__VPS_PRIVATE_KEY__|$VPS_PRIVATE_KEY|" /tmp/wg-home.conf; install -m 600 /tmp/wg-home.conf /etc/wireguard/wg-home.conf; rm -f /tmp/wg-home.conf; systemctl enable wg-quick@wg-home.service >/dev/null; systemctl restart wg-quick@wg-home.service'

echo "[5/8] 配置家宽端 WireGuard、Firewall 和 SS2022"
scp_openwrt "$TMP_DIR/openwrt-xray.json" /tmp/wg-home-xray.json
if [[ "$home_kind" == "openwrt" ]]; then
  scp_openwrt "$TMP_DIR/openwrt-xray-init" /tmp/wg-home-xray-init
  ssh_openwrt "set -eu
STAMP=\$(date +%Y%m%d-%H%M%S)
cp /etc/config/network /etc/config/network.before-wghome.\$STAMP
cp /etc/config/firewall /etc/config/firewall.before-wghome.\$STAMP
XRAY_BIN=\$(command -v xray || true)
test -n \"\$XRAY_BIN\" || { echo 'OpenWrt 缺少 Xray Core' >&2; exit 1; }
mkdir -p /etc/xray-wg-home
chmod 700 /etc/xray-wg-home
cp /tmp/wg-home-xray.json /etc/xray-wg-home/config.json
chmod 600 /etc/xray-wg-home/config.json
cp /tmp/wg-home-xray-init /etc/init.d/xray-wg-home
chmod 755 /etc/init.d/xray-wg-home
ln -sf \"\$XRAY_BIN\" /usr/local/bin/wg-home-xray-core
rm -f /tmp/wg-home-xray.json /tmp/wg-home-xray-init
OPENWRT_PRIVATE_KEY=\$(cat /etc/wireguard/wg-home.key)
uci -q delete network.wghome || true
uci -q delete network.wghome_vps || true
uci set network.wghome=interface
uci set network.wghome.proto='wireguard'
uci set network.wghome.private_key=\"\$OPENWRT_PRIVATE_KEY\"
uci add_list network.wghome.addresses='$WG_PREFIX.2/24'
uci set network.wghome_vps=wireguard_wghome
uci set network.wghome_vps.public_key='$vps_public_key'
uci set network.wghome_vps.endpoint_host='$VPS_PUBLIC_HOST'
uci set network.wghome_vps.endpoint_port='$WG_PORT'
uci set network.wghome_vps.persistent_keepalive='25'
uci set network.wghome_vps.route_allowed_ips='1'
uci add_list network.wghome_vps.allowed_ips='$WG_PREFIX.1/32'
uci commit network
uci -q delete firewall.wghome || true
uci set firewall.wghome=zone
uci set firewall.wghome.name='wghome'
uci add_list firewall.wghome.network='wghome'
uci set firewall.wghome.input='ACCEPT'
uci set firewall.wghome.output='ACCEPT'
uci set firewall.wghome.forward='REJECT'
uci commit firewall
/usr/local/bin/wg-home-xray-core run -test -c /etc/xray-wg-home/config.json
/etc/init.d/xray-wg-home enable"

  if [[ "$openwrt_had_wg" == "0" ]]; then
    echo "OpenWrt 首次安装 WireGuard，正在重启 network；SSH 短暂断开属于正常现象。"
    ssh_openwrt "/etc/init.d/network restart" || true
    wait_for_openwrt
  else
    ssh_openwrt "/etc/init.d/network reload; sleep 2; ifup wghome"
  fi

  ssh_openwrt "/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart; /etc/init.d/xray-wg-home restart || /etc/init.d/xray-wg-home start"
else
  scp_openwrt "$TMP_DIR/home-wg.conf" /tmp/home-wg.conf
  scp_openwrt "$TMP_DIR/home-xray.service" /tmp/xray-wg-home.service
  scp_openwrt "$TMP_DIR/home-input-firewall" /tmp/wg-home-input-firewall
  scp_openwrt "$TMP_DIR/home-input-firewall.service" /tmp/wg-home-input-firewall.service
  ssh_openwrt "set -eu
STAMP=\$(date +%Y%m%d-%H%M%S)
systemctl stop xray-wg-home.service >/dev/null 2>&1 || true
test ! -f /etc/wireguard/wg-home.conf || cp /etc/wireguard/wg-home.conf /etc/wireguard/wg-home.conf.before.\$STAMP
test ! -f /etc/xray-wg-home/config.json || cp /etc/xray-wg-home/config.json /etc/xray-wg-home/config.json.before.\$STAMP
HOME_PRIVATE_KEY=\$(cat /etc/wireguard/wg-home.key)
sed -i \"s|__HOME_PRIVATE_KEY__|\$HOME_PRIVATE_KEY|\" /tmp/home-wg.conf
install -m 600 /tmp/home-wg.conf /etc/wireguard/wg-home.conf
mkdir -p /etc/xray-wg-home
chmod 700 /etc/xray-wg-home
install -m 600 /tmp/wg-home-xray.json /etc/xray-wg-home/config.json
XRAY_BIN=\$(command -v xray || true)
test -n \"\$XRAY_BIN\" || XRAY_BIN=/usr/local/bin/xray
test -x \"\$XRAY_BIN\"
ln -sf \"\$XRAY_BIN\" /usr/local/bin/wg-home-xray-core
/usr/local/bin/wg-home-xray-core run -test -c /etc/xray-wg-home/config.json
install -m 644 /tmp/xray-wg-home.service /etc/systemd/system/xray-wg-home.service
install -m 700 /tmp/wg-home-input-firewall /usr/local/sbin/wg-home-input-firewall
install -m 644 /tmp/wg-home-input-firewall.service /etc/systemd/system/wg-home-input-firewall.service
rm -f /tmp/home-wg.conf /tmp/wg-home-xray.json /tmp/xray-wg-home.service /tmp/wg-home-input-firewall /tmp/wg-home-input-firewall.service
systemctl daemon-reload
systemctl enable --now wg-quick@wg-home.service >/dev/null
systemctl enable --now wg-home-input-firewall.service >/dev/null
systemctl enable --now xray-wg-home.service >/dev/null"
fi

echo "[6/8] 配置数据路径"
if [[ "$MODE" == "relay" ]]; then
  vps_iface="$(ssh_vps 'ip route show default' | awk 'NR==1 {print $5}')"
  [[ -n "$vps_iface" ]] || die "无法识别 VPS 默认公网接口"

  cat >"$TMP_DIR/wg-home-nft" <<EOF
#!/bin/sh
set -eu
case "\${1:-start}" in
  start)
    nft list table ip wg_home >/dev/null 2>&1 && nft delete table ip wg_home || true
    nft -f - <<'NFT'
table ip wg_home {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$vps_iface" tcp dport $SS_PORT counter dnat to $WG_PREFIX.2:$SS_PORT
    iifname "$vps_iface" udp dport $SS_PORT counter dnat to $WG_PREFIX.2:$SS_PORT
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "wg-home" ip daddr $WG_PREFIX.2 tcp dport $SS_PORT counter masquerade
    oifname "wg-home" ip daddr $WG_PREFIX.2 udp dport $SS_PORT counter masquerade
  }
}
NFT
    ;;
  stop)
    nft list table ip wg_home >/dev/null 2>&1 && nft delete table ip wg_home || true
    ;;
  *) exit 2 ;;
esac
EOF
  chmod 700 "$TMP_DIR/wg-home-nft"

  cat >"$TMP_DIR/wg-home-nft.service" <<'EOF'
[Unit]
Description=Forward SS2022 to home exit over WireGuard
Requires=wg-quick@wg-home.service
After=network-online.target wg-quick@wg-home.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/wg-home-nft start
ExecStop=/usr/local/sbin/wg-home-nft stop

[Install]
WantedBy=multi-user.target
EOF

  scp_vps "$TMP_DIR/wg-home-nft" /tmp/wg-home-nft
  scp_vps "$TMP_DIR/wg-home-nft.service" /tmp/wg-home-nft.service
  ssh_vps "set -eu; printf 'net.ipv4.ip_forward=1\n' > /etc/sysctl.d/99-wg-home.conf; sysctl -p /etc/sysctl.d/99-wg-home.conf >/dev/null; install -m 700 /tmp/wg-home-nft /usr/local/sbin/wg-home-nft; install -m 644 /tmp/wg-home-nft.service /etc/systemd/system/wg-home-nft.service; rm -f /tmp/wg-home-nft /tmp/wg-home-nft.service; systemctl daemon-reload; systemctl enable --now wg-home-nft.service >/dev/null"
else
  ssh_vps "systemctl disable --now wg-home-nft.service >/dev/null 2>&1 || true; nft list table ip wg_home >/dev/null 2>&1 && nft delete table ip wg_home || true"
fi

echo "[7/8] 等待握手并验证服务"
sleep 3
ssh_openwrt "ping -c 2 -W 2 '$WG_PREFIX.1' >/dev/null" || die "家宽端无法通过 WireGuard ping VPS；检查 VPS UDP $WG_PORT 防火墙"
ssh_vps "ping -c 2 -W 2 '$WG_PREFIX.2' >/dev/null" || die "VPS 无法通过 WireGuard ping 家宽端"
if [[ "$home_kind" == "openwrt" ]]; then
  ssh_openwrt "ubus call service list '{\"name\":\"xray-wg-home\"}' | grep -q '\"running\": true'" || die "家宽端 SS2022 服务未运行"
else
  ssh_openwrt "systemctl is-active --quiet xray-wg-home.service" || die "家宽端 SS2022 服务未运行"
fi

echo "[8/8] 完成"
echo
echo "加密方式：2022-blake3-aes-256-gcm"
echo "密码：$ss_password"
echo "家宽端 SS 地址：$WG_PREFIX.2:$SS_PORT"

encoded_password="$(urlencode "$ss_password")"
if [[ "$MODE" == "relay" ]]; then
  echo
  echo "SS2022 链接："
  echo "ss://2022-blake3-aes-256-gcm:$encoded_password@$VPS_PUBLIC_HOST:$SS_PORT/#Indonesia-Home"
  echo
  echo "注意：确认 VPS 防火墙允许 $WG_PORT/UDP 和 $SS_PORT/TCP+UDP。"
else
  echo
  echo "优化 VPS 的 Xray outbound（新版 Xray）："
  cat <<EOF
{
  "tag": "indonesia-home",
  "protocol": "shadowsocks",
  "settings": {
    "address": "$WG_PREFIX.2",
    "port": $SS_PORT,
    "method": "2022-blake3-aes-256-gcm",
    "password": "$ss_password"
  }
}
EOF
  echo
  echo "旧版 Xray 若提示 0 Shadowsocks server configured，请改用 settings.servers："
  cat <<EOF
{
  "tag": "indonesia-home",
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "$WG_PREFIX.2",
        "port": $SS_PORT,
        "method": "2022-blake3-aes-256-gcm",
        "password": "$ss_password"
      }
    ]
  }
}
EOF
fi
