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
NODE_ID="home1"
DISPLAY_NAME="家宽线路 1"
REPLACE_NODE="0"
ASSUME_YES="0"
GUIDED="0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
用法：
  volwg deploy --mode relay|direct \
    --node 节点ID --name "线路显示名称" \
    --vps root@VPS地址 --vps-public-host VPS公网IP或域名 \
    --home root@家宽机地址 [选项]

必需参数：
  --mode relay|direct       relay 输出公网 SS 链接；direct 输出私网 Xray outbound
  --vps USER@HOST          可 SSH/root 的 Debian 或 Ubuntu VPS
  --vps-public-host HOST   WireGuard endpoint；relay 模式也是 SS 链接地址
  --home USER@HOST         可 SSH/root 的家宽机
                            支持 OpenWrt/ImmortalWrt、Debian 12/13、Ubuntu

选项：
  --node ID                 节点 ID，1-8 位小写字母/数字/_，默认 home1
  --name NAME               SS 链接和管理后台显示名称，默认“家宽线路 1”
  --vps-ssh-port PORT       VPS SSH 端口，默认 22
  --home-ssh-port PORT      家宽机 SSH 端口，默认 22
  --openwrt USER@HOST       --home 的兼容别名
  --openwrt-ssh-port PORT   --home-ssh-port 的兼容别名
  --identity PATH           SSH 私钥路径；省略则使用 ssh-agent/~/.ssh/config
  --wg-port PORT            VPS WireGuard UDP 端口，默认 51830
  --ss-port PORT            SS2022 端口，默认 31000
  --wg-prefix A.B.C         隧道前缀，默认 10.88.0
  --replace                 明确替换同一节点 ID 的已有配置
  --yes                     跳过确认
  --guided                  进入全自动部署问答向导
  -h, --help                显示帮助

示例（公网中转）：
  volwg deploy --mode relay \
    --node jkt1 --name "印尼雅加达家宽" \
    --vps root@203.0.113.10 --vps-public-host 203.0.113.10 \
    --home root@home.example.com --home-ssh-port 1090 \
    --identity ~/.ssh/id_ed25519 --yes

示例（优化机直连家宽）：
  volwg deploy --mode direct \
    --node sby1 --name "印尼泗水家宽" \
    --vps root@198.51.100.20 --vps-public-host 198.51.100.20 \
    --home root@home.example.com --home-ssh-port 1090 \
    --identity ~/.ssh/id_ed25519 --yes

如需在两个 SSH 窗口手动复制/粘贴 WireGuard 公钥，请使用：
  volwg key --help
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

  NODE_ID="$(prompt_with_default "节点 ID（1-8 位小写字母/数字/_）" "$NODE_ID")"
  DISPLAY_NAME="$(prompt_with_default "线路显示名称/SS 链接名称" "$DISPLAY_NAME")"

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
  echo " VolWG 多线路家宽落地部署向导"
  echo "============================================================"
  echo "  1) 全自动远程部署"
  echo "  2) 双 SSH 窗口：当前机器是 VPS"
  echo "  3) 双 SSH 窗口：当前机器是家宽机"
  echo "  4) 管理 VPS 上已部署的线路"
  echo "  5) 查看帮助"
  read -r -p "请选择 [1-5]：" entry_choice
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
    4)
      if [[ -d /etc/wg-home-exit/nodes || -f /etc/wireguard/wg-home.conf ]] || compgen -G '/etc/wireguard/wgh_*.conf' >/dev/null; then
        exec bash "$SCRIPT_DIR/wg-home-manager.sh" menu
      fi
      echo "本机没有检测到 VolWG/WireGuard 线路，将连接另一台 VPS。"
      manager_vps="$(prompt_required "VPS SSH，例如 root@203.0.113.10")"
      manager_port="$(prompt_with_default "VPS SSH 端口" "22")"
      read -r -p "SSH 私钥路径（留空使用 ssh-agent/~/.ssh/config）：" manager_identity
      manager_ssh=(-o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -p "$manager_port")
      if [[ -n "$manager_identity" ]]; then
        manager_ssh+=(-i "$manager_identity" -o IdentitiesOnly=yes)
      fi
      exec ssh -t "${manager_ssh[@]}" "$manager_vps" "wg-home-manager menu"
      ;;
    5) usage; exit 0 ;;
    *) die "入口选择无效" ;;
  esac
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
    --wg-port) WG_PORT="${2:-}"; shift 2 ;;
    --ss-port) SS_PORT="${2:-}"; shift 2 ;;
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

