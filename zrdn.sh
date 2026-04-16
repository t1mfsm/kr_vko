#!/bin/bash
# Скрипт работы ЗРДН (зенитно-ракетный дивизион)
# Использование: ./zrdn.sh <номер_зрдн> (1, 2 или 3)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_environment

ZRDN_NUM="${1:?Использование: $0 <номер_зрдн> (1, 2 или 3)}"

if [[ "$ZRDN_NUM" != "1" && "$ZRDN_NUM" != "2" && "$ZRDN_NUM" != "3" ]]; then
    echo "ОШИБКА: номер ЗРДН должен быть 1, 2 или 3" >&2
    exit 1
fi

# Загрузка параметров
eval "ZRDN_NAME=\$ZRDN${ZRDN_NUM}_NAME"
eval "ZRDN_X=\$ZRDN${ZRDN_NUM}_X"
eval "ZRDN_Y=\$ZRDN${ZRDN_NUM}_Y"
eval "ZRDN_RANGE=\$ZRDN${ZRDN_NUM}_RANGE"
eval "ZRDN_MAX_AMMO=\$ZRDN${ZRDN_NUM}_AMMO"

check_single_instance "$ZRDN_NAME"
trap "cleanup '$ZRDN_NAME'; exit 0" SIGTERM SIGINT EXIT

LOGFILE="$LOG_DIR/${ZRDN_NAME}.log"
AMMO=$ZRDN_MAX_AMMO
AMMO_EMPTY_TIME=0

echo "[$ZRDN_NAME] Запуск ЗРДН"
echo "[$ZRDN_NAME] Координаты: X=$ZRDN_X Y=$ZRDN_Y, Радиус: $ZRDN_RANGE м"
echo "[$ZRDN_NAME] Боезапас: $AMMO ракет"

log_message "$LOGFILE" "$ZRDN_NAME" "Запуск ЗРДН. Координаты: X=$ZRDN_X Y=$ZRDN_Y, Радиус: $ZRDN_RANGE"
send_to_kp "$ZRDN_NAME" "STATUS $ZRDN_NAME ONLINE AMMO:$AMMO"

# Ассоциативные массивы
declare -A reported_targets   # ID -> 1
declare -A shot_targets       # ID -> target_type
declare -A pending_fire_targets  # ID -> target_type
declare -A target_retry_deadlines # ID -> epoch seconds
declare -A tracked_target_types
declare -A tracked_last_x
declare -A tracked_last_y
declare -A tracked_last_mtime
declare -A tracked_vx
declare -A tracked_vy
declare -A tracked_last_seen_at

clear_zrdn_track() {
    local target_id="$1"
    unset "tracked_target_types[$target_id]"
    unset "tracked_last_x[$target_id]"
    unset "tracked_last_y[$target_id]"
    unset "tracked_last_mtime[$target_id]"
    unset "tracked_vx[$target_id]"
    unset "tracked_vy[$target_id]"
    unset "tracked_last_seen_at[$target_id]"
}

drop_zrdn_target() {
    local target_id="$1"
    unset "pending_fire_targets[$target_id]"
    unset "target_retry_deadlines[$target_id]"
    unset "reported_targets[$target_id]"
    unset "shot_targets[$target_id]"
    clear_zrdn_track "$target_id"
}

update_zrdn_track_from_marks() {
    local target_id="$1" target_type="$2" prev_x="$3" prev_y="$4" prev_mtime="$5" latest_x="$6" latest_y="$7" latest_mtime="$8"
    local dt_ms vx vy

    dt_ms=$((latest_mtime - prev_mtime))
    if (( dt_ms <= 0 )); then
        dt_ms=1000
    fi

    vx=$((((latest_x - prev_x) * 1000) / dt_ms))
    vy=$((((latest_y - prev_y) * 1000) / dt_ms))

    tracked_target_types[$target_id]="$target_type"
    tracked_last_x[$target_id]="$latest_x"
    tracked_last_y[$target_id]="$latest_y"
    tracked_last_mtime[$target_id]="$latest_mtime"
    tracked_vx[$target_id]="$vx"
    tracked_vy[$target_id]="$vy"
    tracked_last_seen_at[$target_id]=$(date +%s)
}

