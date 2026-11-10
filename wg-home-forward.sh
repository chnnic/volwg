#!/usr/bin/env bash
set -Eeuo pipefail

# VPS 端公网 SS 转发放行。Docker 或 ufw 会把 iptables FORWARD 默认策略设为 DROP，
# 导致 DNAT 到家宽 WireGuard 地址的 SS 流量在转发阶段被丢弃。VolWG 自己的 nft 表
# 无法覆盖其他表的 drop，因此在 DOCKER-USER（有 Docker 时）或 FORWARD 链顶部插入
# 只匹配本线路的放行规则，并以注释 volwg-<节点ID> 标记，便于更新和删除。

STATE_DIR="${WG_HOME_STATE_DIR:-/etc/wg-home-exit/nodes}"
UNIT_FILE="${VOLWG_FORWARD_UNIT:-/etc/systemd/system/volwg-forward.service}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
用法：
  volwg forward sync              按本机线路记录更新转发放行规则
  volwg forward remove --node ID  删除指定线路的放行规则
  volwg forward status            查看 FORWARD 策略与 VolWG 放行规则
  volwg forward enable            安装开机服务并立即同步（在 Docker 之后运行）

说明：
  仅在 FORWARD 默认策略为 DROP 或存在 Docker 的 DOCKER-USER 链时添加规则；
  只放行公网入口到本线路家宽 SS 端口的流量及其回包，不修改其他防火墙规则。
USAGE
}

die() {
  echo "错误：$*" >&2
  exit 1
}

field() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || return 0
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

valid_node() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]]
}

have_iptables() {
  command -v iptables >/dev/null 2>&1 && iptables -S FORWARD >/dev/null 2>&1
}

target_chain() {
  # Docker 会在每次启动时把 FORWARD 规则重排到自己的链之前，DOCKER-USER 是官方预留的用户链。
  if iptables -S DOCKER-USER >/dev/null 2>&1; then
    printf 'DOCKER-USER'
  elif iptables -S FORWARD 2>/dev/null | grep -qx -- '-P FORWARD DROP'; then
    printf 'FORWARD'
  fi
}

delete_rules() {
  # 删除带指定注释的规则；comment 为空时删除全部 volwg-* 规则。
  local node="${1:-}" chain line pattern
  local -a spec
  if [[ -n "$node" ]]; then
    pattern="--comment volwg-${node}( |\$)"
  else
    pattern='--comment volwg-[a-z0-9][a-z0-9_]{0,7}( |$)'
  fi
  for chain in DOCKER-USER FORWARD; do
    iptables -S "$chain" >/dev/null 2>&1 || continue
    while IFS= read -r line; do
      [[ "$line" == "-A $chain "* ]] || continue
      read -r -a spec <<<"${line#-A }"
      iptables -D "${spec[@]}" 2>/dev/null || true
    done < <(iptables -S "$chain" 2>/dev/null | grep -E -- "$pattern" || true)
  done
}

public_iface_for() {
  # 与 nft DNAT 规则使用同一公网网卡；表不存在时回退到默认路由网卡。
  local iface="$1" public=""
  if command -v nft >/dev/null 2>&1; then
    public="$(nft list table ip "$iface" 2>/dev/null | sed -n 's/.*iifname "\([^"]*\)".*dnat.*/\1/p' | head -n 1)"
  fi
  [[ -n "$public" ]] || public="$(ip -4 route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)"
  printf '%s' "$public"
}

add_node_rules() {
  local chain="$1" node="$2" iface="$3" home_ip="$4" port="$5" public="$6" comment="volwg-$2"
  # 倒序插入到链顶部，最终顺序为 TCP、UDP、回包。
  iptables -I "$chain" 1 -i "$iface" -o "$public" -s "$home_ip" -m conntrack --ctstate ESTABLISHED,RELATED \
    -m comment --comment "$comment" -j ACCEPT
  iptables -I "$chain" 1 -i "$public" -o "$iface" -d "$home_ip" -p udp --dport "$port" -m comment --comment "$comment" -j ACCEPT
  iptables -I "$chain" 1 -i "$public" -o "$iface" -d "$home_ip" -p tcp --dport "$port" -m comment --comment "$comment" -j ACCEPT
}

sync_rules() {
  local chain file node iface prefix port public_ss mode public added=0
  have_iptables || { echo "未检测到 iptables，跳过转发放行。"; return 0; }
  delete_rules
  chain="$(target_chain)"
  if [[ -z "$chain" ]]; then
    echo "FORWARD 默认策略为 ACCEPT 且没有 Docker，无需额外放行。"
    return 0
  fi
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    node="$(field "$file" NODE_ID)"
    valid_node "$node" || continue
    public_ss="$(field "$file" PUBLIC_SS_ENABLED)"
    if [[ -z "$public_ss" ]]; then
      mode="$(field "$file" MODE)"
      [[ "$mode" == relay ]] && public_ss=1 || public_ss=0
    fi
    [[ "$public_ss" == 1 ]] || continue
    iface="$(field "$file" WG_INTERFACE)"; iface="${iface:-wgh_$node}"
    prefix="$(field "$file" WG_PREFIX)"
    port="$(field "$file" HOME_SS_PORT)"; port="${port:-$(field "$file" SS_PORT)}"
    [[ "$iface" =~ ^[a-zA-Z0-9_.-]{1,15}$ && "$prefix" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ && "$port" =~ ^[0-9]{1,5}$ ]] || {
      echo "跳过线路 ${node}：记录缺少接口、网段或端口" >&2
      continue
    }
    public="$(public_iface_for "$iface")"
    [[ "$public" =~ ^[a-zA-Z0-9_.@-]{1,15}$ ]] || { echo "跳过线路 ${node}：无法识别公网网卡" >&2; continue; }
    add_node_rules "$chain" "$node" "$iface" "$prefix.2" "$port" "$public"
    echo "已放行线路 ${node}：$public → $iface $prefix.2:$port（$chain）"
    added=$((added + 1))
  done
  ((added > 0)) || echo "没有开放公网 SS 的线路，无需放行。"
}

show_status() {
  have_iptables || { echo "未检测到 iptables。"; return 0; }
  iptables -S FORWARD | grep -E -- '^-P FORWARD' || true
  if iptables -S DOCKER-USER >/dev/null 2>&1; then
    echo "检测到 Docker（DOCKER-USER 链）。"
  fi
  echo "VolWG 放行规则："
  { iptables -S DOCKER-USER 2>/dev/null; iptables -S FORWARD 2>/dev/null; } | grep -E -- '--comment volwg-' || echo "  （无）"
}

enable_service() {
  command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
  cat >"$UNIT_FILE" <<UNIT
[Unit]
Description=VolWG allow public SS forwarding to home lines
Wants=network-online.target
After=network-online.target docker.service ufw.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash $SCRIPT_DIR/wg-home-forward.sh sync

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 "$UNIT_FILE"
  systemctl daemon-reload
  systemctl enable volwg-forward.service >/dev/null
  sync_rules
}

main() {
  local action="${1:-status}" node=""
  [[ $# -eq 0 ]] || shift
  case "$action" in -h|--help|help) usage; return 0 ;; esac
  while (($#)); do
    case "$1" in
      --node) node="${2:-}"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  case "$action" in
    sync) sync_rules ;;
    remove)
      valid_node "$node" || die "--node 必须是 1-8 位小写字母、数字或下划线"
      have_iptables || return 0
      delete_rules "$node"
      ;;
    status) show_status ;;
    enable) enable_service ;;
    *) die "操作必须是 sync、remove、status 或 enable" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
