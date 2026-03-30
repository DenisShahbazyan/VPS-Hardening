#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  harden-manager.sh — точка входа
#  Запуск: wget -qO ~/harden.sh https://raw.githubusercontent.com/DenisShahbazyan/VPS-Hardening/master/harden-manager.sh && sudo bash ~/harden.sh
# ─────────────────────────────────────────────────────────────────

set -uo pipefail

# ── Константы ─────────────────────────────────────────────────────
readonly REPO_BASE_URL="https://raw.githubusercontent.com/DenisShahbazyan/VPS-Hardening/master"
readonly SCRIPT_MODULES=(
    "scripts/lib.sh"
    "scripts/create_user.sh"
    "scripts/ssh_key.sh"
    "scripts/ssh_port.sh"
    "scripts/ufw.sh"
    "scripts/crowdsec.sh"
    "scripts/disable_root.sh"
    "scripts/auto_setup.sh"
)

LOG_DIR="/var/log/vps-hardening"
export LOG_FILE="${LOG_DIR}/$(date '+%Y-%m-%d_%H-%M').log"
TMP_DIR=""
LANG_CODE=""

# ── Bootstrap ─────────────────────────────────────────────────────

_ensure_wget() {
    command -v wget &>/dev/null && return 0
    echo "wget not found / wget не найден. Installing..."
    apt-get update -qq && apt-get install -y -qq wget || {
        echo "Error: failed to install wget. Install it manually and try again."
        exit 1
    }
}

_create_tmp_dir() {
    TMP_DIR=$(mktemp -d /tmp/vps-hardening-XXXXX)
}

_register_cleanup() {
    trap '_on_exit' EXIT INT TERM
}

_on_exit() {
    [[ -n "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}

_select_language() {
    echo ""
    echo "  1) Русский"
    echo "  2) English"
    echo ""
    echo -n "  Select language / Выберите язык: "
    read -r lang_choice
    case "$lang_choice" in
        2) LANG_CODE="en" ;;
        *) LANG_CODE="ru" ;;
    esac
}

_download_file() {
    local remote_path="$1"
    local dest="${TMP_DIR}/${remote_path}"
    mkdir -p "$(dirname "$dest")"
    wget -qO "$dest" "${REPO_BASE_URL}/${remote_path}" || return 1
}

_load_i18n() {
    _download_file "scripts/i18n/${LANG_CODE}.sh" || {
        echo "Error: failed to download language file."
        exit 1
    }
    # shellcheck source=/dev/null
    source "${TMP_DIR}/scripts/i18n/${LANG_CODE}.sh"
}

_load_modules() {
    for module in "${SCRIPT_MODULES[@]}"; do
        _download_file "$module" || {
            echo "$(printf "$MSG_MODULE_DOWNLOAD_FAILED" "$module")"
            echo "$MSG_CHECK_INTERNET"
            exit 1
        }
        # shellcheck source=/dev/null
        source "${TMP_DIR}/${module}"
    done
}

# ── Инициализация ─────────────────────────────────────────────────

_init() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "\033[0;31m[ERROR]\033[0m ${MSG_ROOT_REQUIRED}"
        echo -e "        sudo bash <(wget -qO - ${REPO_BASE_URL}/harden-manager.sh)"
        exit 1
    fi

    mkdir -p "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    log "=== VPS Hardening Manager started (lang: $LANG_CODE) ==="
    log "System: $(lsb_release -ds 2>/dev/null || uname -a)"
}

# ── Статус системы ───────────────────────────────────────────────

