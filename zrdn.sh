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
declare -A first_detection    # ID -> "X Y"
declare -A reported_targets   # ID -> 1
declare -A shot_targets       # ID -> 1

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
            db_insert "INSERT INTO nsd_log (timestamp, system_name, details) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$ZRDN_NAME', 'Поддельное сообщение от КП');"
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

    for f in "$TARGETS_DIR"/*; do
        [[ -f "$f" ]] || continue
        target_id=$(decode_target_id "$f")
        [[ -z "$target_id" ]] && continue

        coords=$(read_target_coords "$f")
        [[ -z "$coords" ]] && continue

        tx=$(echo "$coords" | awk '{print $1}')
        ty=$(echo "$coords" | awk '{print $2}')

        # Проверка: цель в зоне ЗРДН (360 градусов)
        if is_in_range "$ZRDN_X" "$ZRDN_Y" "$ZRDN_RANGE" "$tx" "$ty"; then
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
            log_message "$LOGFILE" "$ZRDN_NAME" "$report_msg"
            send_to_kp "$ZRDN_NAME" "DETECT $target_id $tx $ty $target_type $speed"
            echo "[$ZRDN_NAME] $report_msg"

            db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_x, target_y, target_type, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$ZRDN_NAME', 'DETECT', '$target_id', $tx, $ty, '$target_type', 'Обнаружена цель');"

            reported_targets[$target_id]=1

            # ЗРДН уничтожает только самолеты и крылатые ракеты
            if [[ "$target_type" == "SAM" || "$target_type" == "KR" ]]; then
                if (( AMMO > 0 )); then
                    # Попытка уничтожения
                    echo "$ZRDN_NAME" > "$DESTROY_DIR/$target_id"
                    ((AMMO--))
                    shot_targets[$target_id]=1

                    shot_msg="Стрельба по цели id:$target_id тип:$target_type. Осталось ракет: $AMMO"
                    log_message "$LOGFILE" "$ZRDN_NAME" "$shot_msg"
                    send_to_kp "$ZRDN_NAME" "SHOT $target_id $target_type AMMO:$AMMO"
                    echo "[$ZRDN_NAME] $shot_msg"

                    db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_x, target_y, target_type, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$ZRDN_NAME', 'SHOT', '$target_id', $tx, $ty, '$target_type', '$shot_msg');"

                    if (( AMMO <= 0 )); then
                        AMMO_EMPTY_TIME=$(date +%s)
                        empty_msg="Боекомплект исчерпан! Переход в режим обнаружения"
                        log_message "$LOGFILE" "$ZRDN_NAME" "$empty_msg"
                        send_to_kp "$ZRDN_NAME" "AMMO_EMPTY $ZRDN_NAME"
                        echo "[$ZRDN_NAME] $empty_msg"
                    fi
                fi
            fi
        fi
    done

    # Проверка результатов стрельбы
    for target_id in "${!shot_targets[@]}"; do
        if [[ -z "${current_targets[$target_id]}" ]]; then
            # Цель поражена
            destroy_msg="Цель id:$target_id УНИЧТОЖЕНА"
            log_message "$LOGFILE" "$ZRDN_NAME" "$destroy_msg"
            send_to_kp "$ZRDN_NAME" "DESTROYED $target_id"
            echo "[$ZRDN_NAME] $destroy_msg"

            db_insert "INSERT INTO shots (timestamp, system_name, target_id, target_type, result) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$ZRDN_NAME', '$target_id', '', 'DESTROYED');"
            db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$ZRDN_NAME', 'DESTROYED', '$target_id', '$destroy_msg');"

            unset "shot_targets[$target_id]"
            unset "first_detection[$target_id]"
            unset "reported_targets[$target_id]"
        else
            # Проверка промаха
            if [[ -n "${reported_targets[$target_id]}" ]] && [[ -n "${shot_targets[$target_id]}" ]]; then
                if [[ ! -f "$DESTROY_DIR/$target_id" ]]; then
                    miss_msg="ПРОМАХ по цели id:$target_id"
                    log_message "$LOGFILE" "$ZRDN_NAME" "$miss_msg"
                    send_to_kp "$ZRDN_NAME" "MISS $target_id"
                    echo "[$ZRDN_NAME] $miss_msg"

                    db_insert "INSERT INTO shots (timestamp, system_name, target_id, target_type, result) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$ZRDN_NAME', '$target_id', '', 'MISS');"
                    db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, message) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', '$ZRDN_NAME', 'MISS', '$target_id', '$miss_msg');"

                    unset "shot_targets[$target_id]"
                fi
            fi
        fi
    done

    # Очистка пропавших целей
    for target_id in "${!first_detection[@]}"; do
        if [[ -z "${current_targets[$target_id]}" ]] && [[ -z "${shot_targets[$target_id]}" ]]; then
            unset "first_detection[$target_id]"
            unset "reported_targets[$target_id]"
        fi
    done

    unset current_targets

    sleep "$CHECK_INTERVAL"
done
