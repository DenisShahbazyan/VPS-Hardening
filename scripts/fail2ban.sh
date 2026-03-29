#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  fail2ban.sh — Настройка fail2ban
# ─────────────────────────────────────────────────────────────────

step_fail2ban() {
    while true; do
        clear
        section "$MSG_SECTION_FAIL2BAN"

        local f2b_raw
        f2b_raw=$(systemctl is-active fail2ban 2>/dev/null) || f2b_raw="inactive"
        if [[ "$f2b_raw" == "active" ]]; then
            echo -e "  ${MSG_FAIL2BAN_STATUS} ${GREEN}${MSG_STATUS_ACTIVE}${NC}"
        else
            echo -e "  ${MSG_FAIL2BAN_STATUS} ${RED}${MSG_STATUS_INACTIVE}${NC}"
        fi
        echo
        echo -e "  ${BOLD}1)${NC} $MSG_FAIL2BAN_OPT_ENABLE"
        echo -e "  ${BOLD}2)${NC} $MSG_FAIL2BAN_OPT_DISABLE"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_FAIL2BAN_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r subchoice

        case "${subchoice,,}" in
            1) _fail2ban_enable_menu || true ;;
            2) _fail2ban_disable     || true ;;
            "") return 0 ;;
            *) error "$(printf "$MSG_INVALID_CHOICE" "$subchoice")" ;;
        esac

        pause
    done
}

# ── Выбор областей защиты ─────────────────────────────────────────

_fail2ban_enable_menu() {
    local ssh_port
    ssh_port=$(get_ssh_port)

    while true; do
        clear
        section "$MSG_FAIL2BAN_ENABLE_TITLE"
        echo
        echo -e "  ${BOLD}1)${NC} ${MSG_FAIL2BAN_OPT_SSH} (port ${ssh_port})"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_FAIL2BAN_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r area_choice

        case "${area_choice}" in
            1)
                _fail2ban_configure true "$ssh_port"
                return $?
                ;;
            "")
                return 0
                ;;
            *)
                error "$(printf "$MSG_INVALID_CHOICE" "$area_choice")"
                pause
                ;;
        esac
    done
}

# ── Настройка и применение ────────────────────────────────────────

_fail2ban_configure() {
    local protect_ssh="$1"
    local ssh_port="$2"

    if ! command -v fail2ban-server &>/dev/null; then
        info "$MSG_FAIL2BAN_INSTALLING"
        apt-get install -y fail2ban >> "$LOG_FILE" 2>&1
        success "$MSG_FAIL2BAN_INSTALLED"
    fi

    local selected_areas=""
    $protect_ssh && selected_areas="${MSG_FAIL2BAN_OPT_SSH}"

    echo ""
    info "$(printf "$MSG_FAIL2BAN_SELECTED" "$selected_areas")"

    # ── Параметры ──────────────────────────────────────────────────
    echo ""
    echo "$MSG_FAIL2BAN_PARAMS"
    echo ""
    read -rp "$MSG_FAIL2BAN_MAXRETRY" maxretry
    read -rp "$MSG_FAIL2BAN_BANTIME"  bantime
    read -rp "$MSG_FAIL2BAN_FINDTIME" findtime

    maxretry=${maxretry:-5}
    bantime=${bantime:-1h}
    findtime=${findtime:-10m}

    echo ""
    info "$(printf "$MSG_FAIL2BAN_SUMMARY" "$maxretry" "$bantime" "$findtime")"

    if ! confirm "$MSG_FAIL2BAN_CONFIRM"; then
        info "$MSG_CANCELED"
        return 0
    fi

    [[ -f /etc/fail2ban/jail.local ]] && backup_file "/etc/fail2ban/jail.local"

    # ── Генерация jail.local ───────────────────────────────────────
    cat > /etc/fail2ban/jail.local << EOF
# VPS Hardening — $(date '+%Y-%m-%d %H:%M')
# Status:   fail2ban-client status
# Unban:    fail2ban-client set <jail> unbanip <IP>

[DEFAULT]
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
backend  = systemd
EOF

    if $protect_ssh; then
        cat >> /etc/fail2ban/jail.local << EOF

[sshd]
enabled  = true
port     = ${ssh_port}
filter   = sshd
logpath  = %(sshd_log)s
maxretry = ${maxretry}
EOF
    fi

    systemctl enable fail2ban >> "$LOG_FILE" 2>&1
    systemctl restart fail2ban

    sleep 1

    success "$MSG_FAIL2BAN_DONE"
    echo ""
    fail2ban-client status || true
    log "fail2ban: areas=$selected_areas, port=$ssh_port, maxretry=$maxretry, bantime=$bantime, findtime=$findtime"
}

# ── Отключение ────────────────────────────────────────────────────

_fail2ban_disable() {
    local f2b_raw
    f2b_raw=$(systemctl is-active fail2ban 2>/dev/null) || f2b_raw="inactive"
    if [[ "$f2b_raw" != "active" ]]; then
        warn "$MSG_FAIL2BAN_ALREADY_INACTIVE"
        return 0
    fi

    if ! confirm "$MSG_FAIL2BAN_DISABLE_CONFIRM"; then
        info "$MSG_CANCELED"
        return 0
    fi

    systemctl stop    fail2ban >> "$LOG_FILE" 2>&1
    systemctl disable fail2ban >> "$LOG_FILE" 2>&1
    success "$MSG_FAIL2BAN_DISABLED"
    log "fail2ban disabled"
}
