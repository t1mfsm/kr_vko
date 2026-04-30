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
    echo "ОШИБКА: Скрипт остановки разрешен только в Linux. Текущая ОС: $(uname -s)" >&2
    exit 1
fi

stop_component() {
    local name="$1"
    local pidfile="$PID_DIR/${name}.pid"

    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 0.5
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            echo "[-] $name остановлен (PID: $pid)"
        else
            echo "[!] $name не работает (PID: $pid)"
        fi
        rm -f "$pidfile"
    else
        echo "[!] $name: PID-файл не найден"
    fi
}

stop_by_name() {
    local component="$1"
    case "$component" in
        gen|generator)
            stop_component "GenTargets"
            pkill -f "GenTargets.sh" 2>/dev/null
            echo "[-] Генератор целей остановлен"
            ;;
        kp)
            stop_component "KP_VKO"
            ;;
        rls1) stop_component "$RLS1_NAME" ;;
        rls2) stop_component "$RLS2_NAME" ;;
        rls3) stop_component "$RLS3_NAME" ;;
        zrdn1) stop_component "$ZRDN1_NAME" ;;
        zrdn2) stop_component "$ZRDN2_NAME" ;;
        zrdn3) stop_component "$ZRDN3_NAME" ;;
        spro) stop_component "$SPRO_NAME" ;;
        *)
            echo "Неизвестный компонент: $component"
            echo "Доступные: gen, kp, rls1, rls2, rls3, zrdn1, zrdn2, zrdn3, spro"
            return 1
            ;;
    esac
}

if [[ -n "$1" ]]; then
    stop_by_name "$1"
else
    echo "========================================="
    echo "  Остановка системы ВКО"
    echo "========================================="
    echo ""

    stop_component "$ZRDN3_NAME"
    stop_component "$ZRDN2_NAME"
    stop_component "$ZRDN1_NAME"
    stop_component "$SPRO_NAME"
    stop_component "$RLS3_NAME"
    stop_component "$RLS2_NAME"
    stop_component "$RLS1_NAME"
    stop_component "KP_VKO"

    stop_component "GenTargets"
    pkill -f "GenTargets.sh" 2>/dev/null

    rm -f "$MSG_DIR/to_kp/"* 2>/dev/null
    rm -f "$MSG_DIR/from_kp/"* 2>/dev/null
    rm -f "$MSG_DIR/heartbeat/"* 2>/dev/null

    echo ""
    echo "========================================="
    echo "  Все системы ВКО остановлены"
    echo "========================================="
fi
