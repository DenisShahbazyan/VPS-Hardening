#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  lib.sh — общие утилиты, подключается через source во всех модулях
# ─────────────────────────────────────────────────────────────────

# ── Colors ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────
# LOG_FILE устанавливается в harden-manager.sh до подключения модулей
LOG_FILE="${LOG_FILE:-/var/log/vps-hardening/session.log}"

log()     { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG_FILE"; }
info()    { echo -e "${CYAN}[INFO]${NC}  $*";  log "[INFO]  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*";  log "[OK]    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; log "[WARN]  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; log "[ERROR] $*"; }

section() {
    local title="$*"
    local prefix="── ${title} "
    local total=50
    local pad=$(( total - ${#prefix} ))
    [[ $pad -lt 2 ]] && pad=2
    echo -e "\n${BOLD}${prefix}$(printf '─%.0s' $(seq 1 $pad))${NC}\n"
    log "=== $* ==="
}

# ── Интерактивные хелперы ─────────────────────────────────────────

confirm() {
    local msg="$1"
    echo -en "${YELLOW}${msg} [y/N]: ${NC}"
    read -r ans
    [[ "${ans,,}" == "y" ]]
}

pause() {
    echo -en "\n${YELLOW}${MSG_PRESS_ENTER}${NC}"
    read -r
}

# ── Работа с конфигами ────────────────────────────────────────────

backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        local backup="${file}.bak.$(date '+%Y%m%d_%H%M%S')"
        cp "$file" "$backup"
        success "$(printf "$MSG_BACKUP_CREATED" "$backup")"
        log "Backup: $file → $backup"
    fi
}

restore_latest_backup() {
    local file="$1"
    local latest
    latest=$(ls -t "${file}.bak."* 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
        cp "$latest" "$file"
        success "$(printf "$MSG_RESTORED_FROM" "$latest")"
        log "Restored: $file from $latest"
    else
        error "$(printf "$MSG_BACKUP_NOT_FOUND" "$file")"
    fi
}

# ── Список пользователей ──────────────────────────────────────────

# Выводит список пользователей с UID 1000–65533 (без системных)

# Выводит нумерованный список пользователей (UID 1000–65533) и предлагает выбрать.
# Результат записывается в PROMPT_RESULT. Возвращает 1 если нет пользователей или отмена.
_select_user() {
    local users=()
    while IFS=: read -r uname _ uid _ _ _ _; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        users+=("$uname")
    done < /etc/passwd

    if [[ ${#users[@]} -eq 0 ]]; then
        warn "$MSG_MANAGE_USERS_NONE"
        pause
        return 1
    fi

    echo -e "  ${BOLD}${MSG_MANAGE_USERS_LIST_TITLE}${NC}"
    local i=1
    for u in "${users[@]}"; do
        echo -e "  ${BOLD}${i})${NC} ${u}"
        (( i++ ))
    done
    echo

    echo -en "  ${MSG_MENU_CHOICE} "
    read -r choice

    if [[ -z "$choice" ]]; then
        info "$MSG_CANCELED"
        return 1
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#users[@]} ]]; then
        error "$(printf "$MSG_INVALID_CHOICE" "$choice")"
        return 1
    fi

    PROMPT_RESULT="${users[$((choice - 1))]}"
}

# ── Форматирование ────────────────────────────────────────────────

# Возвращает "LABEL:ПРОБЕЛЫ" — метку с двоеточием, дополненную пробелами
# до нужной ширины. Использует ${#} — корректно для UTF-8 локали (Ubuntu default).
_pad_label() {
    local label="$1" width="$2"
    local len=${#label}
    local pad=""
    for (( i=len; i<width; i++ )); do pad+=" "; done
    printf '%s%s:' "$label" "$pad"
}

# ── SSH хелперы ───────────────────────────────────────────────────

get_ssh_port() {
    grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null \
        | awk '{print $2}' \
        | head -1 \
        || echo "22"
}