refresh_zrdn_track_from_current() {
    local target_id="$1"
    local tx ty target_mtime track prev_x prev_y prev_mtime latest_x latest_y latest_mtime speed target_type

    [[ -n "${current_targets[$target_id]}" ]] || return 1

    read -r tx ty <<< "${current_targets[$target_id]}"
    target_mtime="${current_target_mtimes[$target_id]:-0}"
    (( target_mtime > 0 )) || return 1

    track=$(get_latest_two_visible_marks "circle" "$target_id" "$ZRDN_X" "$ZRDN_Y" "$ZRDN_RANGE" 2>/dev/null || true)
    if [[ -n "$track" ]]; then
        read -r prev_x prev_y prev_mtime latest_x latest_y latest_mtime <<< "$track"
        if (( latest_mtime > ${tracked_last_mtime[$target_id]:-0} )); then
            speed=$(calc_speed "$prev_x" "$prev_y" "$latest_x" "$latest_y")
            target_type=$(get_target_type "$speed")
            update_zrdn_track_from_marks "$target_id" "$target_type" "$prev_x" "$prev_y" "$prev_mtime" "$latest_x" "$latest_y" "$latest_mtime"
            return 0
        fi
    fi

    if (( target_mtime >= ${tracked_last_mtime[$target_id]:-0} )); then
        tracked_last_x[$target_id]="$tx"
        tracked_last_y[$target_id]="$ty"
        tracked_last_mtime[$target_id]="$target_mtime"
        tracked_last_seen_at[$target_id]=$(date +%s)
    fi
}

zrdn_track_retryable() {
    local target_id="$1"
    local target_type now_s last_seen last_x last_y last_mtime

    target_type="${tracked_target_types[$target_id]:-}"
    [[ "$target_type" == "SAM" || "$target_type" == "KR" ]] || return 1

    last_seen="${tracked_last_seen_at[$target_id]:-0}"
    now_s=$(date +%s)
    (( last_seen > 0 )) || return 1
    (( now_s - last_seen <= TARGET_RETRY_HOLD_SECONDS )) || return 1

    last_x="${tracked_last_x[$target_id]:-}"
    last_y="${tracked_last_y[$target_id]:-}"
    last_mtime="${tracked_last_mtime[$target_id]:-0}"
    [[ -n "$last_x" && -n "$last_y" ]] || return 1
    (( last_mtime > 0 )) || return 1
    return 0
}

hold_zrdn_target_for_retry() {
    local target_id="$1" target_type="$2"
    pending_fire_targets[$target_id]="$target_type"
    reported_targets[$target_id]=1
    target_retry_deadlines[$target_id]=$(( $(date +%s) + TARGET_RETRY_HOLD_SECONDS ))
}

get_zrdn_retry_mtime() {
    local target_id="$1"
    local latest_mark latest_x latest_y latest_mtime

    if [[ -n "${current_targets[$target_id]}" ]]; then
        refresh_zrdn_track_from_current "$target_id"
        latest_mtime="${tracked_last_mtime[$target_id]:-0}"
        (( latest_mtime > 0 )) && {
            echo "$latest_mtime"
            return 0
        }
    fi

    latest_mark=$(get_latest_visible_mark "circle" "$target_id" "$ZRDN_X" "$ZRDN_Y" "$ZRDN_RANGE" 2>/dev/null || true)
    [[ -n "$latest_mark" ]] || return 1

    read -r latest_x latest_y latest_mtime <<< "$latest_mark"
    tracked_last_x[$target_id]="$latest_x"
    tracked_last_y[$target_id]="$latest_y"
    tracked_last_mtime[$target_id]="$latest_mtime"
    tracked_last_seen_at[$target_id]=$(date +%s)
    echo "$latest_mtime"
}

fire_zrdn_target() {
    local target_id="$1" target_type="$2" latest_mtime="$3"
    local shot_msg empty_msg generator_log_start

    if is_target_destroyed "$target_id"; then
        return 1
    fi

    if (( AMMO <= 0 )); then
        return 1
    fi

    generator_log_start=$(get_generator_log_position)
    echo "$ZRDN_NAME" > "$DESTROY_DIR/$target_id"
    ((AMMO--))
    shot_targets[$target_id]="$target_type"
    track_shot_result_async "$ZRDN_NAME" "$LOGFILE" "$target_id" "$target_type" "$latest_mtime" "$generator_log_start"

    shot_msg="Стрельба по цели id:$target_id тип:$target_type. Осталось ракет: $AMMO"
    log_message "$LOGFILE" "$ZRDN_NAME" "$shot_msg"
    send_to_kp "$ZRDN_NAME" "SHOT $target_id $target_type AMMO:$AMMO"
    echo "[$ZRDN_NAME] $shot_msg"

    if (( AMMO <= 0 )); then
        AMMO_EMPTY_TIME=$(date +%s)
        empty_msg="Боекомплект исчерпан! Переход в режим обнаружения"
        log_message "$LOGFILE" "$ZRDN_NAME" "$empty_msg"
        send_to_kp "$ZRDN_NAME" "AMMO_EMPTY $ZRDN_NAME"
        echo "[$ZRDN_NAME] $empty_msg"
    fi

    return 0
}

