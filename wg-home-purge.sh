#!/usr/bin/env bash
set -Eeuo pipefail

ASSUME_YES="0"
UNINSTALL="0"

usage() {
  cat <<'EOF'
用法：
  volwg purge [--yes] [--uninstall]

作用：
  - 停止并清理本机全部 VolWG wgh_* 线路、SS2022 和 nftables 服务。
  - 清理 /etc/wg-home-exit 中的线路记录与旧删除记录。
  - 清理旧版 VolWG wg-home 接口和已知旧版服务。
  - 默认保留 VolWG 程序，便于清空后重新测试。
  - --uninstall 同时卸载 VolWG 命令和程序文件。

保护：
  - 不处理 wg-id 或其他非 VolWG 命名的 WireGuard 接口。
  - 文件移动到备份目录，不永久擦除。
  - 需要在 VPS 和家宽机上分别执行一次。
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --yes) ASSUME_YES="1"; shift ;;
    --uninstall) UNINSTALL="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ "$(id -u)" == "0" ]] || die "清理配置需要 root，请使用 sudo"

SYSTEM_KIND="linux"
if command -v uci >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
  SYSTEM_KIND="openwrt"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"
if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
  BACKUP_DIR="/root/volwg-backups/$timestamp"
else
  BACKUP_DIR="/var/backups/volwg/$timestamp"
fi

