#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  auto_setup.sh — Автонастройка и сброс к исходным настройкам
# ─────────────────────────────────────────────────────────────────

# Глобальные флаги отката (сбрасываются в начале step_auto_setup)
_AS_USER_CREATED=0
_AS_OLD_SSH_PORT=""
_AS_PASS_AUTH_DISABLED=0
_AS_UFW_CONFIGURED=0
_AS_CROWDSEC_INSTALLED=0
_AS_BOUNCER_SVC_NAME=""
_AS_ROOT_DISABLED=0

# ── Откат всех выполненных шагов ─────────────────────────────────

_auto_setup_rollback() {
    local username="$1"
    echo
    warn "$MSG_AUTO_ROLLBACK_TITLE"
    log "auto_setup: rollback started"

    # Шаг 7 → включить root SSH (прямая правка, не backup)
    if [[ "$_AS_ROOT_DISABLED" -eq 1 ]]; then
        info "$MSG_AUTO_ROLLBACK_ROOT"
        if grep -qE '^PermitRootLogin' /etc/ssh/sshd_config; then
            sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
        else
            echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
        fi
        log "auto_setup: rollback: PermitRootLogin yes"
    fi

    # Шаг 4 → восстановить старый порт SSH (прямая правка)
    if [[ -n "$_AS_OLD_SSH_PORT" ]]; then
        info "$MSG_AUTO_ROLLBACK_SSH_PORT"
        if grep -qE '^Port ' /etc/ssh/sshd_config; then
            sed -i "s/^Port .*/Port ${_AS_OLD_SSH_PORT}/" /etc/ssh/sshd_config
        elif grep -qE '^#Port ' /etc/ssh/sshd_config; then
            sed -i "s/^#Port .*/Port ${_AS_OLD_SSH_PORT}/" /etc/ssh/sshd_config
        else
            echo "Port ${_AS_OLD_SSH_PORT}" >> /etc/ssh/sshd_config
        fi
        log "auto_setup: rollback: SSH port → $_AS_OLD_SSH_PORT"
    fi

    # Шаг 3 → восстановить PasswordAuthentication (прямая правка)
    if [[ "$_AS_PASS_AUTH_DISABLED" -eq 1 ]]; then
        info "$MSG_AUTO_ROLLBACK_PASS_AUTH"
        if grep -qE '^PasswordAuthentication' /etc/ssh/sshd_config; then
            sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        else
            echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
        fi
        log "auto_setup: rollback: PasswordAuthentication yes"
    fi

    # Перезапуск sshd если трогали конфиг
    if [[ "$_AS_ROOT_DISABLED" -eq 1 || -n "$_AS_OLD_SSH_PORT" || "$_AS_PASS_AUTH_DISABLED" -eq 1 ]]; then
        sshd -t 2>/dev/null && systemctl restart sshd >> "$LOG_FILE" 2>&1 || true
    fi

    # Шаг 6 → удалить CrowdSec
    if [[ "$_AS_CROWDSEC_INSTALLED" -eq 1 ]]; then
        info "$MSG_AUTO_ROLLBACK_CROWDSEC"
        _crowdsec_remove_all || true
        log "auto_setup: rollback: CrowdSec removed"
    fi

    # Шаг 5 → сбросить UFW
    if [[ "$_AS_UFW_CONFIGURED" -eq 1 ]]; then
        info "$MSG_AUTO_ROLLBACK_UFW"
        ufw --force reset >> "$LOG_FILE" 2>&1 || true
        log "auto_setup: rollback: UFW reset"
    fi

    # Шаг 1 → удалить пользователя
    if [[ "$_AS_USER_CREATED" -eq 1 ]]; then
        info "$MSG_AUTO_ROLLBACK_USER"
        pkill -u "$username" 2>/dev/null || true
        loginctl terminate-user "$username" 2>/dev/null || true
        deluser --remove-home "$username" >> "$LOG_FILE" 2>&1 || true
        log "auto_setup: rollback: user '$username' deleted"
    fi

    echo
    error "$MSG_AUTO_SETUP_ABORTED"
    log "auto_setup: rollback completed"
}

# ── Установить CrowdSec + crowdsec-firewall-bouncer-iptables ─────

