# OpenWrt 自编译仓库（X86 / BPI-R4 / H68K）

主打**纯净**：源码基线是 OpenWrt 官方 25.12，除 H68K 的设备支持与 SONiC fullcone 外**不动内核**，只额外引入自定义软件包。

```
config/    设备矩阵 + 包配置        scripts/   构建流程（本地与 CI 同一套命令）
patches/   设备/内核补丁            .github/   两条 workflow
```

## 支持的设备

| 设备 | 平台 | 内核 | 管理 IP | 说明 |
|---|---|---|---|---|
| **X86** | `x86/64` generic | 官方原版 | `10.0.0.1` | 按 **PVE 虚拟机**定型，只出 `ext4-combined-efi.img.gz` |
| **BPI-R4** | `mediatek/filogic` | 官方原版 | `192.168.10.1` | Banana Pi BPI-R4（MT7988A），官方原生支持 |
| **H68K** | `rockchip/armv8` | 官方 + 2 个补丁 | `192.168.20.1` | Hinlink H68K（RK3568），官方 25.12 **没有**该设备 |

主机名分别为 `OpenWrt-X86` / `OpenWrt-BPI-R4` / `OpenWrt-H68K`，登录 `root`，初始无密码。默认 IP 与主机名由 `scripts/setup-device.sh` 写进 `package/base-files/files/bin/config_generate`。

## 用法

**CI 构建**：Actions → **Build OpenWrt** → Run workflow。

| 输入 | 说明 |
|---|---|
| `devices` | 设备，逗号分隔（`x86,bpi-r4,h68k`），留空=全部 |
| `version` | OpenWrt 版本（如 `25.12.6`），留空=自动取最新 25.12.x |
| `publish` | 构建完成后是否发布到 Release（默认开） |

每个设备一个 artifact；`publish` 打开时由独立的 `publish` job 汇总发布到 `v<版本>`，产物含镜像、引导件、`*.manifest` 与 `sha256sums-<设备>.txt`。

同一版本号会被重复构建，所以发布是**覆盖**语义（`scripts/publish-release.sh`）：

- 同名资产覆盖上传；
- 这次没产出的旧资产会被删掉 —— 否则改完配置再发版，Release 上会同时挂着新旧两批固件，下载的人拿到哪批全看运气；
- 产物来源的 commit 写在 Release 说明里。

**标签不会跟着产物移动。** `GITHUB_TOKEN` 不允许把 ref 指向「改动过 `.github/workflows/` 的 commit」：`git push` 直接报 `refusing to allow a GitHub App to create or update workflow`，换成 REST API 更新 ref 也是同样的 403，而 `workflows` 权限并不在 workflow 能声明的 `permissions` 列表里。本仓库几乎每个 commit 都动过 workflow，所以这条路是死的。要让标签始终指向产物对应的源码，只能引入带 `workflow` scope 的 PAT。

**本地自检**（不需要源码树，几十秒）：

```bash
bash scripts/doctor.sh        # 脚本语法 / 设备矩阵 / 配置 lint / 补丁行尾，一条命令全跑
```

push 与 PR 会触发 `.github/workflows/validate.yml`，跑的就是这同一条命令。

## 目录结构

