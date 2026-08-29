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
      ├─ 线路管理
      ├─ 新建线路与配对
      └─ 系统维护与在线升级

常用的线路管理排在首位。菜单支持输入 `0` 返回上级，也可以输入 `q` 直接退出；本机存在已登记线路时，页头会显示线路数量。

新建多节点时，留空节点 ID 会自动选择 `home1`、`home2` 等未使用 ID；自动编号会同时检查活动接口、WireGuard 配置和 VolWG 已登记线路。节点 ID 是用于网卡、服务、配置文件和 Xray tag 的内部标识，只允许 1-8 位小写字母、数字或下划线；线路显示名称可以自由使用大写字母、连字符和中文。交互输入不合规时不会退出向导，而会给出规范化建议并停留在当前步骤重新输入。VPS 会在显示网段和端口输入框之前扫描 WireGuard 配置、活动接口、系统监听端口和全部 VolWG 线路记录；例如 `10.88.0.0/24`、`51830`、`31000` 已占用时，默认值会直接向后调整为可用的 `10.88.1.0/24`、`51831`、`31001`。用户手动修改后，写入前还会再次检查。

查看版本或在线升级：

    volwg version
    volwg update

版本号显示在主界面顶部。在线升级会原子替换 VolWG 程序文件，避免覆盖正在运行的入口脚本；升级不会删除 `/etc/wg-home-exit/nodes` 中的线路记录。

root 用户安装到 `/usr/local/bin/volwg`；OpenWrt root 安装到 `/usr/bin/volwg`；普通用户安装到 `~/.local/bin/volwg`，安装器会配置新终端所需的 PATH。

安全提示：一键执行远程脚本前，可以先在仓库中检查 install.sh、wg-home-deploy.sh 和 wg-home-key-wizard.sh。

## 支持系统

公网或优化 VPS：

- Debian
- Ubuntu
- 必须拥有 root/SSH

家宽端：

- OpenWrt / ImmortalWrt
- Debian 11
- Debian 12
- Debian 13
- Ubuntu
- 必须拥有 root/SSH

脚本会自动安装 WireGuard，并允许在家宽端选择 `ss-rust ssserver` 或 Xray Core。默认推荐轻量的 `ss-rust`；选择 Xray 时，Linux 使用 XTLS 官方安装器。

Debian LXC 可以作为家宽端或中转端使用，但容器必须拥有 `NET_ADMIN`，并且宿主机内核必须启用 WireGuard。中转端还必须允许 nftables/NAT 和 IPv4 转发。部署前脚本会临时创建并立即删除一个测试接口；能力不足时会显示 LXC/内核相关的明确错误，不会继续写入线路配置。

Debian 11 安装 ss-rust 时使用 musl 静态构建，不依赖较新的 glibc。脚本在替换程序和创建服务前会先运行 `ssserver --version` 自检；检测到旧二进制无法运行时会自动替换。

## OpenWrt 双 WAN/5G 自动切换

OpenWrt/ImmortalWrt 家宽机部署线路时，会自动为每条线路开启 WireGuard endpoint 的 WAN 跟随服务。它按系统默认路由的 metric 选择当前优先级最高且物理链路在线的出口：网线 WAN 可用时走网线，网线断开后切到 5G/备用 WAN，网线恢复后再自动切回。普通上网已经切换出口、但 WireGuard 仍停留在安装时旧出口的问题也会被自动纠正。每次出口变化时只重建对应节点的 WireGuard 接口，刷新旧 UDP socket、NAT 映射与握手，避免路由已经切换但隧道仍大量丢包；不会重启整个 OpenWrt 网络或影响其他节点。

查看指定线路当前使用的出口：

    volwg wan-follow status --node line1

为升级前已经创建的 OpenWrt 线路补开此功能：

    volwg update
    volwg wan-follow enable --node line1

关闭自动跟随但保留配置：

    volwg wan-follow disable --node line1

每条线路拥有独立的 `wgh-wan-节点ID` 服务。删除指定线路或执行 `volwg purge` 时，对应服务与配置会一并停止并归档，不影响其他节点。

## 隧道内 SSH（默认关闭）

完整部署会询问是否允许 VPS 通过该线路的 WireGuard 私网进入家宽机 SSH，默认选择“关闭”。开启时需要填写家宽机实际监听的 SSH 端口；这里填写设备内部端口，不是 FRP 映射后的外部端口。

开启后可以选择认证方式：

    1) 线路专用密钥（推荐）
    2) 家宽机 root 密码或系统现有 SSH 配置