_crowdsec_setup_with_bouncer() {
    local pkg="crowdsec-firewall-bouncer-iptables"

    # 1. Установить и запустить CrowdSec
    _crowdsec_ensure_running || return 1

    # 2. Установить bouncer
    info "$(printf "$MSG_BOUNCER_INSTALLING" "$pkg")"
    apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1 || {
        error "$(printf "$MSG_BOUNCER_INSTALL_FAILED" "$pkg")"
        return 1
    }

    # 3. Определить имя systemd-сервиса из пакета
    local svc_name
    svc_name=$(dpkg -L "$pkg" 2>/dev/null \
        | grep -E '/systemd/system/[^/]+\.service$' \
        | head -1 | xargs -r basename | sed 's/\.service$//')

    if [[ -z "$svc_name" ]]; then
        success "$(printf "$MSG_BOUNCER_INSTALLED" "$pkg")"
        log "auto_setup: bouncer installed: $pkg (service not detected)"
        return 0
    fi

    # 4. Зарегистрировать bouncer в LAPI и прописать API-ключ
    # Удаляем авто-сгенерированные записи postinst (cs-firewall-bouncer-XXXXXXXXXX)
    info "$MSG_BOUNCER_REGISTERING"
    while IFS= read -r stale; do
        [[ -z "$stale" ]] && continue
        cscli bouncers delete "$stale" >> "$LOG_FILE" 2>&1 || true
        log "auto_setup: removed stale bouncer registration: $stale"
    done < <(cscli bouncers list -o raw 2>/dev/null | awk -F',' 'NR>1 {gsub(/^ +| +$/, "", $1); print $1}' \
        | grep -E '^cs-firewall-bouncer-[0-9]+$')
    cscli bouncers delete "$svc_name" >> "$LOG_FILE" 2>&1 || true
    local api_key
    api_key=$(cscli bouncers add "$svc_name" 2>/dev/null \
        | grep -E '^\s+\S{20,}\s*$' | tr -d ' \t')

    if [[ -n "$api_key" ]]; then
        local config_file="/etc/crowdsec/bouncers/${svc_name}.yaml"
        if [[ -f "$config_file" ]]; then
            if grep -q '^api_key:' "$config_file"; then
                sed -i "s|^api_key:.*|api_key: ${api_key}|" "$config_file"
            else
                echo "api_key: ${api_key}" >> "$config_file"
            fi
            log "auto_setup: api_key written to $config_file"
        fi
    fi

    # 5. Запустить сервис bouncer
    systemctl enable  "$svc_name" >> "$LOG_FILE" 2>&1 || true
    systemctl restart "$svc_name" >> "$LOG_FILE" 2>&1 || true

    _AS_BOUNCER_SVC_NAME="$svc_name"

    success "$(printf "$MSG_BOUNCER_INSTALLED" "$pkg")"
    log "auto_setup: bouncer installed and started: $pkg svc=$svc_name"
}

# ── Отключить root SSH без вывода предупреждений (для автоматики) ─

_disable_root_auto() {
    backup_file "/etc/ssh/sshd_config"

    if grep -qE '^PermitRootLogin' /etc/ssh/sshd_config; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    elif grep -qE '^#PermitRootLogin' /etc/ssh/sshd_config; then
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
    else
        echo "PermitRootLogin no" >> /etc/ssh/sshd_config
    fi

    if ! sshd -t 2>/dev/null; then
        error "$MSG_SSH_CONFIG_ERROR_ROLLBACK"
        restore_latest_backup "/etc/ssh/sshd_config"
        return 1
    fi

    systemctl restart sshd >> "$LOG_FILE" 2>&1
    success "$MSG_ROOT_DISABLED"
}

# ── Автонастройка ─────────────────────────────────────────────────

