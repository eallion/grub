#!/usr/bin/env bash
#
# GRUB2 Automated Configuration & Theme Installer
# Target OS: Ubuntu 26.04 LTS (and compatible Debian/Linux distributions)
#
# Main features:
#   1. Interactive installation/removal of vinceliuice/grub2-themes (via git submodule)
#   2. Step-by-step interactive /etc/default/grub configuration with preset defaults from ./grub
#   3. Optional /etc/grub.d/09_terminal_entry (boot to tty1 multi-user.target without GUI)
#   4. Optional /etc/grub.d/99_rename_entries (detect installed OSes in order, customize titles)
#   5. Automatic backup, restore, dry-run mode, and grub-script-check verification

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SUBMODULE_DIR="${SCRIPT_DIR}/grub2-themes"
readonly TEMPLATE_GRUB_FILE="${SCRIPT_DIR}/grub"
readonly GRUB_DEFAULT_FILE="/etc/default/grub"
readonly GRUB_D_DIR="/etc/grub.d"
readonly TERMINAL_SCRIPT="${GRUB_D_DIR}/09_terminal_entry"
readonly RENAME_SCRIPT="${GRUB_D_DIR}/99_rename_entries"
readonly BACKUP_BASE_DIR="/var/backups/grub-auto-config"

if [[ -d "/boot/grub" ]]; then
    readonly GRUB_CFG="/boot/grub/grub.cfg"
elif [[ -d "/boot/grub2" ]]; then
    readonly GRUB_CFG="/boot/grub2/grub.cfg"
else
    readonly GRUB_CFG="/boot/grub/grub.cfg"
fi

DRY_RUN="false"
DRY_RUN_DIR=""
RENAME_WAS_EXEC="false"
SELECTED_GFXMODE="1920x1080,auto"

# ANSI Colors (no emoji per user rules)
readonly C_RESET="\033[0m"
readonly C_INFO="\033[1;36m"
readonly C_OK="\033[1;32m"
readonly C_WARN="\033[1;33m"
readonly C_ERR="\033[1;31m"
readonly C_DRY="\033[1;35m"
readonly C_BOLD="\033[1m"

info()    { echo -e "${C_INFO}[INFO]${C_RESET} $*"; }
ok()      { echo -e "${C_OK}[OK]${C_RESET} $*"; }
warn()    { echo -e "${C_WARN}[WARN]${C_RESET} $*"; }
error()   { echo -e "${C_ERR}[ERROR]${C_RESET} $*" >&2; }
dry_log() { echo -e "${C_DRY}[DRY-RUN]${C_RESET} $*"; }

cleanup_on_exit() {
    if [[ "${RENAME_WAS_EXEC}" == "true" && -f "${RENAME_SCRIPT}" ]]; then
        chmod 0755 "${RENAME_SCRIPT}" 2>/dev/null || true
    fi
    if [[ -n "${DRY_RUN_DIR}" && -d "${DRY_RUN_DIR}" ]]; then
        rm -rf "${DRY_RUN_DIR}"
    fi
}
trap cleanup_on_exit EXIT

# Safe delete helper: prefer trash-cli (trash-put) per user preference, fallback to rm
safe_delete() {
    local target="$1"
    [[ ! -e "$target" ]] && return 0
    if [[ "${DRY_RUN}" == "true" ]]; then
        if command -v trash-put &>/dev/null; then
            dry_log "将删除文件: trash-put ${target}"
        else
            dry_log "将删除文件: rm -rf ${target}"
        fi
        return 0
    fi
    if command -v trash-put &>/dev/null; then
        trash-put "$target"
    else
        rm -rf "$target"
    fi
}

usage() {
    cat <<EOF
用法:
  sudo ./install.sh [选项]
  ./install.sh --dry-run

选项:
  -n, --dry-run         演练模式（不修改任何系统文件，仅演示交互流程、配置差异及生成结果）
  --restore [备份目录]   从备份恢复 GRUB 配置（不指定目录则恢复最新备份）
  -h, --help            显示此帮助信息

功能说明:
  1. 同步子模块并交互式安装 grub2-themes 主题（默认 whitesur / color / 1080p / -b）
  2. 逐步通过选项设置 /etc/default/grub 各项参数（默认采用仓库 ./grub 中的参数值）
  3. 可选添加自定义启动项（默认 Console tty1 纯控制台模式，或自定义脚本模板预留入口）
  4. 可选修改系统菜单选项标题（默认名称保持不变，或按「发行版名称 + 主版本号」自动命名）
EOF
}

ensure_root() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
            warn "当前以非 root 用户运行 --dry-run，若 ${GRUB_CFG} 不可读将基于 /boot 自动构建模拟菜单；使用 sudo ./install.sh --dry-run 可读取真实 ${GRUB_CFG}（同样不会修改任何系统文件）。"
        fi
        return 0
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        info "需要 root 权限，正在通过 sudo 重新执行..."
        exec sudo -E bash "$0" "$@"
    fi
}

init_dry_run_env() {
    DRY_RUN_DIR="$(mktemp -d /tmp/grub-dry-run.XXXXXX)"
    if [[ -r "${GRUB_DEFAULT_FILE}" ]]; then
        cp "${GRUB_DEFAULT_FILE}" "${DRY_RUN_DIR}/grub.default"
    elif [[ -r "${TEMPLATE_GRUB_FILE}" ]]; then
        cp "${TEMPLATE_GRUB_FILE}" "${DRY_RUN_DIR}/grub.default"
    else
        cat > "${DRY_RUN_DIR}/grub.default" <<'EOF'
GRUB_DEFAULT=0
GRUB_SAVEDEFAULT=false
GRUB_TIMEOUT_STYLE=menu
GRUB_TIMEOUT=3
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nomodeset zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc"
GRUB_CMDLINE_LINUX="nvidia-drm.modeset=1 nvidia-drm.fbdev=1 nvidia.NVreg_EnableGpuFirmware=0"
GRUB_DISABLE_RECOVERY=true
GRUB_DISABLE_SUBMENU=true
GRUB_DISABLE_OS_PROBER=false
GRUB_GFXMODE=1920x1080,auto
GRUB_THEME="/boot/grub/themes/whitesur/theme.txt"
EOF
    fi

    if [[ -r "${GRUB_CFG}" ]]; then
        cp "${GRUB_CFG}" "${DRY_RUN_DIR}/grub.cfg"
    else
        local distro_name="Ubuntu"
        if [[ -r /etc/os-release ]]; then
            distro_name="$(. /etc/os-release && echo "${NAME:-Ubuntu}")"
        fi
        local kver="6.14.0-generic"
        local latest_vmlinuz
        latest_vmlinuz="$(find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*rescue*' ! -name '*.old' 2>/dev/null | sort -V | tail -n 1 || true)"
        if [[ -n "${latest_vmlinuz}" ]]; then
            kver="${latest_vmlinuz#/boot/vmlinuz-}"
        fi
        cat > "${DRY_RUN_DIR}/grub.cfg" <<EOF
menuentry '${distro_name}, with Linux ${kver}' --class ubuntu --class gnu-linux --class gnu --class os \$menuentry_id_option 'gnulinux-${kver}-advanced-simulated-root-uuid' {
	load_video
	linux /boot/vmlinuz-${kver} root=UUID=simulated-root-uuid ro quiet splash
	initrd /boot/initrd.img-${kver}
}
if [ "\$grub_platform" = "efi" ]; then
menuentry 'Windows Boot Manager (on /dev/nvme0n1p1)' --class windows --class os \$menuentry_id_option 'osprober-efi-0000-0000' {
	chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
fi
if [ "\$grub_platform" = "efi" ]; then
	fwsetup --is-supported
	if [ "\$?" = 0 ]; then
		menuentry 'UEFI Firmware Settings' --class efi \$menuentry_id_option 'uefi-firmware' {
			fwsetup
		}
	fi
fi
EOF
    fi
    dry_log "已初始化演练沙箱目录: ${DRY_RUN_DIR}（不会对系统做任何实际改动）"
}

check_dependencies() {
    local missing=()
    for cmd in grub-probe python3 sed grep sort; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if ! command -v update-grub &>/dev/null && ! command -v grub-mkconfig &>/dev/null && ! command -v grub2-mkconfig &>/dev/null; then
        missing+=("grub-mkconfig")
    fi
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "缺少必要命令: ${missing[*]}"
        exit 1
    fi
}

run_update_grub() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "将执行: update-grub (生成 ${GRUB_CFG} 并通过 grub-script-check 校验)"
        return 0
    fi
    info "正在生成并更新 GRUB 配置文件 (${GRUB_CFG})..."
    if command -v update-grub &>/dev/null; then
        update-grub
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o "${GRUB_CFG}"
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o "${GRUB_CFG}"
    fi
    if command -v grub-script-check &>/dev/null && [[ -f "${GRUB_CFG}" ]]; then
        if grub-script-check "${GRUB_CFG}"; then
            ok "GRUB 配置文件语法校验通过。"
        else
            error "GRUB 配置文件语法校验失败，请检查配置或使用 --restore 恢复备份。"
            exit 1
        fi
    fi
}

backup_configs() {
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    local backup_dir="${BACKUP_BASE_DIR}/${ts}"
    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "将备份当前配置 (${GRUB_DEFAULT_FILE}, ${GRUB_CFG}, 自定义脚本) 至: ${backup_dir}"
        return 0
    fi
    mkdir -p "${backup_dir}"

    [[ -f "${GRUB_DEFAULT_FILE}" ]] && cp -a "${GRUB_DEFAULT_FILE}" "${backup_dir}/grub.default"
    [[ -f "${GRUB_CFG}" ]] && cp -a "${GRUB_CFG}" "${backup_dir}/grub.cfg"
    [[ -f "${TERMINAL_SCRIPT}" ]] && cp -a "${TERMINAL_SCRIPT}" "${backup_dir}/09_terminal_entry"
    [[ -f "${RENAME_SCRIPT}" ]] && cp -a "${RENAME_SCRIPT}" "${backup_dir}/99_rename_entries"

    ok "已备份当前 GRUB 配置至: ${backup_dir}"
}

restore_backup() {
    local target_dir="${1:-}"
    if [[ -z "${target_dir}" ]]; then
        if [[ ! -d "${BACKUP_BASE_DIR}" ]]; then
            error "未找到备份目录: ${BACKUP_BASE_DIR}"
            exit 1
        fi
        target_dir="$(find "${BACKUP_BASE_DIR}" -mindepth 1 -maxdepth 1 -type d | sort | tail -n 1)"
    fi

    if [[ -z "${target_dir}" || ! -d "${target_dir}" ]]; then
        error "无效的备份目录: ${target_dir}"
        exit 1
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "将从 ${target_dir} 恢复 ${GRUB_DEFAULT_FILE}、${TERMINAL_SCRIPT}、${RENAME_SCRIPT} 并执行 update-grub"
        return 0
    fi

    info "正在从 ${target_dir} 恢复配置..."
    [[ -f "${target_dir}/grub.default" ]] && cp -a "${target_dir}/grub.default" "${GRUB_DEFAULT_FILE}"
    if [[ -f "${target_dir}/09_terminal_entry" ]]; then
        cp -a "${target_dir}/09_terminal_entry" "${TERMINAL_SCRIPT}"
    else
        safe_delete "${TERMINAL_SCRIPT}"
    fi
    if [[ -f "${target_dir}/99_rename_entries" ]]; then
        cp -a "${target_dir}/99_rename_entries" "${RENAME_SCRIPT}"
    else
        safe_delete "${RENAME_SCRIPT}"
    fi

    run_update_grub
    ok "配置恢复完成。"
}

