# GRUB2 自动配置与主题安装脚本

基于 Ubuntu（如 Ubuntu 26.04 LTS）及 Debian 系发行版的 GRUB2 一键交互式配置脚本，集成 [vinceliuice/grub2-themes](https://github.com/vinceliuice/grub2-themes) 子模块主题安装、自定义启动项预留与纯终端（`tty1`）配置、菜单标题自动修改（发行版名称 + 主版本号）以及 `/etc/default/grub` 最佳实践优化。

## 功能特性

1. **交互式安装 `grub2-themes` 主题**
   - 自动检测、同步（`git submodule sync`）并初始化或更新 `grub2-themes` Git 子模块。
   - 交互式选择主题款式（默认 `whitesur`，可选 `tela` / `vimix` / `stylish`）。
   - 交互式选择图标风格（默认 `color`，可选 `white` / `whitesur`）。
   - 交互式选择屏幕分辨率（默认 `1080p` 即 `1920x1080,auto`，可选 `2k` / `4k` / `ultrawide` / `ultrawide2k` 或自定义分辨率 `-c`）。
   - 交互式选择安装路径（默认 `-b` 安装至 `/boot/grub/themes`，可选 `/usr/share/grub/themes`），支持卸载已安装主题（`-r`）。

2. **逐步选项配置 `/etc/default/grub`（默认采用 `grub` 文件中的参数）**
   - 支持**逐步通过选项设置每一项参数**（默认直接回车即为 `grub` 中的预设值），也支持一键应用全部预设默认值：
     1. `GRUB_DEFAULT`：默认 `0`（可选 `saved` 或自定义序号/菜单名/EFI 路径）
     2. `GRUB_SAVEDEFAULT`：默认 `false`（可选 `true`）
     3. `GRUB_TIMEOUT_STYLE`：默认 `menu`（可选 `hidden` / `countdown`）
     4. `GRUB_TIMEOUT`：默认 `3` 秒（可选 `1` / `5` / `10` / `0` 秒或自定义）
     5. `GRUB_DISTRIBUTOR`：默认 `"Ubuntu"`（可选动态读取 `/etc/os-release` 或自定义）
     6. `GRUB_CMDLINE_LINUX_DEFAULT`：默认 `"quiet splash nomodeset zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc"`（可选无 `nomodeset`、Ubuntu 原始默认、保持不变或自定义）
     7. `GRUB_CMDLINE_LINUX`：默认 `"nvidia-drm.modeset=1 nvidia-drm.fbdev=1 nvidia.NVreg_EnableGpuFirmware=0"`（可选留空、保持不变或自定义）
     8. `GRUB_DISABLE_RECOVERY`：默认 `true`（可选 `false`）
     9. `GRUB_DISABLE_SUBMENU`：默认 `true`（可选 `false`）
     10. `GRUB_DISABLE_OS_PROBER`：默认 `false`（可选 `true`）
     11. `GRUB_GFXMODE`：默认 `1920x1080,auto`（自动跟随所选主题分辨率或自定义）

3. **添加自定义启动项**
   - **选项 1：默认的 Console tty1 纯控制台启动项**（`/etc/grub.d/09_terminal_entry`）：在 `10_linux` 之前（即菜单第 0 项）生成纯终端启动项，通过内核参数 `systemd.unit=multi-user.target` 直接进入控制台环境。当启用时，提供无人值守默认进入控制台（`GRUB_DEFAULT=0, menu, 3秒`）或优先进入桌面系统（`GRUB_DEFAULT=1`）的选项。
   - **选项 2：自定义添加新的启动项（预留入口）**：支持在 `/etc/grub.d/` 生成自定义启动项模板（Linux 内核引导模板、ISO 镜像 loopback 免刻盘引导模板、空白 GRUB menuentry 脚本模板），方便后续使用 vim 灵活拓展。
   - **选项 3**：跳过此步骤。

4. **修改系统菜单选项标题**（`/etc/grub.d/99_rename_entries`）
   - **选项 1：默认名称保持不变**：不修改 GRUB 原生生成的菜单标题；若已安装改名脚本可选择将其禁用或彻底删除。
   - **选项 2：发行版名称 + 主版本号（推荐）**：自动探测并将系统选项统一命名为规范的「发行版名称 + 主版本号」（例如：`Ubuntu 26.04`、`Debian 13`、`Windows 11`、`Fedora 41`，UEFI 设置项精简为 `UEFI`）。
   - **选项 3：逐项自定义配置**：按探测顺序逐一为每个系统指定名称（默认名称 / 发行版+主版本号 / 手动输入自定义名称）。
   - **旧内核去重与持久化**：当开启扁平菜单（`GRUB_DISABLE_SUBMENU=true`）时，自动去除多余的旧内核启动项，仅保留每个 OS 最新的一项；脚本位于 `/etc/grub.d/99_rename_entries`，后续内核升级触发 `update-grub` 时持续生效。

5. **全局状态检测看板与安全保障**
   - 运行前自动展示当前系统 GRUB 已安装组件看板（主题激活状态与磁盘主题、控制台及其他自定义脚本状态、改名脚本状态、完整核心参数解析列表）。
   - 对已存在的组件提供完整的生命周期管理（保持现有 / 重新配置 / 临时禁用 0644 / 恢复启用 0755 / 彻底删除）。
   - 修改前自动备份 `/etc/default/grub`、`/boot/grub/grub.cfg` 及自定义脚本至 `/var/backups/grub-auto-config/<时间戳>/`。
   - 配置完成后自动调用 `update-grub` / `grub-mkconfig` 并执行 `grub-script-check` 校验语法完整性，确保配置立即生效且安全可靠。
   - 支持 `-n` / `--dry-run` 沙箱演练模式（零系统改动）与 `--restore` 一键回滚。

## 目录结构

```text
.
├── install.sh          # 主交互式配置与安装脚本
├── grub                # /etc/default/grub 参考配置与默认参数来源
├── 09_terminal_entry   # 纯控制台 (tty1) 启动项独立示例脚本
├── 99_rename_entries   # GRUB 菜单标题精简与去重独立示例脚本
├── grub2-themes/       # vinceliuice/grub2-themes Git 子模块
└── README.md           # 说明文档
```

## 快速开始

### 1. 克隆仓库（含子模块）

```bash
git clone --recurse-submodules git@github.com:eallion/grub.git
cd grub
```

若克隆时未添加 `--recurse-submodules`，运行 `install.sh` 时脚本也会自动同步并初始化子模块。

### 2. 演练模式（Dry-Run）

在不修改系统任何文件的前提下，完整体验交互流程、查看 `/etc/default/grub` 的 `diff` 变更以及预览最终生效的 GRUB 菜单列表：

```bash
chmod +x install.sh
# 读取真实的 /boot/grub/grub.cfg 进行沙箱演练（推荐，不修改任何系统文件）
sudo ./install.sh --dry-run

# 或以普通用户运行（当 /boot/grub/grub.cfg 不可读时，自动基于 /boot 构建模拟菜单演练）
./install.sh -n
```

### 3. 正式运行自动配置脚本

```bash
sudo ./install.sh
```

按终端提示依次进行配置：
1. `grub2-themes` 的主题款式、图标风格、分辨率及安装位置。
2. `/etc/default/grub` 核心参数逐步设置（默认采用 `./grub` 文件预设值）。
3. 添加自定义启动项（`1` 默认的 Console tty1 / `2` 自定义添加新启动项模板预留入口 / `3` 跳过）。
4. 修改系统菜单选项标题（`1` 默认名称保持不变 / `2` 发行版名称 + 主版本号，如 Ubuntu 26.04, Debian 13, Windows 11 / `3` 逐项自定义配置）。
5. 脚本自动调用 `update-grub` 生效配置并展示最终菜单列表，确认或微调默认启动项 `GRUB_DEFAULT`。

### 4. 恢复备份

如需回滚至修改前的配置：

```bash
# 恢复最近一次备份
sudo ./install.sh --restore

# 或指定具体备份目录恢复
sudo ./install.sh --restore /var/backups/grub-auto-config/20261010_133808
```

## 依赖项

- `bash`、`sed`、`grep`、`sort`、`find`
- `grub-common` / `grub2-common`（提供 `update-grub` / `grub-mkconfig`、`grub-probe`、`grub-script-check`）
- `python3`（用于解析 GRUB 菜单结构与安全原子替换）
- `os-prober`（多系统探测所需）
- `imagemagick`（当在 `grub2-themes` 中使用自定义分辨率 `-c` 或自定义背景图时自动按需安装）
- `trash-cli`（可选，删除文件时优先使用 `trash-put`）