#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────
#  crowdsec.sh — Управление CrowdSec и bouncers
# ─────────────────────────────────────────────────────────────────

# ── Вспомогательные функции ───────────────────────────────────────

_crowdsec_is_installed() {
    command -v cscli &>/dev/null
}

_crowdsec_is_active() {
    [[ "$(systemctl is-active crowdsec 2>/dev/null)" == "active" ]]
}

# Добавление репозитория packagecloud.io
_crowdsec_add_repo() {
    if [[ -f /etc/apt/sources.list.d/crowdsec.list ]]; then
        return 0
    fi

    info "$MSG_CROWDSEC_ADDING_REPO"
    apt-get install -y curl gnupg >> "$LOG_FILE" 2>&1

    curl -fsSL "https://packagecloud.io/crowdsec/crowdsec/gpgkey" \
        | gpg --dearmor > /usr/share/keyrings/crowdsec.gpg 2>> "$LOG_FILE"

    local distro arch
    distro=$(lsb_release -cs 2>/dev/null || echo "focal")
    arch=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

    echo "deb [arch=${arch} signed-by=/usr/share/keyrings/crowdsec.gpg] https://packagecloud.io/crowdsec/crowdsec/ubuntu ${distro} main" \
        > /etc/apt/sources.list.d/crowdsec.list

    apt-get update -qq >> "$LOG_FILE" 2>&1
    success "$MSG_CROWDSEC_REPO_ADDED"
}

# Убедиться что CrowdSec установлен и запущен (установить/запустить при необходимости)
_crowdsec_ensure_running() {
    if ! _crowdsec_is_installed; then
        info "$MSG_CROWDSEC_NOT_INSTALLED_INSTALLING"
        _crowdsec_add_repo || return 1
        info "$MSG_CROWDSEC_INSTALLING"
        apt-get install -y crowdsec >> "$LOG_FILE" 2>&1
        success "$MSG_CROWDSEC_INSTALLED"
    fi

    if ! _crowdsec_is_active; then
        info "$MSG_CROWDSEC_STARTING"
        systemctl enable crowdsec >> "$LOG_FILE" 2>&1
        systemctl start  crowdsec >> "$LOG_FILE" 2>&1
        sleep 2
        success "$MSG_CROWDSEC_STARTED"
    fi
}

# Получить список bouncers: строки вида "name|type"
_crowdsec_get_bouncers() {
    cscli bouncers list -o raw 2>/dev/null | tail -n +2 \
        | awk -F, '{ if ($1 != "") print $1 "|" $5 }'
}

# Найти имя deb-пакета по имени сервиса/типа bouncer
_bouncer_find_package() {
    local service_type="$1"
    dpkg --list "crowdsec*" 2>/dev/null \
        | awk '/^ii/{ print $2 }' \
        | grep -F "$service_type" \
        | head -1
}

# Показать нумерованный список bouncers и вернуть выбранный через глобальные переменные
# BOUNCER_PICK_NAME, BOUNCER_PICK_TYPE
# Возвращает 1 если список пуст или выбор некорректный
_bouncer_pick() {
    if ! _crowdsec_is_installed; then
        warn "$MSG_CROWDSEC_NOT_INSTALLED"
        return 1
    fi

    local bouncers_raw
    bouncers_raw=$(_crowdsec_get_bouncers)
    if [[ -z "$bouncers_raw" ]]; then
        warn "$MSG_BOUNCER_NONE"
        return 1
    fi

    echo
    local i=1
    local names=() types=()
    while IFS='|' read -r b_name b_type; do
        [[ -z "$b_name" ]] && continue
        local svc_status
        svc_status=$(systemctl is-active "$b_type" 2>/dev/null) || svc_status="inactive"
        local status_str
        if [[ "$svc_status" == "active" ]]; then
            status_str="${GREEN}${MSG_STATUS_ACTIVE}${NC}"
        else
            status_str="${RED}${MSG_STATUS_INACTIVE}${NC}"
        fi
        echo -e "  ${BOLD}${i})${NC} ${b_name}  [${b_type}]  ${status_str}"
        names+=("$b_name")
        types+=("$b_type")
        ((i++))
    done <<< "$bouncers_raw"

    echo
    echo -en "  $MSG_BOUNCER_SELECT_NUM"
    read -r sel

    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [[ "$sel" -lt 1 || "$sel" -ge "$i" ]]; then
        error "$MSG_BOUNCER_INVALID_NUM"
        return 1
    fi

    BOUNCER_PICK_NAME="${names[$((sel - 1))]}"
    BOUNCER_PICK_TYPE="${types[$((sel - 1))]}"
}

