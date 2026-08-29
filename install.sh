#!/usr/bin/env bash
set -Eeuo pipefail

REPO_REF="${VOLWG_REF:-main}"
REPO_RAW_URL="https://raw.githubusercontent.com/chnnic/volwg/$REPO_REF"
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

# 安装器可能由正在运行的 volwg 自身调用。不能直接 cp 覆盖入口脚本，
# 否则 Bash 继续读取被截断/重写的文件时可能从错误偏移处解析后续内容。
atomic_install() {
  local source="$1" destination="$2" mode="$3" temporary
  temporary="$(mktemp "${destination}.tmp.XXXXXX")"
  if cp -- "$source" "$temporary" \
    && chmod "$mode" "$temporary" \
    && mv -f -- "$temporary" "$destination"; then
    return 0
  fi
  rm -f -- "$temporary"
  return 1
}

echo "正在下载 VolWG 部署向导..."
download "$REPO_RAW_URL/wg-home-deploy.sh" "$TMP_DIR/wg-home-deploy.sh"
download "$REPO_RAW_URL/wg-home-key-wizard.sh" "$TMP_DIR/wg-home-key-wizard.sh"
download "$REPO_RAW_URL/wg-home-manager.sh" "$TMP_DIR/wg-home-manager.sh"
download "$REPO_RAW_URL/wg-home-remove.sh" "$TMP_DIR/wg-home-remove.sh"
download "$REPO_RAW_URL/wg-home-purge.sh" "$TMP_DIR/wg-home-purge.sh"
download "$REPO_RAW_URL/wg-home-wan-follow.sh" "$TMP_DIR/wg-home-wan-follow.sh"
download "$REPO_RAW_URL/volwg" "$TMP_DIR/volwg"
download "$REPO_RAW_URL/VERSION" "$TMP_DIR/VERSION"
chmod 700 "$TMP_DIR/wg-home-deploy.sh" "$TMP_DIR/wg-home-key-wizard.sh" "$TMP_DIR/wg-home-manager.sh" "$TMP_DIR/wg-home-remove.sh" "$TMP_DIR/wg-home-purge.sh" "$TMP_DIR/wg-home-wan-follow.sh"
chmod 755 "$TMP_DIR/volwg"

if [[ "${VOLWG_TEMPORARY:-0}" == "1" ]]; then
  "$TMP_DIR/volwg" "$@"
  exit
fi

if [[ -n "${VOLWG_INSTALL_LIB_DIR:-}" && -n "${VOLWG_INSTALL_BIN_DIR:-}" ]]; then
  INSTALL_LIB_DIR="$VOLWG_INSTALL_LIB_DIR"
  INSTALL_BIN_DIR="$VOLWG_INSTALL_BIN_DIR"
elif [[ "$(id -u)" == "0" && -f /etc/openwrt_release ]]; then
  INSTALL_LIB_DIR="/usr/lib/volwg"
  INSTALL_BIN_DIR="/usr/bin"
elif [[ "$(id -u)" == "0" ]]; then
  INSTALL_LIB_DIR="/usr/local/lib/volwg"
  INSTALL_BIN_DIR="/usr/local/bin"
else
  INSTALL_LIB_DIR="${XDG_DATA_HOME:-${HOME:?}/.local/share}/volwg"
  INSTALL_BIN_DIR="${HOME:?}/.local/bin"
fi

mkdir -p "$INSTALL_LIB_DIR" "$INSTALL_BIN_DIR"
for component in wg-home-deploy.sh wg-home-key-wizard.sh wg-home-manager.sh wg-home-remove.sh wg-home-purge.sh wg-home-wan-follow.sh; do
  atomic_install "$TMP_DIR/$component" "$INSTALL_LIB_DIR/$component" 700
done
atomic_install "$TMP_DIR/VERSION" "$INSTALL_LIB_DIR/VERSION" 644
# 最后原子替换入口，让新入口出现时依赖文件已经全部就绪。
atomic_install "$TMP_DIR/volwg" "$INSTALL_BIN_DIR/volwg" 755

echo "VolWG 已安装：$INSTALL_BIN_DIR/volwg"
if [[ ":$PATH:" != *":$INSTALL_BIN_DIR:"* ]]; then
  if [[ "$(id -u)" != "0" ]]; then
    case "${SHELL:-}" in
      */zsh) SHELL_RC="${HOME:?}/.zshrc" ;;
      */bash) SHELL_RC="${HOME:?}/.bashrc" ;;
      *) SHELL_RC="${HOME:?}/.profile" ;;
    esac
    # 保留字面量，让新 shell 启动时再展开 HOME 和 PATH。
    # shellcheck disable=SC2016
    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [[ ! -f "$SHELL_RC" ]] || ! grep -Fqx "$PATH_LINE" "$SHELL_RC"; then
      printf '\n%s\n' "$PATH_LINE" >>"$SHELL_RC"
    fi
    echo "已把 ${INSTALL_BIN_DIR} 加入 ${SHELL_RC}，新开终端后可直接输入 volwg。"
  else
    echo "提示：$INSTALL_BIN_DIR 不在当前 PATH，请把它加入 shell 的 PATH。"
  fi
fi
echo
if [[ "${VOLWG_NO_LAUNCH:-0}" == "1" ]]; then
  exit
fi
"$INSTALL_BIN_DIR/volwg" "$@"
