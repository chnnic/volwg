#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")/.." && pwd)"
# shellcheck source=../wg-home-wan-follow.sh
source "$ROOT_DIR/wg-home-wan-follow.sh"

assert_equal() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s: expected <%s>, got <%s>\n' "$3" "$2" "$1" >&2
    exit 1
  fi
}

reset_mocks() {
  NODE_ID=line1 WG_IFACE=wgh_line1 VPS_ENDPOINT=198.51.100.10 VPS_WG_PORT=51830
  LAST_EGRESS="" LAST_RX="" LAST_RECOVERY=-60 FAILURES=0 PING_CONFIRMED=0
  PENDING_EGRESS_CHANGE=0
  MOCK_UP=1 MOCK_PING=1 MOCK_RX=100 MOCK_PING_RX=0 MOCK_NOW=1000 MOCK_KEEPALIVE=25
  MOCK_SOURCE=192.0.2.10
  MOCK_DEFAULTS="default via 192.0.2.1 dev eth1 metric 10"
  MOCK_ROUTE="198.51.100.10 via 192.0.2.1 dev eth1"
  DOWN_COUNT=0 UP_COUNT=0 PROBE_COUNT=0 ENDPOINT_COUNT=0 ROUTE_COUNT=0
  MOCK_ENDPOINT="198.51.100.10:51830" MOCK_RESOLVED="" LAST_SET_ENDPOINT="" ROUTE_TARGET=""
  MOCK_TERM_ON_DOWN=0 UP_MARKER=""
  HEALTH="" LAST_EVENT="" RECOVERING=0 RESUME_IFUP=0 STOP_REQUESTED=0
}

interface_has_carrier() { [[ "$1" != unplugged ]]; }
ip() {
  case "$*" in
    "-4 route show default") printf '%s\n' "$MOCK_DEFAULTS" ;;
    "-4 route show 198.51.100.10/32") printf '%s\n' "$MOCK_ROUTE" ;;
    "-4 route show "*/32) ;;
    "-4 route get "*)
      printf '%s dev eth1 src %s\n' "$4" "$MOCK_SOURCE" ;;
    "-4 route replace "*/32" "*)
      ROUTE_TARGET="$4"; shift 3; MOCK_ROUTE="$*"; ROUTE_COUNT=$((ROUTE_COUNT + 1)) ;;
    *) printf 'Unexpected ip command: %s\n' "$*" >&2; return 1 ;;
  esac
}
wg() {
  case "$*" in
    "show wgh_line1") [[ "$MOCK_UP" == 1 ]] ;;
    "show wgh_line1 endpoints") printf 'peer1\t%s\n' "$MOCK_ENDPOINT" ;;
    "show wgh_line1 peers") printf 'peer1\n' ;;
    "show wgh_line1 allowed-ips") printf 'peer1\t10.88.1.1/32\n' ;;
    "show wgh_line1 transfer") printf 'peer1\t%s\t123\n' "$MOCK_RX" ;;
    "show wgh_line1 persistent-keepalive") printf 'peer1\t%s\n' "$MOCK_KEEPALIVE" ;;
    "set wgh_line1 peer peer1 persistent-keepalive 5") MOCK_KEEPALIVE=5 ;;
    "set wgh_line1 peer peer1 endpoint "*)
      LAST_SET_ENDPOINT="$6"; ENDPOINT_COUNT=$((ENDPOINT_COUNT + 1)) ;;
    *) printf 'Unexpected wg command (must only touch line1): %s\n' "$*" >&2; return 1 ;;
  esac
}
uci() {
  assert_equal "$*" "-q get network.wgh_line1.proto" "UCI recovery guard"
  printf 'wireguard\n'
}
ping() {
  assert_equal "$*" "-I wgh_line1 -c 1 -W 1 10.88.1.1" "probe binds the tunnel"
  PROBE_COUNT=$((PROBE_COUNT + 1))
  MOCK_RX=$((MOCK_RX + MOCK_PING_RX))
  [[ "$MOCK_PING" == 1 ]]
}
ifdown() {
  assert_equal "$*" wgh_line1 "recovery only stops this line"
  DOWN_COUNT=$((DOWN_COUNT + 1)); MOCK_UP=0
  # 模拟升级/重启服务时，停止信号恰好落在 ifdown 与 ifup 之间。
  if [[ "$MOCK_TERM_ON_DOWN" == 1 ]]; then kill -TERM "$BASHPID"; fi
}
ifup() {
  assert_equal "$*" wgh_line1 "recovery only starts this line"
  UP_COUNT=$((UP_COUNT + 1)); MOCK_UP=1
  [[ -z "$UP_MARKER" ]] || printf 'up\n' >>"$UP_MARKER"
}
resolveip() {
  assert_equal "$*" "-4 -t 3 vps.example.com" "domain endpoint resolves IPv4"
  [[ -n "$MOCK_RESOLVED" ]] && printf '%s\n' "$MOCK_RESOLVED"
}
sleep() { :; }
logger() { :; }
monotonic_seconds() { printf '%s' "$MOCK_NOW"; }