[[ "$MODE" == "relay" || "$MODE" == "direct" ]] || die "--mode 必须是 relay 或 direct"
[[ "$NODE_ID" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "--node 必须是 1-8 位小写字母、数字或下划线"
[[ -n "$DISPLAY_NAME" ]] || die "--name 不能为空"
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

WG_IFACE="wgh_$NODE_ID"
XRAY_SERVICE="xray-wgh-$NODE_ID"
NFT_SERVICE="wgh-nft-$NODE_ID"

for command_name in ssh scp openssl mktemp sed awk base64; do
  command -v "$command_name" >/dev/null || die "本机缺少命令：$command_name"
done

if [[ -n "$IDENTITY" ]]; then
  [[ -f "$IDENTITY" ]] || die "SSH 私钥不存在：$IDENTITY"
fi
[[ -f "$SCRIPT_DIR/wg-home-manager.sh" ]] || die "缺少 wg-home-manager.sh；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/wg-home-key-wizard.sh" ]] || die "缺少 wg-home-key-wizard.sh；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/volwg" ]] || die "缺少 volwg 快捷入口；请使用仓库完整版或一键安装命令"
[[ -f "$SCRIPT_DIR/VERSION" ]] || die "缺少 VERSION；请使用仓库完整版或一键安装命令"

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

base64_value() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

base64url_value() {
  printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\r\n'
}

echo "节点 ID：$NODE_ID"
echo "线路名称：$DISPLAY_NAME"
echo "部署模式：$MODE"
echo "公网/优化 VPS：$VPS_TARGET（SSH $VPS_SSH_PORT）"
echo "家宽机：$OPENWRT_TARGET（SSH $OPENWRT_SSH_PORT）"
echo "WireGuard：${WG_IFACE}，${WG_PREFIX}.1 ↔ ${WG_PREFIX}.2，VPS UDP $WG_PORT"
echo "SS2022：$WG_PREFIX.2:$SS_PORT"
if [[ "$MODE" == "relay" ]]; then
  echo "公网 SS：$VPS_PUBLIC_HOST:$SS_PORT/TCP+UDP"
fi
echo
echo "脚本会自动安装 WireGuard；缺少 Xray 时也会自动安装。"
echo "每个节点使用独立 WireGuard、Xray 和防火墙配置；不会配置负载均衡。"

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

if [[ "$REPLACE_NODE" != "1" ]] && ssh_vps "test -e '/etc/wireguard/$WG_IFACE.conf' || test -e '/etc/wg-home-exit/nodes/$NODE_ID.conf'"; then
  die "节点 $NODE_ID 已存在；换一个 --node，或确认覆盖后添加 --replace"
fi

