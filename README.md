# OpenWrt 自编译仓库（X86 / BPI-R4 / H68K）

主打**纯净**：源码基线是 OpenWrt 官方 25.12，除 H68K 的设备支持外**不动内核**，只额外引入自定义软件包。

## 支持的设备

| 设备 | 平台 | 内核 | 说明 |
|---|---|---|---|
| **X86** | `x86/64` generic | 官方原版 | 完全官方支持，零内核改动；产物为 `ext4-combined-efi` / `squashfs-combined-efi` 整盘镜像 |
| **BPI-R4** | `mediatek/filogic` | 官方原版 | Banana Pi BPI-R4（MT7988A），官方原生支持，零内核改动 |
| **H68K** | `rockchip/armv8` | 官方 + 2 个补丁 | Hinlink H68K（RK3568），官方 25.12 **没有**该设备，需 backport 见下 |

### H68K 的两个补丁（唯一的“动内核”部分）

1. `Patches/h68k/h68k-backport.patch` — 移植 OpenWrt PR#21270：U-Boot 目标、设备树、镜像布局、board.d 网口/指示灯、网卡中断亲和性
2. `Patches/h68k/105-phy-rockchip-snps-pcie3-sram-firmware.patch` — RK3568 PCIe3 PHY 内部 SRAM 固件手动上传。2022 旧版 H68K 上该 SRAM 自动加载永不完成（`p3phy lock failed` → `probe -110`），导致 **eth2/eth3（RTL8125B 2.5G）不出现**；此补丁绕过该硬件批次缺陷

除此之外内核只多打一套 **SONiC fullcone NAT** 补丁（见下节）：没有 BBRv3、没有 LRNG、没有 BTF 注入、没有调度器/网络栈魔改。

`Scripts/H68K.sh` 对补丁落地做了三重校验：内核版本必须是 6.12（补丁路径写死在 `patches-6.12`）、`fuzz=0` 优先应用、应用后确认 `.rej` 无残留且设备定义真的进了 `armv8.mk`。

### 全锥形 NAT（SONiC fullcone）

官方 25.12 已移除 `kmod-nft-fullcone`，所以 `base.config` 里没有它。全锥形改由 `Scripts/Fullcone.sh` 打 9 个补丁实现（`Patches/fullcone/`）：

| 层 | 补丁 | 落到哪 |
|---|---|---|
| 内核 | 984 / 985 / 986 | `target/linux/generic/hack-6.12/` |
| iptables | 901 | `package/network/utils/iptables/patches/` |
| libnftnl | 001 | `package/libs/libnftnl/patches/` |
| nftables | 002 | `package/network/utils/nftables/patches/` |
| fw4 / fw3 | 001 各一个 | `package/network/config/firewall4|firewall/patches/` |
| LuCI | 001 | `feeds/luci/applications/luci-app-firewall/patches/` |

要点：

- **不产生新内核模块、不需要任何 `CONFIG_*`**。fullcone 表达式直接编进 `nf_nat` / `xt_MASQUERADE` / `nft_masq`，所以固件里不用装额外 kmod，也不存在“编了但没加载”的情况
- **必须晚于 `feeds install`**：LuCI 补丁要落到 feeds 目录下；**必须早于 `make download`**：`libnftnl` 补丁改了 `src/Makefile.am`，脚本会同时注入 `PKG_FIXUP:=autoreconf`，否则 automake 版本对不上会直接报 `automake-1.17: not found`
- 与旧 `nft-fullcone` 的区别：映射存在 conntrack 自身（第二张 3-tuple 哈希表，RCU 读路径），支持全部 L4 协议，per-rule 标志位——不走 fullcone 的流量零额外开销
- 启用要两步：`defaults.fullcone` 是总开关（默认关，关着时 zone 里的设置无效），再给 wan zone 单独开

`Scripts/Fullcone.sh` 的守卫：内核必须是 6.12 且 `hack-6.12` 存在、补丁必须是 LF（CRLF 会静默打不上）、feeds 必须已安装、落地后逐个校验文件非空与 `PKG_FIXUP` 是否注入。重复执行幂等。

刷机后：

```bash
uci set firewall.@defaults[0].fullcone='1'
uci set firewall.@zone[1].fullcone='1'
uci add_list firewall.@zone[1].fullcone_proto='udp'   # 可选，仅 UDP（游戏/P2P 推荐）
uci commit firewall && /etc/init.d/firewall restart

nft list ruleset | grep fullcone        # 规则是否生成
# 内网机器跑 pystun3，结果应为 Full Cone
```