密钥模式会在 VPS 的 `/etc/wg-home-exit/ssh/` 中为每个节点生成独立 Ed25519 私钥。配对码只携带公钥，家宽机自动将公钥加入 OpenWrt 的 `/etc/dropbear/authorized_keys` 或 Linux 的 `/root/.ssh/authorized_keys`。私钥不会进入配对码，也不会复制到家宽机；删除线路时会随线路配置一起归档。

公钥安装只使用 BusyBox 自带的基础命令，兼容没有 GNU `install` 命令的精简 OpenWrt。

开启后登录 VPS，可以直接从 VolWG 菜单选择线路进入家宽机：

    volwg
    线路管理 → 通过 WireGuard 进入家宽机 SSH

也可以使用命令：

    volwg ssh 节点ID
    volwg diagnose 节点ID

连接目标是该线路的 WireGuard 私网地址，例如 `10.88.1.2`，因此不需要家宽公网 IP、FRP 或额外公网 SSH 端口。VolWG 只开放该 WireGuard 接口上的指定 SSH 端口；其他来源仍由家宽机原有防火墙控制。`volwg ssh 节点ID` 会读取线路记录并自动选择对应私钥，不需要再次输入家宽机密码。

SSH 入口会直接建立真实连接，不会先做 TCP 预连接，因此也兼容使用 systemd socket 激活 SSH 的精简 Debian/LXC；线路诊断仍可单独检查端口状态。

OpenWrt 如果原有 Dropbear 只绑定 LAN 接口，即使相同端口已被占用，VolWG 仍会为 WireGuard 地址创建独立实例。线路密钥模式下，该专用实例关闭密码认证，只接受对应公钥；原有 LAN 管理实例不会被修改。

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

两条链接可以同时存在，用户按实际场景选择即可。公网入口默认开启；不希望暴露公网端口时，在向导中选择“仅生成 WireGuard 私网 SS”，或在非交互命令中加入：

    --public-ss off

## 快速开始：引导式入口

克隆仓库：

    git clone https://github.com/chnnic/volwg.git
    cd volwg
    chmod 700 wg-home-deploy.sh wg-home-key-wizard.sh wg-home-manager.sh wg-home-remove.sh wg-home-purge.sh
    chmod 755 volwg

直接运行主脚本：

    ./volwg

入口菜单：

    1) 线路管理
    2) 新建线路与配对
    3) 系统维护与在线升级
    0) 退出

“新建线路与配对”子菜单：

    1) 双 SSH 窗口完整部署（推荐）
       家宽机主动连接 VPS；无需公网 IP，也无需两端互相 SSH
    2) 仅 WireGuard：当前机器是 VPS
    3) 仅 WireGuard：当前机器是家宽机
    4) 控制端远程全自动部署
       仅适合当前控制机能分别 SSH 到 VPS 和家宽机
    0) 返回主菜单

默认推荐“双 SSH 窗口完整部署”。分别在 VPS 和家宽机的 SSH 窗口运行 `volwg`，选择当前机器角色；两端各自只配置本机。家宽机主动连接 VPS，因此不需要公网 IP、FRP、端口映射，也不需要让 VPS 登录家宽机。两个窗口只复制 WireGuard 公钥和向导生成的 SS2022 AES-128 密钥，SSH 私钥不会交换。

也可以直接在两端分别运行：

    sudo volwg pair --role vps
    sudo volwg pair --role home

VPS 只安装 WireGuard 与 nftables；家宽机安装 WireGuard，并可选择 `ss-rust ssserver` 或 Xray Core 作为 SS2022 服务端。完成后 VPS 窗口保存并显示公网、WireGuard 私网两套 SS 链接。

放在菜单末尾的“控制端远程全自动部署”适合第三台控制机或具备现成管理网络的环境。它按“线路信息 → 家宽 SS 后端 → SSH 连接 → WireGuard 网络 → Shadowsocks 入口”收集配置。

完整远程部署要求“当前运行 VolWG 的机器”能够分别 SSH 到 VPS 和家宽机。家宽机不要求拥有公网 IP：可填写 FRP 域名与映射端口、路由器端口映射、同一 LAN 地址，或者 Tailscale/其他 VPN 地址。若完全不存在可达的 SSH 路径，远程完整部署无法操作家宽机，向导会在写入配置前停止并说明原因。

VPS 与家宽机可以使用不同 SSH 私钥。交互向导会分别询问两个私钥路径；留空时分别使用 ssh-agent 或 `~/.ssh/config`。命令行对应参数为：

    --vps-identity /path/to/vps_key
    --home-identity /path/to/home_key

