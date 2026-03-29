#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  disable_root.sh — Управление root-логином по SSH
# ─────────────────────────────────────────────────────────────────

step_disable_root() {
    local current
    current=$(grep -iE '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null \
        | awk '{print tolower($2)}' | head -1) || current=""

    if [[ "$current" == "no" ]]; then
        _enable_root
    else
        _disable_root
    fi
}

# ── Отключить root SSH ────────────────────────────────────────────

_disable_root() {
    # Проверка: хотя бы у одного пользователя должен быть SSH ключ
    local has_key=0
    while IFS=: read -r _ _ uid _ _ home _; do
        [[ "$uid" -lt 1000 || "$uid" -ge 65534 ]] && continue
        if [[ -f "${home}/.ssh/authorized_keys" ]] && \
           grep -qE '^(ssh-|ecdsa-|sk-)' "${home}/.ssh/authorized_keys" 2>/dev/null; then
            has_key=1
            break
        fi
    done < /etc/passwd

    if [[ "$has_key" -eq 0 ]]; then
        error "$MSG_ROOT_DISABLE_NO_KEYS"
        return 1
    fi

    echo ""
    warn "$MSG_ROOT_CHECK_HEADER"
    warn "  $MSG_ROOT_CHECK1"
    warn "  $MSG_ROOT_CHECK2"
    warn "  $MSG_ROOT_CHECK3"
    echo ""
    warn "$MSG_ROOT_WARNING"
    echo ""

    if ! confirm "$MSG_ROOT_CONFIRM"; then
        info "$MSG_CANCELED"
        return 0
    fi

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

    systemctl restart sshd
    success "$MSG_ROOT_DISABLED"
    log "Root SSH login disabled"
}

# ── Включить root SSH ─────────────────────────────────────────────

_enable_root() {
    if ! confirm "$MSG_ROOT_ENABLE_CONFIRM"; then
        info "$MSG_CANCELED"
        return 0
    fi

    backup_file "/etc/ssh/sshd_config"

    if grep -qE '^PermitRootLogin' /etc/ssh/sshd_config; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    elif grep -qE '^#PermitRootLogin' /etc/ssh/sshd_config; then
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    else
        echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    fi

    if ! sshd -t 2>/dev/null; then
        error "$MSG_SSH_CONFIG_ERROR_ROLLBACK"
        restore_latest_backup "/etc/ssh/sshd_config"
        return 1
    fi

    systemctl restart sshd
    success "$MSG_ROOT_ENABLED_MSG"
    log "Root SSH login enabled"
}