# ── Главное меню CrowdSec ─────────────────────────────────────────

step_crowdsec() {
    while true; do
        clear
        section "$MSG_SECTION_CROWDSEC"

        local cs_active cs_status_str cs_toggle_label
        if _crowdsec_is_active; then
            cs_active=1
            cs_status_str="${GREEN}${MSG_STATUS_ACTIVE}${NC}"
            cs_toggle_label="$MSG_CROWDSEC_OPT_DISABLE"
        else
            cs_active=0
            cs_status_str="${RED}${MSG_STATUS_INACTIVE}${NC}"
            cs_toggle_label="$MSG_CROWDSEC_OPT_ENABLE"
        fi
        echo -e "  ${MSG_CROWDSEC_STATUS} ${cs_status_str}"

        # Bouncers — только если CrowdSec активен и cscli доступен
        if [[ "$cs_active" -eq 1 ]] && command -v cscli &>/dev/null; then
            while IFS=, read -r b_name _ _ _ b_type _; do
                [[ -z "$b_name" ]] && continue
                local b_svc_raw b_str
                b_svc_raw=$(systemctl is-active "$b_type" 2>/dev/null) || b_svc_raw="inactive"
                if [[ "$b_svc_raw" == "active" ]]; then
                    b_str="${GREEN}${MSG_STATUS_ACTIVE}${NC}"
                else
                    b_str="${RED}${MSG_STATUS_INACTIVE}${NC}"
                fi
                echo -e "    ${CYAN}└─${NC} ${b_name}  ${b_str}"
            done < <(cscli bouncers list -o raw 2>/dev/null | tail -n +2)
        fi

        echo
        echo -e "  ${BOLD}1)${NC} ${cs_toggle_label}"
        echo -e "  ${BOLD}2)${NC} $MSG_CROWDSEC_MENU_MANAGE_BOUNCERS"
        echo -e "  ${BOLD}3)${NC} $MSG_CROWDSEC_MENU_REMOVE_ALL"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_CROWDSEC_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r subchoice

        case "${subchoice,,}" in
            1) if [[ "$cs_active" -eq 1 ]]; then
                   _crowdsec_disable || true
               else
                   _crowdsec_enable  || true
               fi
               pause ;;
            2) _bouncer_manage_menu  || true ;;
            3) _crowdsec_remove_all  || true; pause ;;
            "") return 0 ;;
            *) error "$(printf "$MSG_INVALID_CHOICE" "$subchoice")"; pause ;;
        esac
    done
}

# ── Подменю: Управление CrowdSec ──────────────────────────────────

_crowdsec_manage_menu() {
    while true; do
        clear
        section "$MSG_CROWDSEC_SECTION_MANAGE"

        local cs_status_str
        if _crowdsec_is_active; then
            cs_status_str="${GREEN}${MSG_STATUS_ACTIVE}${NC}"
        else
            cs_status_str="${RED}${MSG_STATUS_INACTIVE}${NC}"
        fi
        echo -e "  ${MSG_CROWDSEC_STATUS} ${cs_status_str}"
        echo
        echo -e "  ${BOLD}1)${NC} $MSG_CROWDSEC_OPT_ENABLE"
        echo -e "  ${BOLD}2)${NC} $MSG_CROWDSEC_OPT_DISABLE"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_CROWDSEC_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r subchoice

        case "${subchoice,,}" in
            1) _crowdsec_enable  || true; pause ;;
            2) _crowdsec_disable || true; pause ;;
            "") return 0 ;;
            *) error "$(printf "$MSG_INVALID_CHOICE" "$subchoice")"; pause ;;
        esac
    done
}

# ── Включить CrowdSec ─────────────────────────────────────────────