```
config/
  devices.json         # 设备矩阵唯一事实来源：name / label / target / profile
  base.config          # 所有设备共用的包配置
  x86.config           # 设备差异：target/profile/专属驱动/分区
  bpi-r4.config
  h68k.config
patches/
  h68k/                # H68K 设备支持（U-Boot + DTS + 设备定义）+ PCIe3 PHY 固件
  fullcone/            # SONiC fullcone：内核 + iptables/nftables + fw4/fw3 + LuCI
scripts/
  lib.sh               # 公共库：die/warn/put/apply_patch_strict/json_*/ROOT
  doctor.sh            # 一键静态自检（CI 的 validate 就是它）
  check-devices.sh     # 设备矩阵 ↔ config/<name>.config 交叉校验
  lint-config.sh       # 配置 lint：行语法 / 重复符号 / 覆盖顺序
  fetch-packages.sh    # 克隆上游包到 package/custom/、修上游 Makefile、换 feeds、去重
  setup-device.sh      # 默认 IP / 主机名 / LuCI 构建标识
  patch-h68k.sh        # H68K 设备补丁（带内核版本守卫）
  patch-fullcone.sh    # fullcone 补丁（必须在 feeds install 之后、download 之前）
  check-packages.sh    # 校验请求的包是否真的进了 .config
  build.sh             # 编译 + 资源心跳 + 失败定位
  collect-artifacts.sh # 从 bin/targets 收集镜像/引导件/manifest + 校验和
  publish-release.sh   # 发布到 Release：覆盖同名资产、清掉这次没产出的旧资产
.github/workflows/
  build.yml            # 三设备矩阵构建 → 汇总发布
  republish.yml        # 不重编，把某次构建的 artifact 重新发布（发布失败时用）
  validate.yml         # push/PR 静态校验
.gitattributes         # 强制 LF
.editorconfig          # 缩进 / 行尾 / 编码约定
```

## 设计要点

### 不设 `CONFIG_ALL_KMODS`

它的语义是 *Select all kernel module packages by default* —— 会把官方树里每一个 kmod 都编译进去。这是之前 X86 要 2.5h、H68K 逼近 6h 上限的主因。

设备真正需要的 kmod 在 `config/<设备>.config` 里显式列出即可（defconfig 会保留显式选择），被其他包依赖的 kmod 由 Makefile 的 `DEPENDS` 自动带入。构建流程对 `kmod-*` 也做严格校验：请求了但没生效会直接失败并打印依赖诊断，不会静默产出缺驱动的固件。

### X86 镜像的 PVE 取向

X86 这台按「PVE 里的路由虚拟机」定型（q35 + OVMF + virtio-scsi-single），不是刷物理机 U 盘的：

- **ext4 根分区，不出 squashfs**：导入 8G 盘后可以 `fdisk` 删掉重建分区 2 + `resize2fs` 扩到整盘；只读的 squashfs 根做不到这一点。代价是没有「恢复出厂」的只读基底，回滚靠快照。
- **只出 UEFI（`*-ext4-combined-efi.img.gz`）**：legacy BIOS 的 `combined.img.gz` 在 VM 里用不上，关掉少做一份镜像（x86 镜像阶段是整轮构建的磁盘峰值）。
- **不带 docker**：容器交给 PVE 的 LXC / 独立 VM，路由镜像里再塞一套 dockerd 只是白占空间与 kmod。
- virtio 驱动不需要额外装任何 kmod：`target/linux/x86/64/config-6.12` 里 `VIRTIO_PCI` / `VIRTIO_BLK` / `VIRTIO_NET` / `SCSI_VIRTIO` / `VIRTIO_BALLOON` / `HW_RANDOM_VIRTIO` 全是 `=y`。

```bash
gunzip openwrt-25.12.6-x86-64-generic-ext4-combined-efi.img.gz
qm create 100 --name OpenWrt --ostype l26 --machine q35 --bios ovmf \
  --cpu host --cores 2 --memory 2048 --balloon 0 \
  --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr1,firewall=0 \
  --serial0 socket --vga serial0 --onboot 1
qm importdisk 100 openwrt-25.12.6-x86-64-generic-ext4-combined-efi.img local-zfs
qm set 100 --efidisk0 local-zfs:0,efitype=4m,pre-enrolled-keys=0
qm set 100 --scsi0 local-zfs:vm-100-disk-0,discard=on,ssd=1 --boot order=scsi0
# 启动后扩容根分区（镜像里分区 2 只有 1G）：
#   fdisk /dev/sda → 删分区 2、按原起始扇区重建 → resize2fs /dev/sda2
```

## 设备补丁

### H68K（唯一「改内核/设备树」的整机）