reset_mocks
for ((i=0; i<30; i++)); do apply_route_once; done
assert_equal "$PROBE_COUNT" 30 "ongoing traffic detects invisible NAT changes"
assert_equal "$MOCK_KEEPALIVE" 5 "runtime keepalive upgraded"
assert_equal "$DOWN_COUNT" 0 "healthy line is never restarted"
assert_equal "$HEALTH" 正常 "healthy status"

MOCK_SOURCE=192.0.2.20
apply_route_once
assert_equal "$ENDPOINT_COUNT" 1 "same WAN/gateway with changed source refreshes endpoint"
assert_equal "$DOWN_COUNT" 0 "working session survives local address change"

reset_mocks
apply_route_once
MOCK_PING=0
apply_route_once
apply_route_once
assert_equal "$DOWN_COUNT" 0 "brief loss is tolerated"
apply_route_once
assert_equal "$DOWN_COUNT" 1 "three failures recover invisible CGNAT changes"
assert_equal "$UP_COUNT" 1 "one recovery starts one line"
for ((i=0; i<12; i++)); do apply_route_once; done
assert_equal "$DOWN_COUNT" 1 "cooldown prevents restart storms"
MOCK_NOW=1060
apply_route_once
assert_equal "$DOWN_COUNT" 2 "recovery retries after monotonic cooldown"
MOCK_PING=1
apply_route_once
assert_equal "$FAILURES" 0 "successful probe clears failures"
assert_equal "$HEALTH" 正常 "recovered status"

reset_mocks
apply_route_once
MOCK_PING=0 MOCK_PING_RX=32
for ((i=0; i<5; i++)); do apply_route_once; done
assert_equal "$DOWN_COUNT" 0 "authenticated traffic protects ICMP-filtered line"
assert_equal "$HEALTH" "有隧道回包（Ping 无响应）" "RX overrides missing Ping"
MOCK_PING_RX=0 MOCK_RX=$((MOCK_RX + 50))
apply_route_once
assert_equal "$FAILURES" 0 "traffic between probes also counts"

reset_mocks
MOCK_PING=0
for ((i=0; i<8; i++)); do apply_route_once; done
assert_equal "$DOWN_COUNT" 0 "unknown ICMP policy does not cause endless resets"

reset_mocks
apply_route_once
MOCK_PING=0
apply_route_once
apply_route_once
MOCK_PING=1
apply_route_once
assert_equal "$DOWN_COUNT" 0 "two lost probes do not reset a recovered line"

reset_mocks
apply_route_once
MOCK_DEFAULTS=$'default via 192.0.2.1 dev unplugged metric 1\ndefault via 198.18.0.1 dev wwan0 metric 20'
MOCK_SOURCE=198.18.0.2
apply_route_once
assert_equal "$ROUTE_COUNT" 1 "unplugged WAN switches to available 5G route"
assert_equal "$LAST_EGRESS" "wwan0|198.18.0.1|198.18.0.2" "new egress signature"
assert_equal "$DOWN_COUNT" 0 "healthy WAN switch does not restart WG"

reset_mocks
MOCK_ROUTE="198.51.100.10 via 192.0.2.1 dev eth10"
apply_route_once
assert_equal "$ROUTE_COUNT" 1 "device matching is exact, not eth1 versus eth10"
MOCK_DEFAULTS="default dev pppoe-wan metric 0"
apply_route_once
assert_equal "$MOCK_ROUTE" "198.51.100.10/32 dev pppoe-wan metric 0" "PPP removes old gateway"

reset_mocks
MOCK_UP=0
apply_route_once
assert_equal "$UP_COUNT" 0 "manual pause must not be undone"
assert_equal "$PROBE_COUNT" 0 "paused interface is not probed"
assert_equal "$HEALTH" "接口未运行，等待手动启动" "paused status"

reset_mocks
MOCK_DEFAULTS=""
apply_route_once
assert_equal "$DOWN_COUNT" 0 "no WAN does not trigger useless resets"
assert_equal "$HEALTH" "等待 WAN 联网" "offline status"

