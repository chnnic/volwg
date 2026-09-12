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
  HEALTH="" LAST_EVENT=""
}

interface_has_carrier() { [[ "$1" != unplugged ]]; }
ip() {
  case "$*" in
    "-4 route show default") printf '%s\n' "$MOCK_DEFAULTS" ;;
    "-4 route show 198.51.100.10/32") printf '%s\n' "$MOCK_ROUTE" ;;
    "-4 route get 198.51.100.10")
      printf '198.51.100.10 dev eth1 src %s\n' "$MOCK_SOURCE" ;;
    "-4 route replace 198.51.100.10/32 "*)
      shift 3; MOCK_ROUTE="$*"; ROUTE_COUNT=$((ROUTE_COUNT + 1)) ;;
    *) printf 'Unexpected ip command: %s\n' "$*" >&2; return 1 ;;
  esac
}
wg() {
  case "$*" in
    "show wgh_line1") [[ "$MOCK_UP" == 1 ]] ;;
    "show wgh_line1 endpoints") printf 'peer1\t198.51.100.10:51830\n' ;;
    "show wgh_line1 peers") printf 'peer1\n' ;;
    "show wgh_line1 allowed-ips") printf 'peer1\t10.88.1.1/32\n' ;;
    "show wgh_line1 transfer") printf 'peer1\t%s\t123\n' "$MOCK_RX" ;;
    "show wgh_line1 persistent-keepalive") printf 'peer1\t%s\n' "$MOCK_KEEPALIVE" ;;
    "set wgh_line1 peer peer1 persistent-keepalive 5") MOCK_KEEPALIVE=5 ;;
    "set wgh_line1 peer peer1 endpoint 198.51.100.10:51830")
      ENDPOINT_COUNT=$((ENDPOINT_COUNT + 1)) ;;
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
}
ifup() {
  assert_equal "$*" wgh_line1 "recovery only starts this line"
  UP_COUNT=$((UP_COUNT + 1)); MOCK_UP=1
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
)

printf 'WAN/IP recovery tests PASS\n'