官方 25.12 的 rockchip/armv8 没有 Hinlink H68K，需 backport OpenWrt PR#21270：

1. `patches/h68k/h68k-backport.patch` — U-Boot 目标、设备树、镜像布局、board.d 网口/指示灯、网卡中断亲和性
2. `patches/h68k/105-phy-rockchip-snps-pcie3-sram-firmware.patch` — RK3568 PCIe3 PHY 内部 SRAM 固件手动上传。2022 旧版 H68K 上该 SRAM 自动加载永不完成（`p3phy lock failed` → `probe -110`），导致 **eth2/eth3（RTL8125B 2.5G）不出现**；此补丁绕过该硬件批次缺陷

`scripts/patch-h68k.sh` 对落地做了四重校验：内核必须是 6.12（补丁路径写死在 `patches-6.12`）、`fuzz=0` 优先应用、应用后 `.rej` 无残留、设备定义真的进了 `armv8.mk`。

### 全锥形 NAT（SONiC fullcone）

官方 25.12 已移除 `kmod-nft-fullcone`，所以 `base.config` 里没有它。全锥形改由 `scripts/patch-fullcone.sh` 打 9 个补丁实现（`patches/fullcone/`）：

| 层 | 补丁 | 落到哪 |
|---|---|---|
| 内核 | 984 / 985 / 986 | `target/linux/generic/hack-6.12/` |
| iptables | 901 | `package/network/utils/iptables/patches/` |
| libnftnl | 001 | `package/libs/libnftnl/patches/` |
| nftables | 002 | `package/network/utils/nftables/patches/` |
| fw4 / fw3 | 001 各一个 | `package/network/config/firewall4|firewall/patches/` |
| LuCI | 001 | `feeds/luci/applications/luci-app-firewall/patches/` |

要点：

- **不产生新内核模块、不需要任何 `CONFIG_*`**。fullcone 表达式直接编进 `nf_nat` / `xt_MASQUERADE` / `nft_masq`，固件里不用装额外 kmod，也不存在「编了但没加载」
- **必须晚于 `feeds install`**（LuCI 补丁要落到 feeds 目录下）；**必须早于 `make download`**（`libnftnl` 补丁改了 `src/Makefile.am`，脚本同时注入 `PKG_FIXUP:=autoreconf`，否则 automake 版本对不上会报 `automake-1.17: not found`）
- 与旧 `nft-fullcone` 的区别：映射存在 conntrack 自身（第二张 3-tuple 哈希表，RCU 读路径），支持全部 L4 协议，per-rule 标志位——不走 fullcone 的流量零额外开销
- 启用要两步：`defaults.fullcone` 是总开关（默认关，关着时 zone 里的设置无效），再给 wan zone 单独开

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

基底保持官方纯净（LuCI + 中文语言包），只引入以下**原始上游**仓库。完整清单与目录名规则以 `scripts/fetch-packages.sh` 的 `clone_pkg` 行为准（一行一个源，数量由 `scripts/doctor.sh` 打印）：

