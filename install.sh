#!/usr/bin/env bash
set -Eeuo pipefail

REPO_RAW_URL="https://raw.githubusercontent.com/chnnic/wg-home-exit/main"
TMP_DIR="$(mktemp -d)"
umask 077

cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

download() {
  local url="$1" destination="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 "$url" -o "$destination"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$destination" "$url"
  else
    echo "错误：需要 curl 或 wget" >&2
    exit 1
  fi
}

echo "正在下载 WG Home Exit 部署向导..."
download "$REPO_RAW_URL/wg-home-deploy.sh" "$TMP_DIR/wg-home-deploy.sh"
download "$REPO_RAW_URL/wg-home-key-wizard.sh" "$TMP_DIR/wg-home-key-wizard.sh"
chmod 700 "$TMP_DIR/wg-home-deploy.sh" "$TMP_DIR/wg-home-key-wizard.sh"

bash "$TMP_DIR/wg-home-deploy.sh" "$@"