注意：SNAT 规则必须带端口范围（fw4 生成的会自动带 `to :1024-65535`）。不带范围时 3-tuple 唯一性保证不生效，两台内网主机可能拿到同一个外部端口，先建立映射的那台就丢了该端口的入站可达性——这正是全锥要避免的。

## 自定义软件包

基底保持官方纯净（LuCI + 中文语言包），只引入以下**原始上游**仓库（`Scripts/Packages.sh`，共 38 个源，已逐个验证可达）：

| 分类 | 包 | 上游仓库 |
|---|---|---|
| NAT / P2P / 端口转发 | `luci-app-natmapt`、`stuntman-client`、`luci-app-socat-reforged` | `muink/openwrt-natmapt`、`muink/openwrt-stuntman`、`busybin/luci-app-socat-reforged` |
| DNS | `luci-app-mosdns`、`luci-app-oxidns`、`luci-app-kixdns`、`luci-app-adguardhome-tk` | `sbwml/luci-app-mosdns`(v5)、`hahaher123/luci-app-oxidns`、`JohnsonRan/luci-app-kixdns`、`w9315273/luci-app-adguardhome` |
| 穿透 / 带宽 / 组网 | `luci-app-bandix`、`luci-app-easytier`、`luci-app-honk`、`luci-app-zerotier` | `timsaya/*`、`EasyTier/luci-app-easytier`、`189160/luci-app-honk`、`rabbitrogi/luci-app-zerotier` |
| 媒体 / 推送 | `luci-app-unblockneteasemusic`、`luci-app-wechatpush`、`luci-app-airconnect` | `UnblockNeteaseMusic/...`(js)、`tty228/luci-app-wechatpush`、`sbwml/luci-app-airconnect` |
| 任务 / 定时 / 运维 | `luci-app-taskplan`、`luci-app-tasks`、`luci-app-timecontrol`、`luci-app-partexp`、`luci-app-watchdog`、`luci-app-netspeedtest`、`luci-app-online-upgrade`、`luci-app-substore` | `sirpdboy/*`、`Arthur97172/*` |
| 容器 / 磁盘 / 文件 / 网盘 | `luci-app-dockox`、`luci-app-diskbox`、`luci-app-harbor-file-pro`、`luci-app-openlist2`、`luci-app-wolmon`、`luci-app-oaf` | `permails/*`、`whzhni1/...`、`sbwml/luci-app-openlist2`、`my1639963/...`、`destan19/OpenAppFilter` |
| 其他 | `luci-app-vlmcsd`（KMS） | `permails/luci-app-vlmcsd` |
| 主题 | `luci-theme-lumen`、`luci-theme-footstrap`、`luci-theme-aurora` + `luci-app-aurora-config` | `qidlek114/...`、`VizzleTF/...`、`eamonxg/...` |
| 硬件信息 | `autocore-arm` / `autocore-x86` | `MinimaxFlora/autocore`(openwrt-25.12) |
| 科学插件备份 | helloworld 整仓 44 包（未被 Config 选中的不编译） | `sbwml/openwrt_helloworld`(v5) |

官方 feeds 里需要显式选中的依赖：`node`（换 sbwml 预编译版）、`zerotier`、`dnsmasq-full`、`xz-utils`。

按 helloworld README 的配套操作：feeds 自带的 `xray-core/v2ray-core/v2ray-geodata/sing-box` 等同名核心已自动移除（由 helloworld 版本接管）；`lang/golang` 换 sbwml `27.x`；`lang/node` 换 sbwml 预编译版。最后一步统一删除 feeds 中与 `package/custom` 同名的副本，避免 buildroot 重复定义。

### 自研插件：luci-app-apbridge

`SSkong/luci-app-apbridge` —— 跨子网访问 AP / 光猫。上游同类插件是 `zyqfork/luci-app-ap-modem`，本插件重写了实现：

- **不抓页面**。它解决的是三层可达性：在目标设备所在子网里占用一个空闲地址，LAN 侧用 veth 对把这段地址从 `br-lan` 的三层接口上摘出去，再连同 WAN 侧通道一起丢进 wan 防火墙区域做 masquerade。目标设备看到的源地址在它自己的网段里，因此不需要它有任何回程路由。
- **多条通道**走 `form.GridSection`，不再固定只有 LAN / WAN 两个框；冲突检测在脚本里（与回环、LAN 网段、其它通道比较），界面上以「未创建」直接体现。
- 前端 JS + 后端 `/usr/share/rpcd/ucode/luci.apbridge`，状态面板 5 秒轮询，支持 ping/HTTP 连通性测试与跳转。
- 依赖只有 `rpcd-mod-ucode` / `firewall4`，无编译产物，构建开销可忽略。刻意不依赖 `ip-tiny`（与 `ip-full` 冲突）。