兼容参数 `--identity` 仍表示两端共用同一个私钥。

选择第 2/3 项前，界面会再次提示“仅 WireGuard”不会安装 ss-rust/Xray、不会生成 SS 链接。只有明确输入 `1` 确认后才会进入纯 WireGuard 公钥配对。

在线路管理中选择本机管理时，VolWG 会直接打开本机线路后台，不再要求重复输入本机 SSH；也可以选择连接远程 VPS 管理。

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

交互菜单把链接、线路概览和节点导出排在前面。需要查看详情、导出节点或重命名时，会先列出所有线路并按编号选择，不需要手工输入节点 ID；登记旧线路等低频操作排在菜单末尾。

也可以直接查询：

    sudo volwg manager list
    sudo volwg manager links
    sudo volwg manager show line1
    sudo volwg manager status
    sudo volwg manager rename line1 "备用家宽线路"
    sudo volwg manager node line1
    sudo volwg manager delete line1

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

## 双 SSH 窗口完整部署

这是 NAT/CGNAT 家宽的默认推荐方式。先在 VPS 窗口选择：

    2) 新建线路与配对
    1) 双 SSH 窗口完整部署
    1) 当前窗口是公网/优化 VPS

VPS 窗口会显示一条 `VOLWG1...` 开头的一行配对码，并等待家宽公钥。配对码包含本次线路的 WireGuard 公钥、endpoint、最终端口、网段、SS 后端和 SS2022 AES-128 密钥，只应在自己的两个 SSH 窗口间复制。

再在家宽机窗口选择：

    2) 新建线路与配对
    1) 双 SSH 窗口完整部署
    2) 当前窗口是家宽机

把 VPS 的一行配对码完整粘贴到家宽窗口，家宽端会自动读取所有参数和 VPS 公钥，不再逐项手抄端口或密钥。解码同时兼容 GNU/BusyBox `base64` 和 OpenSSL；精简 OpenWrt 没有 `base64` 命令时会自动使用 OpenSSL。无效或不完整的配对码不会让向导退出，而会停留在当前步骤重新粘贴。家宽窗口会单独框出自己的 WireGuard 公钥，并明确提示把完整一行复制回正在等待的 VPS 窗口；交互模式会等待确认已复制后再继续。两边都完成写入后 WireGuard 才会建立连接。家宽机会主动发起连接；整个过程不会要求家宽公网 IP、家宽 SSH 地址或 SSH 私钥路径。仍可留空配对码进入旧的逐项手动填写模式。

两端都会自动避让本机已使用的端口。若家宽窗口调整了 SS2022 端口，VPS 窗口会在写入转发前再次询问家宽最终端口。部署完成后：

- VPS：运行 WireGuard 和 nftables，并保存公网/私网 SS 链接。
- 家宽机：运行 WireGuard 和所选的 ss-rust/Xray SS2022 服务端。
- 家宽机位于内网，不接受 VPS 的 SSH 登录。

命令行快捷入口：

    sudo volwg pair --role vps
    sudo volwg pair --role home

## 双 SSH 窗口仅 WireGuard

将仓库放到两台机器后，同时打开两个 SSH 窗口。手动配对现在支持多个节点，每条线路使用独立的 `wgh_节点ID` 接口、密钥和配置，不再共用或覆盖固定的 `wg-home`。

窗口 A，公网或优化 VPS：

    sudo ./volwg

选择：

    2) 新建线路与配对
    2) 仅 WireGuard：当前机器是 VPS

窗口 B，家宽机：

    sudo ./volwg

选择：

    2) 新建线路与配对
    3) 仅 WireGuard：当前机器是家宽机

两边都会：

1. 询问节点 ID 和自定义线路名称；两个窗口填写相同内容。
2. 自动安装 WireGuard。
3. 为该节点生成独立 WireGuard 密钥。
4. VPS 窗口检测并显示公网 IP/endpoint。
5. 显示本机公钥，等待粘贴另一个窗口的公钥。
6. 自动避让本机已占用的监听端口。
7. 写入独立配置并设置开机启动；节点已存在时默认拒绝覆盖。

只交换公钥。以节点 `line1` 为例，私钥始终保存在各自机器：

    /etc/wireguard/wgh_line1.key

也可以直接运行：

    sudo ./volwg key --role vps
    sudo ./volwg key --role home

