#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  create_user.sh — Управление пользователями
# ─────────────────────────────────────────────────────────────────

step_manage_users() {
    while true; do
        clear
        section "$MSG_MANAGE_USERS_TITLE"
        echo -e "  ${BOLD}1)${NC} $MSG_MANAGE_USERS_OPT_CREATE"
        echo -e "  ${BOLD}2)${NC} $MSG_MANAGE_USERS_OPT_DELETE"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_MANAGE_USERS_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r subchoice

        case "${subchoice,,}" in
            1) step_create_user || true ;;
            2) _delete_user_interactive || true ;;
            "") return 0 ;;
            *) error "$(printf "$MSG_INVALID_CHOICE" "$subchoice")" ;;
        esac

        pause
    done
}

step_create_user() {
    read -rp "$MSG_ENTER_NEW_USERNAME" username

    if [[ -z "$username" ]]; then
        error "$MSG_USERNAME_EMPTY"
        return 1
    fi

    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "$MSG_USERNAME_INVALID"
        return 1
    fi

    # Пользователь уже существует
    if id "$username" &>/dev/null; then
        warn "$(printf "$MSG_USER_EXISTS" "$username")"

        if groups "$username" | grep -q '\bsudo\b'; then
            success "$MSG_USER_ALREADY_SUDO"
        else
            if confirm "$(printf "$MSG_ADD_TO_SUDO_CONFIRM" "$username")"; then
                usermod -aG sudo "$username"
                success "$MSG_ADDED_TO_SUDO"
                log "User '$username' added to sudo"
            fi
        fi
        return 0
    fi

    adduser "$username"
    usermod -aG sudo "$username"

    success "$(printf "$MSG_USER_CREATED" "$username")"
    success "$MSG_ADDED_TO_SUDO"
    log "User '$username' created with sudo"

    # Предложить добавить SSH ключ сразу после создания пользователя
    if confirm "$(printf "$MSG_ADD_SSH_KEY_NOW" "$username")"; then
        local home_dir
        home_dir=$(getent passwd "$username" | cut -d: -f6)
        _add_key_manually "$username" "${home_dir}/.ssh" "${home_dir}/.ssh/authorized_keys" || true
    fi
}

# ── Удаление пользователя ─────────────────────────────────────────

_delete_user_interactive() {
    # Список пользователей с UID 1000–65533
    local users=()
    while IFS=: read -r uname _ uid _ _ _ _; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        users+=("$uname")
    done < /etc/passwd

    if [[ ${#users[@]} -eq 0 ]]; then
        warn "$MSG_MANAGE_USERS_NONE"
        return 0
    fi

    echo
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
        return 0
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 || "$choice" -gt ${#users[@]} ]]; then
        error "$(printf "$MSG_INVALID_CHOICE" "$choice")"
        return 1
    fi

    local username="${users[$((choice - 1))]}"

    # Защита от самоблокировки: последний пользователь + root SSH отключён
    if [[ ${#users[@]} -eq 1 ]]; then
        local root_login
        root_login=$(grep -iE '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null \
            | awk '{print tolower($2)}' | head -1) || root_login=""
        if [[ "$root_login" == "no" ]]; then
            error "$MSG_DELETE_USER_LAST_LOCKED"
            return 1
        fi
    fi

    if ! confirm "$(printf "$MSG_DELETE_USER_CONFIRM" "$username")"; then
        info "$MSG_CANCELED"
        return 0
    fi

    # Завершаем все процессы пользователя перед удалением
    pkill -u "$username" 2>/dev/null || true
    loginctl terminate-user "$username" 2>/dev/null || true

    if ! deluser --remove-home "$username"; then
        error "$(printf "$MSG_DELETE_USER_FAILED" "$username")"
        return 1
    fi

    success "$(printf "$MSG_DELETE_USER_DONE" "$username")"
    log "User '$username' deleted with home directory"
}
