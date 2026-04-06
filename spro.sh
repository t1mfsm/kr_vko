#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_environment
check_single_instance "$SPRO_NAME"
trap "cleanup '$SPRO_NAME'; exit 0" SIGTERM SIGINT EXIT

LOGFILE="$LOG_DIR/${SPRO_NAME}.log"
AMMO=$SPRO_AMMO
AMMO_EMPTY_TIME=0

echo "[$SPRO_NAME] Запуск СПРО"
echo "[$SPRO_NAME] Координаты: X=$SPRO_X Y=$SPRO_Y, Радиус: $SPRO_RANGE м"
echo "[$SPRO_NAME] Боезапас: $AMMO противоракет"

log_message "$LOGFILE" "$SPRO_NAME" "Запуск СПРО. Координаты: X=$SPRO_X Y=$SPRO_Y, Радиус: $SPRO_RANGE"
send_to_kp "$SPRO_NAME" "STATUS $SPRO_NAME ONLINE AMMO:$AMMO"

# Ассоциативные массивы
declare -A reported_targets   # ID -> 1
declare -A shot_targets       # ID -> "shot_time:last_seen_mtime:target_type"

while true; do
    # Heartbeat
    if [[ -f "$MSG_DIR/heartbeat/${SPRO_NAME}_request" ]]; then
        rm -f "$MSG_DIR/heartbeat/${SPRO_NAME}_request"
        send_heartbeat_response "$SPRO_NAME"
    fi

    # Сообщения от КП
    for msg_file in "$MSG_DIR/from_kp/${SPRO_NAME}_"*; do
        [[ -f "$msg_file" ]] || continue
        encrypted=$(cat "$msg_file" 2>/dev/null)
        decoded=$(decrypt_message "$encrypted")
        if [[ "$decoded" == "ERROR_HMAC" ]]; then
            log_message "$LOGFILE" "$SPRO_NAME" "ПОПЫТКА НСД! Поддельное сообщение"
            send_to_kp "$SPRO_NAME" "NSD $SPRO_NAME Обнаружена попытка подмены сообщения"
        elif [[ "$decoded" == REFILL* ]]; then
            AMMO=$SPRO_AMMO
            log_message "$LOGFILE" "$SPRO_NAME" "Боекомплект пополнен: $AMMO противоракет"
            send_to_kp "$SPRO_NAME" "REFILL $SPRO_NAME AMMO:$AMMO"
            echo "[$SPRO_NAME] Боекомплект пополнен: $AMMO"
        fi
        rm -f "$msg_file"
    done

    # Автопополнение боекомплекта
    if (( AMMO <= 0 && AMMO_EMPTY_TIME > 0 )); then
        local_now=$(date +%s)
        if (( local_now - AMMO_EMPTY_TIME >= AMMO_REFILL_TIME )); then
            AMMO=$SPRO_AMMO
            AMMO_EMPTY_TIME=0
            log_message "$LOGFILE" "$SPRO_NAME" "Боекомплект автоматически пополнен: $AMMO противоракет"
            send_to_kp "$SPRO_NAME" "REFILL $SPRO_NAME AMMO:$AMMO"
            echo "[$SPRO_NAME] Автопополнение боекомплекта: $AMMO"
        fi
    fi

    # Сканирование целей
    declare -A current_targets
    declare -A current_target_mtimes

    while read -r target_id tx ty target_mtime; do
        [[ -z "$target_id" ]] && continue
        # Проверка: цель в зоне СПРО (360 градусов)
        if is_in_range "$SPRO_X" "$SPRO_Y" "$SPRO_RANGE" "$tx" "$ty"; then
            current_targets[$target_id]="$tx $ty"
            current_target_mtimes[$target_id]="$target_mtime"
        fi
    done < <(scan_targets)

    for target_id in "${!current_targets[@]}"; do
        tx=$(echo "${current_targets[$target_id]}" | awk '{print $1}')
        ty=$(echo "${current_targets[$target_id]}" | awk '{print $2}')

        if [[ -z "${reported_targets[$target_id]}" ]]; then
            track=$(get_latest_two_visible_marks "circle" "$target_id" "$SPRO_X" "$SPRO_Y" "$SPRO_RANGE") || continue
            read -r prev_x prev_y prev_mtime latest_x latest_y latest_mtime <<< "$track"
            (( latest_mtime <= prev_mtime )) && continue

            speed=$(calc_speed "$prev_x" "$prev_y" "$latest_x" "$latest_y")
            target_type=$(get_target_type "$speed")
            tx=$latest_x
            ty=$latest_y

            timestamp=$(date +"%H:%M:%S:%3N")

            # Доклад об обнаружении
            report_msg="В $timestamp Обнаружена цель id:$target_id координаты $tx $ty тип:$target_type скорость:$speed"
            log_message "$LOGFILE" "$SPRO_NAME" "$report_msg"
            send_to_kp "$SPRO_NAME" "DETECT $target_id $tx $ty $target_type $speed"
            echo "[$SPRO_NAME] $report_msg"

            reported_targets[$target_id]=1

            # СПРО уничтожает только ББ БР
            if [[ "$target_type" == "BB_BR" ]]; then
                if (( AMMO > 0 )); then
                    # Попытка уничтожения
                    echo "$SPRO_NAME" > "$DESTROY_DIR/$target_id"
                    ((AMMO--))
                    shot_targets[$target_id]=1
                    track_shot_result_async "$SPRO_NAME" "$LOGFILE" "$target_id" "BB_BR" "$latest_mtime"

                    shot_msg="Стрельба по цели id:$target_id тип:BB_BR. Осталось противоракет: $AMMO"
                    log_message "$LOGFILE" "$SPRO_NAME" "$shot_msg"
                    send_to_kp "$SPRO_NAME" "SHOT $target_id BB_BR AMMO:$AMMO"
                    echo "[$SPRO_NAME] $shot_msg"

                    if (( AMMO <= 0 )); then
                        AMMO_EMPTY_TIME=$(date +%s)
                        empty_msg="Боекомплект исчерпан! Переход в режим обнаружения"
                        log_message "$LOGFILE" "$SPRO_NAME" "$empty_msg"
                        send_to_kp "$SPRO_NAME" "AMMO_EMPTY $SPRO_NAME"
                        echo "[$SPRO_NAME] $empty_msg"
                    fi
                fi
            fi
        fi
    done

    # Снятие блокировки по целям, для которых фоновый трекер уже определил результат
    for result_file in "$TEMP_DIR/shot_results/${SPRO_NAME}_"*; do
        [[ -f "$result_file" ]] || continue
        target_id="${result_file##${TEMP_DIR}/shot_results/${SPRO_NAME}_}"
        unset "shot_targets[$target_id]"
        unset "reported_targets[$target_id]"
        rm -f "$result_file"
    done

    # Очистка данных о пропавших целях
    for target_id in "${!reported_targets[@]}"; do
        if [[ -z "${current_targets[$target_id]}" ]] && [[ -z "${shot_targets[$target_id]}" ]]; then
            unset "reported_targets[$target_id]"
        fi
    done

    unset current_targets

    sleep "$CHECK_INTERVAL"
done