`volwg key` 只配置 WireGuard。如果需要自动安装 ss-rust/Xray、生成公网与私网 SS 链接，请使用上面的 `volwg pair`。

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
      --vps-identity ~/.ssh/vps_ed25519 \
      --home-identity ~/.ssh/home_ed25519

优化机直连：

    volwg deploy --mode direct \
      --node line2 --name "家宽线路 B" \
      --vps root@198.51.100.20 \
      --vps-public-host 198.51.100.20 \
      --home root@home-b.example.net \
      --vps-wg-port 51831 --home-wg-port 45001 \
      --vps-ss-port 31001 --home-ss-port 32001 \
      --home-backend ss-rust \
      --vps-identity ~/.ssh/vps_ed25519 \
      --home-identity ~/.ssh/home_ed25519

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

这些端口参数现在表示“起始端口”：创建新节点时如发现端口被现有监听程序或其他 VolWG 节点占用，会依次尝试后续端口，直到找到可用值。最终端口会在写入配置前显示。使用 `--replace` 更新同一节点时不会自动改变原端口。

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
- 一行配对码：包含 VPS WireGuard 公钥和 SS2022 密钥，只能在自己的两个 SSH 窗口间传递。

SS2022、SSH 私钥和 WireGuard 私钥均属于敏感信息，不要公开。

## 删除线路

在 VPS 的线路管理菜单中选择“按序号删除本机线路”。界面会先列出线路名称、节点 ID 和本机角色，可以输入列表序号，也可以直接输入已有节点 ID；选中后输入 `yes` 二次确认。

也可以直接执行：

    sudo volwg manager delete line1

这会停止并删除 VPS 端该节点的 WireGuard、nftables 转发和管理链接记录。然后在对应家宽机执行：

    sudo volwg remove --node line1 --role home

也可以在任意一端直接使用 `volwg remove --node line1`，由脚本自动判断当前角色。直接命令模式删除时必须再次输入完整节点 ID；所有文件先移动到以下归档目录，不会永久擦除：

    /etc/wg-home-exit/removed/时间-节点ID-角色/

删除只作用于选中的节点，不会停止或修改其他线路。VPS 无法自动登录家宽机，因此完整删除需要在两端各执行一次。

早期手动配对固定使用 `wg-home.conf`。如果曾被第二次配对覆盖，可以先检查自动备份：

    ls -1t /etc/wireguard/wg-home.conf.before.*

## 清空旧配置后重新测试

先升级到最新版，然后在 VPS 和家宽机上分别执行：

    volwg update
    volwg purge

`purge` 会先列出检测到的 VolWG 节点，输入大写 `PURGE` 后才开始。它会停止并清理 `wgh_*` 线路、VolWG SS/转发服务、`/etc/wg-home-exit` 记录和旧版 `wg-home`，但不会处理 `wg-id` 或其他非 VolWG WireGuard 接口。

默认保留 VolWG 程序，清理后可以直接重新运行 `volwg`。所有文件会移动到 Linux 的 `/var/backups/volwg/时间/` 或 OpenWrt 的 `/root/volwg-backups/时间/`，不会直接永久擦除。

如需连程序一起卸载：

    volwg purge --uninstall

## 文件

- VERSION：当前语义化版本号。
- install.sh：一键下载和启动入口。
- volwg：安装后的统一快捷入口。
- wg-home-deploy.sh：完整部署脚本和引导式入口。
- wg-home-key-wizard.sh：双 SSH 窗口完整部署及纯 WireGuard 公钥交换向导。
- wg-home-manager.sh：安装到 VPS 的多线路查看和 SS 链接管理后台。
- wg-home-remove.sh：按节点停止服务并归档删除 VPS/家宽端配置。
- wg-home-purge.sh：清空本机全部 VolWG 线路、旧版配置和活动记录。
- wg-home-wan-follow.sh：OpenWrt WireGuard endpoint 的有线 WAN/5G 自动跟随服务。

## 注意

- 家宽端可以位于 NAT/CGNAT 后面，因为它主动连接 VPS。
- OpenWrt 会优先从软件源安装 `shadowsocks-rust-ssserver`；若架构没有可用包，可以改选 Xray 后端。
- 更换家宽公网 IP 后节点参数不变，WireGuard 会自动重新握手。
- 家宽网络必须允许连接 VPS 的 WireGuard UDP 端口。
- OpenWrt 会备份 /etc/config/network 和 /etc/config/firewall。
- Debian 11/12/13、Ubuntu 会备份已有的 wg-home 和 xray-wg-home 配置。
- 首次运行前建议确认默认网段和端口没有被占用。
