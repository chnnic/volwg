#!/usr/bin/env bash
set -Eeuo pipefail

ROLE=""
FULL_STACK="0"
NODE_ID=""
DISPLAY_NAME=""
WG_PREFIX="10.88.0"
VPS_WG_PORT="51830"
HOME_WG_PORT="51830"
VPS_ENDPOINT=""
VPS_SS_PORT="31000"
HOME_SS_PORT="31000"
HOME_BACKEND="ss-rust"
MODE="relay"
PUBLIC_SS_ENABLED="1"
SS_PASSWORD=""
SS_RUST_VERSION="v1.25.0"
REPLACE_NODE="0"

usage() {
  cat <<'EOF'
双 SSH 窗口多节点配对向导

完整部署（家宽机无需公网 IP，也无需允许 VPS SSH 登录）：
  sudo volwg pair --role vps
  sudo volwg pair --role home

仅 WireGuard 窗口 A（公网/优化 VPS）：
  sudo volwg key --role vps

仅 WireGuard 窗口 B（家宽机）：
  sudo volwg key --role home

两个窗口输入相同的节点 ID、线路名称、网段和端口。每个节点使用独立
WireGuard 接口、密钥和配置，默认不会覆盖其他节点。占用的本地监听端口
会自动向后寻找可用端口，并在写入前显示最终结果。

支持：
  VPS：Debian、Ubuntu
  家宽机：OpenWrt/ImmortalWrt、Debian 11/12/13、Ubuntu

选项：
  --role vps|home
  --full                  完整部署 WireGuard + SS2022；pair 命令自动添加
  --node ID               1-8 位小写字母/数字/_
  --name NAME             自定义线路显示名称
  --wg-prefix A.B.C       默认 10.88.0
  --vps-wg-port PORT      VPS 公网 UDP 起始端口，默认 51830
  --home-wg-port PORT     家宽机本地 UDP 起始端口，默认 51830
  --wg-port PORT          兼容选项：同时设置两端起始端口
  --endpoint HOST         VPS 公网 IP/域名
  --vps-ss-port PORT      VPS 公网 SS 起始端口，默认 31000
  --home-ss-port PORT     家宽机 SS2022 起始端口，默认 31000
  --ss-port PORT          兼容选项：同时设置两端 SS 起始端口
  --home-backend TYPE     家宽服务端：ss-rust（默认）或 xray
  --ss-password KEY       SS2022 AES-128 密钥；通常在双窗口间复制粘贴
  --public-ss on|off      是否在 VPS 开放公网 SS，默认 on
  --mode relay|direct     默认推荐公网或私网入口，默认 relay
  --replace               明确替换相同节点 ID；替换前自动备份
  -h, --help

说明：pair 完整模式在两台机器各自本地安装和配置，不需要两端互相 SSH。
key 模式仍然只完成 WireGuard 配对。
EOF
}

die() {
  echo "错误：$*" >&2
  exit 1
}

prompt_default() {
  local prompt="$1" default_value="$2" answer
  read -r -p "$prompt [$default_value]：" answer
  printf '%s' "${answer:-$default_value}"
}

prompt_required() {
  local prompt="$1" answer=""
  while [[ -z "$answer" ]]; do
    read -r -p "${prompt}：" answer
  done
  printf '%s' "$answer"
}

valid_wg_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