| 分类 | 包 | 上游仓库 |
|---|---|---|
| NAT / P2P / 端口转发 | `luci-app-natmapt`、`stuntman-client`、`luci-app-socat-reforged` | `muink/openwrt-natmapt`、`muink/openwrt-stuntman`、`busybin/luci-app-socat-reforged` |
| DNS | `luci-app-mosdns`、`luci-app-oxidns`、`luci-app-kixdns`、`luci-app-adguardhome-tk` | `sbwml/luci-app-mosdns`(v5)、`hahaher123/luci-app-oxidns`、`JohnsonRan/luci-app-kixdns`、`w9315273/luci-app-adguardhome` |
| 穿透 / 带宽 / 组网 | `luci-app-bandix`、`luci-app-easytier`、`luci-app-honk`、`luci-app-zerotier` | `timsaya/*`、`EasyTier/luci-app-easytier`、`189160/luci-app-honk`、`rabbitrogi/luci-app-zerotier` |
| 媒体 / 推送 | `luci-app-unblockneteasemusic`、`luci-app-wechatpush`、`luci-app-airconnect` | `UnblockNeteaseMusic/...`(js)、`tty228/luci-app-wechatpush`、`sbwml/luci-app-airconnect` |
| 任务 / 定时 / 运维 | `luci-app-taskplan`、`luci-app-tasks`、`luci-app-timecontrol`、`luci-app-partexp`、`luci-app-watchdog`、`luci-app-netspeedtest`、`luci-app-online-upgrade`、`luci-app-substore` | `sirpdboy/*`、`Arthur97172/*` |
| 容器 / 磁盘 / 文件 / 网盘 | `luci-app-dockox`、`luci-app-diskbox`、`luci-app-harbor-file-pro`、`luci-app-openlist2`、`luci-app-wolmon`、`luci-app-oaf` | `permails/*`、`whzhni1/...`、`sbwml/luci-app-openlist2`、`my1639963/...`、`destan19/OpenAppFilter` |
| 其他 | `luci-app-vlmcsd`（KMS） | `permails/luci-app-vlmcsd` |
| 主题 | `luci-theme-footstrap`、`luci-theme-aurora` + `luci-app-aurora-config`、`luci-theme-shadcn` | `VizzleTF/...`、`eamonxg/...` |
| 硬件信息 | `autocore-arm` / `autocore-x86` | `MinimaxFlora/autocore`(openwrt-25.12) |
| 科学插件备份 | helloworld 整仓 44 包（未被 config 选中的不编译） | `sbwml/openwrt_helloworld`(v5) |

官方 feeds 里需要显式选中的依赖：`node`（换 sbwml 预编译版）、`zerotier`、`dnsmasq-full`、`xz-utils`。

按 helloworld README 的配套操作：feeds 自带的 `xray-core/v2ray-core/v2ray-geodata/sing-box` 等同名核心自动移除（由 helloworld 版本接管）；`lang/golang` 换 sbwml `27.x`；`lang/node` 换 sbwml 预编译版。最后一步统一删除 feeds 中与 `package/custom` 同名的副本，避免 buildroot 重复定义。

### 自研插件：luci-app-apbridge

`SSkong/luci-app-apbridge` —— 跨子网访问 AP / 光猫。上游同类插件是 `zyqfork/luci-app-ap-modem`，本插件重写了实现：

- **不抓页面**。它解决的是三层可达性：在目标设备所在子网里占用一个空闲地址，LAN 侧用 veth 对把这段地址从 `br-lan` 的三层接口上摘出去，再连同 WAN 侧通道一起丢进 wan 防火墙区域做 masquerade。目标设备看到的源地址在它自己的网段里，因此不需要它有任何回程路由。
- **多条通道**走 `form.GridSection`，不再固定只有 LAN / WAN 两个框；冲突检测在脚本里（与回环、LAN 网段、其它通道比较），界面上以「未创建」直接体现。
- 前端 JS + 后端 `/usr/share/rpcd/ucode/luci.apbridge`，状态面板 5 秒轮询，支持 ping/HTTP 连通性测试与跳转。
- 依赖只有 `rpcd-mod-ucode` / `firewall4`，无编译产物，构建开销可忽略。刻意不依赖 `ip-tiny`（与 `ip-full` 冲突）。

`scripts/fetch-packages.sh` 里对应一行 `clone_pkg luci-app-apbridge SSkong/luci-app-apbridge main`，`config/base.config` 里启用 `CONFIG_PACKAGE_luci-app-apbridge=y`。

## 新增设备

1. 加 `config/<name>.config` —— 至少含 `CONFIG_TARGET_<a>=y`、`CONFIG_TARGET_<a>_<b>=y`、`CONFIG_TARGET_<a>_<b>_DEVICE_<profile>=y`。
2. 加 `config/devices.json` 条目 —— `name`（= 上一步文件名）、`label`、`target`（`"<a>/<b>"`）、`profile`。
   `profile` 不是装饰：`check-devices.sh` 会拿它比对 `..._DEVICE_<profile>=y`。
