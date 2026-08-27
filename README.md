# VolWG

用 WireGuard 将公网/优化 VPS 与位于 NAT、CGNAT 后面的一个或多个家宽机连接，并在每个家宽端运行独立 SS2022 服务。

支持全自动远程部署，也支持在两个 SSH 窗口中显示公钥、手动复制粘贴完成配对。

每条线路使用独立节点，并默认同时生成公网、WireGuard 私网两套 SS 链接和 Xray outbound tag。脚本不会创建默认负载均衡；使用公网还是私网入口、选择哪条家宽线路，都由用户自己的 Xray 路由决定。

## 一键运行

在控制电脑、VPS 或家宽机执行：

    bash -c "$(curl -fsSL https://raw.githubusercontent.com/chnnic/volwg/main/install.sh)"

如果当前机器需要 root 权限，例如在 VPS 或 Debian 家宽机配置本机 WireGuard：

    sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/chnnic/volwg/main/install.sh)"

命令会安装 `volwg` 快捷命令，然后直接进入引导菜单。以后重新登录 SSH 或打开新终端，只需输入：

    volwg

界面采用多级菜单，并在页面切换时自动清屏：

    主菜单
      ├─ 部署与配对
      ├─ 线路管理
      └─ 系统维护与在线升级

查看版本或在线升级：

    volwg version
    volwg update

版本号显示在主界面顶部。在线升级只替换 VolWG 程序文件，不会删除 `/etc/wg-home-exit/nodes` 中的线路记录。

root 用户安装到 `/usr/local/bin/volwg`；OpenWrt root 安装到 `/usr/bin/volwg`；普通用户安装到 `~/.local/bin/volwg`，安装器会配置新终端所需的 PATH。

安全提示：一键执行远程脚本前，可以先在仓库中检查 install.sh、wg-home-deploy.sh 和 wg-home-key-wizard.sh。

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

脚本会自动安装 WireGuard，并允许在家宽端选择 `ss-rust ssserver` 或 Xray Core。默认推荐轻量的 `ss-rust`；选择 Xray 时，Linux 使用 XTLS 官方安装器。

## 家宽服务端选择

全自动向导会询问家宽机的 SS2022 服务端后端：

    1) ss-rust ssserver（推荐，轻量）
    2) Xray Core（兼容模式）

命令行可以使用：

    --home-backend ss-rust
    --home-backend xray

线路机仍然使用 Xray Shadowsocks outbound；只有家宽机安装所选服务端。relay VPS 只运行 WireGuard 与 nftables，不需要安装 ss-rust 或 Xray。两种后端使用相同的 SS2022 协议、AES-128 密钥和 `ss://` 链接格式。

## 两种链路

### relay：公网 VPS 中转

    优化机 Xray
      → 公网 VPS:SS端口
      → WireGuard
      → 家宽机 SS2022
      → 家宽出口

适合优化机只能编辑 Xray JSON、无法 SSH 的情况。脚本会在可 SSH 的公网 VPS 配置 DNAT/SNAT，并同时输出公网与私网 SS2022 链接；relay 仅表示默认推荐公网入口。

### direct：优化 VPS 直接连接家宽

    用户
      → 优化 VPS Xray 入站
      → SS outbound 10.88.0.2
      → WireGuard
      → 家宽机 SS2022
      → 家宽出口

优化 VPS 必须拥有 root/SSH。脚本会输出可加入优化机 Xray JSON 的 WireGuard 私网 outbound，同时默认保留公网转发和公网链接；direct 仅表示默认推荐私网入口。若确定不需要公网访问，可使用 `--public-ss off` 关闭公网转发。

## 公网与私网 SS 链接

每次新部署默认生成两套入口，它们使用同一台家宽机上的 SS2022 服务、同一密钥和同一出口：

- 公网 SS：`VPS公网地址:VPS公网SS端口`，经过 nftables DNAT 和 WireGuard 到达家宽机，可供其他 VPS 或公网设备使用。
- 私网 SS：`WireGuard家宽地址:家宽SS端口`，不绕 VPS 公网 SS 端口，适合已经接入该 WireGuard 隧道的线路机 Xray。

两条链接可以同时存在，用户按实际场景选择即可。公网入口默认开启；不希望暴露公网端口时，在向导中选择 `off`，或在非交互命令中加入：

    --public-ss off

## 快速开始：引导式入口