valid_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] && ((10#$port >= 1 && 10#$port <= 65535))
}

encode() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

base64url_value() {
  printf '%s' "$1" | base64 | tr '+/' '-_' | tr -d '=\r\n'
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

valid_ss_password() {
  local decoded_size
  decoded_size="$(printf '%s' "$1" | base64 -d 2>/dev/null | wc -c | tr -d '[:space:]')"
  [[ "$decoded_size" == "16" ]]
}

next_node_id() {
  local number candidate iface
  for number in {1..99}; do
    candidate="home$number"
    iface="wgh_$candidate"
    if [[ ! -e "/etc/wireguard/$iface.conf" && ! -e "/etc/wg-home-exit/manual/$candidate.conf" ]] && \
       ! ip link show "$iface" >/dev/null 2>&1 && \
       ! { command -v uci >/dev/null 2>&1 && uci -q get "network.$iface" >/dev/null 2>&1; }; then
      printf '%s' "$candidate"
      return
    fi
  done
  printf '%s' home1
}

port_in_use() {
  local port="$1" iface listen_port hex table state_file state_node field value
  local -a state_files fields
  while read -r iface; do
    [[ -n "$iface" && "$iface" != "$WG_IFACE" ]] || continue
    listen_port="$(wg show "$iface" listen-port 2>/dev/null || true)"
    [[ "$listen_port" == "$port" ]] && return 0
  done < <(wg show interfaces 2>/dev/null | tr ' ' '\n')
  printf -v hex '%04X' "$port"
  for table in /proc/net/udp /proc/net/udp6 /proc/net/tcp /proc/net/tcp6; do
    [[ -r "$table" ]] || continue
    grep -Eqi "[[:space:]][0-9A-F]+:${hex}[[:space:]]" "$table" && return 0
  done
  shopt -s nullglob
  state_files=(/etc/wg-home-exit/nodes/*.conf /etc/wg-home-exit/manual/*.conf)
  if [[ "$ROLE" == "vps" ]]; then
    fields=(VPS_WG_PORT VPS_SS_PORT WG_PORT SS_PORT)
  else
    fields=(HOME_WG_PORT HOME_SS_PORT WG_PORT SS_PORT)
  fi
  for state_file in "${state_files[@]}"; do
    state_node="$(sed -n 's/^NODE_ID=//p' "$state_file" | head -n 1)"
    [[ "$state_node" != "$NODE_ID" ]] || continue
    for field in "${fields[@]}"; do
      value="$(sed -n "s/^${field}=//p" "$state_file" | head -n 1)"
      [[ "$value" == "$port" ]] && return 0
    done
  done
  return 1
}

next_free_port() {
  local port="$1"
  valid_port "$port" || die "端口无效：$port"
  while port_in_use "$port"; do
    ((port++))
    ((port <= 65535)) || die "从指定起始值开始没有可用端口"
  done
  printf '%s' "$port"
}

detect_public_ipv4() {
  local address="" url
  for url in https://api.ipify.org https://ipv4.icanhazip.com; do
    if command -v curl >/dev/null 2>&1; then
      address="$(curl -4fsS --max-time 5 "$url" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
      address="$(wget -4qO- -T 5 "$url" 2>/dev/null || true)"
    fi
    address="${address//$'\r'/}"
    address="${address//$'\n'/}"
    if [[ "$address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf '%s' "$address"
      return
    fi
  done
  address="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)"
  [[ -n "$address" ]] && printf '%s' "$address"
}

line_exists() {
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    uci -q get "network.$WG_IFACE" >/dev/null 2>&1 || \
      [[ -e "/etc/wg-home-exit/manual/$NODE_ID.conf" ]]
  else
    [[ -e "$WG_CONFIG" || -e "/etc/wg-home-exit/manual/$NODE_ID.conf" ]]
  fi
}

check_linux_network_collision() {
  local file existing_address
  shopt -s nullglob
  for file in /etc/wireguard/wgh_*.conf; do
    [[ "$file" == "$WG_CONFIG" ]] && continue
    existing_address="$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$file" | head -n 1)"
    if [[ "$existing_address" == "$WG_PREFIX.1/24" || "$existing_address" == "$WG_PREFIX.2/24" ]]; then
      die "WireGuard 网段 $WG_PREFIX.0/24 已被 $(basename "$file" .conf) 使用，请更换网段"
    fi
  done
}

save_metadata() {
  local state_dir=/etc/wg-home-exit/manual state_file
  state_file="$state_dir/$NODE_ID.conf"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  if [[ -e "$state_file" && "$REPLACE_NODE" == "1" ]]; then
    cp "$state_file" "$state_file.before.$(date +%Y%m%d-%H%M%S)"
  fi
  cat >"$state_file" <<EOF
NODE_ID=$NODE_ID
DISPLAY_NAME_B64=$(encode "$DISPLAY_NAME")
ROLE=$ROLE
WG_INTERFACE=$WG_IFACE
WG_PREFIX=$WG_PREFIX
VPS_WG_PORT=$VPS_WG_PORT
HOME_WG_PORT=$HOME_WG_PORT
VPS_ENDPOINT=$VPS_ENDPOINT
FULL_STACK=$FULL_STACK
MODE=$MODE
PUBLIC_SS_ENABLED=$PUBLIC_SS_ENABLED
HOME_BACKEND=$HOME_BACKEND
VPS_SS_PORT=$VPS_SS_PORT
HOME_SS_PORT=$HOME_SS_PORT
EOF
  chmod 600 "$state_file"
}

install_ssrust() {
  local machine target archive base_url work_dir
  if command -v ssserver >/dev/null 2>&1; then
    return
  fi
  machine="$(uname -m)"
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    opkg update >/dev/null 2>&1 || true
    if opkg install shadowsocks-rust-ssserver >/dev/null 2>&1 && command -v ssserver >/dev/null 2>&1; then
      return
    fi
    opkg install ca-bundle curl xz >/dev/null 2>&1 || opkg install ca-bundle curl xz-utils >/dev/null 2>&1 || true
    case "$machine" in
      x86_64) target="x86_64-unknown-linux-musl" ;;
      aarch64) target="aarch64-unknown-linux-musl" ;;
      armv7l) target="armv7-unknown-linux-musleabihf" ;;
      armv6l|armv5*) target="arm-unknown-linux-musleabi" ;;
      i386|i486|i586|i686) target="i686-unknown-linux-musl" ;;
      riscv64) target="riscv64gc-unknown-linux-musl" ;;
      *) die "当前架构 $machine 无可用 ss-rust 静态包，请改选 Xray Core" ;;
    esac
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y ca-certificates curl xz-utils >/dev/null
    case "$machine" in
      x86_64) target="x86_64-unknown-linux-gnu" ;;
      aarch64) target="aarch64-unknown-linux-gnu" ;;
      armv7l) target="armv7-unknown-linux-gnueabihf" ;;
      armv6l|armv5*) target="arm-unknown-linux-gnueabi" ;;
      i386|i486|i586|i686) target="i686-unknown-linux-musl" ;;
      riscv64) target="riscv64gc-unknown-linux-gnu" ;;
      loongarch64) target="loongarch64-unknown-linux-gnu" ;;
      *) die "当前架构 $machine 不支持自动安装 ss-rust" ;;
    esac
  fi
  archive="shadowsocks-${SS_RUST_VERSION}.${target}.tar.xz"
  base_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${SS_RUST_VERSION}"
  work_dir="$(mktemp -d)"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 -o "$work_dir/$archive" "$base_url/$archive"
    curl -fL --retry 3 -o "$work_dir/$archive.sha256" "$base_url/$archive.sha256"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$work_dir/$archive" "$base_url/$archive"
    wget -O "$work_dir/$archive.sha256" "$base_url/$archive.sha256"
  else
    rm -rf -- "$work_dir"
    die "缺少 curl/wget，无法下载 ss-rust"
  fi
  (cd "$work_dir" && sha256sum -c "$archive.sha256")
  tar -xJf "$work_dir/$archive" -C "$work_dir" ssserver
  mkdir -p /usr/local/bin
  cp "$work_dir/ssserver" /usr/local/bin/ssserver
  chmod 755 /usr/local/bin/ssserver
  rm -rf -- "$work_dir"
  command -v ssserver >/dev/null 2>&1 || die "ss-rust ssserver 安装失败"
}

install_xray() {
  local xray_bin
  xray_bin="$(command -v xray 2>/dev/null || true)"
  [[ -n "$xray_bin" ]] && return
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    opkg update >/dev/null
    opkg install xray-core >/dev/null
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null
    apt-get install -y ca-certificates curl unzip >/dev/null
    curl -fL --retry 3 -o /tmp/volwg-xray-install.sh https://github.com/XTLS/Xray-install/raw/main/install-release.sh
    bash /tmp/volwg-xray-install.sh install --without-geodata
    rm -f /tmp/volwg-xray-install.sh
    systemctl disable --now xray.service >/dev/null 2>&1 || true
  fi
  command -v xray >/dev/null 2>&1 || [[ -x /usr/local/bin/xray ]] || die "Xray Core 安装失败"
}

configure_home_ss() {
  local service_name other_service backend_bin config_dir config_file
  if [[ "$HOME_BACKEND" == "ss-rust" ]]; then
    echo "[6/7] 在家宽机本地安装并配置 ss-rust ssserver"
    install_ssrust
    service_name="ssrust-wgh-$NODE_ID"
    other_service="xray-wgh-$NODE_ID"
    backend_bin="$(command -v ssserver 2>/dev/null || printf '%s' /usr/local/bin/ssserver)"
    config_dir="/etc/ss-rust-wg-home/$NODE_ID"
    config_file="$config_dir/config.json"
    mkdir -p "$config_dir"
    chmod 700 /etc/ss-rust-wg-home "$config_dir"
    cat >"$config_file" <<EOF
{
  "server": "$WG_PREFIX.2",
  "server_port": $HOME_SS_PORT,
  "password": "$SS_PASSWORD",
  "method": "2022-blake3-aes-128-gcm",
  "mode": "tcp_and_udp",
  "timeout": 300
}
EOF
  else
    echo "[6/7] 在家宽机本地安装并配置 Xray Core"
    install_xray
    service_name="xray-wgh-$NODE_ID"
    other_service="ssrust-wgh-$NODE_ID"
    backend_bin="$(command -v xray 2>/dev/null || printf '%s' /usr/local/bin/xray)"
    config_dir="/etc/xray-wg-home/$NODE_ID"
    config_file="$config_dir/config.json"
    mkdir -p "$config_dir"
    chmod 700 /etc/xray-wg-home "$config_dir"
    cat >"$config_file" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "tag": "ss2022-$NODE_ID",
    "listen": "$WG_PREFIX.2",
    "port": $HOME_SS_PORT,
    "protocol": "shadowsocks",
    "settings": {
      "network": "tcp,udp",
      "method": "2022-blake3-aes-128-gcm",
      "password": "$SS_PASSWORD"
    }
  }],
  "outbounds": [{"tag": "home-wan", "protocol": "freedom"}]
}
EOF
    "$backend_bin" run -test -c "$config_file"
  fi
  chmod 600 "$config_file"

  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    if [[ -x "/etc/init.d/$other_service" ]]; then
      "/etc/init.d/$other_service" stop >/dev/null 2>&1 || true
      "/etc/init.d/$other_service" disable >/dev/null 2>&1 || true
    fi
    cat >"/etc/init.d/$service_name" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command $backend_bin $(if [[ "$HOME_BACKEND" == "ss-rust" ]]; then printf '%s' '-c'; else printf '%s' 'run -c'; fi) $config_file
  procd_set_param respawn 3600 5 5
  procd_set_param limits nofile="1048576 1048576"
  procd_close_instance
}
EOF
    chmod 755 "/etc/init.d/$service_name"
    "/etc/init.d/$service_name" enable
    "/etc/init.d/$service_name" restart || "/etc/init.d/$service_name" start
  else
    mkdir -p /usr/local/sbin
    systemctl disable --now "$other_service.service" >/dev/null 2>&1 || true
    cat >"/etc/systemd/system/$service_name.service" <<EOF
[Unit]
Description=VolWG SS2022 home exit $NODE_ID
Requires=wg-quick@$WG_IFACE.service
After=network-online.target wg-quick@$WG_IFACE.service

[Service]
Type=simple
ExecStart=$backend_bin $(if [[ "$HOME_BACKEND" == "ss-rust" ]]; then printf '%s' '-c'; else printf '%s' 'run -c'; fi) $config_file
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    cat >"/usr/local/sbin/wgh-input-$NODE_ID" <<EOF
#!/bin/sh
set -eu
case "\${1:-start}" in
  start)
    iptables -w -C INPUT -i $WG_IFACE -p tcp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i $WG_IFACE -p tcp --dport $HOME_SS_PORT -j ACCEPT
    iptables -w -C INPUT -i $WG_IFACE -p udp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || iptables -w -I INPUT 1 -i $WG_IFACE -p udp --dport $HOME_SS_PORT -j ACCEPT
    ;;
  stop)
    iptables -w -D INPUT -i $WG_IFACE -p tcp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || true
    iptables -w -D INPUT -i $WG_IFACE -p udp --dport $HOME_SS_PORT -j ACCEPT 2>/dev/null || true
    ;;
esac
EOF
    chmod 700 "/usr/local/sbin/wgh-input-$NODE_ID"
    cat >"/etc/systemd/system/wgh-input-$NODE_ID.service" <<EOF
[Unit]
Description=Allow VolWG SS2022 input for $NODE_ID
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
    systemctl daemon-reload
    systemctl enable "wgh-input-$NODE_ID.service" "$service_name.service" >/dev/null
    systemctl restart "wgh-input-$NODE_ID.service" "$service_name.service"
  fi
}

configure_vps_forwarding() {
  local public_iface nft_service
  nft_service="wgh-nft-$NODE_ID"
  if [[ "$PUBLIC_SS_ENABLED" != "1" ]]; then
    echo "[6/7] 公网 SS 已关闭，不创建 VPS 端口转发"
    return
  fi
  echo "[6/7] 在 VPS 本地配置公网 SS 转发"
  public_iface="$(ip route show default | awk 'NR==1 {print $5}')"
  [[ -n "$public_iface" ]] || die "无法识别 VPS 默认公网接口"
  mkdir -p /usr/local/sbin
  cat >"/usr/local/sbin/$nft_service" <<EOF
#!/bin/sh
set -eu
case "\${1:-start}" in
  start)
    nft list table ip $WG_IFACE >/dev/null 2>&1 && nft delete table ip $WG_IFACE || true
    nft -f - <<'NFT'
table ip $WG_IFACE {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$public_iface" tcp dport $VPS_SS_PORT counter dnat to $WG_PREFIX.2:$HOME_SS_PORT
    iifname "$public_iface" udp dport $VPS_SS_PORT counter dnat to $WG_PREFIX.2:$HOME_SS_PORT
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "$WG_IFACE" ip daddr $WG_PREFIX.2 tcp dport $HOME_SS_PORT counter masquerade
    oifname "$WG_IFACE" ip daddr $WG_PREFIX.2 udp dport $HOME_SS_PORT counter masquerade
  }
}
NFT
    ;;
  stop)
    nft list table ip $WG_IFACE >/dev/null 2>&1 && nft delete table ip $WG_IFACE || true
    ;;
esac
EOF
  chmod 700 "/usr/local/sbin/$nft_service"
  cat >"/etc/systemd/system/$nft_service.service" <<EOF
[Unit]
Description=VolWG forward SS2022 $NODE_ID to home
Requires=wg-quick@$WG_IFACE.service
After=network-online.target wg-quick@$WG_IFACE.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/$nft_service start
ExecStop=/usr/local/sbin/$nft_service stop

[Install]
WantedBy=multi-user.target
EOF
  printf 'net.ipv4.ip_forward=1\n' >/etc/sysctl.d/99-wg-home.conf
  sysctl -p /etc/sysctl.d/99-wg-home.conf >/dev/null
  systemctl daemon-reload
  systemctl enable "$nft_service.service" >/dev/null
  systemctl restart "$nft_service.service"
}

save_vps_full_state() {
  local state_dir state_file ss_userinfo public_link private_link default_link
  local public_endpoint private_endpoint default_endpoint default_port
  local public_outbound private_outbound default_outbound
  state_dir="/etc/wg-home-exit/nodes"
  state_file="$state_dir/$NODE_ID.conf"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"
  if [[ -e "$state_file" && "$REPLACE_NODE" == "1" ]]; then
    cp "$state_file" "$state_file.before.$(date +%Y%m%d-%H%M%S)"
  fi
  ss_userinfo="$(base64url_value "2022-blake3-aes-128-gcm:$SS_PASSWORD")"
  public_endpoint="$VPS_ENDPOINT:$VPS_SS_PORT"
  private_endpoint="$WG_PREFIX.2:$HOME_SS_PORT"
  public_link=""
  if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
    public_link="ss://$ss_userinfo@$public_endpoint#$(urlencode "$DISPLAY_NAME-外网")"
  fi
  private_link="ss://$ss_userinfo@$private_endpoint#$(urlencode "$DISPLAY_NAME-内网")"
  if [[ "$MODE" == "relay" && "$PUBLIC_SS_ENABLED" == "1" ]]; then
    default_endpoint="$public_endpoint"
    default_port="$VPS_SS_PORT"
    default_link="$public_link"
  else
    default_endpoint="$private_endpoint"
    default_port="$HOME_SS_PORT"
    default_link="$private_link"
  fi
  public_outbound="$(cat <<EOF
{
  "tag": "home-$NODE_ID-public",
  "protocol": "shadowsocks",
  "settings": {"address": "$VPS_ENDPOINT", "port": $VPS_SS_PORT, "method": "2022-blake3-aes-128-gcm", "password": "$SS_PASSWORD"}
}
EOF
)"
  private_outbound="$(cat <<EOF
{
  "tag": "home-$NODE_ID-private",
  "protocol": "shadowsocks",
  "settings": {"address": "$WG_PREFIX.2", "port": $HOME_SS_PORT, "method": "2022-blake3-aes-128-gcm", "password": "$SS_PASSWORD"}
}
EOF
)"
  if [[ "$MODE" == "relay" && "$PUBLIC_SS_ENABLED" == "1" ]]; then
    default_outbound="${public_outbound/home-$NODE_ID-public/home-$NODE_ID}"
  else
    default_outbound="${private_outbound/home-$NODE_ID-private/home-$NODE_ID}"
  fi
  cat >"$state_file" <<EOF
NODE_ID=$NODE_ID
DISPLAY_NAME_B64=$(encode "$DISPLAY_NAME")
MODE=$MODE
PUBLIC_SS_ENABLED=$PUBLIC_SS_ENABLED
HOME_BACKEND=$HOME_BACKEND
WG_INTERFACE=$WG_IFACE
WG_PORT=$VPS_WG_PORT
VPS_WG_PORT=$VPS_WG_PORT
HOME_WG_PORT=$HOME_WG_PORT
WG_PREFIX=$WG_PREFIX
SS_PORT=$default_port
VPS_SS_PORT=$VPS_SS_PORT
HOME_SS_PORT=$HOME_SS_PORT
SS_ENDPOINT=$default_endpoint
SS_LINK_B64=$(encode "$default_link")
XRAY_OUTBOUND_B64=$(encode "$default_outbound")
PUBLIC_SS_ENDPOINT=$(if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then printf '%s' "$public_endpoint"; fi)
PRIVATE_SS_ENDPOINT=$private_endpoint
PUBLIC_SS_LINK_B64=$(encode "$public_link")
PRIVATE_SS_LINK_B64=$(encode "$private_link")
PUBLIC_XRAY_OUTBOUND_B64=$(encode "$public_outbound")
PRIVATE_XRAY_OUTBOUND_B64=$(encode "$private_outbound")
EOF
  chmod 600 "$state_file"
  echo
  echo "公网 SS2022 链接："
  if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
    echo "$public_link"
  else
    echo "已关闭"
  fi
  echo "私网 SS2022 链接："
  echo "$private_link"
  echo "以后查看全部链接：volwg manager links"
}

while (($#)); do
  case "$1" in
    --role) ROLE="${2:-}"; shift 2 ;;
    --full) FULL_STACK="1"; shift ;;
    --node) NODE_ID="${2:-}"; shift 2 ;;
    --name) DISPLAY_NAME="${2:-}"; shift 2 ;;
    --wg-prefix) WG_PREFIX="${2:-}"; shift 2 ;;
    --vps-wg-port) VPS_WG_PORT="${2:-}"; shift 2 ;;
    --home-wg-port) HOME_WG_PORT="${2:-}"; shift 2 ;;
    --wg-port) VPS_WG_PORT="${2:-}"; HOME_WG_PORT="${2:-}"; shift 2 ;;
    --endpoint) VPS_ENDPOINT="${2:-}"; shift 2 ;;
    --vps-ss-port) VPS_SS_PORT="${2:-}"; shift 2 ;;
    --home-ss-port) HOME_SS_PORT="${2:-}"; shift 2 ;;
    --ss-port) VPS_SS_PORT="${2:-}"; HOME_SS_PORT="${2:-}"; shift 2 ;;
    --home-backend) HOME_BACKEND="${2:-}"; shift 2 ;;
    --ss-password) SS_PASSWORD="${2:-}"; shift 2 ;;
    --public-ss)
      case "${2:-}" in
        on) PUBLIC_SS_ENABLED="1" ;;
        off) PUBLIC_SS_ENABLED="0" ;;
        *) die "--public-ss 必须是 on 或 off" ;;
      esac
      shift 2
      ;;
    --mode) MODE="${2:-}"; shift 2 ;;
    --replace) REPLACE_NODE="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

if [[ -z "$ROLE" ]]; then
  echo "请选择当前 SSH 窗口的机器角色："
  echo "  1) 公网/优化 VPS"
  echo "  2) 家宽机"
  read -r -p "输入 1 或 2：" role_choice
  case "$role_choice" in
    1) ROLE="vps" ;;
    2) ROLE="home" ;;
    *) die "角色选择无效" ;;
  esac
fi

[[ "$ROLE" == "vps" || "$ROLE" == "home" ]] || die "--role 必须是 vps 或 home"
[[ "$FULL_STACK" == "0" || "$FULL_STACK" == "1" ]] || die "完整部署模式无效"
[[ "$HOME_BACKEND" == "ss-rust" || "$HOME_BACKEND" == "xray" ]] || die "--home-backend 必须是 ss-rust 或 xray"
[[ "$MODE" == "relay" || "$MODE" == "direct" ]] || die "--mode 必须是 relay 或 direct"
[[ "$(id -u)" == "0" ]] || die "请使用 root 或 sudo 运行"

echo
echo "============================================================"
if [[ "$FULL_STACK" == "1" ]]; then
  echo " 当前模式：双 SSH 窗口完整部署（WireGuard + SS2022）"
else
  echo " 当前模式：仅 WireGuard 手动配对"
fi
echo "============================================================"
if [[ "$FULL_STACK" == "1" ]]; then
  echo "两台机器在各自窗口本地配置，不会互相 SSH，也不需要交换 SSH 私钥。"
  echo "家宽机不需要公网 IP；它会主动连接 VPS 的 WireGuard 公网端口。"
  echo "只复制本向导显示的 WireGuard 公钥和 SS2022 密钥。"
else
  echo "此向导不会安装 ss-rust 或 Xray Core，也不会生成 SS 链接。"
  echo "需要完整落地线路，请退出后运行 volwg，选择："
  echo "  新建线路与配对 → 双 SSH 窗口完整部署"
fi
echo

if command -v uci >/dev/null 2>&1 && command -v opkg >/dev/null 2>&1; then
  SYSTEM_KIND="openwrt"
elif [[ -r /etc/os-release ]] && command -v systemctl >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:11|debian:12|debian:13|ubuntu:*) SYSTEM_KIND="linux" ;;
    *) die "Linux 仅支持 Debian 11/12/13 或 Ubuntu" ;;
  esac
else
  die "不支持当前系统"
fi
[[ "$ROLE" != "vps" || "$SYSTEM_KIND" == "linux" ]] || die "VPS 角色仅支持 Debian/Ubuntu"

default_node="$(next_node_id)"
[[ -n "$NODE_ID" ]] || NODE_ID="$(prompt_default "节点 ID（两个窗口填写相同 ID）" "$default_node")"
[[ "$NODE_ID" =~ ^[a-z0-9][a-z0-9_]{0,7}$ ]] || die "节点 ID 必须是 1-8 位小写字母、数字或下划线"
[[ -n "$DISPLAY_NAME" ]] || DISPLAY_NAME="$(prompt_default "线路显示名称（两个窗口建议相同）" "家宽线路 $NODE_ID")"
[[ -n "$DISPLAY_NAME" ]] || die "线路名称不能为空"

WG_IFACE="wgh_$NODE_ID"
WG_CONFIG="/etc/wireguard/$WG_IFACE.conf"
WG_KEY="/etc/wireguard/$WG_IFACE.key"
WG_PUB="/etc/wireguard/$WG_IFACE.pub"

if line_exists && [[ "$REPLACE_NODE" != "1" ]]; then
  die "节点 $NODE_ID 已存在。为防止覆盖，请换一个节点 ID；确需替换时明确添加 --replace"
fi

echo
if [[ "$FULL_STACK" == "1" ]]; then
  echo "[1/7] 系统与线路"
else
  echo "[1/5] 系统与线路"
fi
echo "  系统：$SYSTEM_KIND"
echo "  角色：$ROLE"
echo "  名称：$DISPLAY_NAME"
echo "  节点：$NODE_ID"
echo "  接口：$WG_IFACE"

wg_was_installed="1"
if ! command -v wg >/dev/null 2>&1; then
  wg_was_installed="0"
  if [[ "$FULL_STACK" == "1" ]]; then
    echo "[2/7] 正在自动安装 WireGuard"
  else
    echo "[2/5] 正在自动安装 WireGuard"
  fi
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    opkg update
    opkg install wireguard-tools
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard-tools
  fi
else
  if [[ "$FULL_STACK" == "1" ]]; then
    echo "[2/7] WireGuard 已安装"
  else
    echo "[2/5] WireGuard 已安装"
  fi
fi
command -v wg >/dev/null || die "WireGuard 安装失败"

if [[ "$FULL_STACK" == "1" && "$ROLE" == "vps" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get install -y nftables >/dev/null
elif [[ "$FULL_STACK" == "1" && "$ROLE" == "home" && "$SYSTEM_KIND" == "linux" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update >/dev/null
  apt-get install -y iptables ca-certificates >/dev/null
fi

if [[ "$SYSTEM_KIND" == "linux" ]]; then
  test_iface="vwgcap$$"
  cleanup_test_iface() {
    ip link del "$test_iface" >/dev/null 2>&1 || true
  }
  trap cleanup_test_iface EXIT INT TERM
  if ! wg_capability_error="$(ip link add "$test_iface" type wireguard 2>&1)"; then
    virtualization="$(systemd-detect-virt 2>/dev/null || true)"
    die "无法创建 WireGuard 接口。LXC 请确认 NET_ADMIN 和宿主机 WireGuard。虚拟化：${virtualization:-none}；原始输出：$wg_capability_error"
  fi
  ip link del "$test_iface"
  trap - EXIT INT TERM
fi

mkdir -p /etc/wireguard
chmod 700 /etc/wireguard
umask 077
if [[ ! -s "$WG_KEY" ]]; then
  wg genkey >"$WG_KEY"
fi
wg pubkey <"$WG_KEY" >"$WG_PUB"
chmod 600 "$WG_KEY" "$WG_PUB"
local_public_key="$(<"$WG_PUB")"

if [[ "$ROLE" == "vps" ]]; then
  detected_endpoint="$(detect_public_ipv4)"
  if [[ -z "$VPS_ENDPOINT" ]]; then
    if [[ -n "$detected_endpoint" ]]; then
      VPS_ENDPOINT="$(prompt_default "VPS 公网 IP/域名（复制到家宽窗口）" "$detected_endpoint")"
    else
      VPS_ENDPOINT="$(prompt_required "VPS 公网 IP/域名（复制到家宽窗口）")"
    fi
  fi
fi

if [[ "$FULL_STACK" == "1" ]]; then
  echo
  echo "[3/7] 双窗口共享参数"
  echo "以下参数请以 VPS 窗口最终显示的值为准，在家宽窗口填写相同内容。"
  if [[ "$ROLE" == "home" && -z "$VPS_ENDPOINT" ]]; then
    VPS_ENDPOINT="$(prompt_required "输入 VPS 窗口显示的公网 IP 或域名")"
  fi
  WG_PREFIX="$(prompt_default "WireGuard 网段前缀" "$WG_PREFIX")"
  VPS_WG_PORT="$(prompt_default "VPS WireGuard 公网 UDP 起始端口" "$VPS_WG_PORT")"
  HOME_WG_PORT="$(prompt_default "家宽机 WireGuard 本地 UDP 起始端口" "$HOME_WG_PORT")"
  VPS_SS_PORT="$(prompt_default "VPS 公网 SS TCP/UDP 起始端口" "$VPS_SS_PORT")"
  HOME_SS_PORT="$(prompt_default "家宽机 SS2022 TCP/UDP 起始端口" "$HOME_SS_PORT")"
  echo "家宽 SS2022 服务端（两个窗口选择相同项）："
  echo "  1) ss-rust ssserver（推荐）"
  echo "  2) Xray Core"
  read -r -p "请选择 [1-2，默认 1]：" backend_choice
  case "${backend_choice:-1}" in
    1) HOME_BACKEND="ss-rust" ;;
    2) HOME_BACKEND="xray" ;;
    *) die "家宽服务端选择无效" ;;
  esac
  if [[ "$ROLE" == "vps" ]]; then
    echo "推荐入口："
    echo "  1) relay：默认推荐公网 SS"
    echo "  2) direct：默认推荐 WireGuard 私网 SS"
    read -r -p "请选择 [1-2，默认 1]：" mode_choice
    case "${mode_choice:-1}" in
      1) MODE="relay" ;;
      2) MODE="direct" ;;
      *) die "推荐入口选择无效" ;;
    esac
    echo "  1) 同时生成公网和私网 SS（推荐）"
    echo "  2) 仅生成 WireGuard 私网 SS"
    read -r -p "请选择 [1-2，默认 1]：" public_choice
    case "${public_choice:-1}" in
      1) PUBLIC_SS_ENABLED="1" ;;
      2) PUBLIC_SS_ENABLED="0" ;;
      *) die "公网 SS 选择无效" ;;
    esac
  fi
else
  WG_PREFIX="$(prompt_default "WireGuard 网段前缀" "$WG_PREFIX")"
  VPS_WG_PORT="$(prompt_default "VPS WireGuard 公网 UDP 起始端口" "$VPS_WG_PORT")"
  HOME_WG_PORT="$(prompt_default "家宽机 WireGuard 本地 UDP 起始端口" "$HOME_WG_PORT")"
  if [[ "$ROLE" == "home" && -z "$VPS_ENDPOINT" ]]; then
    VPS_ENDPOINT="$(prompt_required "输入 VPS 窗口显示的公网 IP 或域名")"
  fi
fi

[[ "$WG_PREFIX" =~ ^([0-9]{1,3}\.){2}[0-9]{1,3}$ ]] || die "网段前缀格式无效"
valid_port "$VPS_WG_PORT" || die "VPS WireGuard 端口无效"
valid_port "$HOME_WG_PORT" || die "家宽机 WireGuard 端口无效"
if [[ "$FULL_STACK" == "1" ]]; then
  valid_port "$VPS_SS_PORT" || die "VPS SS 端口无效"
  valid_port "$HOME_SS_PORT" || die "家宽机 SS 端口无效"
fi

if [[ "$ROLE" == "vps" && "$REPLACE_NODE" != "1" ]]; then
  selected_port="$(next_free_port "$VPS_WG_PORT")"
  if [[ "$selected_port" != "$VPS_WG_PORT" ]]; then
    echo "VPS UDP $VPS_WG_PORT 已占用，自动改用 $selected_port。请在家宽窗口填写 $selected_port。"
    VPS_WG_PORT="$selected_port"
  fi
  if [[ "$FULL_STACK" == "1" && "$PUBLIC_SS_ENABLED" == "1" ]]; then
    selected_port="$(next_free_port "$VPS_SS_PORT")"
    if [[ "$selected_port" == "$VPS_WG_PORT" ]]; then
      selected_port="$(next_free_port "$((VPS_WG_PORT + 1))")"
    fi
    if [[ "$selected_port" != "$VPS_SS_PORT" ]]; then
      echo "VPS SS 端口 $VPS_SS_PORT 已占用，自动改用 $selected_port。请在家宽窗口填写 $selected_port。"
      VPS_SS_PORT="$selected_port"
    fi
  fi
elif [[ "$ROLE" == "home" && "$REPLACE_NODE" != "1" ]]; then
  selected_port="$(next_free_port "$HOME_WG_PORT")"
  if [[ "$selected_port" != "$HOME_WG_PORT" ]]; then
    echo "家宽本地 UDP $HOME_WG_PORT 已占用，自动改用 $selected_port。"
    HOME_WG_PORT="$selected_port"
  fi
  if [[ "$FULL_STACK" == "1" ]]; then
    selected_port="$(next_free_port "$HOME_SS_PORT")"
    if [[ "$selected_port" == "$HOME_WG_PORT" ]]; then
      selected_port="$(next_free_port "$((HOME_WG_PORT + 1))")"
    fi
    if [[ "$selected_port" != "$HOME_SS_PORT" ]]; then
      echo "家宽 SS 端口 $HOME_SS_PORT 已占用，自动改用 $selected_port。请在 VPS 窗口使用同一最终端口。"
      HOME_SS_PORT="$selected_port"
    fi
  fi
fi

if [[ "$FULL_STACK" == "1" && "$ROLE" == "vps" && -z "$SS_PASSWORD" ]]; then
  SS_PASSWORD="$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | base64 | tr -d '\r\n')"
fi

echo
echo "============================================================"
echo "线路：$DISPLAY_NAME ($NODE_ID)"
if [[ "$ROLE" == "vps" ]]; then
  echo "VPS endpoint：$VPS_ENDPOINT:$VPS_WG_PORT"
  echo "VPS WireGuard 公钥："
else
  echo "家宽 WireGuard 公钥："
fi
echo "$local_public_key"
if [[ "$FULL_STACK" == "1" && "$ROLE" == "vps" ]]; then
  echo
  echo "请把下面参数复制到家宽窗口："
  echo "  WireGuard 网段：$WG_PREFIX"
  echo "  VPS endpoint：$VPS_ENDPOINT"
  echo "  VPS WireGuard 端口：$VPS_WG_PORT"
  echo "  家宽 WireGuard 本地端口建议：$HOME_WG_PORT"
  echo "  VPS 公网 SS 端口：$VPS_SS_PORT"
  echo "  家宽 SS 端口：$HOME_SS_PORT"
  echo "  SS2022 AES-128 密钥：$SS_PASSWORD"
  echo "密钥只在自己的两个 SSH 窗口间复制，不要公开。"
fi
echo "============================================================"
echo

if [[ "$ROLE" == "vps" ]]; then
  read -r -p "粘贴家宽机公钥：" peer_public_key
else
  read -r -p "粘贴 VPS 公钥：" peer_public_key
fi
valid_wg_key "$peer_public_key" || die "粘贴的 WireGuard 公钥格式无效"

if [[ "$FULL_STACK" == "1" && "$ROLE" == "vps" ]]; then
  HOME_SS_PORT="$(prompt_default "确认家宽窗口最终采用的 SS2022 端口" "$HOME_SS_PORT")"
  valid_port "$HOME_SS_PORT" || die "家宽机 SS 端口无效"
fi
if [[ "$FULL_STACK" == "1" && "$ROLE" == "home" ]]; then
  if [[ -z "$SS_PASSWORD" ]]; then
    SS_PASSWORD="$(prompt_required "粘贴 VPS 窗口显示的 SS2022 AES-128 密钥")"
  fi
  valid_ss_password "$SS_PASSWORD" || die "SS2022 AES-128 密钥无效，必须是 16 字节 Base64 密钥"
elif [[ "$FULL_STACK" == "1" ]]; then
  valid_ss_password "$SS_PASSWORD" || die "生成 SS2022 密钥失败"
fi

if [[ "$SYSTEM_KIND" == "linux" ]]; then
  check_linux_network_collision
fi

echo
if [[ "$FULL_STACK" == "1" ]]; then
  echo "[4/7] 配置确认"
else
  echo "[3/5] 配置确认"
fi
echo "  名称/节点：$DISPLAY_NAME ($NODE_ID)"
echo "  WireGuard：$WG_IFACE，$WG_PREFIX.1 ↔ $WG_PREFIX.2"
echo "  VPS endpoint：${VPS_ENDPOINT:-本机}:$VPS_WG_PORT"
echo "  家宽本地端口：$HOME_WG_PORT"
if [[ "$FULL_STACK" == "1" ]]; then
  echo "  SS2022：2022-blake3-aes-128-gcm"
  echo "  家宽 SS：$WG_PREFIX.2:$HOME_SS_PORT"
  if [[ "$PUBLIC_SS_ENABLED" == "1" ]]; then
    echo "  公网 SS：$VPS_ENDPOINT:$VPS_SS_PORT"
  fi
  if [[ "$ROLE" == "home" ]]; then
    echo "  家宽服务端：$HOME_BACKEND"
  fi
fi
echo "  其他节点不会被修改。"
read -r -p "输入 yes 写入配置：" confirm
[[ "$confirm" == "yes" ]] || die "用户取消"

if [[ "$ROLE" == "vps" ]]; then
  if [[ "$FULL_STACK" == "1" ]]; then
    echo "[5/7] 写入 VPS WireGuard 配置"
  else
    echo "[4/5] 写入 VPS WireGuard 配置"
  fi
  if [[ -f "$WG_CONFIG" ]]; then
    cp "$WG_CONFIG" "$WG_CONFIG.before.$(date +%Y%m%d-%H%M%S)"
  fi
  private_key="$(<"$WG_KEY")"
  cat >"$WG_CONFIG" <<EOF
# VolWG: $DISPLAY_NAME ($NODE_ID)
[Interface]
Address = $WG_PREFIX.1/24
ListenPort = $VPS_WG_PORT
PrivateKey = $private_key

[Peer]
PublicKey = $peer_public_key
AllowedIPs = $WG_PREFIX.2/32
EOF
  chmod 600 "$WG_CONFIG"
  systemctl enable "wg-quick@$WG_IFACE.service" >/dev/null
  systemctl restart "wg-quick@$WG_IFACE.service"
else
  if [[ "$FULL_STACK" == "1" ]]; then
    echo "[5/7] 写入家宽端 WireGuard 配置"
  else
    echo "[4/5] 写入家宽端 WireGuard 配置"
  fi
  if [[ "$SYSTEM_KIND" == "openwrt" ]]; then
    config_stamp="$(date +%Y%m%d-%H%M%S)"
    cp /etc/config/network "/etc/config/network.before-volwg.$config_stamp"
    cp /etc/config/firewall "/etc/config/firewall.before-volwg.$config_stamp"
    private_key="$(<"$WG_KEY")"
    uci -q delete "network.$WG_IFACE" || true
    uci -q delete "network.${WG_IFACE}_vps" || true
    uci set "network.$WG_IFACE=interface"
    uci set "network.$WG_IFACE.proto=wireguard"
    uci set "network.$WG_IFACE.private_key=$private_key"
    uci set "network.$WG_IFACE.description=$DISPLAY_NAME"
    uci add_list "network.$WG_IFACE.addresses=$WG_PREFIX.2/24"
    uci set "network.$WG_IFACE.listen_port=$HOME_WG_PORT"
    uci set "network.${WG_IFACE}_vps=wireguard_$WG_IFACE"
    uci set "network.${WG_IFACE}_vps.public_key=$peer_public_key"
    uci set "network.${WG_IFACE}_vps.endpoint_host=$VPS_ENDPOINT"
    uci set "network.${WG_IFACE}_vps.endpoint_port=$VPS_WG_PORT"
    uci set "network.${WG_IFACE}_vps.persistent_keepalive=25"
    uci set "network.${WG_IFACE}_vps.route_allowed_ips=1"
    uci add_list "network.${WG_IFACE}_vps.allowed_ips=$WG_PREFIX.1/32"
    uci -q delete "firewall.fw_$NODE_ID" || true
    uci set "firewall.fw_$NODE_ID=zone"
    uci set "firewall.fw_$NODE_ID.name=$WG_IFACE"
    uci add_list "firewall.fw_$NODE_ID.network=$WG_IFACE"
    uci set "firewall.fw_$NODE_ID.input=ACCEPT"
    uci set "firewall.fw_$NODE_ID.output=ACCEPT"
    uci set "firewall.fw_$NODE_ID.forward=REJECT"
    uci commit network
    uci commit firewall
    if [[ "$wg_was_installed" == "0" && "$FULL_STACK" == "1" ]]; then
      echo "WireGuard 刚安装，正在重载家宽机本地网络。"
      /etc/init.d/network restart
      sleep 2
      ifup "$WG_IFACE" >/dev/null 2>&1 || true
      /etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart
    elif [[ "$wg_was_installed" == "0" ]]; then
      echo "WireGuard 刚安装。配置已保存，请退出向导后运行：/etc/init.d/network restart"
    else
      /etc/init.d/network reload
      sleep 2
      ifup "$WG_IFACE"
      /etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart
    fi
  else
    if [[ -f "$WG_CONFIG" ]]; then
      cp "$WG_CONFIG" "$WG_CONFIG.before.$(date +%Y%m%d-%H%M%S)"
    fi
    private_key="$(<"$WG_KEY")"
    cat >"$WG_CONFIG" <<EOF
# VolWG: $DISPLAY_NAME ($NODE_ID)
[Interface]
Address = $WG_PREFIX.2/24
ListenPort = $HOME_WG_PORT
PrivateKey = $private_key

[Peer]
PublicKey = $peer_public_key
Endpoint = $VPS_ENDPOINT:$VPS_WG_PORT
AllowedIPs = $WG_PREFIX.1/32
PersistentKeepalive = 25
EOF
    chmod 600 "$WG_CONFIG"
    systemctl enable "wg-quick@$WG_IFACE.service" >/dev/null
    systemctl restart "wg-quick@$WG_IFACE.service"
  fi
fi

save_metadata

if [[ "$FULL_STACK" == "1" ]]; then
  if [[ "$ROLE" == "vps" ]]; then
    configure_vps_forwarding
    save_vps_full_state
  else
    configure_home_ss
  fi
fi

echo
if [[ "$FULL_STACK" == "1" ]]; then
  echo "[7/7] 完整部署完成"
else
  echo "[5/5] 配对完成"
fi
echo "线路名称：$DISPLAY_NAME"
echo "节点 ID：$NODE_ID"
echo "WireGuard 接口：$WG_IFACE"
echo "VPS 地址：$WG_PREFIX.1"
echo "家宽地址：$WG_PREFIX.2"
echo "VPS endpoint：$VPS_ENDPOINT:$VPS_WG_PORT"
echo "私钥：$WG_KEY"
echo "公钥：$WG_PUB"
if [[ "$ROLE" == "vps" ]]; then
  echo "测试：ping $WG_PREFIX.2"
  echo "请确认云防火墙允许：$VPS_WG_PORT/UDP"
  if [[ "$FULL_STACK" == "1" && "$PUBLIC_SS_ENABLED" == "1" ]]; then
    echo "请同时允许：$VPS_SS_PORT/TCP+UDP"
  fi
else
  echo "测试：ping $WG_PREFIX.1"
fi
echo "删除本机这条线路：volwg remove --node $NODE_ID"
if [[ "$FULL_STACK" == "1" ]]; then
  if [[ "$ROLE" == "home" ]]; then
    echo "SS2022 服务端已安装在本机（家宽机）：$HOME_BACKEND"
  else
    echo "VPS 只运行 WireGuard + nftables；SS2022 服务端位于家宽机。"
  fi
else
  echo "本模式未安装 SS 服务；需要 SS2022 请使用完整部署入口。"
fi
if [[ "$FULL_STACK" == "1" ]]; then
  echo "WireGuard 私钥始终留在本机；只在自己的两个窗口间交换公钥和 SS2022 密钥。"
else
  echo "私钥不要复制或发送，只交换上面显示的公钥。"
fi
echo
wg show "$WG_IFACE" 2>/dev/null || true
