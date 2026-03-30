#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  ssh_key.sh — Управление SSH ключами
# ─────────────────────────────────────────────────────────────────

step_manage_keys() {
    clear
    section "$MSG_MANAGE_KEYS_TITLE"
    _select_user || return 1
    local username="$PROMPT_RESULT"

    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    while true; do
        clear
        section "$(printf "$MSG_MANAGE_KEYS_USER_TITLE" "$username")"
        echo -e "  ${BOLD}1)${NC} $MSG_MANAGE_KEYS_OPT_ADD"
        echo -e "  ${BOLD}2)${NC} $MSG_MANAGE_KEYS_OPT_DELETE"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_MANAGE_KEYS_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r subchoice

        case "${subchoice,,}" in
            1) _add_key_manually "$username" "$ssh_dir" "$auth_keys" || true ;;
            2) _delete_key_interactive "$username" "$auth_keys" || true ;;
            "") return 0 ;;
            *) error "$(printf "$MSG_INVALID_CHOICE" "$subchoice")" ;;
        esac

        pause
    done
}

step_ssh_key() {
    _select_user || return 1
    local username="$PROMPT_RESULT"

    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    _add_key_manually "$username" "$ssh_dir" "$auth_keys"
}

# ── Вставить ключ вручную ─────────────────────────────────────────

_add_key_manually() {
    local username="$1"
    local ssh_dir="$2"
    local auth_keys="$3"

    echo -e "${CYAN}${MSG_PASTE_KEY}${NC}"
    read -r pub_key

    if [[ -z "$pub_key" ]]; then
        error "$MSG_KEY_EMPTY"
        return 1
    fi

    # Базовая проверка формата
    local valid_prefixes="ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com"
    if ! echo "$pub_key" | grep -qE "^(${valid_prefixes}) "; then
        warn "$MSG_KEY_INVALID_FORMAT"
        warn "$MSG_KEY_INVALID_FORMAT2"
        if ! confirm "$MSG_KEY_ADD_ANYWAY"; then
            return 0
        fi
    fi

    # Проверка на дубликат
    if [[ -f "$auth_keys" ]] && grep -qF "$pub_key" "$auth_keys"; then
        warn "$(printf "$MSG_KEY_DUPLICATE" "$username")"
        return 0
    fi

    mkdir -p "$ssh_dir"
    echo "$pub_key" >> "$auth_keys"
    chown -R "${username}:${username}" "$ssh_dir"
    chmod 700 "$ssh_dir"
    chmod 600 "$auth_keys"

    success "$(printf "$MSG_KEY_ADDED" "$username")"
    log "SSH key added for '$username'"
}

# ── Удалить ключ ──────────────────────────────────────────────────

_delete_key_interactive() {
    local username="$1"
    local auth_keys="$2"

    if [[ ! -f "$auth_keys" ]]; then
        warn "$MSG_KEYS_NONE"
        return 0
    fi

    # Читаем только строки с SSH ключами
    local keys=()
    while IFS= read -r line; do
        [[ "$line" =~ ^(ssh-|ecdsa-|sk-) ]] && keys+=("$line")
    done < "$auth_keys"

    if [[ ${#keys[@]} -eq 0 ]]; then
        warn "$MSG_KEYS_NONE"
        return 0
    fi

    echo -e "  ${BOLD}$(printf "$MSG_KEYS_LIST_TITLE" "$username")${NC}"
    local i=1
    for key in "${keys[@]}"; do
        local key_type key_comment
        key_type=$(echo "$key" | awk '{print $1}')
        key_comment=$(echo "$key" | awk '{print $3}')
        # Если комментарий пустой — показываем часть тела ключа
        [[ -z "$key_comment" ]] && key_comment="$(echo "$key" | awk '{print substr($2,1,20)}')..."
        echo -e "    ${BOLD}${i})${NC} ${key_type}  ${CYAN}${key_comment}${NC}"
        (( i++ ))
    done
    echo

    read -rp "$MSG_KEYS_SELECT_DELETE" key_num

    if ! [[ "$key_num" =~ ^[0-9]+$ ]] || \
       [[ "$key_num" -lt 1 || "$key_num" -gt ${#keys[@]} ]]; then
        error "$MSG_KEY_SELECT_INVALID"
        return 1
    fi

    local target_key="${keys[$((key_num - 1))]}"
    local tmp_file
    tmp_file=$(mktemp)
    grep -vF "$target_key" "$auth_keys" > "$tmp_file" || true
    mv "$tmp_file" "$auth_keys"
    chmod 600 "$auth_keys"

    success "$(printf "$MSG_KEY_DELETED" "$key_num")"
    log "SSH key #${key_num} deleted for '$username'"
}

# ── Отключить вход по паролю ──────────────────────────────────────

_disable_password_auth() {
    backup_file "/etc/ssh/sshd_config"

    if grep -qE '^PasswordAuthentication' /etc/ssh/sshd_config; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    elif grep -qE '^#PasswordAuthentication' /etc/ssh/sshd_config; then
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    else
        echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    fi

    if sshd -t 2>/dev/null; then
        systemctl restart sshd
        success "$MSG_PASS_DISABLED"
        log "PasswordAuthentication disabled"
    else
        error "$MSG_SSH_CONFIG_ERROR"
        restore_latest_backup "/etc/ssh/sshd_config"
    fi
}