克隆仓库：

    git clone https://github.com/chnnic/volwg.git
    cd volwg
    chmod 700 wg-home-deploy.sh wg-home-key-wizard.sh wg-home-manager.sh
    chmod 755 volwg

直接运行主脚本：

    ./volwg

入口菜单：

    1) 全自动远程部署
    2) 双 SSH 窗口：当前机器是 VPS
    3) 双 SSH 窗口：当前机器是家宽机
    4) 管理 VPS 上已部署的线路
    5) 查看帮助

选择全自动部署后，向导会依次询问节点 ID、线路显示名称、部署结构、两端 SSH、端口、网段和 SSH 私钥，不需要记忆命令行参数。

在 VPS 本机选择第 4 项时，VolWG 会自动打开本机线路后台，不再要求重复输入本机 SSH。只有在控制电脑没有检测到本地线路时，才会询问远程 VPS 地址。

## 一台 VPS 连接多个家宽机

每个家宽节点必须使用不同的节点 ID、VPS WireGuard 监听端口和 WireGuard 网段。多个开放公网 SS 的节点还必须使用不同的 VPS 公网 SS 端口。VPS 与家宽机两端的 WireGuard、SS 端口均可分别设置，适合 NAT 端口映射或服务商限定端口的机器。

例如第一条家宽线路：

    volwg deploy --mode relay \
      --node line1 --name "家宽线路 A" \
      --vps root@203.0.113.10 --vps-public-host 203.0.113.10 \
      --home root@home-a.example.net \
      --vps-wg-port 51830 --home-wg-port 45000 \
      --vps-ss-port 31001 --home-ss-port 32001 \
      --home-backend ss-rust \
      --wg-prefix 10.88.1

第二条家宽线路：

    volwg deploy --mode relay \
      --node line2 --name "家宽线路 B" \
      --vps root@203.0.113.10 --vps-public-host 203.0.113.10 \
      --home root@home-b.example.net \
      --vps-wg-port 51831 --home-wg-port 45001 \
      --vps-ss-port 31002 --home-ss-port 32002 \
      --home-backend ss-rust \
      --wg-prefix 10.88.2

部署完成后，登录 VPS 使用管理后台：

    sudo volwg manager

也可以直接查询：

    sudo volwg manager list
    sudo volwg manager links
    sudo volwg manager show line1
    sudo volwg manager status
    sudo volwg manager rename line1 "备用家宽线路"
    sudo volwg manager node line1

`links` 会按自定义线路名称分别显示公网和 WireGuard 私网 SS 链接。私网链接仅供已连接对应隧道的 VPS/Xray 使用。

`node` 专门用于导入图形化 Xray 客户端或面板，一次输出三种内容：

- 公网与私网标准 `ss://` 导入链接。
- 公网与私网 Xray outbound JSON。
- 将指定入站指向私网 outbound 的 routing 规则。

也可以只输出需要的格式：

    volwg manager node line1 ss
    volwg manager node line1 xray
    volwg manager node line1 routing

公网链接可以从公网访问；私网链接只能导入到已经连接对应 WireGuard 隧道的优化 VPS/Xray，不能直接用于普通公网客户端。relay/direct 只影响兼容 tag `home-节点ID` 默认指向哪一套入口，不限制两套链接同时存在。

旧版本已经部署好的线路不会被自动覆盖。可以运行下面的命令，将旧 SS 链接粘贴登记到管理后台，并重新设置易于区分的名称：

    sudo volwg manager register

旧版 VPS 只保存 WireGuard 和转发规则，没有保存 SS 密钥，因此首次登记需要粘贴原来的 SS 链接；登记后便会长期保存在后台。

## 双 SSH 窗口交换公钥

将仓库放到两台机器后，同时打开两个 SSH 窗口。

窗口 A，公网或优化 VPS：

    sudo ./volwg

选择：

    2) 双 SSH 窗口：当前机器是 VPS

窗口 B，家宽机：

    sudo ./volwg

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

    sudo ./volwg key --role vps
    sudo ./volwg key --role home

OpenWrt 首次安装 WireGuard 后，向导会提示运行：

    /etc/init.d/network restart

SSH 可能短暂断开，重新连接后使用以下命令检查：

    wg show

## 非交互部署

