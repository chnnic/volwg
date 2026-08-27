# WG Home Exit

用 WireGuard 将公网/优化 VPS 与位于 NAT、CGNAT 后面的家宽机连接，并在家宽端运行独立 SS2022 服务。

支持全自动远程部署，也支持在两个 SSH 窗口中显示公钥、手动复制粘贴完成配对。

## 支持系统

公网或优化 VPS：

- Debian
- Ubuntu
- 必须拥有 root/SSH

家宽端：

- OpenWrt / ImmortalWrt
- Debian 12
- Debian 13
- Ubuntu
- 必须拥有 root/SSH

脚本会自动安装 WireGuard。家宽端缺少 Xray Core 时也会自动安装；Linux 使用 XTLS 官方 Xray 安装器。

## 两种链路

### relay：公网 VPS 中转

    优化机 Xray
      → 公网 VPS:SS端口
      → WireGuard
      → 家宽机 SS2022
      → 家宽出口

适合优化机只能编辑 Xray JSON、无法 SSH 的情况。脚本会在可 SSH 的公网 VPS 配置 DNAT/SNAT，并输出公网 SS2022 链接。

### direct：优化 VPS 直接连接家宽

    用户
      → 优化 VPS Xray 入站
      → SS outbound 10.88.0.2
      → WireGuard
      → 家宽机 SS2022
      → 家宽出口

优化 VPS 必须拥有 root/SSH。该模式不需要公网 SS 端口转发，脚本会输出可加入优化机 Xray JSON 的 outbound。

## 快速开始：引导式入口

克隆仓库：

    git clone https://github.com/chnnic/wg-home-exit.git
    cd wg-home-exit
    chmod 700 wg-home-deploy.sh wg-home-key-wizard.sh

直接运行主脚本：

    ./wg-home-deploy.sh

入口菜单：

    1) 全自动远程部署
    2) 双 SSH 窗口：当前机器是 VPS
    3) 双 SSH 窗口：当前机器是家宽机
    4) 查看帮助

选择全自动部署后，向导会依次询问部署结构、两端 SSH、端口、网段和 SSH 私钥，不需要记忆命令行参数。

## 双 SSH 窗口交换公钥

将仓库放到两台机器后，同时打开两个 SSH 窗口。

窗口 A，公网或优化 VPS：

    sudo ./wg-home-deploy.sh

选择：

    2) 双 SSH 窗口：当前机器是 VPS

窗口 B，家宽机：

    sudo ./wg-home-deploy.sh

选择：

    3) 双 SSH 窗口：当前机器是家宽机

两边都会：

1. 自动安装 WireGuard。
2. 生成本机 WireGuard 密钥。
3. 显示本机公钥。
4. 等待粘贴另一个窗口显示的公钥。
5. 写入配置并设置开机启动。

只交换公钥。私钥始终保存在各自机器：

    /etc/wireguard/wg-home.key

也可以直接运行：

    sudo ./wg-home-key-wizard.sh --role vps
    sudo ./wg-home-key-wizard.sh --role home

OpenWrt 首次安装 WireGuard 后，向导会提示运行：

    /etc/init.d/network restart

SSH 可能短暂断开，重新连接后使用以下命令检查：

    wg show

## 非交互部署

公网中转：

    ./wg-home-deploy.sh --mode relay \
      --vps root@203.0.113.10 \
      --vps-public-host 203.0.113.10 \
      --home root@home.example.com \
      --home-ssh-port 1090 \
      --identity ~/.ssh/id_ed25519

优化机直连：

    ./wg-home-deploy.sh --mode direct \
      --vps root@198.51.100.20 \
      --vps-public-host 198.51.100.20 \
      --home root@home.example.com \
      --identity ~/.ssh/id_ed25519

查看所有参数：

    ./wg-home-deploy.sh --help

## 默认值

- WireGuard 网段：10.88.0.0/24
- VPS 隧道地址：10.88.0.1
- 家宽端隧道地址：10.88.0.2
- WireGuard：51830/UDP
- SS2022：31000/TCP+UDP
- SS2022 加密：2022-blake3-aes-256-gcm
- PersistentKeepalive：25 秒

可通过 --wg-prefix、--wg-port 和 --ss-port 修改，避免和现有网络、端口冲突。

## Xray 路由

把脚本输出的 Shadowsocks outbound 加入优化机 outbounds，然后将需要落地家宽的入站指向它：

    {
      "type": "field",
      "inboundTag": ["需要走家宽的入站 tag"],
      "outboundTag": "indonesia-home"
    }

脚本同时输出新版 Xray 和旧版 settings.servers 两种 Shadowsocks outbound 格式。

## 密钥说明

- SSH 密钥：仅用于部署脚本登录设备。
- WireGuard 私钥：每台机器本地生成，不会传给另一端。
- WireGuard 公钥：可以在两个 SSH 窗口之间复制粘贴。
- SS2022 密钥：写入家宽 Xray 服务端，并输出到 SS 链接或优化机 outbound。

SS2022、SSH 私钥和 WireGuard 私钥均属于敏感信息，不要公开。

## 文件

- wg-home-deploy.sh：完整部署脚本和引导式入口。
- wg-home-key-wizard.sh：双 SSH 窗口 WireGuard 公钥交换向导。

## 注意

- 家宽端可以位于 NAT/CGNAT 后面，因为它主动连接 VPS。
- 更换家宽公网 IP 后节点参数不变，WireGuard 会自动重新握手。
- 家宽网络必须允许连接 VPS 的 WireGuard UDP 端口。
- OpenWrt 会备份 /etc/config/network 和 /etc/config/firewall。
- Debian/Ubuntu 会备份已有的 wg-home 和 xray-wg-home 配置。
- 首次运行前建议确认默认网段和端口没有被占用。
