#!/usr/bin/env bash
set -Eeuo pipefail

NODE_ID=""
ROLE="auto"
ASSUME_YES="0"
STATE_DIR="${WG_HOME_STATE_DIR:-/etc/wg-home-exit/nodes}"

usage() {
  cat <<'EOF'
用法：
  volwg remove --node 节点ID [--role auto|vps|home] [--yes]

说明：
  - 默认自动判断当前机器是 VPS 端还是家宽端。
  - 删除前停止该节点的 WireGuard、SS2022 和防火墙服务。
  - 文件移动到 /etc/wg-home-exit/removed/时间-节点ID-角色，可恢复。
  - 在 VPS 删除只清理 VPS；仍需在对应家宽机执行相同的 remove 命令。
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --node) NODE_ID="${2:-}"; shift 2 ;;
    --role) ROLE="${2:-}"; shift 2 ;;
    --yes) ASSUME_YES="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ "$(id -u)" == "0" ]] || die "删除线路需要 root，请使用 sudo"
[[ "$NODE_ID" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "--node 必须是 1-8 位小写字母、数字或下划线"
[[ "$ROLE" == "auto" || "$ROLE" == "vps" || "$ROLE" == "home" ]] || die "--role 必须是 auto、vps 或 home"

WG_IFACE="wgh_$NODE_ID"
NFT_SERVICE="wgh-nft-$NODE_ID"
XRAY_SERVICE="xray-wgh-$NODE_ID"
SS_RUST_SERVICE="ssrust-wgh-$NODE_ID"
INPUT_SERVICE="wgh-input-$NODE_ID"
WAN_FOLLOW_SERVICE="wgh-wan-$NODE_ID"
MANUAL_STATE="/etc/wg-home-exit/manual/$NODE_ID.conf"
NODE_STATE="$STATE_DIR/$NODE_ID.conf"
SYSTEM_KIND="linux"
if command -v uci >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
  SYSTEM_KIND="openwrt"
fi

manual_role=""
if [[ -r "$MANUAL_STATE" ]]; then
  manual_role="$(sed -n 's/^ROLE=//p' "$MANUAL_STATE" | head -n 1)"
fi

if [[ "$ROLE" == "auto" ]]; then
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    ROLE="home"
  elif [[ "$manual_role" == "vps" || "$manual_role" == "home" ]]; then
    ROLE="$manual_role"
  elif [[ -e "$NODE_STATE" || -e "/etc/systemd/system/$NFT_SERVICE.service" || -e "/usr/local/sbin/$NFT_SERVICE" ]]; then
    ROLE="vps"
  elif [[ -e "/etc/systemd/system/$SS_RUST_SERVICE.service" || -e "/etc/systemd/system/$XRAY_SERVICE.service" || \
          -d "/etc/ss-rust-wg-home/$NODE_ID" || -d "/etc/xray-wg-home/$NODE_ID" ]]; then
    ROLE="home"
  else
    die "无法判断节点 $NODE_ID 在本机的角色；请检查节点 ID，或明确使用 --role vps/home"
  fi
fi

echo "============================================================"
echo " VolWG 删除线路"
echo "============================================================"
echo "节点 ID：$NODE_ID"
echo "本机角色：$ROLE"
echo "WireGuard 接口：$WG_IFACE"
echo "操作：停止并移除本机该节点的 WireGuard、SS/转发服务和管理记录"
echo "保护：文件先归档，不永久擦除"
echo "其他节点不会被修改。"
echo

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "请输入节点 ID [$NODE_ID] 确认删除：" confirmation
  [[ "$confirmation" == "$NODE_ID" ]] || die "确认内容不匹配，已取消"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_DIR="/etc/wg-home-exit/removed/$timestamp-$NODE_ID-$ROLE"
mkdir -p "$ARCHIVE_DIR"
chmod 700 "$ARCHIVE_DIR"
archived_count=0

archive_item() {
  local source="$1" destination
  [[ -e "$source" || -L "$source" ]] || return 0
  destination="$ARCHIVE_DIR$source"
  mkdir -p "$(dirname "$destination")"
  mv -- "$source" "$destination"
  ((archived_count++)) || true
}

stop_systemd_service() {
  local service="$1"
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl disable --now "$service.service" >/dev/null 2>&1 || true
}

if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
  if [[ -x "/etc/init.d/$WAN_FOLLOW_SERVICE" ]]; then
    "/etc/init.d/$WAN_FOLLOW_SERVICE" stop >/dev/null 2>&1 || true
    "/etc/init.d/$WAN_FOLLOW_SERVICE" disable >/dev/null 2>&1 || true
  fi
  for init_script in "/etc/init.d/$SS_RUST_SERVICE" "/etc/init.d/$XRAY_SERVICE"; do
    if [[ -x "$init_script" ]]; then
      "$init_script" stop >/dev/null 2>&1 || true
      "$init_script" disable >/dev/null 2>&1 || true
    fi
  done
  ifdown "$WG_IFACE" >/dev/null 2>&1 || true
  uci -q delete "network.${WG_IFACE}_vps" || true
  uci -q delete "network.$WG_IFACE" || true
  uci -q delete "firewall.fw_$NODE_ID" || true
  uci -q delete "firewall.allow_ping_$NODE_ID" || true
  uci -q delete "firewall.allow_ss_$NODE_ID" || true
  uci -q delete "firewall.allow_ssh_$NODE_ID" || true
  uci -q delete "dropbear.volwg_$NODE_ID" || true
  uci commit network
  uci commit firewall
  uci commit dropbear 2>/dev/null || true
  archive_item "/etc/init.d/$SS_RUST_SERVICE"
  archive_item "/etc/init.d/$XRAY_SERVICE"
  archive_item "/etc/init.d/$WAN_FOLLOW_SERVICE"
  archive_item "/etc/wg-home-exit/wan-follow/$NODE_ID.conf"
  archive_item "/etc/wireguard/$WG_IFACE.conf"
  archive_item "/etc/wireguard/$WG_IFACE.key"
  archive_item "/etc/wireguard/$WG_IFACE.pub"
  archive_item "/etc/wg-home-exit/ssh/${NODE_ID}_ed25519"
  archive_item "/etc/wg-home-exit/ssh/${NODE_ID}_ed25519.pub"
  archive_item "/etc/ss-rust-wg-home/$NODE_ID"
  archive_item "/etc/xray-wg-home/$NODE_ID"
  archive_item "$MANUAL_STATE"
  /etc/init.d/network reload >/dev/null 2>&1 || true
  /etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true
  /etc/init.d/dropbear reload >/dev/null 2>&1 || true
else
  if [[ "$ROLE" == "vps" ]]; then
    stop_systemd_service "$NFT_SERVICE"
    stop_systemd_service "wg-quick@$WG_IFACE"
    if command -v nft >/dev/null 2>&1; then
      nft list table ip "$WG_IFACE" >/dev/null 2>&1 && nft delete table ip "$WG_IFACE" || true
    fi
    archive_item "/etc/systemd/system/$NFT_SERVICE.service"
    archive_item "/usr/local/sbin/$NFT_SERVICE"
    archive_item "$NODE_STATE"
  else
    stop_systemd_service "$INPUT_SERVICE"
    stop_systemd_service "$SS_RUST_SERVICE"
    stop_systemd_service "$XRAY_SERVICE"
    stop_systemd_service "wg-quick@$WG_IFACE"
    archive_item "/etc/systemd/system/$INPUT_SERVICE.service"
    archive_item "/usr/local/sbin/$INPUT_SERVICE"
    archive_item "/etc/systemd/system/$SS_RUST_SERVICE.service"
    archive_item "/etc/systemd/system/$XRAY_SERVICE.service"
    archive_item "/etc/ss-rust-wg-home/$NODE_ID"
    archive_item "/etc/xray-wg-home/$NODE_ID"
  fi
  ip link del "$WG_IFACE" >/dev/null 2>&1 || true
  archive_item "/etc/wireguard/$WG_IFACE.conf"
  archive_item "/etc/wireguard/$WG_IFACE.key"
  archive_item "/etc/wireguard/$WG_IFACE.pub"
  archive_item "/etc/wg-home-exit/ssh/${NODE_ID}_ed25519"
  archive_item "/etc/wg-home-exit/ssh/${NODE_ID}_ed25519.pub"
  archive_item "$MANUAL_STATE"
  systemctl daemon-reload
fi

if ((archived_count == 0)); then
  rmdir "$ARCHIVE_DIR" 2>/dev/null || true
  die "没有找到节点 $NODE_ID 的本机文件；未修改其他节点"
fi

echo
echo "本机线路已删除：$NODE_ID"
echo "已归档 $archived_count 个文件/目录：$ARCHIVE_DIR"
echo "其他节点未修改。"
if [[ "$ROLE" == "vps" ]]; then
  echo
  echo "还需要在对应家宽机执行："
  echo "  volwg remove --node $NODE_ID --role home"
fi