_crowdsec_enable() {
    if _crowdsec_is_active; then
        warn "$MSG_CROWDSEC_ALREADY_ACTIVE"
        return 0
    fi

    _crowdsec_ensure_running || return 1

    # Регистрация в CrowdSec Console (опционально)
    echo
    echo -en "  $MSG_CROWDSEC_ENROLL_PROMPT"
    read -r enroll_key
    if [[ -n "$enroll_key" ]]; then
        info "$MSG_CROWDSEC_ENROLLING"
        cscli console enroll "$enroll_key" >> "$LOG_FILE" 2>&1 || true
        systemctl reload crowdsec >> "$LOG_FILE" 2>&1 || true
        success "$MSG_CROWDSEC_ENROLLED"
    else
        info "$MSG_CROWDSEC_ENROLL_SKIPPED"
    fi

    success "$MSG_CROWDSEC_DONE"
    log "crowdsec: enabled, enroll_key=${enroll_key:+(provided)}"
}

# ── Отключить CrowdSec ────────────────────────────────────────────

_crowdsec_disable() {
    if ! _crowdsec_is_active; then
        warn "$MSG_CROWDSEC_ALREADY_INACTIVE"
        return 0
    fi

    # Предупреждение если есть bouncers
    local bouncers_raw
    bouncers_raw=$(_crowdsec_get_bouncers)
    if [[ -n "$bouncers_raw" ]]; then
        warn "$MSG_CROWDSEC_DISABLE_BOUNCERS_WARNING"
        echo
    fi

    # Останавливаем bouncers (без удаления и дерегистрации)
    if [[ -n "$bouncers_raw" ]]; then
        info "$MSG_CROWDSEC_STOPPING_BOUNCERS"
        while IFS='|' read -r b_name b_type; do
            [[ -z "$b_name" ]] && continue
            systemctl stop    "$b_type" >> "$LOG_FILE" 2>&1 || true
            systemctl disable "$b_type" >> "$LOG_FILE" 2>&1 || true
            log "crowdsec: bouncer stopped: $b_name ($b_type)"
        done <<< "$bouncers_raw"
        success "$MSG_CROWDSEC_BOUNCERS_STOPPED"
    fi

    systemctl stop    crowdsec >> "$LOG_FILE" 2>&1
    systemctl disable crowdsec >> "$LOG_FILE" 2>&1
    success "$MSG_CROWDSEC_DISABLED"
    log "crowdsec: disabled"
}

# ── Подменю: Управление bouncers ─────────────────────────────────

_bouncer_manage_menu() {
    while true; do
        clear
        section "$MSG_CROWDSEC_SECTION_BOUNCERS"
        echo
        echo -e "  ${BOLD}1)${NC} $MSG_BOUNCER_OPT_ADD"
        echo -e "  ${BOLD}2)${NC} $MSG_BOUNCER_OPT_REMOVE"
        echo -e "  ${BOLD}3)${NC} $MSG_BOUNCER_OPT_ENABLE"
        echo -e "  ${BOLD}4)${NC} $MSG_BOUNCER_OPT_DISABLE"
        echo
        echo -e "  ${BOLD}Enter)${NC} $MSG_CROWDSEC_BACK"
        echo
        echo -en "  ${MSG_MENU_CHOICE} "
        read -r subchoice

        case "${subchoice,,}" in
            1) _bouncer_add     || true; pause ;;
            2) _bouncer_remove  || true; pause ;;
            3) _bouncer_enable  || true; pause ;;
            4) _bouncer_disable || true; pause ;;
            "") return 0 ;;
            *) error "$(printf "$MSG_INVALID_CHOICE" "$subchoice")"; pause ;;
        esac
    done
}

# ── Добавить bouncer ──────────────────────────────────────────────