try_pending_zrdn_targets() {
    local target_id latest_mtime target_type

    (( AMMO <= 0 )) && return 0

    for target_id in "${!pending_fire_targets[@]}"; do
        target_type="${pending_fire_targets[$target_id]}"
        [[ -n "${shot_targets[$target_id]}" ]] && continue
        [[ "$target_type" != "SAM" && "$target_type" != "KR" ]] && continue
        if is_target_destroyed "$target_id"; then
            drop_zrdn_target "$target_id"
            continue
        fi

        latest_mtime=$(get_zrdn_retry_mtime "$target_id" 2>/dev/null || echo 0)
        (( latest_mtime > 0 )) || continue

        if fire_zrdn_target "$target_id" "$target_type" "$latest_mtime"; then
            reported_targets[$target_id]=1
            unset "pending_fire_targets[$target_id]"
            unset "target_retry_deadlines[$target_id]"
        elif is_target_destroyed "$target_id"; then
            drop_zrdn_target "$target_id"
        fi
    done
}

while true; do
    # Heartbeat
    if [[ -f "$MSG_DIR/heartbeat/${ZRDN_NAME}_request" ]]; then
        rm -f "$MSG_DIR/heartbeat/${ZRDN_NAME}_request"
        send_heartbeat_response "$ZRDN_NAME"
    fi

    # Сообщения от КП
    for msg_file in "$MSG_DIR/from_kp/${ZRDN_NAME}_"*; do
        [[ -f "$msg_file" ]] || continue
        encrypted=$(cat "$msg_file" 2>/dev/null)
        decoded=$(decrypt_message "$encrypted")
        if [[ "$decoded" == "ERROR_HMAC" ]]; then
            log_message "$LOGFILE" "$ZRDN_NAME" "ПОПЫТКА НСД! Поддельное сообщение"
            send_to_kp "$ZRDN_NAME" "NSD $ZRDN_NAME Обнаружена попытка подмены сообщения"
        elif [[ "$decoded" == REFILL* ]]; then
            AMMO=$ZRDN_MAX_AMMO
            log_message "$LOGFILE" "$ZRDN_NAME" "Боекомплект пополнен: $AMMO ракет"
            send_to_kp "$ZRDN_NAME" "REFILL $ZRDN_NAME AMMO:$AMMO"
            echo "[$ZRDN_NAME] Боекомплект пополнен: $AMMO"
        fi
        rm -f "$msg_file"
    done

    # Автопополнение
    if (( AMMO <= 0 && AMMO_EMPTY_TIME > 0 )); then
        local_now=$(date +%s)
        if (( local_now - AMMO_EMPTY_TIME >= AMMO_REFILL_TIME )); then
            AMMO=$ZRDN_MAX_AMMO
            AMMO_EMPTY_TIME=0
            log_message "$LOGFILE" "$ZRDN_NAME" "Боекомплект автоматически пополнен: $AMMO ракет"
            send_to_kp "$ZRDN_NAME" "REFILL $ZRDN_NAME AMMO:$AMMO"
            echo "[$ZRDN_NAME] Автопополнение боекомплекта: $AMMO"
        fi
    fi

    # Сканирование целей
    declare -A current_targets
    declare -A current_target_mtimes

    while read -r target_id tx ty target_mtime; do
        [[ -z "$target_id" ]] && continue
        is_target_destroyed "$target_id" && continue
        # Проверка: цель в зоне ЗРДН (360 градусов)
        if is_in_range "$ZRDN_X" "$ZRDN_Y" "$ZRDN_RANGE" "$tx" "$ty"; then
            current_targets[$target_id]="$tx $ty"
            current_target_mtimes[$target_id]="$target_mtime"
        fi
    done < <(scan_targets)

    for target_id in "${!current_targets[@]}"; do
        if [[ -n "${tracked_target_types[$target_id]}" ]] || [[ -n "${pending_fire_targets[$target_id]}" ]] || [[ -n "${shot_targets[$target_id]}" ]]; then
            refresh_zrdn_track_from_current "$target_id"
        fi
    done

    for target_id in "${!current_targets[@]}"; do
        tx=$(echo "${current_targets[$target_id]}" | awk '{print $1}')
        ty=$(echo "${current_targets[$target_id]}" | awk '{print $2}')

        if [[ -z "${reported_targets[$target_id]}" ]]; then
            track=$(get_latest_two_visible_marks "circle" "$target_id" "$ZRDN_X" "$ZRDN_Y" "$ZRDN_RANGE") || continue
            read -r prev_x prev_y prev_mtime latest_x latest_y latest_mtime <<< "$track"
            (( latest_mtime <= prev_mtime )) && continue

            speed=$(calc_speed "$prev_x" "$prev_y" "$latest_x" "$latest_y")
            target_type=$(get_target_type "$speed")
            [[ "$target_type" != "SAM" && "$target_type" != "KR" ]] && continue
            tx=$latest_x
            ty=$latest_y
            update_zrdn_track_from_marks "$target_id" "$target_type" "$prev_x" "$prev_y" "$prev_mtime" "$latest_x" "$latest_y" "$latest_mtime"

            timestamp=$(date +"%H:%M:%S:%3N")

            # Доклад об обнаружении
            report_msg="В $timestamp Обнаружена цель id:$target_id координаты $tx $ty тип:$target_type скорость:$speed"
            log_message "$LOGFILE" "$ZRDN_NAME" "$report_msg"
            send_to_kp "$ZRDN_NAME" "DETECT $target_id $tx $ty $target_type $speed"
            echo "[$ZRDN_NAME] $report_msg"

            reported_targets[$target_id]=1

            # ЗРДН уничтожает только самолеты и крылатые ракеты на второй засечке.
            if ! fire_zrdn_target "$target_id" "$target_type" "$latest_mtime"; then
                if is_target_destroyed "$target_id"; then
                    drop_zrdn_target "$target_id"
                else
                    hold_zrdn_target_for_retry "$target_id" "$target_type"
                fi
            fi
        fi
    done

    # Сначала разбираем результаты уже выполненных выстрелов, чтобы при промахе
    # успеть выпустить повторную ракету в этом же цикле.
    for result_file in "$TEMP_DIR/shot_results/${ZRDN_NAME}_"*; do
        [[ -f "$result_file" ]] || continue
        target_id="${result_file##${TEMP_DIR}/shot_results/${ZRDN_NAME}_}"
        result=$(cat "$result_file" 2>/dev/null)
        shot_target_type="${shot_targets[$target_id]:-}"
        unset "shot_targets[$target_id]"
        rm -f "$result_file"

        if [[ -n "${current_targets[$target_id]}" ]]; then
            refresh_zrdn_track_from_current "$target_id"
        fi

        if [[ "$result" == "ALREADY_DESTROYED" ]] || is_target_destroyed "$target_id"; then
            drop_zrdn_target "$target_id"
            continue
        fi

        if [[ "$result" == "MISS" ]]; then
            target_type="$shot_target_type"
            latest_mtime=$(get_zrdn_retry_mtime "$target_id" 2>/dev/null || echo 0)
            if ! is_target_destroyed "$target_id" && (( latest_mtime > 0 )) && fire_zrdn_target "$target_id" "$target_type" "$latest_mtime"; then
                reported_targets[$target_id]=1
                unset "pending_fire_targets[$target_id]"
                unset "target_retry_deadlines[$target_id]"
            elif is_target_destroyed "$target_id"; then
                drop_zrdn_target "$target_id"
            else
                hold_zrdn_target_for_retry "$target_id" "$target_type"
            fi
            continue
        fi

        drop_zrdn_target "$target_id"
    done

    try_pending_zrdn_targets

    # Очистка пропавших целей
    for target_id in "${!reported_targets[@]}"; do
        if is_target_destroyed "$target_id"; then
            drop_zrdn_target "$target_id"
            continue
        fi

        if [[ -z "${current_targets[$target_id]}" ]] && [[ -z "${shot_targets[$target_id]}" ]]; then
            if [[ -n "${pending_fire_targets[$target_id]}" ]]; then
                retry_deadline="${target_retry_deadlines[$target_id]:-0}"
                if (( retry_deadline > $(date +%s) )); then
                    continue
                fi
            fi

            drop_zrdn_target "$target_id"
        fi
    done

    unset current_targets

    sleep "$CHECK_INTERVAL"
done