`Scripts/Packages.sh` 里对应一行 `clone_pkg luci-app-apbridge SSkong/luci-app-apbridge main`，`Config/base.config` 里启用 `CONFIG_PACKAGE_luci-app-apbridge=y`。

### 为什么不设 `CONFIG_ALL_KMODS`

它的语义是 *Select all kernel module packages by default* —— 会把官方树里每一个 kmod 都编译进去。这是之前 X86 要 2.5h、H68K 逼近 6h 上限的主因。

设备真正需要的 kmod 在 `Config/<设备>.config` 里显式列出即可（defconfig 会保留显式选择），被其他包依赖的 kmod 由 Makefile 的 `DEPENDS` 自动带入。构建流程里对 `kmod-*` 也做了严格校验：请求了但没生效会直接失败并打印依赖诊断，不会静默产出缺驱动的固件。

## 用法

Actions → **Build OpenWrt** → Run workflow：

| 输入 | 说明 |
|---|---|
| `devices` | 设备，逗号分隔（`x86,bpi-r4,h68k`），留空=全部 |
| `version` | OpenWrt 版本（如 `25.12.6`），留空=自动取最新 25.12.x |
| `publish` | 构建完成后是否发布到 Release（默认开） |

每个设备一个 artifact；`publish` 打开时由独立的 `publish` job 汇总发布到 `v<版本>`，产物包含镜像、引导件、`*.manifest` 与 `sha256sums.txt`。

## 目录结构

```
Config/
  base.config          # 所有设备共用的包配置
  x86.config           # 设备差异（target/profile/专属驱动）
  bpi-r4.config
  h68k.config
Scripts/
  Packages.sh          # 克隆自定义包到 package/custom/
  Settings.sh          # 默认主机名/管理IP/LuCI 日期标识（纯配置层）
  H68K.sh              # 仅 H68K：应用设备支持补丁（带内核版本守卫）
Patches/h68k/          # H68K 两个补丁
.github/workflows/build.yml
.gitattributes         # 强制 LF，防止 CRLF 弄坏脚本与补丁
```

管理 IP：X86 `192.168.1.1` / BPI-R4 `192.168.10.1` / H68K `192.168.20.1`（root，初始无密码）。

## 编译耗时（量级参考）

移除 `CONFIG_ALL_KMODS` 后的典型量级，实测以首次运行为准：

| 设备 | 冷启动 | 有工具链缓存 |
|---|---|---|
| X86 | 60–90 min | 25–35 min |
| BPI-R4 | 80–120 min | 35–50 min |
| H68K | 100–150 min | 45–60 min |

构建缓存覆盖 `staging_dir/host*` 与 `staging_dir/tool*`（工具链），源码 commit 变动时自动失效。

## 如何确认一次构建是真的可用

编译通过只说明代码能跑完，不代表固件能启动。按这个顺序看：

1. **构建摘要里没有 `✗ 未生效`** —— 流程会打印请求包数、无源码目录的包、被 defconfig 取消选中的包；`luci-app-*` / `luci-theme-*` / `kmod-*` 有丢失会直接判失败。
   这段逻辑在 `Scripts/VerifyPackages.sh`，可以脱离 CI 单独跑（生成 `.config` 之后、`make download` 之前）：

   ```bash
   bash Scripts/VerifyPackages.sh openwrt x86
   ```

   退出码 0 全部生效 / 1 有关键包没进 `.config` / 2 前置文件缺失。它会把未生效包的 `depends on` 段落打印出来，并标出哪个依赖符号没启用——包括 `!PACKAGE_x` 这种否定依赖（方向是反的，x 未启用才算满足）。
2. **产物非空且带 `*.manifest`** —— manifest 是已装包清单，用 `grep` 直接确认某个包到底进没进固件，比看目录结构可靠。
3. **`sha256sums.txt` 与镜像同目录** —— 下载后先校验，排除传输损坏。
4. **设备侧验证**：X86 可直接在 PVE/Libvirt 里起虚拟机看能否进系统；BPI-R4 用 `sdcard.img.gz` 写 TF 卡启动；H68K 刷完先看 `dmesg | grep -E "fw-d54d0eb|p3phy"` 与 `ip -br link`，确认 PHY 补丁生效、eth2/eth3 在不在。
5. **失败时先看 `diag-*` artifact** —— 含 `.config`、`.config.requested`、`openwrt/logs/` 和构建日志尾部，不用回头翻控制台。