_bouncer_add() {
    echo -en "  $MSG_BOUNCER_ENTER_PACKAGE"
    read -r pkg_name
    if [[ -z "$pkg_name" ]]; then
        error "$MSG_BOUNCER_PACKAGE_EMPTY"
        return 1
    fi

    # CrowdSec должен быть установлен и запущен до установки bouncer
    _crowdsec_ensure_running || return 1

    info "$(printf "$MSG_BOUNCER_INSTALLING" "$pkg_name")"
    apt-get install -y "$pkg_name" >> "$LOG_FILE" 2>&1 || {
        error "$(printf "$MSG_BOUNCER_INSTALL_FAILED" "$pkg_name")"
        return 1
    }

    # Определяем имя systemd-сервиса из установленного пакета
    local svc_name
    svc_name=$(dpkg -L "$pkg_name" 2>/dev/null \
        | grep -E '/systemd/system/[^/]+\.service$' \
        | head -1 | xargs -r basename | sed 's/\.service$//')

    if [[ -z "$svc_name" ]]; then
        success "$(printf "$MSG_BOUNCER_INSTALLED" "$pkg_name")"
        log "crowdsec: bouncer installed: $pkg_name (service not detected)"
        return 0
    fi

    # Регистрируем bouncer в LAPI (удаляем авто-сгенерированные записи postinst и битую регистрацию)
    info "$MSG_BOUNCER_REGISTERING"
    while IFS= read -r stale; do
        [[ -z "$stale" ]] && continue
        cscli bouncers delete "$stale" >> "$LOG_FILE" 2>&1 || true
        log "crowdsec: removed stale bouncer registration: $stale"
    done < <(cscli bouncers list -o raw 2>/dev/null | awk -F',' 'NR>1 {gsub(/^ +| +$/, "", $1); print $1}' \
        | grep -E '^cs-firewall-bouncer-[0-9]+$')
    cscli bouncers delete "$svc_name" >> "$LOG_FILE" 2>&1 || true
    local api_key
    api_key=$(cscli bouncers add "$svc_name" 2>/dev/null \
        | grep -E '^\s+\S{20,}\s*$' | tr -d ' \t')

    if [[ -z "$api_key" ]]; then
        warn "$MSG_BOUNCER_REGISTER_FAILED"
        log "crowdsec: bouncer registered (no key captured): $svc_name"
    else
        # Прописываем API-ключ в конфиг bouncer
        local config_file="/etc/crowdsec/bouncers/${svc_name}.yaml"
        if [[ -f "$config_file" ]]; then
            if grep -q '^api_key:' "$config_file"; then
                sed -i "s|^api_key:.*|api_key: ${api_key}|" "$config_file"
            else
                echo "api_key: ${api_key}" >> "$config_file"
            fi
            log "crowdsec: api_key written to $config_file"
        else
            warn "$(printf "$MSG_BOUNCER_CONFIG_NOT_FOUND" "$config_file")"
            info "$(printf "$MSG_BOUNCER_API_KEY_MANUAL" "$api_key")"
        fi
    fi

    # Запускаем сервис
    systemctl enable  "$svc_name" >> "$LOG_FILE" 2>&1 || true
    systemctl restart "$svc_name" >> "$LOG_FILE" 2>&1 || true

    success "$(printf "$MSG_BOUNCER_INSTALLED" "$pkg_name")"
    log "crowdsec: bouncer installed: $pkg_name svc=$svc_name"
}

# ── Удалить bouncer ───────────────────────────────────────────────

_bouncer_remove() {
    # CrowdSec должен быть запущен для cscli bouncers delete
    _crowdsec_ensure_running || return 1

    BOUNCER_PICK_NAME=""
    BOUNCER_PICK_TYPE=""
    _bouncer_pick || return 0

    local b_name="$BOUNCER_PICK_NAME"
    local b_type="$BOUNCER_PICK_TYPE"

    systemctl stop    "$b_type" >> "$LOG_FILE" 2>&1 || true
    systemctl disable "$b_type" >> "$LOG_FILE" 2>&1 || true
    cscli bouncers delete "$b_name" >> "$LOG_FILE" 2>&1 || true

    local pkg
    pkg=$(_bouncer_find_package "$b_type")
    if [[ -n "$pkg" ]]; then
        apt-get remove --purge -y "$pkg" >> "$LOG_FILE" 2>&1 || true
        success "$(printf "$MSG_BOUNCER_REMOVED" "$b_name")"
    else
        warn "$(printf "$MSG_BOUNCER_PKG_NOT_FOUND" "$b_type")"
        success "$(printf "$MSG_BOUNCER_REMOVED_NO_PKG" "$b_name")"
    fi

    log "crowdsec: bouncer removed: $b_name ($b_type) pkg=${pkg:-unknown}"
}