3. 在 `scripts/setup-device.sh` 的 `case` 里加一行默认 IP 与主机名。
4. 跑 `bash scripts/doctor.sh`（也可 `bash scripts/check-devices.sh <name>` 只验一个）。
5. 若该设备需要自己的补丁，照 `scripts/patch-h68k.sh` 加一个脚本 + `patches/<name>/`，并在 `build.yml` 里按 `matrix.name == '<name>'` 加一步。补丁守卫直接复用 `scripts/lib.sh`。

## 脚本约定

- 统一三行开头：`#!/usr/bin/env bash`、`set -uo pipefail`、`. "$(cd "$(dirname "$0")" && pwd)/lib.sh"`。
  不加 `-e`：有些失败是有意容错的（例如换源失败回退官方版本），一律在调用处显式 `|| die` / `|| warn`。
- 公共守卫在 `scripts/lib.sh`：`die` / `warn`（`::warning::`，GitHub 渲染成注解）/ `step` / `sub` / `require_file` / `require_dir` / `enter` / `ensure_dir` / `put` / `check_no_crlf` / `apply_patch_strict` / `check_rej` / `has_line`（BRE 正则）/ `has_text`（固定字符串）/ `json_devices` / `json_dev_field`。
  路径常量也在这里：`ROOT` / `CONFIG_DIR` / `PATCH_DIR`，脚本里不再各算一遍。
- **凡是 `sed -i` 改上游文件，改完必须断言**。sed 匹配不到时退出码仍是 0，脚本会假装成功——管理 IP 悄悄变回 `192.168.1.1` 这种事，刷进去才发现。
- 断言里别写 `\$`：`case` 模式中被引号包住的 `*` 会变成字面量，`grep` BRE 里的 `\$` 行为也不一致。字面量用 `has_text` 或字符类 `[$]`。

## 构建耗时

实测（三设备并发、工具链缓存未命中，ccache 上线前，run 41213077974）：

| 设备 | 并行构建 |
|---|---|
| X86 | ≈ 3 h |
| BPI-R4 | ≈ 4 h 15 min |
| H68K | ≈ 4 h 15 min |

单 job 硬上限 360 分钟，`timeout-minutes: 355` 是留出的余量（首轮 ccache 未命中时，写缓存本身会把编译拖慢几个百分点）。三设备同时跑会互相抢 CPU，想快就一次只选一个设备。

### CI 缓存了什么

两层，都是 Actions cache：

| 缓存 | 路径 | 压缩后大小 | key |
|---|---|---|---|
| 工具链 | `openwrt/staging_dir/host*`、`tool*` | ≈ 400 MB/台 | `<设备>-<源码 commit>` |
| 编译对象 | `openwrt/.ccache` | ≈ 1~2 GB/台（上限 2 G） | `<设备>-ccache-<源码 commit>-<run_id>` |

工具链缓存恢复后必须刷新 stamp 时间戳，否则 make 认为 host/工具链未安装而重编。

**为什么缓存 `.ccache` 而不是 `build_dir` 里的内核产物。** `build_dir/target-*/linux-<board>/` 看起来更直接（内核编译占单轮 50~70 分钟），但它的失效条件和「需要重编」的条件几乎重合：`.prepared` 的 stamp 名字里带内核补丁目录的 md5，`target/linux` 一动就 `rm -rf` 整块重建；换 OpenWrt 版本又会让源码 commit 变、key 全 miss。而 ccache 是**文件级**哈希（源文件 + 命令行 + 编译器 + 头文件），`.config` 只改包选择时内核对象照样命中 —— 它比目录快照耐用得多。

两个必要的环境变量（写在 `build` job 的 `env`）：

