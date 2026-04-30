#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

if [[ $EUID -eq 0 ]]; then
    echo "ОШИБКА: Запуск от имени root запрещен!" >&2
    exit 1
fi

if [[ -z "$BASH_VERSION" ]]; then
    echo "ОШИБКА: Требуется интерпретатор Bash!" >&2
    exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ОШИБКА: Запуск разрешен только в Linux. Текущая ОС: $(uname -s)" >&2
    exit 1
fi

mkdir -p "$DB_DIR" "$LOG_DIR" "$MSG_DIR/to_kp" "$MSG_DIR/from_kp" "$MSG_DIR/heartbeat" "$TEMP_DIR" "$PID_DIR"
mkdir -p /tmp/GenTargets/Targets /tmp/GenTargets/Destroy

source "$SCRIPT_DIR/common.sh"
init_database

start_component() {
    local component="$1"
    case "$component" in
        gen|generator)
            if [[ -f "$PID_DIR/GenTargets.pid" ]] && kill -0 "$(cat "$PID_DIR/GenTargets.pid" 2>/dev/null)" 2>/dev/null; then
                echo "[!] Генератор целей уже запущен"
                return
            fi
            echo "[*] Запуск генератора целей..."
            chmod +x "$SCRIPT_DIR/GenTargets.sh"
            bash "$SCRIPT_DIR/GenTargets.sh" &
            echo "[+] Генератор целей запущен (PID: $!)"
            ;;
        kp)
            echo "[*] Запуск КП ВКО..."
            bash "$SCRIPT_DIR/kp.sh" &
            echo "[+] КП ВКО запущен"
            ;;
        rls1)
            echo "[*] Запуск РЛС1 (Дарьял, Минск)..."
            bash "$SCRIPT_DIR/rls.sh" 1 &
            echo "[+] РЛС1 запущена"
            ;;
        rls2)
            echo "[*] Запуск РЛС2 (Днепр)..."
            bash "$SCRIPT_DIR/rls.sh" 2 &
            echo "[+] РЛС2 запущена"
            ;;
        rls3)
            echo "[*] Запуск РЛС3 (Воронеж-ДМ, Казань)..."
            bash "$SCRIPT_DIR/rls.sh" 3 &
            echo "[+] РЛС3 запущена"
            ;;
        zrdn1)
            echo "[*] Запуск ЗРДН1 (Крым)..."
            bash "$SCRIPT_DIR/zrdn.sh" 1 &
            echo "[+] ЗРДН1 запущен"
            ;;
        zrdn2)
            echo "[*] Запуск ЗРДН2 (Петрозаводск)..."
            bash "$SCRIPT_DIR/zrdn.sh" 2 &
            echo "[+] ЗРДН2 запущен"
            ;;
        zrdn3)
            echo "[*] Запуск ЗРДН3 (Уфа)..."
            bash "$SCRIPT_DIR/zrdn.sh" 3 &
            echo "[+] ЗРДН3 запущен"
            ;;
        spro)
            echo "[*] Запуск СПРО (Новосибирск)..."
            bash "$SCRIPT_DIR/spro.sh" &
            echo "[+] СПРО запущен"
            ;;
        *)
            echo "Неизвестный компонент: $component"
            echo "Доступные: gen, kp, rls1, rls2, rls3, zrdn1, zrdn2, zrdn3, spro"
            return 1
            ;;
    esac
}

if [[ -n "$1" ]]; then
    start_component "$1"
else
    echo "========================================="
    echo "  Запуск системы ВКО"
    echo "========================================="
    echo ""

    rm -f "$DB_DIR/vko.db"
    rm -f "$MSG_DIR/to_kp/"* 2>/dev/null
    rm -f "$MSG_DIR/from_kp/"* 2>/dev/null
    rm -f "$MSG_DIR/heartbeat/"* 2>/dev/null
    init_database

    start_component gen
    sleep 2

    start_component kp
    sleep 1

    start_component rls1
    start_component rls2
    start_component rls3
    sleep 1

    start_component spro
    sleep 1

    start_component zrdn1
    start_component zrdn2
    start_component zrdn3

    echo ""
    echo "========================================="
    echo "  Все системы ВКО запущены"
    echo "========================================="
    echo ""
    echo "Логи: $LOG_DIR/"
    echo "Журнал системы: $LOG_DIR/system_journal.log"
    echo "БД: $DB_DIR/vko.db"
    echo ""
    echo "Для остановки: ./stop.sh"
    echo "Для статистики: ./db_queries.sh"
fi