# 不同接口必须使用不同 WG 监听端口和隧道网段；relay 的公网 SS 端口也必须唯一。
collision="$(ssh_vps "set -eu; for f in /etc/wg-home-exit/nodes/*.conf; do test -f \"\$f\" || continue; test \"\$f\" = '/etc/wg-home-exit/nodes/$NODE_ID.conf' && continue; FILE_NODE=\$(sed -n 's/^NODE_ID=//p' \"\$f\" | head -n1); FILE_WG_PORT=\$(sed -n 's/^WG_PORT=//p' \"\$f\" | head -n1); FILE_WG_PREFIX=\$(sed -n 's/^WG_PREFIX=//p' \"\$f\" | head -n1); FILE_MODE=\$(sed -n 's/^MODE=//p' \"\$f\" | head -n1); FILE_SS_PORT=\$(sed -n 's/^SS_PORT=//p' \"\$f\" | head -n1); if test \"\$FILE_WG_PORT\" = '$WG_PORT'; then echo WG_PORT:\$FILE_NODE; fi; if test \"\$FILE_WG_PREFIX\" = '$WG_PREFIX'; then echo WG_PREFIX:\$FILE_NODE; fi; if test '$MODE' = relay && test \"\$FILE_MODE\" = relay && test \"\$FILE_SS_PORT\" = '$SS_PORT'; then echo SS_PORT:\$FILE_NODE; fi; done" 2>/dev/null || true)"
[[ -z "$collision" ]] || die "端口或网段与已有节点冲突：$collision"

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

if [[ "$REPLACE_NODE" != "1" ]]; then
  used_wg_iface="$(ssh_vps "for iface in \$(wg show interfaces 2>/dev/null); do test \"\$iface\" = '$WG_IFACE' && continue; test \"\$(wg show \"\$iface\" listen-port 2>/dev/null)\" = '$WG_PORT' && echo \"\$iface\"; done" || true)"
  [[ -z "$used_wg_iface" ]] || die "WireGuard UDP $WG_PORT 已被接口 $used_wg_iface 使用，请更换 --wg-port"
  if [[ "$MODE" == "relay" ]] && ssh_vps "nft -a list ruleset 2>/dev/null | grep -Eq '(tcp|udp) dport $SS_PORT .*dnat'"; then
    die "公网 SS 端口 $SS_PORT 已存在 DNAT 规则，请更换 --ss-port"
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
      "tag": "ss2022-$NODE_ID",
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

cat >"$TMP_DIR/home-input-firewall" <<EOF
#!/bin/sh
set -eu
case "\${1:-start}" in
  start)
    iptables -w -C INPUT -i $WG_IFACE -p tcp --dport $SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i $WG_IFACE -p tcp --dport $SS_PORT -j ACCEPT
    iptables -w -C INPUT -i $WG_IFACE -p udp --dport $SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i $WG_IFACE -p udp --dport $SS_PORT -j ACCEPT
    ;;
  stop)
    iptables -w -D INPUT -i $WG_IFACE -p tcp --dport $SS_PORT -j ACCEPT 2>/dev/null || true
    iptables -w -D INPUT -i $WG_IFACE -p udp --dport $SS_PORT -j ACCEPT 2>/dev/null || true
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
scp_openwrt "$TMP_DIR/openwrt-xray.json" /tmp/wg-home-xray.json
if [[ "$home_kind" == "openwrt" ]]; then
  scp_openwrt "$TMP_DIR/openwrt-xray-init" /tmp/wg-home-xray-init
  ssh_openwrt "set -eu
STAMP=\$(date +%Y%m%d-%H%M%S)
cp /etc/config/network /etc/config/network.before-wghome.\$STAMP
cp /etc/config/firewall /etc/config/firewall.before-wghome.\$STAMP
XRAY_BIN=\$(command -v xray || true)
test -n \"\$XRAY_BIN\" || { echo 'OpenWrt 缺少 Xray Core' >&2; exit 1; }
mkdir -p '/etc/xray-wg-home/$NODE_ID'
chmod 700 /etc/xray-wg-home
cp /tmp/wg-home-xray.json '/etc/xray-wg-home/$NODE_ID/config.json'
chmod 600 '/etc/xray-wg-home/$NODE_ID/config.json'
cp /tmp/wg-home-xray-init '/etc/init.d/$XRAY_SERVICE'
chmod 755 '/etc/init.d/$XRAY_SERVICE'
ln -sf \"\$XRAY_BIN\" /usr/local/bin/wg-home-xray-core
rm -f /tmp/wg-home-xray.json /tmp/wg-home-xray-init
OPENWRT_PRIVATE_KEY=\$(cat '/etc/wireguard/$WG_IFACE.key')
uci -q delete 'network.$WG_IFACE' || true
uci -q delete 'network.${WG_IFACE}_vps' || true
uci set 'network.$WG_IFACE=interface'
uci set 'network.$WG_IFACE.proto=wireguard'
uci set 'network.$WG_IFACE.private_key='\"\$OPENWRT_PRIVATE_KEY\"
uci add_list 'network.$WG_IFACE.addresses=$WG_PREFIX.2/24'
uci set 'network.${WG_IFACE}_vps=wireguard_$WG_IFACE'
uci set 'network.${WG_IFACE}_vps.public_key=$vps_public_key'
uci set 'network.${WG_IFACE}_vps.endpoint_host=$VPS_PUBLIC_HOST'
uci set 'network.${WG_IFACE}_vps.endpoint_port=$WG_PORT'
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
/usr/local/bin/wg-home-xray-core run -test -c '/etc/xray-wg-home/$NODE_ID/config.json'
'/etc/init.d/$XRAY_SERVICE' enable"

  if [[ "$openwrt_had_wg" == "0" ]]; then
    echo "OpenWrt 首次安装 WireGuard，正在重启 network；SSH 短暂断开属于正常现象。"
    ssh_openwrt "/etc/init.d/network restart" || true
    wait_for_openwrt
  else
    ssh_openwrt "/etc/init.d/network reload; sleep 2; ifup '$WG_IFACE'"
  fi

  ssh_openwrt "/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart; '/etc/init.d/$XRAY_SERVICE' restart || '/etc/init.d/$XRAY_SERVICE' start"
else
  scp_openwrt "$TMP_DIR/home-wg.conf" /tmp/home-wg.conf
  scp_openwrt "$TMP_DIR/home-xray.service" "/tmp/$XRAY_SERVICE.service"
  scp_openwrt "$TMP_DIR/home-input-firewall" "/tmp/wgh-input-$NODE_ID"
  scp_openwrt "$TMP_DIR/home-input-firewall.service" "/tmp/wgh-input-$NODE_ID.service"
  ssh_openwrt "set -eu
STAMP=\$(date +%Y%m%d-%H%M%S)
systemctl stop '$XRAY_SERVICE.service' >/dev/null 2>&1 || true
systemctl stop 'wgh-input-$NODE_ID.service' >/dev/null 2>&1 || true
test ! -f '/etc/wireguard/$WG_IFACE.conf' || cp '/etc/wireguard/$WG_IFACE.conf' '/etc/wireguard/$WG_IFACE.conf.before.'\$STAMP
test ! -f '/etc/xray-wg-home/$NODE_ID/config.json' || cp '/etc/xray-wg-home/$NODE_ID/config.json' '/etc/xray-wg-home/$NODE_ID/config.json.before.'\$STAMP
HOME_PRIVATE_KEY=\$(cat '/etc/wireguard/$WG_IFACE.key')
sed -i \"s|__HOME_PRIVATE_KEY__|\$HOME_PRIVATE_KEY|\" /tmp/home-wg.conf
install -m 600 /tmp/home-wg.conf '/etc/wireguard/$WG_IFACE.conf'
mkdir -p '/etc/xray-wg-home/$NODE_ID'
chmod 700 /etc/xray-wg-home
install -m 600 /tmp/wg-home-xray.json '/etc/xray-wg-home/$NODE_ID/config.json'
XRAY_BIN=\$(command -v xray || true)
test -n \"\$XRAY_BIN\" || XRAY_BIN=/usr/local/bin/xray
test -x \"\$XRAY_BIN\"
ln -sf \"\$XRAY_BIN\" /usr/local/bin/wg-home-xray-core
/usr/local/bin/wg-home-xray-core run -test -c '/etc/xray-wg-home/$NODE_ID/config.json'
install -m 644 '/tmp/$XRAY_SERVICE.service' '/etc/systemd/system/$XRAY_SERVICE.service'
install -m 700 '/tmp/wgh-input-$NODE_ID' '/usr/local/sbin/wgh-input-$NODE_ID'
install -m 644 '/tmp/wgh-input-$NODE_ID.service' '/etc/systemd/system/wgh-input-$NODE_ID.service'
rm -f /tmp/home-wg.conf /tmp/wg-home-xray.json '/tmp/$XRAY_SERVICE.service' '/tmp/wgh-input-$NODE_ID' '/tmp/wgh-input-$NODE_ID.service'
systemctl daemon-reload
systemctl enable 'wg-quick@$WG_IFACE.service' >/dev/null
systemctl enable 'wgh-input-$NODE_ID.service' >/dev/null
systemctl enable '$XRAY_SERVICE.service' >/dev/null
systemctl restart 'wg-quick@$WG_IFACE.service'
systemctl restart 'wgh-input-$NODE_ID.service'
systemctl restart '$XRAY_SERVICE.service'"
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
    nft list table ip $WG_IFACE >/dev/null 2>&1 && nft delete table ip $WG_IFACE || true
    nft -f - <<'NFT'
table ip $WG_IFACE {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$vps_iface" tcp dport $SS_PORT counter dnat to $WG_PREFIX.2:$SS_PORT
    iifname "$vps_iface" udp dport $SS_PORT counter dnat to $WG_PREFIX.2:$SS_PORT
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WG_IFACE" ip daddr $WG_PREFIX.2 tcp dport $SS_PORT counter masquerade
    oifname "$WG_IFACE" ip daddr $WG_PREFIX.2 udp dport $SS_PORT counter masquerade
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
  echo "direct 节点不创建公网转发规则，也不会修改其他 relay 节点。"
fi

echo "[7/8] 等待握手并验证服务"
sleep 3
ssh_openwrt "ping -c 2 -W 2 '$WG_PREFIX.1' >/dev/null" || die "家宽端无法通过 WireGuard ping VPS；检查 VPS UDP $WG_PORT 防火墙"
ssh_vps "ping -c 2 -W 2 '$WG_PREFIX.2' >/dev/null" || die "VPS 无法通过 WireGuard ping 家宽端"
if [[ "$home_kind" == "openwrt" ]]; then
  ssh_openwrt "ubus call service list '{\"name\":\"$XRAY_SERVICE\"}' | grep -q '\"running\": true'" || die "家宽端 SS2022 服务未运行"
else
  ssh_openwrt "systemctl is-active --quiet '$XRAY_SERVICE.service'" || die "家宽端 SS2022 服务未运行"
fi

echo "[8/8] 登记线路并完成"

if [[ "$MODE" == "relay" ]]; then
  ss_host="$VPS_PUBLIC_HOST"
else
  ss_host="$WG_PREFIX.2"
fi
ss_endpoint="$ss_host:$SS_PORT"
ss_userinfo="$(base64url_value "2022-blake3-aes-256-gcm:$ss_password")"
encoded_name="$(urlencode "$DISPLAY_NAME")"
ss_link="ss://$ss_userinfo@$ss_endpoint#$encoded_name"

cat >"$TMP_DIR/xray-outbound.json" <<EOF
{
  "tag": "home-$NODE_ID",
  "protocol": "shadowsocks",
  "settings": {
    "address": "$ss_host",
    "port": $SS_PORT,
    "method": "2022-blake3-aes-256-gcm",
    "password": "$ss_password"
  }
}
EOF

cat >"$TMP_DIR/node.conf" <<EOF
NODE_ID=$NODE_ID
DISPLAY_NAME_B64=$(base64_value "$DISPLAY_NAME")
MODE=$MODE
WG_INTERFACE=$WG_IFACE
WG_PORT=$WG_PORT
WG_PREFIX=$WG_PREFIX
SS_PORT=$SS_PORT
SS_ENDPOINT=$ss_endpoint
SS_LINK_B64=$(base64_value "$ss_link")
XRAY_OUTBOUND_B64=$(base64_value "$(cat "$TMP_DIR/xray-outbound.json")")
EOF
chmod 600 "$TMP_DIR/node.conf"

scp_vps "$SCRIPT_DIR/wg-home-manager.sh" /tmp/wg-home-manager
scp_vps "$SCRIPT_DIR/wg-home-deploy.sh" /tmp/volwg-deploy
scp_vps "$SCRIPT_DIR/wg-home-key-wizard.sh" /tmp/volwg-key-wizard
scp_vps "$SCRIPT_DIR/volwg" /tmp/volwg-launcher
scp_vps "$SCRIPT_DIR/VERSION" /tmp/volwg-version
scp_vps "$TMP_DIR/node.conf" "/tmp/$NODE_ID.conf"
ssh_vps "set -eu; install -d -m 755 /usr/local/lib/volwg /usr/local/bin; install -m 700 /tmp/volwg-deploy /usr/local/lib/volwg/wg-home-deploy.sh; install -m 700 /tmp/volwg-key-wizard /usr/local/lib/volwg/wg-home-key-wizard.sh; install -m 700 /tmp/wg-home-manager /usr/local/lib/volwg/wg-home-manager.sh; install -m 644 /tmp/volwg-version /usr/local/lib/volwg/VERSION; install -m 755 /tmp/volwg-launcher /usr/local/bin/volwg; install -m 755 /tmp/wg-home-manager /usr/local/sbin/wg-home-manager; install -d -m 700 /etc/wg-home-exit/nodes; install -m 600 '/tmp/$NODE_ID.conf' '/etc/wg-home-exit/nodes/$NODE_ID.conf'; rm -f /tmp/wg-home-manager /tmp/volwg-deploy /tmp/volwg-key-wizard /tmp/volwg-launcher /tmp/volwg-version '/tmp/$NODE_ID.conf'"

echo
echo "线路名称：$DISPLAY_NAME"
echo "节点 ID：$NODE_ID"
echo "加密方式：2022-blake3-aes-256-gcm"
echo "密码：$ss_password"
echo "SS 地址：$ss_endpoint"
echo "SS2022 链接："
echo "$ss_link"
if [[ "$MODE" == "direct" ]]; then
  echo "注意：direct 链接使用 WireGuard 私网地址，只能在该 VPS/WireGuard 网络内使用。"
fi
echo
echo "Xray outbound（每条线路独立 tag，不含负载均衡）："
cat "$TMP_DIR/xray-outbound.json"
echo
echo "旧版 Xray 若提示 0 Shadowsocks server configured，请改用 settings.servers："
cat <<EOF
{
  "tag": "home-$NODE_ID",
  "protocol": "shadowsocks",
  "settings": {
    "servers": [
      {
        "address": "$ss_host",
        "port": $SS_PORT,
        "method": "2022-blake3-aes-256-gcm",
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
if [[ "$MODE" == "relay" ]]; then
  echo
  echo "注意：确认 VPS 防火墙允许 $WG_PORT/UDP 和 $SS_PORT/TCP+UDP。"
fi