active_grub_default_file() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "${DRY_RUN_DIR}/grub.default"
    else
        echo "${GRUB_DEFAULT_FILE}"
    fi
}

active_grub_cfg_file() {
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo "${DRY_RUN_DIR}/grub.cfg"
    else
        echo "${GRUB_CFG}"
    fi
}

# Safely set or update a key=value in /etc/default/grub (and deduplicate multiple active lines for the same key)
set_grub_default_kv() {
    local key="$1"
    local val="$2"
    local target_file
    target_file="$(active_grub_default_file)"

    python3 - "${target_file}" "${key}" "${val}" <<'PYEOF'
import re, sys

path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

active_pat = re.compile(rf'^\s*{re.escape(key)}=')
comment_pat = re.compile(rf'^\s*#\s*{re.escape(key)}=')

has_active = any(active_pat.match(line) for line in lines)
out = []
replaced = False

if has_active:
    for line in lines:
        if active_pat.match(line):
            if not replaced:
                out.append(f"{key}={val}\n")
                replaced = True
            # Drop duplicate active definitions of the same key
        else:
            out.append(line)
else:
    for line in lines:
        if not replaced and comment_pat.match(line):
            out.append(f"{key}={val}\n")
            replaced = True
        else:
            out.append(line)
    if not replaced:
        if out and not out[-1].endswith('\n'):
            out[-1] += '\n'
        out.append(f"{key}={val}\n")

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(out)
PYEOF
}

