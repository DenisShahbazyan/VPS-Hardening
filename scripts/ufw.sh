#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  ufw.sh — Настройка UFW
# ─────────────────────────────────────────────────────────────────

step_ufw() {
    while true; do
        clear
        section "$MSG_SECTION_UFW"

        local ufw_raw
        ufw_raw=$(ufw status 2>/dev/null | awk 'NR==1{print $2}') || ufw_raw=""
        if [[ "$ufw_raw" == "active" ]]; then
            echo -e "  ${MSG_UFW_STATUS} ${GREEN}${MSG_STATUS_ACTIVE}${NC}"
        else
            echo -e "  ${MSG_UFW_STATUS} ${RED}${MSG_STATUS_INACTIVE}${NC}"
        fi
        echo
        echo -e "  ${BOLD}1)${NC} $MSG_UFW_OPT_ENABLE"
        echo -e "  ${BOLD}2)${NC} $MSG_UFW_OPT_DISABLE"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_UFW_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r subchoice

        case "${subchoice,,}" in
            1) _ufw_enable  || true ;;
            2) _ufw_disable || true ;;
            "") return 0 ;;
            *) error "$(printf "$MSG_INVALID_CHOICE" "$subchoice")" ;;
        esac

        pause
    done
}

_ufw_enable() {
    if ! command -v ufw &>/dev/null; then
        info "$MSG_UFW_INSTALLING"
        apt-get install -y ufw >> "$LOG_FILE" 2>&1
        success "$MSG_UFW_INSTALLED"
    fi

    local ssh_port
    ssh_port=$(get_ssh_port)

    echo -e "${MSG_UFW_RULES_TITLE}\n"
    echo -e "  ${GREEN}ALLOW${NC}  SSH   → ${BOLD}${ssh_port}/tcp${NC}"
    echo -e "  ${GREEN}ALLOW${NC}  HTTP  → ${BOLD}80/tcp${NC}"
    echo -e "  ${GREEN}ALLOW${NC}  HTTPS → ${BOLD}443/tcp${NC}"
    echo -e "  ${RED}DENY${NC}   ${MSG_UFW_RULE_DENY}"
    echo ""
    warn "$MSG_UFW_RESET_WARN"
    echo ""

    if ! confirm "$MSG_UFW_CONFIRM"; then
        info "$MSG_CANCELED"
        return 0
    fi

    ufw --force reset          >> "$LOG_FILE" 2>&1
    ufw default deny incoming  >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1
    ufw allow "${ssh_port}/tcp" comment "SSH"   >> "$LOG_FILE" 2>&1
    ufw allow 80/tcp            comment "HTTP"  >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp           comment "HTTPS" >> "$LOG_FILE" 2>&1
    ufw --force enable         >> "$LOG_FILE" 2>&1

    success "$MSG_UFW_DONE"
    echo ""
    ufw status verbose
    log "UFW configured: SSH=$ssh_port, HTTP=80, HTTPS=443"
}

_ufw_disable() {
    local ufw_raw
    ufw_raw=$(ufw status 2>/dev/null | awk 'NR==1{print $2}') || ufw_raw=""
    if [[ "$ufw_raw" != "active" ]]; then
        warn "$MSG_UFW_ALREADY_INACTIVE"
        return 0
    fi

    if ! confirm "$MSG_UFW_DISABLE_CONFIRM"; then
        info "$MSG_CANCELED"
        return 0
    fi

    ufw --force reset >> "$LOG_FILE" 2>&1
    success "$MSG_UFW_DISABLED"
    log "UFW disabled and all rules removed"
}