_render_status() {
    local ssh_port users_str ufw_str f2b_str root_str

    # SSH порт
    ssh_port=$(get_ssh_port)

    # Пользователи с UID > 1000 (без системных учёток)
    local user_items=()
    while IFS=: read -r uname _ uid _ _ home _; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        local key_count=0
        if [[ -f "${home}/.ssh/authorized_keys" ]]; then
            key_count=$(grep -cE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null) || true
        fi
        local key_label
        if [[ "${key_count:-0}" -gt 0 ]]; then
            [[ "$key_count" -eq 1 ]] && key_label="$MSG_STATUS_KEY" || key_label="$MSG_STATUS_KEYS"
            user_items+=("${GREEN}${uname}${NC} (${key_count} ${key_label})")
        else
            user_items+=("${YELLOW}${uname}${NC} (${MSG_STATUS_NO_KEY})")
        fi
    done < /etc/passwd

    if [[ ${#user_items[@]} -eq 0 ]]; then
        users_str="${YELLOW}${MSG_STATUS_NO_USERS}${NC}"
    else
        local joined=""
        for item in "${user_items[@]}"; do
            [[ -n "$joined" ]] && joined+=", "
            joined+="$item"
        done
        users_str="$joined"
    fi

    # Статус UFW
    local ufw_raw
    ufw_raw=$(ufw status 2>/dev/null | awk 'NR==1{print $2}') || ufw_raw=""
    if [[ "$ufw_raw" == "active" ]]; then
        ufw_str="${GREEN}${MSG_STATUS_ACTIVE}${NC}"
    else
        ufw_str="${RED}${MSG_STATUS_INACTIVE}${NC}"
    fi

    # Статус CrowdSec
    local f2b_raw
    f2b_raw=$(systemctl is-active crowdsec 2>/dev/null) || f2b_raw="inactive"
    if [[ "$f2b_raw" == "active" ]]; then
        f2b_str="${GREEN}${MSG_STATUS_ACTIVE}${NC}"
    else
        f2b_str="${RED}${MSG_STATUS_INACTIVE}${NC}"
    fi

    # Root-логин SSH
    local root_raw
    root_raw=$(grep -iE '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null \
        | awk '{print tolower($2)}' | head -1) || root_raw=""
    if [[ "$root_raw" == "no" ]]; then
        root_str="${GREEN}${MSG_STATUS_ROOT_DISABLED}${NC}"
    elif [[ -z "$root_raw" ]]; then
        root_str="${YELLOW}${MSG_STATUS_ROOT_DEFAULT}${NC}"
    else
        root_str="${RED}${MSG_STATUS_ROOT_ENABLED}${NC}"
    fi

    echo -e "${BOLD}  ──────────────────────────────────────────────${NC}"
    echo
    echo -e "  ${BOLD}${MSG_STATUS_SECTION}${NC}"
    echo
    local w="$MSG_STATUS_LABEL_WIDTH"
    echo -e "  $(_pad_label "$MSG_STATUS_USERS"    $w) ${users_str}"
    echo -e "  $(_pad_label "$MSG_STATUS_SSH_PORT" $w) ${CYAN}${ssh_port}${NC}"
    echo -e "  $(_pad_label "UFW"                  $w) ${ufw_str}"
    echo -e "  $(_pad_label "CrowdSec"             $w) ${f2b_str}"

    # Бансеры — только если CrowdSec активен и cscli доступен
    if [[ "$f2b_raw" == "active" ]] && command -v cscli &>/dev/null; then
        local b_name b_ip b_revoked b_last b_type bouncer_raw b_str
        while IFS=, read -r b_name b_ip b_revoked b_last b_type _; do
            [[ -z "$b_name" ]] && continue
            bouncer_raw=$(systemctl is-active "$b_type" 2>/dev/null) || bouncer_raw="inactive"
            if [[ "$bouncer_raw" == "active" ]]; then
                b_str="${GREEN}${MSG_STATUS_ACTIVE}${NC}"
            else
                b_str="${RED}${MSG_STATUS_INACTIVE}${NC}"
            fi
            echo -e "    ${CYAN}└─${NC} ${b_name}  ${b_str}"
        done < <(cscli bouncers list -o raw 2>/dev/null | tail -n +2)
    fi

    echo -e "  $(_pad_label "$MSG_STATUS_ROOT_SSH" $w) ${root_str}"
    echo
}

# ── Меню ──────────────────────────────────────────────────────────

_show_menu() {
    clear
    echo -e "${BOLD}  ╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}  ║           VPS Hardening Manager              ║${NC}"
    echo -e "${BOLD}  ║                  Ubuntu                      ║${NC}"
    echo -e "${BOLD}  ╚══════════════════════════════════════════════╝${NC}"
    echo
    _render_status
    echo -e "${BOLD}  ──────────────────────────────────────────────${NC}"
    echo
    echo -e "  ${BOLD}1)${NC} $MSG_MENU_MANAGE_USERS"
    echo -e "  ${BOLD}2)${NC} $MSG_MENU_MANAGE_KEYS"
    echo -e "  ${BOLD}3)${NC} $MSG_MENU_SSH_PORT"
    echo -e "  ${BOLD}4)${NC} $MSG_MENU_UFW"
    echo -e "  ${BOLD}5)${NC} $MSG_MENU_CROWDSEC"
    local root_login_now
    root_login_now=$(grep -iE '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null \
        | awk '{print tolower($2)}' | head -1) || root_login_now=""
    local menu_root_label
    if [[ "$root_login_now" == "no" ]]; then
        menu_root_label="$MSG_MENU_ENABLE_ROOT"
    else
        menu_root_label="$MSG_MENU_DISABLE_ROOT"
    fi
    echo -e "  ${BOLD}6)${NC} ${menu_root_label}"
    echo ""
    echo -e "  ${BOLD}7)${NC} ${CYAN}${MSG_MENU_AUTO_SETUP}${NC}"
    echo -e "  ${BOLD}8)${NC} ${YELLOW}${MSG_MENU_RESET_DEFAULTS}${NC}"
    echo ""
    echo -e "  ${BOLD}Enter)${NC} $MSG_MENU_EXIT"
    echo
    echo -e "${BOLD}  ──────────────────────────────────────────────${NC}"
    echo
    echo -en "  ${MSG_MENU_CHOICE} "
}

_menu_loop() {
    while true; do
        _show_menu
        read -r choice
        echo ""

        case "${choice,,}" in
            # Пункты с подменю — открываются на новом экране, pause не нужен
            1) step_manage_users    || true; continue ;;
            2) step_manage_keys     || true; continue ;;
            3) step_ssh_port        || true ;;
            4) step_ufw             || true; continue ;;
            5) step_crowdsec        || true; continue ;;
            6) step_disable_root    || true ;;
            7) step_auto_setup      || true ;;
            8) step_reset_defaults  || true ;;
            "")
                exit 0
                ;;
            *)
                error "$(printf "$MSG_INVALID_CHOICE" "$choice")"
                ;;
        esac

        pause
    done
}

# ── Main ──────────────────────────────────────────────────────────

main() {
    _ensure_wget
    _create_tmp_dir
    _register_cleanup
    _select_language
    _load_i18n
    _load_modules
    _init
    _menu_loop
}

main