# 域名 endpoint 的 VPS 换 IP：恢复后必须使用重新解析的新地址，不能写回缓存的旧 IP。
reset_mocks
VPS_ENDPOINT=vps.example.com MOCK_RESOLVED=198.51.100.20 PING_CONFIRMED=1
MOCK_PING=0
for ((i=0; i<3; i++)); do apply_route_once; done
assert_equal "$DOWN_COUNT" 1 "dead domain endpoint triggers one recovery"
assert_equal "$LAST_SET_ENDPOINT" "198.51.100.20:51830" "recovery uses re-resolved VPS address"
assert_equal "$ROUTE_TARGET" "198.51.100.20/32" "endpoint route follows the new VPS address"

# 停止信号落在 ifdown 与 ifup 之间：必须先完成 ifup 再退出，不能把线路留在停用状态。
(
  reset_mocks
  PING_CONFIRMED=1 MOCK_PING=0 MOCK_TERM_ON_DOWN=1
  UP_MARKER="$(mktemp)"
  # shellcheck disable=SC2064 # Expand the marker path now.
  trap "rm -f '$UP_MARKER'" EXIT
  (
    trap 'exit 0' TERM INT  # 与守护进程 acquire_lock 设置的处理方式相同
    for ((i=0; i<3; i++)); do apply_route_once; done
    echo "FAIL: daemon ignored the deferred stop request" >&2
    exit 1
  ) || exit 1
  assert_equal "$(cat "$UP_MARKER")" up "interrupted recovery still brings the line back up"
)

# Real filesystem checks for per-line process exclusion and RAM-state continuity.
(
  TEST_DIR="$(mktemp -d)"
  # shellcheck disable=SC2329 # Invoked by the EXIT trap.
  cleanup() { release_lock; rm -rf "$TEST_DIR"; }
  RUNTIME_ROOT="$TEST_DIR/runtime"
  STATE_ROOT="$TEST_DIR/config"
  set_paths
  trap cleanup EXIT
  # Use scripts: BusyBox dispatches symlinked true/false by the symlink name.
  printf '#!/bin/sh\nexit 0\n' >"$TEST_DIR/enabled"
  printf '#!/bin/sh\nexit 1\n' >"$TEST_DIR/disabled"
  chmod 755 "$TEST_DIR/enabled" "$TEST_DIR/disabled"
  MOCK_UP=1
  should_refresh_follow wgh_line1 "$TEST_DIR/enabled" "$TEST_DIR/missing.conf"
  if should_refresh_follow wgh_line1 "$TEST_DIR/disabled" "$TEST_DIR/missing.conf"; then
    echo 'FAIL: upgrade re-enabled a disabled service' >&2; exit 1
  fi
  should_refresh_follow wgh_line1 "$TEST_DIR/missing" "$TEST_DIR/missing.conf"
  touch "$TEST_DIR/retained.conf"
  if should_refresh_follow wgh_line1 "$TEST_DIR/missing" "$TEST_DIR/retained.conf"; then
    echo 'FAIL: upgrade re-enabled a removed service with retained config' >&2; exit 1
  fi
  MOCK_UP=0
  if should_refresh_follow wgh_line1 "$TEST_DIR/missing" "$TEST_DIR/missing.conf"; then
    echo 'FAIL: upgrade started a paused old interface' >&2; exit 1
  fi
  acquire_lock
  trap cleanup EXIT
  HEALTH="正常" LAST_RECOVERY=123 PING_CONFIRMED=1
  save_runtime
  assert_equal "$(field "$RUNTIME_FILE" HEALTH)" 正常 "runtime snapshot"
  if acquire_lock; then echo "FAIL: duplicate watcher acquired lock" >&2; exit 1; fi
  release_lock
  LAST_RECOVERY=-60 PING_CONFIRMED=0
  acquire_lock
  trap cleanup EXIT
  assert_equal "$LAST_RECOVERY" 123 "cooldown survives watcher restart"
  assert_equal "$PING_CONFIRMED" 1 "confirmed probe support survives restart"

  # 上一个进程在自动恢复中途被强制结束（RECOVERING=1）：重启后只补一次 ifup。
  release_lock
  reset_mocks
  printf 'RECOVERING=1\nLAST_RECOVERY=123\n' >"$RUNTIME_FILE"
  acquire_lock
  trap cleanup EXIT
  MOCK_UP=0
  apply_route_once
  assert_equal "$UP_COUNT" 1 "killed recovery is completed after restart"
  assert_equal "$HEALTH" "已重新启动，等待隧道回包" "resume status"
  save_runtime
  assert_equal "$(field "$RUNTIME_FILE" RECOVERING)" 0 "resume marker cleared"
  MOCK_UP=0
  apply_route_once
  assert_equal "$UP_COUNT" 1 "later manual pause is still respected"
)

printf 'WAN/IP recovery tests PASS\n'