- `CCACHE_MAXSIZE=2G`：三台设备各一份，总配额只有 10GB，必须给工具链留位置。
- `CCACHE_COMPILERCHECK=content`：默认的 `mtime` 在 CI 里不可靠 —— 工具链每次现编，gcc 的 mtime 每轮都变，一次对不上就等于全部失效。改成按内容哈希，才和「工具链缓存这轮是否命中」解耦。

`CONFIG_CCACHE` 依赖 `CONFIG_DEVEL=y`（它在开发者菜单下，没有 DEVEL 时会被 defconfig 静默丢弃），`scripts/doctor.sh` 会检查这一条，以及 runner 上有没有装 ccache 本体。

缓存条目每轮重建：key 带 `run_id`（固定 key 命中时 `actions/cache` 不会重新保存，新对象就永远存不进去），保存前先删掉同设备的旧条目，否则会一路累加到吃光配额。首次构建没有收益，从第二轮起才体现 —— 单次净收益取决于上一轮之后改了多少东西。

源码包和语言级编译缓存**都不缓存**：

- **`dl/` 不缓存**：重新下载只要几分钟，缓存它挤占配额不划算。
- **Go 不缓存**：GOCACHE 回到默认的 `$(TMP_DIR)/go-build`（`openwrt/tmp`），每轮重编。曾经把它指到外部目录并缓存过，可行，但那份配额换来的收益不值，已回退。
- **Rust 不能按 target 目录缓存**：把 `CARGO_TARGET_DIR` 指到外部后，产物不再落在包目录的 `target/`，而 smartdns-ui 这类包的 Makefile 写死了这个相对路径（`cp target/$(CARGO_BUILD_TARGET)/release/libsmartdns_ui.so ...`），cargo 照样 "Finished"、紧接着 `cp` 找不到文件，编译 4 小时后失败（run 41108533638）。真要缓存应走 `CONFIG_RUST_SCCACHE`（`RUSTC_WRAPPER=sccache`，不动 target 目录、对包 Makefile 透明），但要先在 runner 上装 sccache。

**配额提醒**：仓库总配额 10GB，现在是 3 份工具链（≈1.2GB）+ 3 份 ccache（最多 6GB）。若发现缓存被 LRU 反复淘汰（日志里没改源码却一直 cache miss），先降 `CCACHE_MAXSIZE`，再考虑减少构建频率。

## 如何确认一次构建是真的可用

编译通过只说明代码能跑完，不代表固件能启动。按这个顺序看：

1. **构建摘要里没有 `✗ 未生效`** —— 流程会打印请求包数、无源码目录的包、被 defconfig 取消选中的包；`luci-app-*` / `luci-theme-*` / `kmod-*` 有丢失会直接判失败。这段逻辑在 `scripts/check-packages.sh`，可以脱离 CI 单独跑（生成 `.config` 之后、`make download` 之前）：

   ```bash
   bash scripts/check-packages.sh openwrt x86
   ```

   退出码 0 全部生效 / 1 有关键包没进 `.config` / 2 前置文件缺失。它会把未生效包的 `depends on` 段落打印出来，并标出哪个依赖符号没启用——包括 `!PACKAGE_x` 这种否定依赖（方向是反的，x 未启用才算满足）。
2. **产物非空且带 `*.manifest`** —— manifest 是已装包清单，用 `grep` 直接确认某个包到底进没进固件，比看目录结构可靠。
3. **`sha256sums-<设备>.txt` 与镜像同目录** —— 下载后先校验，排除传输损坏。
4. **设备侧验证**：X86 直接在 PVE 里起虚拟机看能否进系统；BPI-R4 用 `sdcard.img.gz` 写 TF 卡启动；H68K 刷完先看 `dmesg | grep -E "fw-d54d0eb|p3phy"` 与 `ip -br link`，确认 PHY 补丁生效、eth2/eth3 在不在。
5. **失败时先看 `diag-*` artifact** —— 含 `.config`、`.config.requested`、`openwrt/logs/`、`build.log`/`retry.log` 尾部与资源曲线（`usage.log`），不用回头翻控制台。
