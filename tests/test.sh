#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/nodes" "$TEST_DIR/manual"
full_name="$(printf '%s' '主线路' | base64 | tr -d '\r\n')"
manual_name="$(printf '%s' '备用家宽' | base64 | tr -d '\r\n')"

printf '%s\n' \
  'NODE_ID=line1' \
  "DISPLAY_NAME_B64=$full_name" \
  'MODE=relay' \
  'HOME_BACKEND=ss-rust' \
  'WG_INTERFACE=wgh_line1' \
  'SS_ENDPOINT=198.51.100.10:31000' \
  >"$TEST_DIR/nodes/line1.conf"

printf '%s\n' \
  'NODE_ID=home2' \
  "DISPLAY_NAME_B64=$manual_name" \
  'ROLE=vps' \
  'WG_INTERFACE=wgh_home2' \
  'WG_PREFIX=10.88.2' \
  >"$TEST_DIR/manual/home2.conf"

manager_output="$(WG_HOME_STATE_DIR="$TEST_DIR/nodes" WG_HOME_MANUAL_STATE_DIR="$TEST_DIR/manual" bash "$ROOT_DIR/wg-home-manager.sh" list)"
grep -Fq 'line1' <<<"$manager_output"
grep -Fq '主线路' <<<"$manager_output"
grep -Fq 'home2' <<<"$manager_output"
grep -Fq '备用家宽' <<<"$manager_output"
grep -Fq 'WG-only' <<<"$manager_output"

grep -Fq -- '--node ID' < <(bash "$ROOT_DIR/wg-home-key-wizard.sh" --help)
grep -Fq '自动向后寻找可用端口' < <(bash "$ROOT_DIR/wg-home-key-wizard.sh" --help)
grep -Fq 'volwg remove --node' < <(bash "$ROOT_DIR/wg-home-remove.sh" --help)
grep -Fq 'wg-home-remove.sh' "$ROOT_DIR/install.sh"
grep -Fq '完整部署：WireGuard + SS2022' "$ROOT_DIR/volwg"
grep -Fq '不安装 ss-rust' "$ROOT_DIR/volwg"
grep -Fq '当前模式：仅 WireGuard 手动配对' "$ROOT_DIR/wg-home-key-wizard.sh"
grep -Fq '组件安装位置' "$ROOT_DIR/wg-home-deploy.sh"
grep -Fq 'BUILTIN_VERSION="1.4.6"' "$ROOT_DIR/volwg"
grep -Fxq '1.4.6' "$ROOT_DIR/VERSION"

menu_output="$(printf '2\n2\n0\n0\n0\n' | "$ROOT_DIR/volwg")"
grep -Fq '此模式只会' <<<"$menu_output"
grep -Fq '不安装 ss-rust' <<<"$menu_output"
grep -Fq '需要完整家宽落地线路' <<<"$menu_output"

echo "VolWG tests: PASS"
