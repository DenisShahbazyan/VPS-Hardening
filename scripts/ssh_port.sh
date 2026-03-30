#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  ssh_port.sh — Смена порта SSH
# ─────────────────────────────────────────────────────────────────

step_ssh_port() {
    local current_port
    current_port=$(get_ssh_port)
    info "${MSG_CURRENT_SSH_PORT} ${BOLD}${current_port}${NC}"

    read -rp "$MSG_ENTER_NEW_PORT" new_port

    if ! [[ "$new_port" =~ ^[0-9]+$ ]]; then
        error "$MSG_PORT_NOT_NUMBER"
        return 1
    fi

    if (( new_port < 1 || new_port > 65535 )); then
        error "$MSG_PORT_OUT_OF_RANGE"
        return 1
    fi

    if [[ "$new_port" == "$current_port" ]]; then
        warn "$(printf "$MSG_PORT_SAME" "$new_port")"
        return 0
    fi

    # Проверка занятости порта (TCP + UDP, точное совпадение по номеру порта)
    if ss -tunlp 2>/dev/null | awk 'NR>1 {print $5}' | awk -F: '{print $NF}' | grep -qx "${new_port}"; then
        error "$(printf "$MSG_PORT_IN_USE" "$new_port")"
        ss -tunlp 2>/dev/null | awk 'NR>1' | grep -E ":\b${new_port}\b" || true
        return 1
    fi

    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${BOLD}${MSG_PORT_CRITICAL_TITLE}${NC}${YELLOW}║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  ${MSG_PORT_WILL_CHANGE}  ${BOLD}${current_port}${NC} → ${BOLD}${new_port}${NC}"
    echo -e "${YELLOW}║${NC}  ${MSG_PORT_NEW_SSH} ssh -p ${new_port} user@server"
    echo -e "${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  ${RED}${MSG_PORT_DONT_CLOSE}${NC}"
    echo -e "${YELLOW}║${NC}  ${MSG_PORT_VERIFY}"
    echo -e "${YELLOW}║${NC}  ${MSG_PORT_VERIFY2}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    backup_file "/etc/ssh/sshd_config"

    # Обновить или добавить директиву Port
    if grep -qE '^Port ' /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    elif grep -qE '^#Port ' /etc/ssh/sshd_config; then
        sed -i "s/^#Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    else
        echo "Port ${new_port}" >> /etc/ssh/sshd_config
    fi

    # Проверка конфига перед рестартом
    if ! sshd -t 2>/dev/null; then
        error "$MSG_SSH_CONFIG_ERROR_ROLLBACK"
        restore_latest_backup "/etc/ssh/sshd_config"
        return 1
    fi

    systemctl restart sshd

    success "$(printf "$MSG_PORT_CHANGED" "$current_port" "$new_port")"
    echo ""

    # Определяем IP сервера
    local server_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1 || true)
    if [ -z "$server_ip" ]; then
        server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    fi

    warn "${MSG_PORT_NEW_CONNECTION} ${BOLD}ssh -p ${new_port} user@${server_ip}${NC}"

    # Автоматически обновить UFW, если он активен
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        info "$MSG_PORT_UFW_UPDATING"
        ufw delete allow "${current_port}/tcp" >> "$LOG_FILE" 2>&1 || true
        ufw allow "${new_port}/tcp" comment "SSH" >> "$LOG_FILE" 2>&1
        success "$(printf "$MSG_PORT_UFW_OLD_CLOSED" "$current_port")"
        success "$(printf "$MSG_PORT_UFW_NEW_OPENED" "$new_port")"
        success "$MSG_PORT_UFW_UPDATED"
        log "UFW updated: closed $current_port/tcp, opened $new_port/tcp"
    else
        info "$MSG_PORT_UFW_NOT_ACTIVE"
    fi

    log "SSH port changed: $current_port → $new_port"
}
