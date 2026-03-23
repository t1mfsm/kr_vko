#!/bin/bash
# Скрипт работы системы ПРО (СПРО)
# Использование: ./spro.sh

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
declare -A first_detection    # ID -> "X Y"
declare -A reported_targets   # ID -> 1
declare -A shot_targets       # ID -> 1 (цели, по которым стреляли)

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
            db_insert "INSERT INTO nsd_log (timestamp, system_name, details) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$SPRO_NAME', 'Поддельное сообщение от КП');"
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

    for f in "$TARGETS_DIR"/*; do
        [[ -f "$f" ]] || continue
        target_id=$(decode_target_id "$f")
        [[ -z "$target_id" ]] && continue

        coords=$(read_target_coords "$f")
        [[ -z "$coords" ]] && continue

        tx=$(echo "$coords" | awk '{print $1}')
        ty=$(echo "$coords" | awk '{print $2}')

        # Проверка: цель в зоне СПРО (360 градусов)
        if is_in_range "$SPRO_X" "$SPRO_Y" "$SPRO_RANGE" "$tx" "$ty"; then
            current_targets[$target_id]="$tx $ty"
        fi
    done

    for target_id in "${!current_targets[@]}"; do
        tx=$(echo "${current_targets[$target_id]}" | awk '{print $1}')
        ty=$(echo "${current_targets[$target_id]}" | awk '{print $2}')

        if [[ -z "${first_detection[$target_id]}" ]]; then
            # Первая засечка
            first_detection[$target_id]="$tx $ty"
        elif [[ -z "${reported_targets[$target_id]}" ]]; then
            # Вторая засечка
            prev_x=$(echo "${first_detection[$target_id]}" | awk '{print $1}')
            prev_y=$(echo "${first_detection[$target_id]}" | awk '{print $2}')

            speed=$(calc_speed "$prev_x" "$prev_y" "$tx" "$ty")
            target_type=$(get_target_type "$speed")

            timestamp=$(date +"%H:%M:%S:%3N")

            # Доклад об обнаружении
            report_msg="В $timestamp Обнаружена цель id:$target_id координаты $tx $ty тип:$target_type скорость:$speed"
            log_message "$LOGFILE" "$SPRO_NAME" "$report_msg"
            send_to_kp "$SPRO_NAME" "DETECT $target_id $tx $ty $target_type $speed"
            echo "[$SPRO_NAME] $report_msg"

            db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_x, target_y, target_type, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$SPRO_NAME', 'DETECT', '$target_id', $tx, $ty, '$target_type', 'Обнаружена цель');"

            reported_targets[$target_id]=1

            # СПРО уничтожает только ББ БР
            if [[ "$target_type" == "BB_BR" ]]; then
                if (( AMMO > 0 )); then
                    # Попытка уничтожения
                    echo "$SPRO_NAME" > "$DESTROY_DIR/$target_id"
                    ((AMMO--))
                    shot_targets[$target_id]=1

                    shot_msg="Стрельба по цели id:$target_id тип:BB_BR. Осталось противоракет: $AMMO"
                    log_message "$LOGFILE" "$SPRO_NAME" "$shot_msg"
                    send_to_kp "$SPRO_NAME" "SHOT $target_id BB_BR AMMO:$AMMO"
                    echo "[$SPRO_NAME] $shot_msg"

                    db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_x, target_y, target_type, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$SPRO_NAME', 'SHOT', '$target_id', $tx, $ty, 'BB_BR', '$shot_msg');"

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

    # Проверка результатов стрельбы
    for target_id in "${!shot_targets[@]}"; do
        if [[ -z "${current_targets[$target_id]}" ]]; then
            # Цель больше не генерируется — поражена
            destroy_msg="Цель id:$target_id УНИЧТОЖЕНА"
            log_message "$LOGFILE" "$SPRO_NAME" "$destroy_msg"
            send_to_kp "$SPRO_NAME" "DESTROYED $target_id BB_BR"
            echo "[$SPRO_NAME] $destroy_msg"

            db_insert "INSERT INTO shots (timestamp, system_name, target_id, target_type, result) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$SPRO_NAME', '$target_id', 'BB_BR', 'DESTROYED');"
            db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_type, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$SPRO_NAME', 'DESTROYED', '$target_id', 'BB_BR', '$destroy_msg');"

            unset "shot_targets[$target_id]"
            unset "first_detection[$target_id]"
            unset "reported_targets[$target_id]"
        else
            # Цель все еще существует - проверяем, был ли промах
            # Если прошло достаточно времени и цель все еще есть — промах
            if [[ -n "${reported_targets[$target_id]}" ]] && [[ -n "${shot_targets[$target_id]}" ]]; then
                # Файл уничтожения уже обработан генератором (удален из Destroy)
                if [[ ! -f "$DESTROY_DIR/$target_id" ]]; then
                    miss_msg="ПРОМАХ по цели id:$target_id"
                    log_message "$LOGFILE" "$SPRO_NAME" "$miss_msg"
                    send_to_kp "$SPRO_NAME" "MISS $target_id BB_BR"
                    echo "[$SPRO_NAME] $miss_msg"

                    db_insert "INSERT INTO shots (timestamp, system_name, target_id, target_type, result) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$SPRO_NAME', '$target_id', 'BB_BR', 'MISS');"
                    db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_type, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$SPRO_NAME', 'MISS', '$target_id', 'BB_BR', '$miss_msg');"

                    unset "shot_targets[$target_id]"
                fi
            fi
        fi
    done

    # Очистка данных о пропавших целях
    for target_id in "${!first_detection[@]}"; do
        if [[ -z "${current_targets[$target_id]}" ]] && [[ -z "${shot_targets[$target_id]}" ]]; then
            unset "first_detection[$target_id]"
            unset "reported_targets[$target_id]"
        fi
    done

    unset current_targets

    sleep "$CHECK_INTERVAL"
done