# ==============================================================================
# 0. Global Installed Components Detection Panel
# ==============================================================================
detect_installed_components() {
    echo ""
    echo -e "${C_BOLD}=== 当前系统 GRUB 已安装配置与组件检测 ===${C_RESET}"

    # 1. Theme status
    local cur_theme=""
    local target_default
    target_default="$(active_grub_default_file)"
    if [[ -r "${target_default}" ]]; then
        cur_theme="$(grep -E '^[[:space:]]*GRUB_THEME=' "${target_default}" | tail -n1 | cut -d= -f2- | tr -d '"'"'" || true)"
    fi
    local found_themes=()
    for dir in "/boot/grub/themes" "/boot/grub2/themes" "/usr/share/grub/themes"; do
        if [[ -d "$dir" ]]; then
            while IFS= read -r tpath; do
                [[ -n "$tpath" ]] && found_themes+=("$(basename "$tpath") (${dir})")
            done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
        fi
    done

    if [[ -n "${cur_theme}" ]]; then
        echo -e "  [主题状态]   ${C_OK}已配置${C_RESET}: ${cur_theme}"
    else
        echo -e "  [主题状态]   ${C_WARN}未配置${C_RESET} (未设置 GRUB_THEME)"
    fi
    if [[ ${#found_themes[@]} -gt 0 ]]; then
        echo -e "               磁盘已安装主题目录: ${found_themes[*]}"
    fi

    # 2. Custom boot entries (09_terminal_entry and others)
    if [[ -f "${TERMINAL_SCRIPT}" ]]; then
        local t_title
        t_title="$(grep -oP "menuentry '[^']+'" "${TERMINAL_SCRIPT}" 2>/dev/null | head -n1 | cut -d"'" -f2 || echo "Console tty1")"
        if [[ -x "${TERMINAL_SCRIPT}" ]]; then
            echo -e "  [自定义项]   ${C_OK}已安装控制台${C_RESET}: ${TERMINAL_SCRIPT} (标题: '${t_title}', 状态: 已启用 0755)"
        else
            echo -e "  [自定义项]   ${C_WARN}控制台已禁用${C_RESET}: ${TERMINAL_SCRIPT} (标题: '${t_title}', 状态: 已禁用 0644)"
        fi
    else
        echo -e "  [自定义项]   未安装控制台脚本: ${TERMINAL_SCRIPT}"
    fi

    local extra_custom=()
    if [[ -d "${GRUB_D_DIR}" ]]; then
        for f in "${GRUB_D_DIR}"/*; do
            [[ ! -f "$f" ]] && continue
            local fname
            fname="$(basename "$f")"
            if [[ "$fname" =~ ^[0-9]{2}_ && "$fname" != "00_header" && "$fname" != "05_debian_theme" && "$fname" != "09_terminal_entry" && "$fname" != "10_linux" && "$fname" != "20_linux_xen" && "$fname" != "20_memtest86+" && "$fname" != "30_os-prober" && "$fname" != "30_uefi-firmware" && "$fname" != "40_custom" && "$fname" != "41_custom" && "$fname" != "99_rename_entries" ]]; then
                extra_custom+=("${fname}")
            fi
        done
    fi
    if [[ ${#extra_custom[@]} -gt 0 ]]; then
        echo -e "               检测到其他自定义启动项: ${extra_custom[*]}"
    fi

    # 3. Rename script 99_rename_entries
    if [[ -f "${RENAME_SCRIPT}" ]]; then
        if [[ -x "${RENAME_SCRIPT}" ]]; then
            echo -e "  [改名脚本]   ${C_OK}已安装${C_RESET}: ${RENAME_SCRIPT} (状态: 已启用 0755)"
        else
            echo -e "  [改名脚本]   ${C_WARN}已安装但禁用${C_RESET}: ${RENAME_SCRIPT} (状态: 已禁用 0644)"
        fi
    else
        echo -e "  [改名脚本]   未安装: ${RENAME_SCRIPT}"
    fi

    # 4. Core settings (/etc/default/grub)
    if [[ -r "${target_default}" ]]; then
        echo -e "  [核心参数]   (${target_default}):"
        python3 - "${target_default}" <<'PYEOF'
import re, sys

path = sys.argv[1]
try:
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
except Exception:
    lines = []

def get_val(key, default="[未设置]"):
    pat = re.compile(rf'^\s*{re.escape(key)}=(.*)$')
    for line in reversed(lines):
        m = pat.match(line)
        if m:
            val = m.group(1).strip()
            if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
                val = val[1:-1]
            return val
    return default

g_def = get_val("GRUB_DEFAULT", "0")
g_save = get_val("GRUB_SAVEDEFAULT", "false")
g_style = get_val("GRUB_TIMEOUT_STYLE", "menu")
g_timeout = get_val("GRUB_TIMEOUT", "3")
g_dist = get_val("GRUB_DISTRIBUTOR", "Ubuntu")
g_gfx = get_val("GRUB_GFXMODE", "1920x1080,auto")
g_sub = get_val("GRUB_DISABLE_SUBMENU", "true")
g_rec = get_val("GRUB_DISABLE_RECOVERY", "true")
g_prob = get_val("GRUB_DISABLE_OS_PROBER", "false")
g_cmd_def = get_val("GRUB_CMDLINE_LINUX_DEFAULT", "")
g_cmd_lin = get_val("GRUB_CMDLINE_LINUX", "")

sub_desc = " (扁平无二级子菜单)" if g_sub.lower() in ("true", "y", "yes") else " (保留二级子菜单)"
rec_desc = " (已隐藏恢复模式)" if g_rec.lower() in ("true", "y", "yes") else " (显示恢复模式)"
prob_desc = " (多系统探测已启用)" if g_prob.lower() in ("false", "n", "no") else " (多系统探测已禁用)"

def shorten(s, max_len=75):
    if not s:
        return "[空/未设置]"
    return s if len(s) <= max_len else s[:max_len-3] + "..."

print(f"    • 默认启动项 (GRUB_DEFAULT)          : {g_def} (自动保存上次: {g_save})")
print(f"    • 菜单显示样式 (GRUB_TIMEOUT_STYLE)  : {g_style} (倒计时等待: {g_timeout}s)")
print(f"    • 发行版标识名 (GRUB_DISTRIBUTOR)    : {g_dist}")
print(f"    • 图形分辨率 (GRUB_GFXMODE)          : {g_gfx}")
print(f"    • 菜单扁平化 (GRUB_DISABLE_SUBMENU)  : {g_sub}{sub_desc}")
print(f"    • 隐藏恢复模式 (GRUB_DISABLE_RECOVERY): {g_rec}{rec_desc}")
print(f"    • 多系统探测 (GRUB_DISABLE_OS_PROBER): {g_prob}{prob_desc}")
print(f"    • 默认内核参数 (CMDLINE_DEFAULT)     : {shorten(g_cmd_def)}")
print(f"    • 全局内核参数 (CMDLINE_LINUX)       : {shorten(g_cmd_lin)}")
PYEOF
    fi
    echo -e "${C_BOLD}=============================================${C_RESET}"
}

run_git_in_repo() {
    if [[ -n "${SUDO_USER:-}" && "${EUID:-$(id -u)}" -eq 0 ]]; then
        sudo -u "${SUDO_USER}" git -C "${SCRIPT_DIR}" "$@"
    else
        git -C "${SCRIPT_DIR}" "$@"
    fi
}

# ==============================================================================
# 1. Submodule grub2-themes Interactive Configuration
# ==============================================================================
configure_grub2_themes() {
    echo ""
    echo -e "${C_BOLD}=== [1/4] 同步并配置安装 grub2-themes 主题 ===${C_RESET}"

    # Detect current active theme
    local cur_theme=""
    local cur_theme_name=""
    local target_default
    target_default="$(active_grub_default_file)"
    if [[ -r "${target_default}" ]]; then
        cur_theme="$(grep -E '^[[:space:]]*GRUB_THEME=' "${target_default}" | tail -n1 | cut -d= -f2- | tr -d '"'"'" || true)"
        if [[ -n "${cur_theme}" ]]; then
            cur_theme_name="$(basename "$(dirname "${cur_theme}")")"
        fi
    fi

    if [[ -n "${cur_theme}" ]]; then
        info "检测到当前已配置主题: ${C_OK}${cur_theme_name}${C_RESET} (路径: ${cur_theme})"
    else
        info "当前尚未配置 GRUB 主题 (GRUB_THEME 未设置)。"
    fi

    if command -v git &>/dev/null && [[ -e "${SCRIPT_DIR}/.git" ]]; then
        if [[ ! -f "${SUBMODULE_DIR}/install.sh" ]]; then
            if [[ "${DRY_RUN}" == "true" ]]; then
                dry_log "检测到子模块未初始化，将执行: git submodule sync --recursive && git submodule update --init --recursive"
            else
                info "检测到 grub2-themes 子模块未初始化，正在同步并拉取子模块..."
                run_git_in_repo submodule sync --recursive
                run_git_in_repo submodule update --init --recursive
                ok "grub2-themes 子模块初始化完成。"
            fi
        else
            local sync_sub
            read -r -p "是否同步并更新 grub2-themes 子模块 (git submodule sync & update --remote)？ [y/N] (默认: N): " sync_sub
            if [[ "${sync_sub:-N}" =~ ^[Yy]$ ]]; then
                if [[ "${DRY_RUN}" == "true" ]]; then
                    dry_log "将执行: git -C ${SCRIPT_DIR} submodule sync --recursive && git -C ${SCRIPT_DIR} submodule update --init --remote --recursive"
                else
                    info "正在同步并更新 grub2-themes 子模块..."
                    run_git_in_repo submodule sync --recursive
                    run_git_in_repo submodule update --init --remote --recursive
                    ok "grub2-themes 子模块已更新至远程最新提交。"
                fi
            else
                if [[ "${DRY_RUN}" == "true" ]]; then
                    dry_log "保持当前子模块版本（必要时执行 git submodule sync --recursive && git submodule update --init --recursive）"
                else
                    run_git_in_repo submodule sync --recursive >/dev/null 2>&1 || true
                    run_git_in_repo submodule update --init --recursive >/dev/null 2>&1 || true
                fi
            fi
        fi
    elif [[ ! -f "${SUBMODULE_DIR}/install.sh" ]]; then
        error "未找到 ${SUBMODULE_DIR}/install.sh 且当前环境无法运行 git submodule。"
        exit 1
    fi

    echo "请选择主题操作:"
    echo "  1) 安装 / 更新 GRUB2 主题 (默认)"
    echo "  2) 卸载已安装的 GRUB2 主题"
    echo "  3) 跳过主题配置"
    local action_choice
    read -r -p "请输入选项 [1-3] (默认: 1): " action_choice
    action_choice="${action_choice:-1}"

    case "${action_choice}" in
        3)
            info "已跳过 grub2-themes 主题配置。"
            return 0
            ;;
        2)
            echo ""
            echo "请选择要卸载的主题 (-r -t):"
            echo "  1) whitesur (默认)"
            echo "  2) tela"
            echo "  3) vimix"
            echo "  4) stylish"
            local rm_choice rm_theme
            read -r -p "请输入选项 [1-4] (默认: 1): " rm_choice
            case "${rm_choice:-1}" in
                1) rm_theme="whitesur" ;;
                2) rm_theme="tela" ;;
                3) rm_theme="vimix" ;;
                4) rm_theme="stylish" ;;
                *) warn "无效选项，使用默认 whitesur"; rm_theme="whitesur" ;;
            esac
            if [[ "${DRY_RUN}" == "true" ]]; then
                dry_log "将执行卸载命令: bash ${SUBMODULE_DIR}/install.sh -r -t ${rm_theme}"
            else
                info "正在卸载主题: ${rm_theme}..."
                bash "${SUBMODULE_DIR}/install.sh" -r -t "${rm_theme}"
            fi
            return 0
            ;;
        1|*)
            ;;
    esac

    # 1. Theme variant (-t) — default whitesur matching ./grub
    echo ""
    echo "请选择主题款式 (-t, --theme):"
    echo "  1) whitesur (默认，对应 GRUB_THEME=\"/boot/grub/themes/whitesur/theme.txt\")"
    echo "  2) tela"
    echo "  3) vimix"
    echo "  4) stylish"
    local t_choice theme_val
    read -r -p "请输入选项 [1-4] (默认: 1): " t_choice
    case "${t_choice:-1}" in
        1) theme_val="whitesur" ;;
        2) theme_val="tela" ;;
        3) theme_val="vimix" ;;
        4) theme_val="stylish" ;;
        *) warn "无效选项，使用默认: whitesur"; theme_val="whitesur" ;;
    esac

    # 2. Icon variant (-i)
    echo ""
    echo "请选择图标风格 (-i, --icon):"
    echo "  1) color    (彩色图标，默认)"
    echo "  2) white    (白色图标)"
    echo "  3) whitesur (WhiteSur 图标)"
    local i_choice icon_val
    read -r -p "请输入选项 [1-3] (默认: 1): " i_choice
    case "${i_choice:-1}" in
        1) icon_val="color" ;;
        2) icon_val="white" ;;
        3) icon_val="whitesur" ;;
        *) warn "无效选项，使用默认: color"; icon_val="color" ;;
    esac

    # 3. Screen resolution (-s or -c) — default 1080p (1920x1080,auto) matching ./grub
    echo ""
    echo "请选择屏幕分辨率 (-s, --screen / -c, --custom-resolution):"
    echo "  1) 1080p       (1920x1080，默认)"
    echo "  2) 2k          (2560x1440)"
    echo "  3) 4k          (3840x2160)"
    echo "  4) ultrawide   (2560x1080)"
    echo "  5) ultrawide2k (3440x1440)"
    echo "  6) 自定义分辨率 (-c，如 1600x900)"
    local s_choice screen_val="" custom_res=""
    read -r -p "请输入选项 [1-6] (默认: 1): " s_choice
    case "${s_choice:-1}" in
        1) screen_val="1080p";       SELECTED_GFXMODE="1920x1080,auto" ;;
        2) screen_val="2k";          SELECTED_GFXMODE="2560x1440,auto" ;;
        3) screen_val="4k";          SELECTED_GFXMODE="3840x2160,auto" ;;
        4) screen_val="ultrawide";   SELECTED_GFXMODE="2560x1080,auto" ;;
        5) screen_val="ultrawide2k"; SELECTED_GFXMODE="3440x1440,auto" ;;
        6)
            while true; do
                read -r -p "请输入自定义分辨率 (格式 宽x高，例如 1600x900): " custom_res
                if [[ "${custom_res}" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]]; then
                    SELECTED_GFXMODE="${custom_res},auto"
                    break
                fi
                warn "分辨率格式不正确，请按 宽x高 格式输入（例如 1920x1200）。"
            done
            ;;
        *) warn "无效选项，使用默认: 1080p"; screen_val="1080p"; SELECTED_GFXMODE="1920x1080,auto" ;;
    esac

    # 4. Install directory (-b, --boot) — default /boot/grub/themes matching ./grub
    echo ""
    echo "请选择主题安装目录:"
    echo "  1) /boot/grub/themes (附加 -b 参数，默认)"
    echo "  2) /usr/share/grub/themes (系统目录)"
    local b_choice boot_flag=""
    read -r -p "请输入选项 [1-2] (默认: 1): " b_choice
    case "${b_choice:-1}" in
        1) boot_flag="-b" ;;
        2) boot_flag="" ;;
        *) boot_flag="-b" ;;
    esac

    local cmd_args=("-t" "${theme_val}" "-i" "${icon_val}")
    if [[ -n "${custom_res}" ]]; then
        cmd_args+=("-c" "${custom_res}")
    else
        cmd_args+=("-s" "${screen_val}")
    fi
    if [[ -n "${boot_flag}" ]]; then
        cmd_args+=("${boot_flag}")
    fi

    local target_theme_dir="/usr/share/grub/themes"
    [[ -n "${boot_flag}" ]] && target_theme_dir="/boot/grub/themes"

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "将执行: bash ${SUBMODULE_DIR}/install.sh ${cmd_args[*]}"
        set_grub_default_kv "GRUB_THEME" "\"${target_theme_dir}/${theme_val}/theme.txt\""
        set_grub_default_kv "GRUB_GFXMODE" "${SELECTED_GFXMODE}"
    else
        info "执行命令: ${SUBMODULE_DIR}/install.sh ${cmd_args[*]}"
        bash "${SUBMODULE_DIR}/install.sh" "${cmd_args[@]}"
        ok "grub2-themes (${theme_val}) 安装完成。"
    fi
}

# ==============================================================================
# 2. Step-by-Step /etc/default/grub Settings (Defaults from ./grub)
# ==============================================================================
configure_grub_defaults() {
    echo ""
    echo -e "${C_BOLD}=== [2/4] 逐步配置 /etc/default/grub 参数（默认采用 ./grub 配置值） ===${C_RESET}"

    echo "请选择配置模式:"
    echo "  1) 逐步交互选择每一项参数 (默认)"
    echo "  2) 一键应用全部预设默认值 (来自 ./grub)"
    echo "  3) 跳过 /etc/default/grub 参数设置"
    local mode_choice
    read -r -p "请输入选项 [1-3] (默认: 1): " mode_choice
    mode_choice="${mode_choice:-1}"

    if [[ "${mode_choice}" == "3" ]]; then
        info "已跳过 /etc/default/grub 参数设置。"
        return 0
    fi

    local default_cmdline_default='quiet splash nomodeset zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc'
    local default_cmdline_linux='nvidia-drm.modeset=1 nvidia-drm.fbdev=1 nvidia.NVreg_EnableGpuFirmware=0'
    local host_distro="Ubuntu"
    if [[ -r /etc/os-release ]]; then
        host_distro="$(. /etc/os-release && echo "${NAME:-Ubuntu}" | sed -E 's/[[:space:]]*GNU\/Linux//I')"
    fi

    if [[ "${mode_choice}" == "2" ]]; then
        set_grub_default_kv "GRUB_DEFAULT" "0"
        set_grub_default_kv "GRUB_SAVEDEFAULT" "false"
        set_grub_default_kv "GRUB_TIMEOUT_STYLE" "menu"
        set_grub_default_kv "GRUB_TIMEOUT" "3"
        set_grub_default_kv "GRUB_DISTRIBUTOR" "\"${host_distro}\""
        set_grub_default_kv "GRUB_CMDLINE_LINUX_DEFAULT" "\"${default_cmdline_default}\""
        set_grub_default_kv "GRUB_CMDLINE_LINUX" "\"${default_cmdline_linux}\""
        set_grub_default_kv "GRUB_DISABLE_RECOVERY" "true"
        set_grub_default_kv "GRUB_DISABLE_SUBMENU" "true"
        set_grub_default_kv "GRUB_DISABLE_OS_PROBER" "false"
        set_grub_default_kv "GRUB_GFXMODE" "${SELECTED_GFXMODE}"
        if [[ "${DRY_RUN}" == "true" ]]; then
            dry_log "${GRUB_DEFAULT_FILE} 变更预览 (diff):"
            if [[ -r "${GRUB_DEFAULT_FILE}" ]]; then
                diff -u "${GRUB_DEFAULT_FILE}" "$(active_grub_default_file)" || true
            else
                cat "$(active_grub_default_file)"
            fi
        else
            ok "已一键应用全部预设默认参数至 ${GRUB_DEFAULT_FILE}。"
        fi
        return 0
    fi

    # --- 2.1 GRUB_DEFAULT ---
    echo ""
    echo "1) 设置默认启动项 (GRUB_DEFAULT):"
    echo "  1) 0      (第一个菜单项，默认)"
    echo "  2) saved  (上次启动的菜单项)"
    echo "  3) 自定义输入 (序号、菜单标题或 EFI 路径)"
    local c_def val_def
    read -r -p "请选择 [1-3] (默认: 1): " c_def
    case "${c_def:-1}" in
        1) val_def="0" ;;
        2) val_def="saved" ;;
        3)
            read -r -p "请输入 GRUB_DEFAULT 值 (例如 0 或 \"${host_distro}\"): " val_def
            val_def="${val_def:-0}"
            ;;
        *) val_def="0" ;;
    esac
    set_grub_default_kv "GRUB_DEFAULT" "${val_def}"

    # --- 2.2 GRUB_SAVEDEFAULT ---
    echo ""
    echo "2) 设置是否自动记住上次选择的启动项 (GRUB_SAVEDEFAULT):"
    echo "  1) false (不保存，默认)"
    echo "  2) true  (保存上次选择)"
    local c_save val_save
    read -r -p "请选择 [1-2] (默认: 1): " c_save
    case "${c_save:-1}" in
        1) val_save="false" ;;
        2) val_save="true" ;;
        *) val_save="false" ;;
    esac
    set_grub_default_kv "GRUB_SAVEDEFAULT" "${val_save}"

    # --- 2.3 GRUB_TIMEOUT_STYLE ---
    echo ""
    echo "3) 设置菜单显示样式 (GRUB_TIMEOUT_STYLE):"
    echo "  1) menu      (直接显示图形/文本菜单，默认)"
    echo "  2) hidden    (隐藏菜单，按 Esc/Shift 呼出)"
    echo "  3) countdown (单行倒计时)"
    local c_tstyle val_tstyle
    read -r -p "请选择 [1-3] (默认: 1): " c_tstyle
    case "${c_tstyle:-1}" in
        1) val_tstyle="menu" ;;
        2) val_tstyle="hidden" ;;
        3) val_tstyle="countdown" ;;
        *) val_tstyle="menu" ;;
    esac
    set_grub_default_kv "GRUB_TIMEOUT_STYLE" "${val_tstyle}"

    # --- 2.4 GRUB_TIMEOUT ---
    echo ""
    echo "4) 设置等待超时秒数 (GRUB_TIMEOUT):"
    echo "  1) 3 秒 (默认)"
    echo "  2) 1 秒"
    echo "  3) 5 秒"
    echo "  4) 10 秒"
    echo "  5) 0 秒"
    echo "  6) 自定义秒数"
    local c_timeout val_timeout
    read -r -p "请选择 [1-6] (默认: 1): " c_timeout
    case "${c_timeout:-1}" in
        1) val_timeout="3" ;;
        2) val_timeout="1" ;;
        3) val_timeout="5" ;;
        4) val_timeout="10" ;;
        5) val_timeout="0" ;;
        6)
            read -r -p "请输入超时秒数 (非负整数): " val_timeout
            [[ ! "${val_timeout:-}" =~ ^[0-9]+$ ]] && val_timeout="3"
            ;;
        *) val_timeout="3" ;;
    esac
    set_grub_default_kv "GRUB_TIMEOUT" "${val_timeout}"

    # --- 2.5 GRUB_DISTRIBUTOR ---
    echo ""
    echo "5) 设置发行版名称标识 (GRUB_DISTRIBUTOR):"
    echo "  1) \"${host_distro}\"                          (从 /etc/os-release 读取的名称，默认)"
    echo "  2) \`( . /etc/os-release && echo \${NAME} )\`   (GRUB 运行时动态读取 /etc/os-release)"
    echo "  3) 自定义输入"
    local c_dist val_dist
    read -r -p "请选择 [1-3] (默认: 1): " c_dist
    case "${c_dist:-1}" in
        1) val_dist="\"${host_distro}\"" ;;
        2) val_dist='`( . /etc/os-release && echo ${NAME} )`' ;;
        3)
            read -r -p "请输入发行版标识名称 (默认 ${host_distro}): " val_dist
            val_dist="\"${val_dist:-${host_distro}}\""
            ;;
        *) val_dist="\"${host_distro}\"" ;;
    esac
    set_grub_default_kv "GRUB_DISTRIBUTOR" "${val_dist}"

    # --- 2.6 GRUB_CMDLINE_LINUX_DEFAULT ---
    echo ""
    echo "6) 设置默认内核启动参数 (GRUB_CMDLINE_LINUX_DEFAULT):"
    echo "  1) \"${default_cmdline_default}\" (默认)"
    echo "  2) \"quiet splash zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc\" (不含 nomodeset)"
    echo "  3) \"quiet splash\" (Ubuntu 原始默认)"
    echo "  4) 保持当前文件中的值不变"
    echo "  5) 自定义输入"
    local c_cmd_def val_cmd_def
    read -r -p "请选择 [1-5] (默认: 1): " c_cmd_def
    case "${c_cmd_def:-1}" in
        1) set_grub_default_kv "GRUB_CMDLINE_LINUX_DEFAULT" "\"${default_cmdline_default}\"" ;;
        2) set_grub_default_kv "GRUB_CMDLINE_LINUX_DEFAULT" "\"quiet splash zswap.enabled=1 zswap.compressor=zstd zswap.zpool=zsmalloc\"" ;;
        3) set_grub_default_kv "GRUB_CMDLINE_LINUX_DEFAULT" "\"quiet splash\"" ;;
        4) info "保持现有 GRUB_CMDLINE_LINUX_DEFAULT 不变。" ;;
        5)
            read -r -p "请输入 GRUB_CMDLINE_LINUX_DEFAULT 内容 (不含外层双引号): " val_cmd_def
            set_grub_default_kv "GRUB_CMDLINE_LINUX_DEFAULT" "\"${val_cmd_def}\""
            ;;
        *) set_grub_default_kv "GRUB_CMDLINE_LINUX_DEFAULT" "\"${default_cmdline_default}\"" ;;
    esac

    # --- 2.7 GRUB_CMDLINE_LINUX ---
    echo ""
    echo "7) 设置全局内核启动参数 (GRUB_CMDLINE_LINUX):"
    echo "  1) \"${default_cmdline_linux}\" (NVIDIA DRM/FBDEV 参数，默认)"
    echo "  2) \"\" (留空)"
    echo "  3) 保持当前文件中的值不变"
    echo "  4) 自定义输入"
    local c_cmd_lin val_cmd_lin
    read -r -p "请选择 [1-4] (默认: 1): " c_cmd_lin
    case "${c_cmd_lin:-1}" in
        1) set_grub_default_kv "GRUB_CMDLINE_LINUX" "\"${default_cmdline_linux}\"" ;;
        2) set_grub_default_kv "GRUB_CMDLINE_LINUX" "\"\"" ;;
        3) info "保持现有 GRUB_CMDLINE_LINUX 不变。" ;;
        4)
            read -r -p "请输入 GRUB_CMDLINE_LINUX 内容 (不含外层双引号): " val_cmd_lin
            set_grub_default_kv "GRUB_CMDLINE_LINUX" "\"${val_cmd_lin}\""
            ;;
        *) set_grub_default_kv "GRUB_CMDLINE_LINUX" "\"${default_cmdline_linux}\"" ;;
    esac

    # --- 2.8 GRUB_DISABLE_RECOVERY ---
    echo ""
    echo "8) 是否禁用恢复模式菜单项 (GRUB_DISABLE_RECOVERY):"
    echo "  1) true  (禁用恢复模式条目，默认)"
    echo "  2) false (显示恢复模式条目)"
    local c_rec
    read -r -p "请选择 [1-2] (默认: 1): " c_rec
    case "${c_rec:-1}" in
        1) set_grub_default_kv "GRUB_DISABLE_RECOVERY" "true" ;;
        2) set_grub_default_kv "GRUB_DISABLE_RECOVERY" "false" ;;
        *) set_grub_default_kv "GRUB_DISABLE_RECOVERY" "true" ;;
    esac

    # --- 2.9 GRUB_DISABLE_SUBMENU ---
    echo ""
    echo "9) 是否关闭二级子菜单使菜单扁平化 (GRUB_DISABLE_SUBMENU):"
    echo "  1) true  (关闭子菜单，使菜单扁平，默认)"
    echo "  2) false (使用 Advanced options 二级子菜单)"
    local c_sub
    read -r -p "请选择 [1-2] (默认: 1): " c_sub
    case "${c_sub:-1}" in
        1) set_grub_default_kv "GRUB_DISABLE_SUBMENU" "true" ;;
        2) set_grub_default_kv "GRUB_DISABLE_SUBMENU" "false" ;;
        *) set_grub_default_kv "GRUB_DISABLE_SUBMENU" "true" ;;
    esac

    # --- 2.10 GRUB_DISABLE_OS_PROBER ---
    echo ""
    echo "10) 是否启用多系统探测 (GRUB_DISABLE_OS_PROBER):"
    echo "  1) false (启用 os-prober 探测其他系统，默认)"
    echo "  2) true  (禁用 os-prober)"
    local c_prob
    read -r -p "请选择 [1-2] (默认: 1): " c_prob
    case "${c_prob:-1}" in
        1) set_grub_default_kv "GRUB_DISABLE_OS_PROBER" "false" ;;
        2) set_grub_default_kv "GRUB_DISABLE_OS_PROBER" "true" ;;
        *) set_grub_default_kv "GRUB_DISABLE_OS_PROBER" "false" ;;
    esac

    # --- 2.11 GRUB_GFXMODE ---
    echo ""
    echo "11) 设置 GRUB 图形终端分辨率 (GRUB_GFXMODE):"
    echo "  1) ${SELECTED_GFXMODE} (默认)"
    echo "  2) 1920x1080,auto"
    echo "  3) 2560x1440,auto"
    echo "  4) 3840x2160,auto"
    echo "  5) auto"
    echo "  6) 自定义输入"
    local c_gfx val_gfx
    read -r -p "请选择 [1-6] (默认: 1): " c_gfx
    case "${c_gfx:-1}" in
        1) val_gfx="${SELECTED_GFXMODE}" ;;
        2) val_gfx="1920x1080,auto" ;;
        3) val_gfx="2560x1440,auto" ;;
        4) val_gfx="3840x2160,auto" ;;
        5) val_gfx="auto" ;;
        6)
            read -r -p "请输入 GRUB_GFXMODE (例如 1920x1080,auto): " val_gfx
            val_gfx="${val_gfx:-1920x1080,auto}"
            ;;
        *) val_gfx="${SELECTED_GFXMODE}" ;;
    esac
    set_grub_default_kv "GRUB_GFXMODE" "${val_gfx}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "${GRUB_DEFAULT_FILE} 变更预览 (diff):"
        if [[ -r "${GRUB_DEFAULT_FILE}" ]]; then
            diff -u "${GRUB_DEFAULT_FILE}" "$(active_grub_default_file)" || true
        else
            cat "$(active_grub_default_file)"
        fi
    else
        ok "/etc/default/grub 参数已更新。"
    fi
}

# ==============================================================================
# 3. Custom Boot Entries (Console tty1 & Custom Template Slot)
# ==============================================================================
configure_terminal_entry_sub() {
    local term_exists="false"
    local cur_term_title="Console tty1"
    local term_perm_str="未安装"
    if [[ -f "${TERMINAL_SCRIPT}" ]]; then
        term_exists="true"
        cur_term_title="$(grep -oP "menuentry '[^']+'" "${TERMINAL_SCRIPT}" 2>/dev/null | head -n1 | cut -d"'" -f2 || echo "Console tty1")"
        if [[ -x "${TERMINAL_SCRIPT}" ]]; then
            term_perm_str="已启用 (0755)"
        else
            term_perm_str="已禁用 (0644)"
        fi
    fi

    if [[ "${term_exists}" == "true" ]]; then
        info "检测到已安装 ${TERMINAL_SCRIPT} (当前标题: '${cur_term_title}'，状态: ${term_perm_str})"
        echo "请选择操作:"
        echo "  1) 保持现有控制台脚本不变 (默认)"
        echo "  2) 重新配置 / 更新控制台脚本标题"
        echo "  3) 临时禁用脚本 (chmod 0644，取消可执行，update-grub 将忽略)"
        echo "  4) 恢复启用脚本 (chmod 0755，恢复生效)"
        echo "  5) 彻底删除该控制台脚本"
        local term_act
        read -r -p "请输入选项 [1-5] (默认: 1): " term_act
        case "${term_act:-1}" in
            1)
                info "保持现有 ${TERMINAL_SCRIPT} 不变。"
                return 0
                ;;
            3)
                if [[ "${DRY_RUN}" == "true" ]]; then
                    dry_log "将执行: chmod 0644 ${TERMINAL_SCRIPT}"
                else
                    chmod 0644 "${TERMINAL_SCRIPT}"
                    ok "已将 ${TERMINAL_SCRIPT} 设为 0644 (已禁用)。"
                fi
                return 0
                ;;
            4)
                if [[ "${DRY_RUN}" == "true" ]]; then
                    dry_log "将执行: chmod 0755 ${TERMINAL_SCRIPT}"
                else
                    chmod 0755 "${TERMINAL_SCRIPT}"
                    ok "已将 ${TERMINAL_SCRIPT} 设为 0755 (已启用)。"
                fi
                return 0
                ;;
            5)
                safe_delete "${TERMINAL_SCRIPT}"
                if [[ "${DRY_RUN}" == "true" ]]; then
                    python3 - "$(active_grub_cfg_file)" <<'PYEOF'
import re, sys
p = sys.argv[1]
with open(p, 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()
text = re.sub(r"menuentry\s+'[^']*'\s+--class\s+terminal\b[^{]*\{.+?\n\}\n?", "", text, flags=re.DOTALL)
with open(p, 'w', encoding='utf-8') as f:
    f.write(text)
PYEOF
                fi
                ok "已删除 ${TERMINAL_SCRIPT}"
                return 0
                ;;
            2)
                # Proceed to regenerate
                ;;
            *)
                info "保持现有 ${TERMINAL_SCRIPT} 不变。"
                return 0
                ;;
        esac
    fi

    local term_title
    read -r -p "请输入纯控制台启动项的显示名称 (默认: Console tty1): " term_title
    term_title="${term_title:-Console tty1}"
    term_title="${term_title//\'/}"

    local dest_script="${TERMINAL_SCRIPT}"
    [[ "${DRY_RUN}" == "true" ]] && dest_script="${DRY_RUN_DIR}/09_terminal_entry"

    cat > "${dest_script}" <<EOF
#!/bin/sh
set -e

# 1. 动态判断 /boot 是否为独立分区，并获取 GRUB search 应指向的 UUID
BOOT_UUID=\$(grub-probe --target=fs_uuid /boot)
ROOT_UUID=\$(grub-probe --target=fs_uuid /)

# 如果 /boot 是独立分区，GRUB 加载内核时的相对路径不带 /boot
# 如果 /boot 和 / 在同一个分区，相对路径需要带 /boot
if [ "\$BOOT_UUID" = "\$ROOT_UUID" ]; then
    BOOT_REL_PATH="/boot"
else
    BOOT_REL_PATH=""
fi

# 2. 动态探测 /boot 下最新的内核版本（排除 rescue 和 .old 备份）
VMLINUZ_FILE=\$(find /boot -maxdepth 1 -name 'vmlinuz-*' ! -name '*rescue*' ! -name '*.old' | sort -V | tail -n 1)

if [ -z "\$VMLINUZ_FILE" ]; then
    exit 0
fi

KERNEL_VERSION=\$(basename "\$VMLINUZ_FILE" | sed 's/^vmlinuz-//')

# 匹配对应的 initrd 文件名
if [ -f "/boot/initrd.img-\${KERNEL_VERSION}" ]; then
    INITRD_NAME="initrd.img-\${KERNEL_VERSION}"
elif [ -f "/boot/initramfs-\${KERNEL_VERSION}.img" ]; then
    INITRD_NAME="initramfs-\${KERNEL_VERSION}.img"
else
    INITRD_NAME="initrd.img"
fi

# 3. 动态输出 GRUB 菜单项（位于 09，排在 10_linux 之前作为第一条菜单，进入 tty1 多用户纯控制台模式）
cat << EOM
menuentry '${term_title}' --class terminal --class gnu-linux --class os \\\$menuentry_id_option 'gnulinux-terminal-\${ROOT_UUID}' {
	recordfail
	load_video
	insmod gzio
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root \${BOOT_UUID}
	linux	\${BOOT_REL_PATH}/vmlinuz-\${KERNEL_VERSION} root=UUID=\${ROOT_UUID} ro systemd.unit=multi-user.target quiet splash
	initrd	\${BOOT_REL_PATH}/\${INITRD_NAME}
}
EOM
EOF

    chmod 0755 "${dest_script}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "将创建 ${TERMINAL_SCRIPT} (属主 root:root，权限 0755)，标题为 '${term_title}'。"
        python3 - "$(active_grub_cfg_file)" "${term_title}" <<'PYEOF'
import re, sys
cfg_path, title = sys.argv[1], sys.argv[2]
with open(cfg_path, 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()
text = re.sub(r"menuentry\s+'[^']*'\s+--class\s+terminal\b[^{]*\{.+?\n\}\n?", "", text, flags=re.DOTALL)
entry = (
    f"menuentry '{title}' --class terminal --class gnu-linux --class os $menuentry_id_option 'gnulinux-terminal-root' {{\n"
    f"\tlinux /boot/vmlinuz root=UUID=root ro systemd.unit=multi-user.target quiet splash\n"
    f"}}\n"
)
with open(cfg_path, 'w', encoding='utf-8') as f:
    f.write(entry + text)
PYEOF
    else
        chown root:root "${dest_script}"
        ok "已创建并启用 ${TERMINAL_SCRIPT} (属主 root:root，权限 0755，标题: '${term_title}')"
    fi

    echo ""
    warn "提示: 控制台启动项位于菜单第 0 位（第一项）。"
    echo "请选择默认启动目标与超时等待模式:"
    echo "  1) 无人值守默认进入 Console tty1 (GRUB_DEFAULT=0, menu 显示, 超时 3 秒，按方向键可切系统) (默认)"
    echo "  2) 默认优先进入 桌面系统 (GRUB_DEFAULT=1, menu 显示, 超时 3 秒)"
    echo "  3) 保持现有 /etc/default/grub 参数不变"
    local adjust_defaults
    read -r -p "请输入选项 [1-3] (默认: 1): " adjust_defaults
    case "${adjust_defaults:-1}" in
        1)
            set_grub_default_kv "GRUB_DEFAULT" "0"
            set_grub_default_kv "GRUB_TIMEOUT_STYLE" "menu"
            set_grub_default_kv "GRUB_TIMEOUT" "3"
            if [[ "${DRY_RUN}" == "true" ]]; then
                dry_log "已在沙箱中设置: GRUB_DEFAULT=0, GRUB_TIMEOUT_STYLE=menu, GRUB_TIMEOUT=3"
            else
                ok "已设置: GRUB_DEFAULT=0（默认 Console tty1），GRUB_TIMEOUT_STYLE=menu（显示菜单），GRUB_TIMEOUT=3（超时 3 秒）"
            fi
            ;;
        2)
            set_grub_default_kv "GRUB_DEFAULT" "1"
            set_grub_default_kv "GRUB_TIMEOUT_STYLE" "menu"
            set_grub_default_kv "GRUB_TIMEOUT" "3"
            if [[ "${DRY_RUN}" == "true" ]]; then
                dry_log "已在沙箱中设置: GRUB_DEFAULT=1, GRUB_TIMEOUT_STYLE=menu, GRUB_TIMEOUT=3"
            else
                ok "已设置: GRUB_DEFAULT=1（桌面系统优先），GRUB_TIMEOUT_STYLE=menu（显示菜单），GRUB_TIMEOUT=3（超时 3 秒）"
            fi
            ;;
        *)
            info "保持当前 GRUB_DEFAULT / GRUB_TIMEOUT 参数不变。"
            ;;
    esac
}

configure_custom_entry_slot() {
    echo ""
    info "--- 自定义启动项预留入口 ---"
    echo "可在 /etc/grub.d/ 中生成自定义启动项脚本模板，以数字开头控制在 GRUB 菜单中的排序。"
    echo "（例如: 08_custom 排在控制台和系统之前，15_custom 排在系统后，42_custom 排在末尾）"

    local slot_filename
    read -r -p "请输入自定义脚本文件名 (默认: 08_custom): " slot_filename
    slot_filename="${slot_filename:-08_custom}"
    slot_filename="${slot_filename//\//}"
    slot_filename="${slot_filename// /_}"

    if [[ ! "${slot_filename}" =~ ^[0-9A-Za-z_-]+$ ]]; then
        error "文件名包含非法字符，仅允许字母、数字、下划线及短横线。"
        return 1
    fi

    local target_script="${GRUB_D_DIR}/${slot_filename}"
    local dest_script="${target_script}"
    [[ "${DRY_RUN}" == "true" ]] && dest_script="${DRY_RUN_DIR}/${slot_filename}"

    if [[ -f "${target_script}" && "${DRY_RUN}" != "true" ]]; then
        warn "文件 ${target_script} 已存在。"
        local overwrite_slot
        read -r -p "是否覆盖现有文件？ [y/N] (默认: N): " overwrite_slot
        if [[ ! "${overwrite_slot:-N}" =~ ^[Yy]$ ]]; then
            info "取消创建自定义脚本。"
            return 0
        fi
    fi

    local slot_title
    read -r -p "请输入该启动项在菜单中的显示标题 (默认: Custom Boot Entry): " slot_title
    slot_title="${slot_title:-Custom Boot Entry}"
    slot_title="${slot_title//\'/}"

    echo "请选择自定义启动项的脚本模板:"
    echo "  1) Linux 内核自定义引导模板 (含独立/非独立 boot 分区探测、内核及启动参数) (默认)"
    echo "  2) ISO 镜像 loopback 引导模板 (从磁盘 ISO 镜像免刻盘直接引导)"
    echo "  3) 空白自定义 GRUB 菜单项模板 (预留代码块，供后续使用 vim 编写具体逻辑)"
    local tmpl_choice
    read -r -p "请输入选项 [1-3] (默认: 1): " tmpl_choice

    case "${tmpl_choice:-1}" in
        2)
            cat > "${dest_script}" <<EOF
#!/bin/sh
set -e

# 自定义 ISO 镜像 Loopback 免刻盘引导脚本: ${target_script}
cat << 'EOM'
menuentry '${slot_title}' --class tool --class os {
	load_video
	insmod loopback
	insmod iso9660
	insmod part_gpt
	insmod ext2
	# 请将以下路径与 UUID 替换为您实际的 ISO 文件路径:
	# set isofile="/boot/iso/rescue.iso"
	# search --no-floppy --set=root --file \$isofile
	# loopback loop \$isofile
	# linux (loop)/casper/vmlinuz boot=casper iso-scan/filename=\$isofile quiet splash
	# initrd (loop)/casper/initrd
}
EOM
EOF
            ;;
        3)
            cat > "${dest_script}" <<EOF
#!/bin/sh
set -e

# 自定义 GRUB 菜单项模板: ${target_script}
# 提示: 使用 vim 编辑此文件，修改后运行 sudo update-grub 生效
cat << 'EOM'
menuentry '${slot_title}' --class custom --class os {
	# TODO: 在此添加自定义 GRUB 指令
	# load_video
	# insmod ext2
	# search --no-floppy --fs-uuid --set=root <UUID>
	# linux /boot/vmlinuz root=UUID=<UUID> ro
	# initrd /boot/initrd.img
}
EOM
EOF
            ;;
        *)
            cat > "${dest_script}" <<EOF
#!/bin/sh
set -e

# 自定义 Linux 引导脚本模板: ${target_script}
BOOT_UUID=\$(grub-probe --target=fs_uuid /boot 2>/dev/null || true)
ROOT_UUID=\$(grub-probe --target=fs_uuid / 2>/dev/null || true)

cat << EOM
menuentry '${slot_title}' --class custom --class gnu-linux --class os {
	recordfail
	load_video
	insmod gzio
	insmod part_gpt
	insmod ext2
	search --no-floppy --fs-uuid --set=root \${BOOT_UUID:-\$ROOT_UUID}
	linux /boot/vmlinuz root=UUID=\${ROOT_UUID} ro quiet splash
	initrd /boot/initrd.img
}
EOM
EOF
            ;;
    esac

    chmod 0755 "${dest_script}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "将创建自定义脚本 ${target_script} (权限 0755，标题: '${slot_title}')"
        python3 - "$(active_grub_cfg_file)" "${slot_title}" <<'PYEOF'
import sys
cfg_path, title = sys.argv[1], sys.argv[2]
entry = f"menuentry '{title}' --class custom --class os {{\n\t# 自定义启动项模拟代码\n}}\n"
with open(cfg_path, 'r', encoding='utf-8', errors='replace') as f:
    text = f.read()
with open(cfg_path, 'w', encoding='utf-8') as f:
    f.write(entry + text)
PYEOF
    else
        chown root:root "${dest_script}"
        ok "已成功创建自定义启动项脚本: ${target_script} (权限 0755，标题: '${slot_title}')"
        info "您后续可随时使用 sudo vim ${target_script} 调整或丰富具体的引导代码。"
    fi
}

configure_custom_entries() {
    echo ""
    echo -e "${C_BOLD}=== [3/4] 添加自定义启动项 ===${C_RESET}"

    echo "请选择要添加或管理的自定义启动项:"
    echo "  1) Console tty1 纯控制台启动项 (/etc/grub.d/09_terminal_entry) (默认)"
    echo "  2) 添加新的自定义启动项 (预留入口，自动生成 /etc/grub.d/ 启动脚本模板)"
    echo "  3) 跳过此步骤"
    local entry_choice
    read -r -p "请输入选项 [1-3] (默认: 1): " entry_choice
    case "${entry_choice:-1}" in
        1)
            configure_terminal_entry_sub
            ;;
        2)
            configure_custom_entry_slot
            ;;
        3)
            info "跳过添加自定义启动项。"
            return 0
            ;;
        *)
            configure_terminal_entry_sub
            ;;
    esac
}

# ==============================================================================
# 4. Optional /etc/grub.d/99_rename_entries (Interactive OS Title Customization)
# ==============================================================================
configure_rename_entries() {
    echo ""
    echo -e "${C_BOLD}=== [4/4] 修改系统菜单选项标题 ===${C_RESET}"

    local rename_exists="false"
    local rename_perm_str="未安装"
    if [[ -f "${RENAME_SCRIPT}" ]]; then
        rename_exists="true"
        if [[ -x "${RENAME_SCRIPT}" ]]; then
            rename_perm_str="已启用 (0755)"
        else
            rename_perm_str="已禁用 (0644)"
        fi
    fi

    local rename_mode_choice="distro_version"

    if [[ "${rename_exists}" == "true" ]]; then
        info "检测到已安装 ${RENAME_SCRIPT} (状态: ${rename_perm_str})"
        echo "请选择操作:"
        echo "  1) 保持现有菜单标题设置不变 (默认)"
        echo "  2) 所有系统统一改为「发行版名称 + 主版本号」(例如: Ubuntu 26.04, Debian 13, Windows 11 等)"
        echo "  3) 逐项自定义配置各个系统的菜单标题 (交互式逐一配置)"
        echo "  4) 恢复为系统默认原始标题 (彻底删除改名脚本)"
        echo "  5) 临时禁用改名脚本 (chmod 0644，取消可执行，update-grub 将恢复默认标题)"
        echo "  6) 恢复启用改名脚本 (chmod 0755，恢复生效)"
        local ren_act
        read -r -p "请输入选项 [1-6] (默认: 1): " ren_act
        case "${ren_act:-1}" in
            1)
                info "保持现有 ${RENAME_SCRIPT} 不变。"
                return 0
                ;;
            4)
                safe_delete "${RENAME_SCRIPT}"
                ok "已删除 ${RENAME_SCRIPT}，菜单标题将恢复为 GRUB 默认原始名称。"
                return 0
                ;;
            5)
                if [[ "${DRY_RUN}" == "true" ]]; then
                    dry_log "将执行: chmod 0644 ${RENAME_SCRIPT}"
                else
                    chmod 0644 "${RENAME_SCRIPT}"
                    ok "已将 ${RENAME_SCRIPT} 设为 0644 (已禁用)。"
                fi
                return 0
                ;;
            6)
                if [[ "${DRY_RUN}" == "true" ]]; then
                    dry_log "将执行: chmod 0755 ${RENAME_SCRIPT}"
                else
                    chmod 0755 "${RENAME_SCRIPT}"
                    ok "已将 ${RENAME_SCRIPT} 设为 0755 (已启用)。"
                fi
                return 0
                ;;
            2)
                rename_mode_choice="distro_version"
                ;;
            3)
                rename_mode_choice="custom"
                ;;
            *)
                info "保持现有 ${RENAME_SCRIPT} 不变。"
                return 0
                ;;
        esac
    else
        info "当前未安装 ${RENAME_SCRIPT}"
        echo "请选择修改系统菜单选项标题的方式:"
        echo "  1) 默认名称都保持不变 (不修改 GRUB 默认生成的标题，跳过此步骤) (默认)"
        echo "  2) 发行版名称 + 主版本号 (例如: Ubuntu 26.04, Debian 13, Windows 11 等，推荐)"
        echo "  3) 逐项自定义配置 (交互式为每个检测到的系统单独设置标题或手动输入)"
        local ren_create_choice
        read -r -p "请输入选项 [1-3] (默认: 1): " ren_create_choice
        case "${ren_create_choice:-1}" in
            2)
                rename_mode_choice="distro_version"
                ;;
            3)
                rename_mode_choice="custom"
                ;;
            1|*)
                info "保持系统菜单选项为默认名称不变。"
                return 0
                ;;
        esac
    fi

    # Temporarily disable existing 99_rename_entries in real mode so we probe raw, unmodified GRUB titles in order
    if [[ "${DRY_RUN}" != "true" && -f "${RENAME_SCRIPT}" ]]; then
        [[ -x "${RENAME_SCRIPT}" ]] && RENAME_WAS_EXEC="true"
        chmod 0644 "${RENAME_SCRIPT}"
    fi

    info "正在探测当前已安装系统及其默认 GRUB 菜单顺序..."
    run_update_grub

    local cfg_to_parse
    cfg_to_parse="$(active_grub_cfg_file)"

    # Parse GRUB_CFG and system metadata (/etc/os-release, mounted partitions, EFI BCD) to extract installed systems in order
    local probe_json
    probe_json="$(python3 - "${cfg_to_parse}" <<'PYEOF'
import json, os, re, subprocess, sys

cfg_path = sys.argv[1]
try:
    with open(cfg_path, 'r', encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
except Exception:
    print("[]")
    sys.exit(0)

def clean_distro_name(raw):
    s = raw.strip().strip('"').strip("'")
    s = re.sub(r',\s*with\s+Linux.*$', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\(on\s+/dev/[^)]+\)', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\([^)]*\)', '', s)
    s = re.sub(r'\s*GNU/Linux\b', '', s, flags=re.IGNORECASE)
    if s.lower().startswith('fedora linux'):
        s = 'Fedora' + s[12:]
    elif s.lower().startswith('manjaro linux'):
        s = 'Manjaro'
    return s.strip()

def clean_version_num(distro, raw_ver):
    if not raw_ver:
        return ""
    v = raw_ver.strip().strip('"').strip("'")
    d = distro.lower()
    if d == 'ubuntu':
        parts = v.split('.')
        if len(parts) >= 2:
            return f"{parts[0]}.{parts[1]}"
        return v
    if d in ('debian', 'fedora'):
        return v.split('.')[0]
    return v

def format_distro_version(name, version_id, raw_title=""):
    if name:
        dname = clean_distro_name(name)
        dver = clean_version_num(dname, version_id)
        if dver:
            return f"{dname} {dver}".strip()
        return dname

    s = raw_title.strip().strip('"').strip("'")
    s = re.sub(r',\s*with\s+Linux.*$', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\(on\s+/dev/[^)]+\)', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\([^)]*\)', '', s)
    s = re.sub(r'\s*GNU/Linux\b', '', s, flags=re.IGNORECASE)
    if s.lower().startswith('fedora linux'):
        s = 'Fedora' + s[12:]

    m = re.match(r'^([A-Za-z!_ -]+?)\s+(?:release\s+)?([0-9]+(?:\.[0-9]+)*)', s.strip(), flags=re.IGNORECASE)
    if m:
        dname = clean_distro_name(m.group(1))
        dver = clean_version_num(dname, m.group(2))
        if dver:
            return f"{dname} {dver}".strip()
        return dname
    return clean_distro_name(s)

def read_os_release_from_root(root_dir="/"):
    for rel in ("etc/os-release", "usr/lib/os-release"):
        p = os.path.join(root_dir, rel)
        if os.path.isfile(p):
            try:
                data = {}
                with open(p, 'r', encoding='utf-8', errors='replace') as f:
                    for line in f:
                        line = line.strip()
                        if '=' in line and not line.startswith('#'):
                            k, v = line.split('=', 1)
                            data[k.strip()] = v.strip().strip('"').strip("'")
                name = data.get('NAME', '')
                ver = data.get('VERSION_ID', '')
                pretty = data.get('PRETTY_NAME', '')
                distro_ver = format_distro_version(name, ver)
                if distro_ver:
                    return distro_ver, pretty
            except Exception:
                pass
    return None, None

def read_distro_for_device(dev_path):
    if not dev_path:
        return None, None
    try:
        res = subprocess.run(
            ["findmnt", "-rn", "-S", dev_path, "-o", "TARGET"],
            capture_output=True, text=True, timeout=2
        )
        mnt = res.stdout.strip().splitlines()[0] if res.stdout.strip() else ""
        if mnt and os.path.isdir(mnt):
            return read_os_release_from_root(mnt)
    except Exception:
        pass
    return None, None

def read_windows_bcd_title():
    bcd_paths = [
        "/boot/efi/EFI/Microsoft/Boot/BCD",
        "/efi/EFI/Microsoft/Boot/BCD",
    ]
    for p in bcd_paths:
        if os.path.isfile(p) and os.access(p, os.R_OK):
            try:
                with open(p, "rb") as f:
                    raw = f.read()
                matches = re.findall(
                    rb'(?:W\x00i\x00n\x00d\x00o\x00w\x00s\x00(?:\x20\x00)+(?:1\x001\x00|1\x000\x00|8\x00(?:\.\x001\x00)?|7\x00|S\x00e\x00r\x00v\x00e\x00r\x00(?:\x20\x00+\d\x00\d\x00\d\x00\d\x00)?))',
                    raw
                )
                if matches:
                    return matches[0].decode('utf-16le', errors='ignore').strip()
            except Exception:
                pass
    return "Windows 11"

def extract_distro_name(raw_title, kind, key):
    if kind == 'windows':
        return bcd_win_ver or 'Windows 11'
    if key == 'linux:host':
        os_name, _ = read_os_release_from_root("/")
        if os_name:
            return os_name
    elif key.startswith('linux:osprober:/dev/'):
        dev = key.split('linux:osprober:', 1)[1]
        os_name, _ = read_distro_for_device(dev)
        if os_name:
            return os_name
    return format_distro_version("", "", raw_title)

bcd_win_ver = read_windows_bcd_title()
host_distro, host_pretty = read_os_release_from_root("/")

systems = []
seen_keys = set()
in_submenu = False
submenu_depth = 0
brace_depth = 0

menu_re = re.compile(r'^[ \t]*menuentry\s+([\'"])(.*?)\1(.*)$')
sub_re = re.compile(r'^[ \t]*submenu\s+([\'"])(.*?)\1(.*)$')

for line in lines:
    stripped = line.strip()
    if stripped.startswith('#'):
        continue

    m_sub = sub_re.match(line)
    if m_sub and stripped.endswith('{'):
        if not in_submenu:
            in_submenu = True
            submenu_depth = brace_depth
        brace_depth += 1
        continue

    m_menu = menu_re.match(line)
    if m_menu and stripped.endswith('{'):
        title = m_menu.group(2)
        attrs = m_menu.group(3)
        if not in_submenu:
            if '--class terminal' in attrs or 'gnulinux-terminal-' in attrs or '--class custom' in attrs:
                pass
            elif 'uefi-firmware' in attrs or '--class efi' in attrs or title in ('UEFI Firmware Settings', 'UEFI'):
                pass
            elif 'memtest' in title.lower() or 'memtest' in attrs.lower():
                pass
            elif '--class windows' in attrs or 'osprober-efi-' in attrs or 'osprober-chain-' in attrs or title.lower().startswith('windows'):
                key = 'windows'
                if key not in seen_keys:
                    seen_keys.add(key)
                    systems.append({
                        'key': key,
                        'kind': 'windows',
                        'default_name': title,
                        'distro_name': extract_distro_name(title, 'windows', key),
                        'detected_detail': bcd_win_ver or ''
                    })
            elif '--class gnu-linux' in attrs or 'gnulinux-' in attrs:
                m_osprober = re.search(r"osprober-gnulinux-.*?-([0-9a-fA-F-]{8,}|[0-9a-zA-Z_-]+)'", attrs)
                m_ondev = re.search(r'\(on (/dev/[^)]+)\)', title)
                detail = ''
                if 'osprober-gnulinux-' in attrs:
                    if m_ondev:
                        key = f"linux:osprober:{m_ondev.group(1)}"
                        _, detail = read_distro_for_device(m_ondev.group(1))
                    elif m_osprober:
                        key = f"linux:osprober:{m_osprober.group(1)}"
                    else:
                        key = f"linux:osprober:{title}"
                else:
                    key = "linux:host"
                    detail = host_pretty or ''
                if key not in seen_keys:
                    seen_keys.add(key)
                    systems.append({
                        'key': key,
                        'kind': 'linux',
                        'default_name': title,
                        'distro_name': extract_distro_name(title, 'linux', key),
                        'detected_detail': detail or ''
                    })
        brace_depth += 1
        continue

    opens = len(re.findall(r'\{', stripped))
    closes = len(re.findall(r'\}', stripped))
    brace_depth += opens - closes
    if in_submenu and brace_depth <= submenu_depth:
        in_submenu = False

print(json.dumps(systems, ensure_ascii=False))
PYEOF
)"

    local count
    count="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "${probe_json}")"

    local rules_json="[]"
    if [[ "${count}" -eq 0 ]]; then
        warn "未在 ${cfg_to_parse} 中探测到可重命名的 Linux 或 Windows 条目，将仅配置 UEFI 标题精简。"
    elif [[ "${rename_mode_choice}" == "distro_version" ]]; then
        info "已自动生成「发行版名称 + 主版本号」系统菜单选项标题重命名方案:"
        local idx=0
        while [[ "${idx}" -lt "${count}" ]]; do
            local key kind def_name distro_name
            key="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["key"])' "${probe_json}" "${idx}")"
            kind="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["kind"])' "${probe_json}" "${idx}")"
            def_name="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["default_name"])' "${probe_json}" "${idx}")"
            distro_name="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["distro_name"])' "${probe_json}" "${idx}")"

            local kind_label="Linux"
            [[ "${kind}" == "windows" ]] && kind_label="Windows"
            echo "    • [${kind_label}]  原标题: '${def_name}' -> 新标题: '${distro_name}'"

            rules_json="$(python3 -c '
import json, sys
arr = json.loads(sys.argv[1])
arr.append({
    "key": sys.argv[2],
    "kind": sys.argv[3],
    "mode": "rename",
    "title": sys.argv[4]
})
print(json.dumps(arr, ensure_ascii=False))
' "${rules_json}" "${key}" "${kind}" "${distro_name}")"

            idx=$((idx + 1))
        done
        echo "    • [UEFI]   原标题: 'UEFI Firmware Settings' -> 新标题: 'UEFI'"
    else
        info "共按顺序检测到 ${count} 个系统，请逐项进行配置:"
        local idx=0
        while [[ "${idx}" -lt "${count}" ]]; do
            local key kind def_name distro_name detected_detail
            key="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["key"])' "${probe_json}" "${idx}")"
            kind="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["kind"])' "${probe_json}" "${idx}")"
            def_name="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["default_name"])' "${probe_json}" "${idx}")"
            distro_name="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d["distro_name"])' "${probe_json}" "${idx}")"
            detected_detail="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1])[int(sys.argv[2])]; print(d.get("detected_detail",""))' "${probe_json}" "${idx}")"

            local num=$((idx + 1))
            local kind_label="Linux"
            [[ "${kind}" == "windows" ]] && kind_label="Windows"

            echo ""
            if [[ -n "${detected_detail}" ]]; then
                echo -e "${C_BOLD}系统 [${num}/${count}] (${kind_label} - 探测标识: ${detected_detail}):${C_RESET}"
            else
                echo -e "${C_BOLD}系统 [${num}/${count}] (${kind_label}):${C_RESET}"
            fi
            echo "  1) 默认名称:       ${def_name}"
            echo "  2) 发行版+主版本号: ${distro_name}"
            if [[ -n "${detected_detail}" && "${detected_detail}" != "${distro_name}" ]]; then
                echo "  3) 自定义名称:     手动输入 (例如: ${detected_detail})"
            else
                echo "  3) 自定义名称:     手动输入"
            fi

            local name_choice chosen_mode chosen_title
            read -r -p "请选择系统 [${num}] 的标题方式 [1-3] (默认: 2): " name_choice
            case "${name_choice:-2}" in
                1)
                    chosen_mode="default"
                    chosen_title="${def_name}"
                    ;;
                2)
                    chosen_mode="rename"
                    chosen_title="${distro_name}"
                    ;;
                3)
                    chosen_mode="rename"
                    while true; do
                        read -r -p "请输入系统 [${num}] 的自定义标题名称: " chosen_title
                        chosen_title="${chosen_title//\'/}"
                        if [[ -n "${chosen_title}" ]]; then
                            break
                        fi
                        warn "自定义名称不能为空，请重新输入。"
                    done
                    ;;
                *)
                    warn "无效选项，使用发行版+版本号: ${distro_name}"
                    chosen_mode="rename"
                    chosen_title="${distro_name}"
                    ;;
            esac

            info "系统 [${num}] 已设置为: ${chosen_title}"
            rules_json="$(python3 -c '
import json, sys
arr = json.loads(sys.argv[1])
arr.append({
    "key": sys.argv[2],
    "kind": sys.argv[3],
    "mode": sys.argv[4],
    "title": sys.argv[5]
})
print(json.dumps(arr, ensure_ascii=False))
' "${rules_json}" "${key}" "${kind}" "${chosen_mode}" "${chosen_title}")"

            idx=$((idx + 1))
        done
    fi

    local dest_rename="${RENAME_SCRIPT}"
    [[ "${DRY_RUN}" == "true" ]] && dest_rename="${DRY_RUN_DIR}/99_rename_entries"

    # Write 99_rename_entries
    cat > "${dest_rename}" <<EOF
#!/bin/sh
set -e

# update-grub (grub-mkconfig) 执行时会先把配置写入临时文件 /boot/grub/grub.cfg.new
# 在 99 号脚本这里，所有前置项已生成完毕，在此处完成菜单标题精简与旧内核去重
TARGET="\${1:-${GRUB_CFG}.new}"

if [ -f "\$TARGET" ]; then
    python3 - "\$TARGET" << 'PYEOF'
import json
import os
import re
import stat
import subprocess
import sys

target = sys.argv[1]
rules_list = json.loads('''${rules_json}''')
rules = {item['key']: item for item in rules_list}

with open(target, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

def clean_distro_name(raw):
    s = raw.strip().strip('"').strip("'")
    s = re.sub(r',\s*with\s+Linux.*$', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\(on\s+/dev/[^)]+\)', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\([^)]*\)', '', s)
    s = re.sub(r'\s*GNU/Linux\b', '', s, flags=re.IGNORECASE)
    if s.lower().startswith('fedora linux'):
        s = 'Fedora' + s[12:]
    elif s.lower().startswith('manjaro linux'):
        s = 'Manjaro'
    return s.strip()

def clean_version_num(distro, raw_ver):
    if not raw_ver:
        return ""
    v = raw_ver.strip().strip('"').strip("'")
    d = distro.lower()
    if d == 'ubuntu':
        parts = v.split('.')
        if len(parts) >= 2:
            return f"{parts[0]}.{parts[1]}"
        return v
    if d in ('debian', 'fedora'):
        return v.split('.')[0]
    return v

def format_distro_version(name, version_id, raw_title=""):
    if name:
        dname = clean_distro_name(name)
        dver = clean_version_num(dname, version_id)
        if dver:
            return f"{dname} {dver}".strip()
        return dname

    s = raw_title.strip().strip('"').strip("'")
    s = re.sub(r',\s*with\s+Linux.*$', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\(on\s+/dev/[^)]+\)', '', s, flags=re.IGNORECASE)
    s = re.sub(r'\s*\([^)]*\)', '', s)
    s = re.sub(r'\s*GNU/Linux\b', '', s, flags=re.IGNORECASE)
    if s.lower().startswith('fedora linux'):
        s = 'Fedora' + s[12:]

    m = re.match(r'^([A-Za-z!_ -]+?)\s+(?:release\s+)?([0-9]+(?:\.[0-9]+)*)', s.strip(), flags=re.IGNORECASE)
    if m:
        dname = clean_distro_name(m.group(1))
        dver = clean_version_num(dname, m.group(2))
        if dver:
            return f"{dname} {dver}".strip()
        return dname
    return clean_distro_name(s)

def read_os_release(root_dir="/"):
    for rel in ("etc/os-release", "usr/lib/os-release"):
        p = os.path.join(root_dir, rel)
        if os.path.isfile(p):
            try:
                data = {}
                with open(p, 'r', encoding='utf-8', errors='replace') as f:
                    for line in f:
                        line = line.strip()
                        if '=' in line and not line.startswith('#'):
                            k, v = line.split('=', 1)
                            data[k.strip()] = v.strip().strip('"').strip("'")
                name = data.get('NAME', '')
                ver = data.get('VERSION_ID', '')
                if name:
                    return format_distro_version(name, ver)
            except Exception:
                pass
    return None

def read_distro_for_device(dev_path):
    if not dev_path:
        return None
    try:
        res = subprocess.run(
            ["findmnt", "-rn", "-S", dev_path, "-o", "TARGET"],
            capture_output=True, text=True, timeout=2
        )
        mnt = res.stdout.strip().splitlines()[0] if res.stdout.strip() else ""
        if mnt and os.path.isdir(mnt):
            return read_os_release(mnt)
    except Exception:
        pass
    return None

def read_windows_bcd_title():
    for p in ("/boot/efi/EFI/Microsoft/Boot/BCD", "/efi/EFI/Microsoft/Boot/BCD"):
        if os.path.isfile(p) and os.access(p, os.R_OK):
            try:
                with open(p, "rb") as f:
                    raw = f.read()
                matches = re.findall(
                    rb'(?:W\x00i\x00n\x00d\x00o\x00w\x00s\x00(?:\x20\x00)+(?:1\x001\x00|1\x000\x00|8\x00(?:\.\x001\x00)?|7\x00|S\x00e\x00r\x00v\x00e\x00r\x00(?:\x20\x00+\d\x00\d\x00\d\x00\d\x00)?))',
                    raw
                )
                if matches:
                    return matches[0].decode('utf-16le', errors='ignore').strip()
            except Exception:
                pass
    return "Windows 11"

host_distro = read_os_release("/")
win_title = read_windows_bcd_title()

menu_re = re.compile(r'^([ \t]*menuentry\s+)([\'"])(.*?)\2(.*)$')
sub_re = re.compile(r'^[ \t]*submenu\s+([\'"])(.*?)\1(.*)$')
if_plat_re = re.compile(r'^[ \t]*if\s+\[\s*"\$grub_platform"\s*=\s*"[^"]+"\s*\];\s*then\s*$')

def classify_entry(title, attrs):
    if '--class terminal' in attrs or 'gnulinux-terminal-' in attrs or '--class custom' in attrs:
        return ('terminal', None)
    if 'uefi-firmware' in attrs or '--class efi' in attrs or title in ('UEFI Firmware Settings', 'UEFI'):
        return ('uefi', 'uefi')
    if 'memtest' in title.lower() or 'memtest' in attrs.lower():
        return ('memtest', None)
    if '--class windows' in attrs or 'osprober-efi-' in attrs or 'osprober-chain-' in attrs or title.lower().startswith('windows'):
        return ('windows', 'windows')
    if '--class gnu-linux' in attrs or 'gnulinux-' in attrs:
        m_osprober = re.search(r"osprober-gnulinux-.*?-([0-9a-fA-F-]{8,}|[0-9a-zA-Z_-]+)'", attrs)
        m_ondev = re.search(r'\(on (/dev/[^)]+)\)', title)
        if 'osprober-gnulinux-' in attrs:
            if m_ondev:
                return ('linux', f"linux:osprober:{m_ondev.group(1)}")
            if m_osprober:
                return ('linux', f"linux:osprober:{m_osprober.group(1)}")
            return ('linux', f"linux:osprober:{title}")
        return ('linux', 'linux:host')
    return ('other', None)

out_lines = []
seen_groups = set()
in_submenu = False
submenu_depth = 0
brace_depth = 0

i = 0
n = len(lines)
while i < n:
    line = lines[i]
    stripped = line.strip()

    if stripped.startswith('#'):
        out_lines.append(line)
        i += 1
        continue

    m_sub = sub_re.match(line)
    if m_sub and stripped.endswith('{'):
        if not in_submenu:
            in_submenu = True
            submenu_depth = brace_depth
        brace_depth += 1
        out_lines.append(line)
        i += 1
        continue

    m_menu = menu_re.match(line)
    if m_menu and stripped.endswith('{') and not in_submenu:
        prefix, quote, title, attrs = m_menu.group(1), m_menu.group(2), m_menu.group(3), m_menu.group(4)
        kind, key = classify_entry(title, attrs)

        # Collect the entire top-level menuentry { ... } block
        entry_start_depth = brace_depth
        block = [line]
        brace_depth += 1
        i += 1
        while i < n and brace_depth > entry_start_depth:
            bline = lines[i]
            bstripped = bline.strip()
            if not bstripped.startswith('#'):
                brace_depth += len(re.findall(r'\{', bstripped)) - len(re.findall(r'\}', bstripped))
            block.append(bline)
            i += 1

        if kind == 'uefi':
            # Always keep UEFI as 'UEFI'
            block[0] = f"{prefix}'UEFI'{attrs}\n"
            out_lines.extend(block)
            continue

        if kind in ('linux', 'windows') and key:
            if key in seen_groups:
                # Duplicate top-level entry for the same OS (e.g. older kernel when GRUB_DISABLE_SUBMENU=true,
                # or extra Windows Boot Manager entry): remove it.
                if out_lines and if_plat_re.match(out_lines[-1]) and i < n and lines[i].strip() == 'fi':
                    out_lines.pop()
                    i += 1
                continue
            seen_groups.add(key)
            rule = rules.get(key)
            if rule and rule.get('mode') == 'rename' and rule.get('title'):
                new_title = rule['title']
                block[0] = f"{prefix}'{new_title}'{attrs}\n"
            elif rule and rule.get('mode') == 'default':
                pass
            else:
                # Fallback: dynamic distro + version
                if kind == 'windows':
                    new_title = win_title
                elif key.startswith('linux:osprober:'):
                    dev = key.split('linux:osprober:', 1)[1]
                    new_title = read_distro_for_device(dev) or format_distro_version("", "", title)
                else:
                    new_title = host_distro or format_distro_version("", "", title)
                block[0] = f"{prefix}'{new_title}'{attrs}\n"

            out_lines.extend(block)
            continue

        out_lines.extend(block)
        continue

    opens = len(re.findall(r'\{', stripped))
    closes = len(re.findall(r'\}', stripped))
    brace_depth += opens - closes
    if in_submenu and brace_depth <= submenu_depth:
        in_submenu = False
    out_lines.append(line)
    i += 1

if target.endswith('.new'):
    out_lines.append("### END /etc/grub.d/99_rename_entries ###\n")

# Atomic replace via temporary file so parent shell fd offset never injects NUL bytes
tmp_target = f"{target}.tmp"
with open(tmp_target, 'w', encoding='utf-8') as f:
    f.writelines(out_lines)
os.chmod(tmp_target, stat.S_IRUSR | stat.S_IWUSR)
os.replace(tmp_target, target)
PYEOF
fi
EOF

    chmod 0755 "${dest_rename}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "将生成 ${RENAME_SCRIPT} (属主 root:root，权限 0755)，正在沙箱中模拟执行重命名规则..."
        sh "${dest_rename}" "${cfg_to_parse}"
    else
        chown root:root "${dest_rename}"
        RENAME_WAS_EXEC="false"
        ok "已生成并启用 ${RENAME_SCRIPT} (属主 root:root，权限 0755)"
    fi
}

# ==============================================================================
# 5. Summary & Default Boot Entry Confirmation
# ==============================================================================
configure_default_entry_and_finish() {
    echo ""
    info "正在执行最终 GRUB 配置生成与生效 (sudo update-grub)..."
    run_update_grub

    local cfg_to_show
    cfg_to_show="$(active_grub_cfg_file)"
    local target_default
    target_default="$(active_grub_default_file)"

    echo ""
    if [[ "${DRY_RUN}" == "true" ]]; then
        echo -e "${C_BOLD}=== [DRY-RUN 预览] 最终 GRUB 顶层启动菜单列表 ===${C_RESET}"
    else
        echo -e "${C_BOLD}=== 当前 GRUB 顶层启动菜单列表 ===${C_RESET}"
    fi
    python3 - "${cfg_to_show}" <<'PYEOF'
import re, sys

cfg_path = sys.argv[1]
with open(cfg_path, 'r', encoding='utf-8', errors='replace') as f:
    lines = f.readlines()

menu_re = re.compile(r'^[ \t]*menuentry\s+([\'"])(.*?)\1')
sub_re = re.compile(r'^[ \t]*submenu\s+([\'"])(.*?)\1')

in_submenu = False
submenu_depth = 0
brace_depth = 0
idx = 0

for line in lines:
    stripped = line.strip()
    if stripped.startswith('#'):
        continue
    if sub_re.match(line) and stripped.endswith('{'):
        if not in_submenu:
            in_submenu = True
            submenu_depth = brace_depth
        brace_depth += 1
        continue
    m = menu_re.match(line)
    if m and stripped.endswith('{'):
        if not in_submenu:
            print(f"  [{idx}] {m.group(2)}")
            idx += 1
        brace_depth += 1
        continue
    brace_depth += len(re.findall(r'\{', stripped)) - len(re.findall(r'\}', stripped))
    if in_submenu and brace_depth <= submenu_depth:
        in_submenu = False
PYEOF

    echo ""
    local cur_def
    cur_def="$(grep -E '^[[:space:]]*GRUB_DEFAULT=' "${target_default}" | tail -n1 | cut -d= -f2- || echo "0")"
    local change_def
    read -r -p "当前默认启动项 GRUB_DEFAULT=${cur_def}，是否根据上方菜单列表再次调整？ [y/N] (默认: N): " change_def
    if [[ "${change_def:-N}" =~ ^[Yy]$ ]]; then
        local new_def
        read -r -p "请输入默认启动项序号或名称 (例如 0, 1, 2...): " new_def
        if [[ -n "${new_def}" ]]; then
            set_grub_default_kv "GRUB_DEFAULT" "${new_def}"
            run_update_grub
            if [[ "${DRY_RUN}" == "true" ]]; then
                dry_log "已将沙箱中 GRUB_DEFAULT 更新为 ${new_def}。"
            else
                ok "已将 GRUB_DEFAULT 更新为 ${new_def}。"
            fi
        fi
    fi

    echo ""
    if [[ "${DRY_RUN}" == "true" ]]; then
        dry_log "演练结束：未对系统任何真实文件做修改。"
    else
        ok "配置已全部生效！已执行 update-grub 生成 /boot/grub/grub.cfg 并通过语法校验。"
        ok "全部 GRUB 配置已完成，重启系统即可在引导菜单查看效果。"
    fi
}

main() {
    local restore_mode="false"
    local restore_arg=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --restore)
                restore_mode="true"
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    restore_arg="$2"
                    shift 2
                else
                    shift 1
                fi
                ;;
            *)
                error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
    done

    ensure_root "$@"
    check_dependencies

    if [[ "${DRY_RUN}" == "true" ]]; then
        init_dry_run_env
    fi

    if [[ "${restore_mode}" == "true" ]]; then
        restore_backup "${restore_arg}"
        exit 0
    fi

    backup_configs
    detect_installed_components
    configure_grub2_themes
    configure_grub_defaults
    configure_custom_entries
    configure_rename_entries
    configure_default_entry_and_finish
}

main "$@"
