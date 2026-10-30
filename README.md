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

除此之外**不加任何内核补丁**：没有 BBRv3、没有 LRNG、没有 fullcone 内核 hack、没有 BTF 注入、没有调度器/网络栈魔改。

## 自定义软件包

基底保持官方纯净（LuCI + 中文语言包），只引入以下**原始上游**仓库（`Scripts/Packages.sh`）：

| 包 | 上游仓库 | 说明 |
|---|---|---|
| natmapt + LuCI | `muink/openwrt-natmapt`、`muink/luci-app-natmapt` | 全锥 NAT 端口映射 |
| stuntman | `muink/openwrt-stuntman` | STUN 客户端（natmapt 配套） |
| mosdns + LuCI + geo2txt | `sbwml/luci-app-mosdns` (v5) | DNS 分流 |
| bandix + LuCI | `timsaya/openwrt-bandix`、`timsaya/luci-app-bandix` | 带宽利用 |
| 网易云解锁 | `UnblockNeteaseMusic/luci-app-unblockneteasemusic` (js) | 依赖官方 node |
| 微信推送 | `tty228/luci-app-wechatpush` | |
| 计划任务 | `sirpdboy/luci-app-taskplan` | |
| 定时控制 | `sirpdboy/luci-app-timecontrol` | nft 上网时间控制 |
| 测速 | `sirpdboy/netspeedtest` | 含 ookla-speedtest、homebox |
| 看门狗 | `sirpdboy/luci-app-watchdog` | 登录防护，含核心包 |
| 分区扩容 | `sirpdboy/luci-app-partexp` | |
| AirConnect | `sbwml/luci-app-airconnect` | 含核心，AirPlay 投射 |
| ZeroTier LuCI | `rabbitrogi/luci-app-zerotier` | 核心用官方 zerotier |
| vlmcsd + LuCI | `permails/luci-app-vlmcsd` | KMS 服务器 |
| **helloworld（44 包整仓）** | `sbwml/openwrt_helloworld` (v5) | 科学插件防炸上游备份：passwall/passwall2/ssr-plus/openclash/nikki/mihomo/dae/sing-box/xray/v2ray/trojan/hysteria/shadowsocks 系列等；未被 Config 选中的不编译。README 配套：删 feeds 同名核心 + golang 换 sbwml 27.x + node 换 sbwml 预编译 |

自定义包在官方 feeds 中的依赖已在 `Config/base.config` 显式选中：`node`、`zerotier`、`dnsmasq-full`（sing-box 随 homeproxy 移除后不再主动选，仍在 helloworld 中可选）。

按 helloworld README 的配套操作：feeds 自带的 `xray-core/v2ray-core/v2ray-geodata/sing-box` 等同名核心已自动移除（由 helloworld 版本接管）；`lang/golang` 换 sbwml `27.x` 分支；`lang/node` 换 sbwml 预编译版（`feeds_packages_lang_node@packages-25.12`，版本由 Makefile 原生动态解析，未做钉入）。
其余（docker、dae、smartdns、openclash、主题等）**一律不引入**——保持纯净，需要时再按上面的模式加仓库。

`Scripts/Settings.sh` 只做三件事：设备默认管理 IP、主机名、LuCI 概览页构建日期标识。

## 用法

Actions → **Build OpenWrt** → Run workflow：

| 输入 | 说明 |
|---|---|
| `devices` | 设备，逗号分隔（`x86,bpi-r4,h68k`），留空=全部 |
| `version` | OpenWrt 版本（如 `25.12.6`），留空=自动取最新 25.12.x |
| `publish` | 构建完成后是否发布到 Release（默认开） |

产物：每个设备一个 artifact，同时按 `v<版本>` 汇总发布到 Releases。

## 目录结构

```
Config/
  base.config          # 所有设备共用的包配置
  x86.config           # 设备差异（target/profile/专属驱动）
  bpi-r4.config
  h68k.config
Scripts/
  Packages.sh          # 克隆自定义包到 package/custom/
  Settings.sh          # 默认主题/主机名/管理IP/包适配（纯配置层）
  H68K.sh              # 仅 H68K：应用设备支持补丁
Patches/h68k/          # H68K 两个补丁
.github/workflows/build.yml
```

管理 IP：X86 `192.168.1.1` / BPI-R4 `192.168.10.1` / H68K `192.168.20.1`（root，初始无密码）。

## 编译耗时参考

| 设备 | 冷启动 | 有缓存 |
|---|---|---|
| X86 | ~2.5h | ~40min |
| BPI-R4 | ~3.5h | ~1h |
| H68K | ~5.5h | ~1.5h |

构建缓存覆盖 `staging_dir/host*` 与 `staging_dir/tool*`（工具链），源码有变动时自动失效。
GitHub 托管 runner 单 job 上限 6h，H68K 冷启动接近上限，首次建议单独触发。