declare -a NODE_IDS=()
add_node_id() {
  local candidate="$1" existing
  [[ "$candidate" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || return 0
  for existing in "${NODE_IDS[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  NODE_IDS+=("$candidate")
}

shopt -s nullglob
for state_file in /etc/wg-home-exit/nodes/*.conf /etc/wg-home-exit/manual/*.conf; do
  state_id="$(sed -n 's/^NODE_ID=//p' "$state_file" | head -n 1)"
  [[ -n "$state_id" ]] || state_id="$(basename "$state_file" .conf)"
  add_node_id "$state_id"
done
for wg_file in /etc/wireguard/wgh_*.conf; do
  state_id="${wg_file##*/wgh_}"
  add_node_id "${state_id%.conf}"
done

echo "============================================================"
echo " VolWG 清空旧配置与安装记录"
echo "============================================================"
echo "系统：$SYSTEM_KIND"
echo "检测到 VolWG 节点：${#NODE_IDS[@]} 条"
if ((${#NODE_IDS[@]} > 0)); then
  index=1
  for node_id in "${NODE_IDS[@]}"; do
    echo "  $index) $node_id"
    ((index++))
  done
fi
if [[ -e /etc/wireguard/wg-home.conf ]] || ip link show wg-home >/dev/null 2>&1; then
  echo "检测到旧版接口：wg-home"
fi
echo
echo "将清理：VolWG 节点、服务、线路记录及旧版 wg-home。"
echo "不会清理：wg-id 和其他非 VolWG WireGuard 接口。"
if [[ "$UNINSTALL" == "1" ]]; then
  echo "VolWG 程序：同时卸载"
else
  echo "VolWG 程序：保留（清理后可直接重新测试）"
fi
echo "备份目录：$BACKUP_DIR"
echo

if [[ "$ASSUME_YES" != "1" ]]; then
  read -r -p "输入 PURGE 确认清空本机 VolWG 配置：" confirmation
  [[ "$confirmation" == "PURGE" ]] || die "已取消"
fi

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
archived_count=0

archive_item() {
  local source="$1" destination
  [[ -e "$source" || -L "$source" ]] || return 0
  destination="$BACKUP_DIR$source"
  mkdir -p "$(dirname "$destination")"
  mv "$source" "$destination"
  ((archived_count++)) || true
}

stop_systemd() {
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl disable --now "$1" >/dev/null 2>&1 || true
}

echo "正在停止 VolWG 节点服务..."
for node_id in "${NODE_IDS[@]}"; do
  iface="wgh_$node_id"
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    if [[ -x "/etc/init.d/wgh-wan-$node_id" ]]; then
      "/etc/init.d/wgh-wan-$node_id" stop >/dev/null 2>&1 || true
      "/etc/init.d/wgh-wan-$node_id" disable >/dev/null 2>&1 || true
    fi
    archive_item "/etc/init.d/wgh-wan-$node_id"
    archive_item "/etc/wg-home-exit/wan-follow/$node_id.conf"
    for init_name in "ssrust-wgh-$node_id" "xray-wgh-$node_id"; do
      if [[ -x "/etc/init.d/$init_name" ]]; then
        "/etc/init.d/$init_name" stop >/dev/null 2>&1 || true
        "/etc/init.d/$init_name" disable >/dev/null 2>&1 || true
      fi
      archive_item "/etc/init.d/$init_name"
    done
    ifdown "$iface" >/dev/null 2>&1 || true
    uci -q delete "network.${iface}_vps" || true
    uci -q delete "network.$iface" || true
    uci -q delete "firewall.fw_$node_id" || true
    uci -q delete "firewall.allow_ping_$node_id" || true
    uci -q delete "firewall.allow_ss_$node_id" || true
    uci -q delete "firewall.allow_ssh_$node_id" || true
    uci -q delete "dropbear.volwg_$node_id" || true
  else
    stop_systemd "wg-quick@$iface.service"
    stop_systemd "wgh-nft-$node_id.service"
    stop_systemd "ssrust-wgh-$node_id.service"
    stop_systemd "xray-wgh-$node_id.service"
    stop_systemd "wgh-input-$node_id.service"
    command -v nft >/dev/null 2>&1 && nft list table ip "$iface" >/dev/null 2>&1 && nft delete table ip "$iface" || true
    ip link del "$iface" >/dev/null 2>&1 || true
    archive_item "/etc/systemd/system/wgh-nft-$node_id.service"
    archive_item "/etc/systemd/system/ssrust-wgh-$node_id.service"
    archive_item "/etc/systemd/system/xray-wgh-$node_id.service"
    archive_item "/etc/systemd/system/wgh-input-$node_id.service"
    archive_item "/usr/local/sbin/wgh-nft-$node_id"
    archive_item "/usr/local/sbin/wgh-input-$node_id"
  fi
  archive_item "/etc/wireguard/$iface.conf"
  archive_item "/etc/wireguard/$iface.key"
  archive_item "/etc/wireguard/$iface.pub"
  archive_item "/etc/wg-home-exit/ssh/${node_id}_ed25519"
  archive_item "/etc/wg-home-exit/ssh/${node_id}_ed25519.pub"
  archive_item "/etc/ss-rust-wg-home/$node_id"
  archive_item "/etc/xray-wg-home/$node_id"
done

echo "正在清理旧版 wg-home..."
if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
  ifdown wg-home >/dev/null 2>&1 || true
  uci -q delete network.wg-home_vps || true
  uci -q delete network.wg-home || true
  uci -q delete network.wg_home_vps || true
  uci -q delete network.wg_home || true
  uci -q delete firewall.fw_wg_home || true
  uci commit network
  uci commit firewall
  uci commit dropbear 2>/dev/null || true
  /etc/init.d/network reload >/dev/null 2>&1 || true
  /etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true
  /etc/init.d/dropbear reload >/dev/null 2>&1 || true
  for legacy_init in /etc/init.d/xray-wg-home /etc/init.d/ssrust-wg-home; do
    if [[ -x "$legacy_init" ]]; then
      "$legacy_init" stop >/dev/null 2>&1 || true
      "$legacy_init" disable >/dev/null 2>&1 || true
    fi
    archive_item "$legacy_init"
  done
else
  stop_systemd wg-quick@wg-home.service
  stop_systemd wg-home-nft.service
  stop_systemd xray-wg-home.service
  stop_systemd ssrust-wg-home.service
  ip link del wg-home >/dev/null 2>&1 || true
  if command -v nft >/dev/null 2>&1; then
    nft list table ip wg_home >/dev/null 2>&1 && nft delete table ip wg_home || true
    nft list table ip wg-home >/dev/null 2>&1 && nft delete table ip wg-home || true
  fi
  archive_item /etc/systemd/system/wg-home-nft.service
  archive_item /etc/systemd/system/xray-wg-home.service
  archive_item /etc/systemd/system/ssrust-wg-home.service
  archive_item /usr/local/sbin/wg-home-nft
fi
archive_item /etc/wireguard/wg-home.conf
archive_item /etc/wireguard/wg-home.key
archive_item /etc/wireguard/wg-home.pub
archive_item /etc/ss-rust-wg-home
archive_item /etc/xray-wg-home
archive_item /usr/local/bin/wg-home-ssserver
archive_item /usr/local/bin/wg-home-xray-core

# 将所有线路记录（包括旧 removed 记录）整体移出活动目录，获得真正干净的状态。
archive_item /etc/wg-home-exit

if [[ "$SYSTEM_KIND" == "linux" ]]; then
  systemctl daemon-reload
fi

if [[ "$UNINSTALL" == "1" ]]; then
  echo "正在卸载 VolWG 程序..."
  archive_item /usr/local/lib/volwg
  archive_item /usr/local/bin/volwg
  archive_item /usr/lib/volwg
  archive_item /usr/bin/volwg
fi

echo
echo "清理完成。归档项目：$archived_count"
echo "备份位置：$BACKUP_DIR"
if [[ "$UNINSTALL" != "1" ]]; then
  echo "VolWG 程序已保留，可以直接运行 volwg 重新部署。"
fi
echo "请在另一端也执行一次：volwg purge"