step_auto_setup() {
    clear
    section "$MSG_AUTO_SETUP_TITLE"

    warn "$MSG_AUTO_SETUP_DESCRIPTION"
    echo
    confirm "$MSG_AUTO_SETUP_CONFIRM" || { info "$MSG_CANCELED"; return 0; }
    echo

    # Сброс флагов отката
    _AS_USER_CREATED=0
    _AS_OLD_SSH_PORT=""
    _AS_PASS_AUTH_DISABLED=0
    _AS_UFW_CONFIGURED=0
    _AS_CROWDSEC_INSTALLED=0
    _AS_ROOT_DISABLED=0

    # Выбор имени пользователя (по умолчанию "user")
    echo -en "  ${MSG_AUTO_USERNAME_PROMPT}"
    read -r _input_username
    local username="${_input_username:-user}"

    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "$MSG_USERNAME_INVALID"
        return 1
    fi

    echo

    # ── Шаг 1: Создать пользователя ──────────────────────────────
    info "$(printf "$MSG_AUTO_STEP_N" "1/7") $MSG_AUTO_STEP_CREATE_USER"

    if id "$username" &>/dev/null; then
        warn "$(printf "$MSG_USER_EXISTS" "$username")"
        if ! groups "$username" | grep -q '\bsudo\b'; then
            usermod -aG sudo "$username"
            success "$MSG_ADDED_TO_SUDO"
        fi
    else
        adduser --disabled-password --gecos "" "$username" >> "$LOG_FILE" 2>&1 || {
            error "$(printf "$MSG_AUTO_STEP_FAILED" "1" "$MSG_AUTO_STEP_CREATE_USER")"
            _auto_setup_rollback "$username"
            return 1
        }
        usermod -aG sudo "$username"
        _AS_USER_CREATED=1
        success "$(printf "$MSG_USER_CREATED" "$username")"
    fi
    log "auto_setup: user '$username' ready"

    # ── Шаг 2: SSH ключ ───────────────────────────────────────────
    info "$(printf "$MSG_AUTO_STEP_N" "2/7") $MSG_AUTO_STEP_SSH_KEY"

    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    local ssh_dir="${home_dir}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    _add_key_manually "$username" "$ssh_dir" "$auth_keys" || {
        error "$(printf "$MSG_AUTO_STEP_FAILED" "2" "$MSG_AUTO_STEP_SSH_KEY")"
        _auto_setup_rollback "$username"
        return 1
    }
    log "auto_setup: SSH key added for '$username'"

    # ── Шаг 3: Пароль для sudo + отключение SSH-аутентификации по паролю ──
    info "$(printf "$MSG_AUTO_STEP_N" "3/7") $MSG_AUTO_STEP_SET_PASSWORD"

    local user_password
    user_password=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 20)
    echo "${username}:${user_password}" | chpasswd >> "$LOG_FILE" 2>&1 || {
        error "$(printf "$MSG_AUTO_STEP_FAILED" "3" "$MSG_AUTO_STEP_SET_PASSWORD")"
        _auto_setup_rollback "$username"
        return 1
    }
    log "auto_setup: password set for '$username'"

    _disable_password_auth || {
        error "$(printf "$MSG_AUTO_STEP_FAILED" "3" "$MSG_AUTO_STEP_SET_PASSWORD")"
        _auto_setup_rollback "$username"
        return 1
    }
    _AS_PASS_AUTH_DISABLED=1
    log "auto_setup: SSH PasswordAuthentication disabled"

    # ── Шаг 4: Случайный SSH порт (10000–65000) ───────────────────
    info "$(printf "$MSG_AUTO_STEP_N" "4/7") $MSG_AUTO_STEP_SSH_PORT"

    local old_port new_port attempt=0
    old_port=$(get_ssh_port)
    _AS_OLD_SSH_PORT="$old_port"

    while true; do
        new_port=$(( RANDOM % 55001 + 10000 ))
        (( attempt++ ))
        if ! ss -tunlp 2>/dev/null | awk 'NR>1 {print $5}' \
                | awk -F: '{print $NF}' | grep -qx "$new_port"; then
            break
        fi
        if [[ $attempt -gt 100 ]]; then
            error "$MSG_AUTO_PORT_NOT_FOUND"
            _auto_setup_rollback "$username"
            return 1
        fi
    done

    backup_file "/etc/ssh/sshd_config"

    if grep -qE '^Port ' /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    elif grep -qE '^#Port ' /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    else
        echo "Port ${new_port}" >> /etc/ssh/sshd_config
    fi

    if ! sshd -t 2>/dev/null; then
        error "$MSG_SSH_CONFIG_ERROR_ROLLBACK"
        restore_latest_backup "/etc/ssh/sshd_config"
        _AS_OLD_SSH_PORT=""
        _auto_setup_rollback "$username"
        return 1
    fi

    systemctl restart sshd >> "$LOG_FILE" 2>&1
    success "$(printf "$MSG_PORT_CHANGED" "$old_port" "$new_port")"
    log "auto_setup: SSH port $old_port → $new_port"

    # ── Шаг 5: UFW ───────────────────────────────────────────────
    info "$(printf "$MSG_AUTO_STEP_N" "5/7") $MSG_AUTO_STEP_UFW"

    _ufw_enable || {
        error "$(printf "$MSG_AUTO_STEP_FAILED" "5" "$MSG_AUTO_STEP_UFW")"
        _auto_setup_rollback "$username"
        return 1
    }
    _AS_UFW_CONFIGURED=1
    log "auto_setup: UFW configured"

    # ── Шаг 6: CrowdSec + bouncer ────────────────────────────────
    info "$(printf "$MSG_AUTO_STEP_N" "6/7") $MSG_AUTO_STEP_CROWDSEC"

    _crowdsec_setup_with_bouncer || {
        error "$(printf "$MSG_AUTO_STEP_FAILED" "6" "$MSG_AUTO_STEP_CROWDSEC")"
        _auto_setup_rollback "$username"
        return 1
    }
    _AS_CROWDSEC_INSTALLED=1
    log "auto_setup: CrowdSec + bouncer configured"

    # ── Шаг 7: Отключить root SSH ─────────────────────────────────
    info "$(printf "$MSG_AUTO_STEP_N" "7/7") $MSG_AUTO_STEP_ROOT"

    _disable_root_auto || {
        error "$(printf "$MSG_AUTO_STEP_FAILED" "7" "$MSG_AUTO_STEP_ROOT")"
        _auto_setup_rollback "$username"
        return 1
    }
    _AS_ROOT_DISABLED=1
    log "auto_setup: root SSH login disabled"

    # ── Итог ─────────────────────────────────────────────────────
    local server_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1 || true)
    [[ -z "$server_ip" ]] && server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_SERVER_IP")

    local w="$MSG_STATUS_LABEL_WIDTH"
    echo
    success "$MSG_AUTO_SETUP_DONE"
    echo
    echo -e "${BOLD}  ──────────────────────────────────────────────${NC}"
    echo -e "  ${BOLD}${MSG_AUTO_SETUP_SUMMARY}${NC}"
    echo
    echo -e "  $(_pad_label "$MSG_STATUS_USERS"         $w) ${GREEN}${username}${NC}"
    echo -e "  $(_pad_label "$MSG_AUTO_SETUP_USER_PASS" $w) ${YELLOW}${user_password}${NC}"
    echo -e "  $(_pad_label "$MSG_STATUS_SSH_PORT"      $w) ${CYAN}${new_port}${NC}"
    echo -e "  $(_pad_label "UFW"                       $w) ${GREEN}${MSG_STATUS_ACTIVE}${NC}"
    echo -e "  $(_pad_label "CrowdSec"                  $w) ${GREEN}${MSG_STATUS_ACTIVE}${NC}"
    # Bouncers из LAPI с проверкой статуса systemd-сервиса
    while IFS= read -r bname; do
        [[ -z "$bname" ]] && continue
        local bstatus bcolor
        if systemctl list-units --no-legend --type=service 2>/dev/null | grep -qF "${bname}.service"; then
            bstatus=$(systemctl is-active "$bname" 2>/dev/null || echo "$MSG_STATUS_INACTIVE")
        else
            bstatus="$MSG_STATUS_ACTIVE"
        fi
        if [[ "$bstatus" == "$MSG_STATUS_ACTIVE" || "$bstatus" == "active" ]]; then
            bcolor="${GREEN}"
        else
            bcolor="${RED}"
        fi
        echo -e "    └─ ${bname}  ${bcolor}${bstatus}${NC}"
    done < <(cscli bouncers list -o raw 2>/dev/null | awk -F',' 'NR>1 {gsub(/^ +| +$/, "", $1); print $1}')
    echo -e "  $(_pad_label "$MSG_STATUS_ROOT_SSH"      $w) ${GREEN}${MSG_STATUS_ROOT_DISABLED}${NC}"
    echo
    warn "$MSG_AUTO_SETUP_SAVE_PASSWORD"
    warn "$(printf "$MSG_AUTO_SETUP_CONNECT" "$new_port" "$username" "$server_ip")"
    echo -e "${BOLD}  ──────────────────────────────────────────────${NC}"
    echo

    log "auto_setup: done. user=$username port=$new_port server=$server_ip"
}