# ── Включить bouncer ──────────────────────────────────────────────

_bouncer_enable() {
    # CrowdSec должен быть запущен — bouncer подключается к LAPI
    _crowdsec_ensure_running || return 1

    BOUNCER_PICK_NAME=""
    BOUNCER_PICK_TYPE=""
    _bouncer_pick || return 0

    local b_type="$BOUNCER_PICK_TYPE"
    systemctl enable "$b_type" >> "$LOG_FILE" 2>&1 || true
    systemctl start  "$b_type" >> "$LOG_FILE" 2>&1 || true
    success "$(printf "$MSG_BOUNCER_ENABLED" "$BOUNCER_PICK_NAME")"
    log "crowdsec: bouncer enabled: $BOUNCER_PICK_NAME ($b_type)"
}

# ── Отключить bouncer ─────────────────────────────────────────────

_bouncer_disable() {
    BOUNCER_PICK_NAME=""
    BOUNCER_PICK_TYPE=""
    _bouncer_pick || return 0

    local b_type="$BOUNCER_PICK_TYPE"
    systemctl stop    "$b_type" >> "$LOG_FILE" 2>&1 || true
    systemctl disable "$b_type" >> "$LOG_FILE" 2>&1 || true
    success "$(printf "$MSG_BOUNCER_DISABLED" "$BOUNCER_PICK_NAME")"
    log "crowdsec: bouncer disabled: $BOUNCER_PICK_NAME ($b_type)"
}

# ── Удалить всё ───────────────────────────────────────────────────

_crowdsec_remove_all() {
    if ! _crowdsec_is_installed; then
        warn "$MSG_CROWDSEC_NOT_INSTALLED"
        return 0
    fi

    info "$MSG_CROWDSEC_REMOVE_ALL_SLOW"

    # Нужен запущенный CrowdSec для cscli bouncers delete
    if ! _crowdsec_is_active; then
        info "$MSG_CROWDSEC_STARTING"
        systemctl start crowdsec >> "$LOG_FILE" 2>&1 || true
        sleep 2
    fi

    # Удаляем все bouncers в правильном порядке
    local bouncers_raw
    bouncers_raw=$(_crowdsec_get_bouncers)
    if [[ -n "$bouncers_raw" ]]; then
        info "$MSG_CROWDSEC_REMOVING_BOUNCERS"
        while IFS='|' read -r b_name b_type; do
            [[ -z "$b_name" ]] && continue
            local pkg
            pkg=$(_bouncer_find_package "$b_type")
            systemctl stop    "$b_type" >> "$LOG_FILE" 2>&1 || true
            systemctl disable "$b_type" >> "$LOG_FILE" 2>&1 || true
            cscli bouncers delete "$b_name" >> "$LOG_FILE" 2>&1 || true
            [[ -n "$pkg" ]] && apt-get remove --purge -y "$pkg" >> "$LOG_FILE" 2>&1 || true
            log "crowdsec: remove-all: bouncer removed: $b_name ($b_type) pkg=${pkg:-unknown}"
        done <<< "$bouncers_raw"
        success "$MSG_CROWDSEC_BOUNCERS_REMOVED"
    fi

    # Удаляем CrowdSec
    info "$MSG_CROWDSEC_REMOVING_CS"
    systemctl stop    crowdsec >> "$LOG_FILE" 2>&1 || true
    systemctl disable crowdsec >> "$LOG_FILE" 2>&1 || true
    apt-get remove --purge -y crowdsec >> "$LOG_FILE" 2>&1 || true

    # Удаляем репозиторий и ключ
    info "$MSG_CROWDSEC_REMOVING_REPO"
    rm -f /etc/apt/sources.list.d/crowdsec.list
    rm -f /usr/share/keyrings/crowdsec.gpg
    apt-get update -qq >> "$LOG_FILE" 2>&1 || true

    success "$MSG_CROWDSEC_REMOVED_ALL"
    log "crowdsec: remove-all completed"
}
