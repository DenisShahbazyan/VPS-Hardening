# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Что это за проект

Интерактивный CLI-инструмент на Bash для hardening Ubuntu/Debian VPS-серверов. Меню-интерфейс с поддержкой русского и английского языков. Скрипт запускается через `sudo bash`, все операции с привилегиями выполняются через `sudo` внутри.

**Запуск из GitHub:**
```bash
wget -qO ~/harden.sh https://raw.githubusercontent.com/DenisShahbazyan/VPS-Hardening/master/harden-manager.sh && sudo bash ~/harden.sh
```

**Локальный запуск (разработка):**
```bash
sudo bash harden-manager.sh
```

---

## Валидация синтаксиса

```bash
# Один файл
bash -n harden-manager.sh

# Все файлы сразу
for f in harden-manager.sh scripts/*.sh scripts/i18n/*.sh; do bash -n "$f" || echo "FAIL: $f"; done
```

---

## Архитектура

### Точка входа и загрузка модулей

`harden-manager.sh` — единственная точка входа. При старте:
1. Скачивает все модули с GitHub в `/tmp/vps-hardening-XXXXX` через `wget`
2. `source`-ит их в фиксированном порядке (`SCRIPT_MODULES`)
3. Временная директория удаляется по trap на EXIT/INT/TERM

Все модули разделяют одно плоское пространство имён — межмодульные вызовы неявные. При переименовании или переносе функций — проверять весь `scripts/` через `grep`.

### Порядок загрузки (критичен)

1. `scripts/i18n/{LANG_CODE}.sh` — первым, определяет все `MSG_*`-переменные
2. `scripts/lib.sh` — цвета, логирование, хелперы (`confirm`, `pause`, `backup_file`, `get_ssh_port`)
3. `scripts/create_user.sh`, `scripts/ssh_key.sh`, `scripts/ssh_port.sh`, `scripts/ufw.sh`, `scripts/crowdsec.sh`, `scripts/disable_root.sh` — модули шагов, зависят от `lib.sh`

### Соглашение об именовании функций

- `step_*` — публичные точки входа, вызываемые из меню (`step_create_user`, `step_ssh_key` и т.д.)
- `_underscore_*` — приватные/внутренние функции модуля
- `PROMPT_RESULT` — глобальная переменная для возврата строки из `_prompt_*`-функций (Bash не может возвращать строки через `return`)
- `LANG_CODE` — глобальная, устанавливается при выборе языка

### Логи

`/var/log/vps-hardening/YYYY-MM-DD_HH-MM.log` — создаётся при каждом запуске, права 600.

---

## Система i18n

Языковые строки в `scripts/i18n/{ru,en}.sh` как `MSG_*`-переменные.

- Весь пользовательский вывод — только через `MSG_*`, никаких хардкоженных строк
- При добавлении новых сообщений — добавлять в **оба** файла локализации
- Часть сообщений использует `printf`-спецификаторы (`%s`) — вызывающий код оборачивает: `printf "$MSG_*" "$arg"`
- Переменные организованы по секциям-комментариям — новые добавлять в нужную секцию

---

## Shell-опции и стиль

```bash
set -uo pipefail  # без set -e
```

- Ошибки обрабатываются явно через `|| return` / `|| exit`, скрипт не падает автоматически
- **Не добавлять `set -e`**
- Все комментарии в коде — на русском языке

---

## Модификация конфигов системы

Перед изменением системных файлов всегда создавать бэкап через `backup_file()` из `lib.sh`. Это касается:
- `/etc/ssh/sshd_config`

После изменения `sshd_config` — валидировать через `sshd -t` перед рестартом сервиса.