# ── Сброс к исходным настройкам ──────────────────────────────────

step_reset_defaults() {
    clear
    section "$MSG_RESET_TITLE"

    warn "$MSG_RESET_DESCRIPTION"
    echo
    confirm "$MSG_RESET_CONFIRM" || { info "$MSG_CANCELED"; return 0; }
    echo

    # 1. Включить root SSH
    info "$MSG_RESET_STEP_ROOT"
    _enable_root || true

    # 2. Включить аутентификацию по паролю SSH
    info "$MSG_RESET_STEP_PASSAUTH"
    backup_file "/etc/ssh/sshd_config"
    if grep -qE '^PasswordAuthentication' /etc/ssh/sshd_config; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    elif grep -qE '^#PasswordAuthentication' /etc/ssh/sshd_config; then
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    else
        echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    fi
    if sshd -t 2>/dev/null; then
        systemctl restart sshd >> "$LOG_FILE" 2>&1
        log "reset: PasswordAuthentication → yes"
    else
        restore_latest_backup "/etc/ssh/sshd_config"
        warn "$MSG_SSH_CONFIG_ERROR_ROLLBACK"
    fi

    # 3. Сбросить порт SSH на 22
    info "$MSG_RESET_STEP_PORT"
    local current_port
    current_port=$(get_ssh_port)
    if [[ "$current_port" != "22" ]]; then
        backup_file "/etc/ssh/sshd_config"
        if grep -qE '^Port ' /etc/ssh/sshd_config; then
            sed -i "s/^Port .*/Port 22/" /etc/ssh/sshd_config
        elif grep -qE '^#Port ' /etc/ssh/sshd_config; then
            sed -i "s/^#Port .*/Port 22/" /etc/ssh/sshd_config
        else
            echo "Port 22" >> /etc/ssh/sshd_config
        fi
        if sshd -t 2>/dev/null; then
            systemctl restart sshd >> "$LOG_FILE" 2>&1
            success "$(printf "$MSG_PORT_CHANGED" "$current_port" "22")"
            # Обновить UFW если активен
            if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
                ufw delete allow "${current_port}/tcp" >> "$LOG_FILE" 2>&1 || true
                ufw allow "22/tcp" comment "SSH" >> "$LOG_FILE" 2>&1
                log "reset: UFW updated: closed $current_port/tcp, opened 22/tcp"
            fi
            log "reset: SSH port → 22"
        else
            restore_latest_backup "/etc/ssh/sshd_config"
            warn "$MSG_RESET_PORT_FAILED"
        fi
    else
        info "$(printf "$MSG_PORT_SAME" "22")"
    fi

    # 3. Отключить UFW
    info "$MSG_RESET_STEP_UFW"
    _ufw_disable || true

    # 4. Удалить CrowdSec
    info "$MSG_RESET_STEP_CROWDSEC"
    _crowdsec_remove_all || true

    # 5. Удалить всех обычных пользователей (аккаунты + home)
    # UIDs собираем заранее — после userdel они уже не будут в /etc/passwd
    info "$MSG_RESET_STEP_USERS"
    warn "$MSG_RESET_USERS_WARN"
    local del_users=()
    local del_uids=()
    while IFS=: read -r uname _ uid _ _ _ _; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        del_users+=("$uname")
        del_uids+=("$uid")
    done < /etc/passwd

    if [[ ${#del_users[@]} -eq 0 ]]; then
        info "$MSG_RESET_NO_USERS"
    else
        for uname in "${del_users[@]}"; do
            info "$(printf "$MSG_RESET_DELETING_USER" "$uname")"
            userdel -f -r "$uname" >> "$LOG_FILE" 2>&1 \
                && success "$(printf "$MSG_RESET_USER_DELETED" "$uname")" \
                || warn "$(printf "$MSG_RESET_USER_DELETE_FAILED" "$uname")"
            log "reset: user '$uname' deleted"
        done
    fi

    echo
    success "$MSG_RESET_DONE"
    log "reset: defaults restored"

    # Завершаем процессы удалённых пользователей последними.
    # Намеренно в конце: pkill может отправить SIGHUP нашему скрипту
    # (если он запущен в той же сессии), но вся важная работа уже выполнена.
    if [[ ${#del_uids[@]} -gt 0 ]]; then
        info "$MSG_RESET_KILLING_SESSIONS"
        for uid in "${del_uids[@]}"; do
            pkill -u "$uid" 2>/dev/null || true
        done
    fi
}