公网中转：

    volwg deploy --mode relay \
      --node line1 --name "家宽线路 A" \
      --vps root@203.0.113.10 \
      --vps-public-host 203.0.113.10 \
      --home root@home-a.example.net \
      --home-ssh-port 1090 \
      --vps-wg-port 51830 --home-wg-port 45000 \
      --vps-ss-port 31000 --home-ss-port 32000 \
      --home-backend ss-rust \
      --identity ~/.ssh/id_ed25519

优化机直连：

    volwg deploy --mode direct \
      --node line2 --name "家宽线路 B" \
      --vps root@198.51.100.20 \
      --vps-public-host 198.51.100.20 \
      --home root@home-b.example.net \
      --vps-wg-port 51831 --home-wg-port 45001 \
      --vps-ss-port 31001 --home-ss-port 32001 \
      --home-backend ss-rust \
      --identity ~/.ssh/id_ed25519

查看所有参数：

    volwg deploy --help

## 节点和默认值

- 节点 ID：home1（1-8 位小写字母、数字或下划线）
- 线路显示名称：家宽线路 1
- 家宽服务端：ss-rust（可选 xray）

- WireGuard 网段：10.88.0.0/24
- VPS 隧道地址：10.88.0.1
- 家宽端隧道地址：10.88.0.2
- VPS WireGuard 公网端口：51830/UDP
- 家宽机 WireGuard 本地端口：51830/UDP
- VPS 公网 SS 端口：31000/TCP+UDP（默认开放，可关闭）
- 家宽机 SS2022 服务端口：31000/TCP+UDP
- SS2022 加密：2022-blake3-aes-128-gcm（16 字节密钥）
- PersistentKeepalive：25 秒

可通过 `--vps-wg-port`、`--home-wg-port`、`--vps-ss-port`、`--home-ss-port` 分别指定两端端口。兼容参数 `--wg-port` 和 `--ss-port` 会把两端设置成同一个值。`--public-ss on|off` 控制是否创建公网 DNAT/SNAT，默认 `on`。脚本会检查已登记节点的 VPS 监听端口和网段冲突；同一节点 ID 默认禁止覆盖，确认需要更新时使用 `--replace`。

公网 SS 允许两端使用不同端口，例如公网访问 VPS `31000`，再 DNAT 到家宽机 WireGuard 地址的 `32000`。家宽端主动连接 VPS，因此家宽 WireGuard 本地端口也可以按 NAT 或服务商允许的端口范围单独指定。

## Xray 路由

把脚本输出的 Shadowsocks outbound 加入优化机 outbounds，然后将需要落地家宽的入站指向它。公网 tag 为 `home-节点ID-public`，私网 tag 为 `home-节点ID-private`；兼容 tag `home-节点ID` 根据 relay/direct 指向推荐入口。脚本不会添加 balancer 或负载均衡规则：

    {
      "type": "field",
      "inboundTag": ["需要走家宽的入站 tag"],
      "outboundTag": "home-line1-private"
    }

脚本同时输出新版 Xray 和旧版 settings.servers 两种 Shadowsocks outbound 格式。

## 密钥说明

- SSH 密钥：仅用于部署脚本登录设备。
- WireGuard 私钥：每台机器本地生成，不会传给另一端。
- WireGuard 公钥：可以在两个 SSH 窗口之间复制粘贴。
- SS2022 密钥：写入家宽机所选的 ss-rust/Xray 服务端，并输出到 SS 链接或优化机 outbound。

SS2022、SSH 私钥和 WireGuard 私钥均属于敏感信息，不要公开。

## 文件

- VERSION：当前语义化版本号。
- install.sh：一键下载和启动入口。
- volwg：安装后的统一快捷入口。
- wg-home-deploy.sh：完整部署脚本和引导式入口。
- wg-home-key-wizard.sh：双 SSH 窗口 WireGuard 公钥交换向导。
- wg-home-manager.sh：安装到 VPS 的多线路查看和 SS 链接管理后台。

## 注意

- 家宽端可以位于 NAT/CGNAT 后面，因为它主动连接 VPS。
- OpenWrt 会优先从软件源安装 `shadowsocks-rust-ssserver`；若架构没有可用包，可以改选 Xray 后端。
- 更换家宽公网 IP 后节点参数不变，WireGuard 会自动重新握手。
- 家宽网络必须允许连接 VPS 的 WireGuard UDP 端口。
- OpenWrt 会备份 /etc/config/network 和 /etc/config/firewall。
- Debian/Ubuntu 会备份已有的 wg-home 和 xray-wg-home 配置。
- 首次运行前建议确认默认网段和端口没有被占用。
