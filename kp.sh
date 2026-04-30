#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_environment
check_single_instance "KP_VKO"
trap "cleanup 'KP_VKO'; exit 0" SIGTERM SIGINT EXIT

LOGFILE="$LOG_DIR/KP_VKO.log"
SYSTEM_LOG="$LOG_DIR/system_journal.log"
DB_FILE="$DB_DIR/vko.db"

init_database

echo "[КП ВКО] Запуск командного пункта ВКО"
log_message "$LOGFILE" "KP_VKO" "Запуск КП ВКО"
log_message "$SYSTEM_LOG" "KP_VKO" "=== Система ВКО запущена ==="

ALL_SYSTEMS=("$RLS1_NAME" "$RLS2_NAME" "$RLS3_NAME" "$ZRDN1_NAME" "$ZRDN2_NAME" "$ZRDN3_NAME" "$SPRO_NAME")

declare -A system_status
declare -A last_heartbeat
declare -A missed_heartbeats
declare -A reported_status

for sys in "${ALL_SYSTEMS[@]}"; do
    system_status[$sys]="UNKNOWN"
    last_heartbeat[$sys]=0
    missed_heartbeats[$sys]=0
done

process_kp_messages() {
    local msg_file encrypted decoded sender msg_type timestamp
    local sys sys_name status ammo_info ammo_left target_id tx ty target_type speed details log_msg

    for msg_file in "$MSG_DIR/to_kp/"*; do
        [[ -f "$msg_file" ]] || continue

        encrypted=$(cat "$msg_file" 2>/dev/null)
        decoded=$(decrypt_message "$encrypted")

        if [[ "$decoded" == "ERROR_HMAC" || "$decoded" == "ERROR_DECRYPT" ]]; then
            log_message "$LOGFILE" "KP_VKO" "ПОПЫТКА НСД! Подменённое сообщение в файле $(basename "$msg_file")"
            log_message "$SYSTEM_LOG" "KP_VKO" "ПОПЫТКА НСД! Подменённое сообщение"
            db_insert "INSERT INTO nsd_log (timestamp, system_name, details) VALUES ('$(date +"%d.%m %H:%M:%S:%3N")', 'KP_VKO', 'Подменённое сообщение: $(basename "$msg_file")');"
            rm -f "$msg_file"
            continue
        fi

        sender=$(basename "$msg_file" | cut -d'_' -f1-2)
        if [[ "$sender" != *"_"* ]]; then
            sender=$(basename "$msg_file" | cut -d'_' -f1)
        fi

        msg_type=$(echo "$decoded" | awk '{print $1}')
        timestamp=$(date +"%d.%m %H:%M:%S:%3N")

        case "$msg_type" in
            STATUS)
                sys_name=$(echo "$decoded" | awk '{print $2}')
                status=$(echo "$decoded" | awk '{print $3}')
                ammo_info=$(echo "$decoded" | grep -o 'AMMO:[0-9]*' || true)

                if [[ "${system_status[$sys_name]}" != "$status" ]]; then
                    system_status[$sys_name]="$status"
                    log_msg="$sys_name статус: $status $ammo_info"
                    log_message "$LOGFILE" "KP_VKO" "$log_msg"
                    log_message "$SYSTEM_LOG" "$sys_name" "статус: $status $ammo_info"
                    echo "[КП] $log_msg"

                    db_insert "INSERT INTO system_status (timestamp, system_name, status, ammo_left) VALUES ('$timestamp', '$sys_name', '$status', $(echo "$ammo_info" | grep -o '[0-9]*' || echo 'NULL'));"
                    db_insert "INSERT INTO journal (timestamp, system_name, event_type, message) VALUES ('$timestamp', '$sys_name', 'STATUS', '$log_msg');"
                fi
                ;;

            DETECT)
                target_id=$(echo "$decoded" | awk '{print $2}')
                tx=$(echo "$decoded" | awk '{print $3}')
                ty=$(echo "$decoded" | awk '{print $4}')
                target_type=$(echo "$decoded" | awk '{print $5}')
                speed=$(echo "$decoded" | awk '{print $6}')

                for sys in "${ALL_SYSTEMS[@]}"; do
                    if [[ "$(basename "$msg_file")" == "${sys}_"* ]]; then
                        sender="$sys"
                        break
                    fi
                done

                log_msg="Обнаружена цель id:$target_id координаты X:$tx Y:$ty тип:$target_type скорость:$speed"
                log_message "$LOGFILE" "KP_VKO" "от $sender: $log_msg"
                log_message "$SYSTEM_LOG" "$sender" "$log_msg"
                echo "[КП от $sender] $log_msg"

                db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_x, target_y, target_type, message) VALUES ('$timestamp', '$sender', 'DETECT', '$target_id', ${tx:-0}, ${ty:-0}, '$target_type', '$log_msg');"
                ;;

            SPRO_ALERT)
                target_id=$(echo "$decoded" | awk '{print $2}')
                tx=$(echo "$decoded" | awk '{print $3}')
                ty=$(echo "$decoded" | awk '{print $4}')

                for sys in "${ALL_SYSTEMS[@]}"; do
                    if [[ "$(basename "$msg_file")" == "${sys}_"* ]]; then
                        sender="$sys"
                        break
                    fi
                done

                log_msg="цель движется в направлении СПРО id:$target_id"
                log_message "$LOGFILE" "KP_VKO" "от $sender: $log_msg"
                log_message "$SYSTEM_LOG" "$sender" "$log_msg"
                echo "[КП от $sender] !!! $log_msg !!!"

                db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_x, target_y, target_type, message) VALUES ('$timestamp', '$sender', 'SPRO_ALERT', '$target_id', ${tx:-0}, ${ty:-0}, 'BB_BR', '$log_msg');"
                ;;

            SHOT)
                target_id=$(echo "$decoded" | awk '{print $2}')
                target_type=$(echo "$decoded" | awk '{print $3}')
                ammo_info=$(echo "$decoded" | grep -o 'AMMO:[0-9]*' || true)
                ammo_left=$(echo "$ammo_info" | grep -o '[0-9]*' || true)

                for sys in "${ALL_SYSTEMS[@]}"; do
                    if [[ "$(basename "$msg_file")" == "${sys}_"* ]]; then
                        sender="$sys"
                        break
                    fi
                done

                log_msg="Стрельба по цели id:$target_id тип:$target_type $ammo_info"
                log_message "$LOGFILE" "KP_VKO" "от $sender: $log_msg"
                log_message "$SYSTEM_LOG" "$sender" "$log_msg"
                echo "[КП от $sender] $log_msg"

                db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_type, message) VALUES ('$timestamp', '$sender', 'SHOT', '$target_id', '$target_type', '$log_msg');"
                if [[ -n "$ammo_left" ]]; then
                    db_insert "INSERT INTO system_status (timestamp, system_name, status, ammo_left) VALUES ('$timestamp', '$sender', 'ONLINE', $ammo_left);"
                fi
                ;;

            DESTROYED)
                target_id=$(echo "$decoded" | awk '{print $2}')
                target_type=$(echo "$decoded" | awk '{print $3}')

                for sys in "${ALL_SYSTEMS[@]}"; do
                    if [[ "$(basename "$msg_file")" == "${sys}_"* ]]; then
                        sender="$sys"
                        break
                    fi
                done

                log_msg="Цель id:$target_id УНИЧТОЖЕНА ($target_type)"
                log_message "$LOGFILE" "KP_VKO" "от $sender: $log_msg"
                log_message "$SYSTEM_LOG" "$sender" "$log_msg"
                echo "[КП от $sender] >>> $log_msg <<<"

                db_insert "INSERT INTO shots (timestamp, system_name, target_id, target_type, result) VALUES ('$timestamp', '$sender', '$target_id', '$target_type', 'DESTROYED');"
                db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_type, message) VALUES ('$timestamp', '$sender', 'DESTROYED', '$target_id', '$target_type', '$log_msg');"
                ;;

            MISS)
                target_id=$(echo "$decoded" | awk '{print $2}')
                target_type=$(echo "$decoded" | awk '{print $3}')

                for sys in "${ALL_SYSTEMS[@]}"; do
                    if [[ "$(basename "$msg_file")" == "${sys}_"* ]]; then
                        sender="$sys"
                        break
                    fi
                done

                log_msg="ПРОМАХ по цели id:$target_id ($target_type)"
                log_message "$LOGFILE" "KP_VKO" "от $sender: $log_msg"
                log_message "$SYSTEM_LOG" "$sender" "$log_msg"
                echo "[КП от $sender] $log_msg"

                db_insert "INSERT INTO shots (timestamp, system_name, target_id, target_type, result) VALUES ('$timestamp', '$sender', '$target_id', '$target_type', 'MISS');"
                db_insert "INSERT INTO journal (timestamp, system_name, event_type, target_id, target_type, message) VALUES ('$timestamp', '$sender', 'MISS', '$target_id', '$target_type', '$log_msg');"
                ;;

            AMMO_EMPTY)
                sys_name=$(echo "$decoded" | awk '{print $2}')

                log_msg="$sys_name: боекомплект исчерпан!"
                log_message "$LOGFILE" "KP_VKO" "$log_msg"
                log_message "$SYSTEM_LOG" "$sys_name" "Боекомплект исчерпан! Режим обнаружения"
                echo "[КП] !!! $log_msg !!!"

                db_insert "INSERT INTO journal (timestamp, system_name, event_type, message) VALUES ('$timestamp', '$sys_name', 'AMMO_EMPTY', '$log_msg');"
                db_insert "INSERT INTO system_status (timestamp, system_name, status, ammo_left) VALUES ('$timestamp', '$sys_name', 'AMMO_EMPTY', 0);"
                ;;

            REFILL)
                sys_name=$(echo "$decoded" | awk '{print $2}')
                ammo_info=$(echo "$decoded" | grep -o 'AMMO:[0-9]*' || true)

                log_msg="$sys_name: боекомплект пополнен $ammo_info"
                log_message "$LOGFILE" "KP_VKO" "$log_msg"
                log_message "$SYSTEM_LOG" "$sys_name" "Боекомплект пополнен $ammo_info"
                echo "[КП] $log_msg"

                db_insert "INSERT INTO journal (timestamp, system_name, event_type, message) VALUES ('$timestamp', '$sys_name', 'REFILL', '$log_msg');"
                db_insert "INSERT INTO system_status (timestamp, system_name, status, ammo_left) VALUES ('$timestamp', '$sys_name', 'ONLINE', $(echo "$ammo_info" | grep -o '[0-9]*' || echo 'NULL'));"
                ;;

            NSD)
                sys_name=$(echo "$decoded" | awk '{print $2}')
                details=$(echo "$decoded" | cut -d' ' -f3-)

                log_msg="НСД от $sys_name: $details"
                log_message "$LOGFILE" "KP_VKO" "$log_msg"
                log_message "$SYSTEM_LOG" "KP_VKO" "!!! $log_msg !!!"
                echo "[КП] !!! ПОПЫТКА НСД: $log_msg !!!"

                db_insert "INSERT INTO nsd_log (timestamp, system_name, details) VALUES ('$timestamp', '$sys_name', '$details');"
                db_insert "INSERT INTO journal (timestamp, system_name, event_type, message) VALUES ('$timestamp', '$sys_name', 'NSD', '$log_msg');"
                ;;

            *)
                log_message "$LOGFILE" "KP_VKO" "Неизвестное сообщение: $decoded"
                ;;
        esac

        rm -f "$msg_file"
    done
}

last_heartbeat_check=0

while true; do
    current_time=$(date +%s)

    process_kp_messages

    if (( current_time - last_heartbeat_check >= HEARTBEAT_INTERVAL )); then
        heartbeat_deadline=$((current_time + HEARTBEAT_RESPONSE_TIMEOUT))
        last_heartbeat_check=$current_time

        for sys in "${ALL_SYSTEMS[@]}"; do
            touch "$MSG_DIR/heartbeat/${sys}_request"
        done

        while (( $(date +%s) < heartbeat_deadline )); do
            sleep "$CHECK_INTERVAL"
            process_kp_messages
        done

        timestamp=$(date +"%d.%m %H:%M:%S:%3N")
        for sys in "${ALL_SYSTEMS[@]}"; do
            response_file="$MSG_DIR/heartbeat/${sys}_response"
            status_key="${sys}_status"

            if [[ -f "$response_file" ]]; then
                encrypted=$(cat "$response_file" 2>/dev/null)
                decoded=$(decrypt_message "$encrypted")

                if [[ "$decoded" == "ERROR_HMAC" ]]; then
                    log_message "$LOGFILE" "KP_VKO" "ПОПЫТКА НСД в heartbeat от $sys"
                    db_insert "INSERT INTO nsd_log (timestamp, system_name, details) VALUES ('$timestamp', '$sys', 'Поддельный heartbeat');"
                fi

                rm -f "$response_file"
                last_heartbeat[$sys]=$current_time
                missed_heartbeats[$sys]=0

                if [[ "${system_status[$sys]}" != "ONLINE" ]]; then
                    previous_status="${system_status[$sys]}"
                    system_status[$sys]="ONLINE"
                    if [[ "$previous_status" == "OFFLINE" && "${reported_status[$status_key]}" != "ONLINE" ]]; then
                        log_msg="$sys работоспособность восстановлена"
                        log_message "$SYSTEM_LOG" "$sys" "работоспособность восстановлена"
                        log_message "$LOGFILE" "KP_VKO" "$log_msg"
                        echo "[КП] $log_msg"
                        db_insert "INSERT INTO journal (timestamp, system_name, event_type, message) VALUES ('$timestamp', '$sys', 'HEARTBEAT', '$log_msg');"
                        db_insert "INSERT INTO system_status (timestamp, system_name, status) VALUES ('$timestamp', '$sys', 'ONLINE');"
                        reported_status[$status_key]="ONLINE"
                    elif [[ "$previous_status" == "UNKNOWN" ]]; then
                        reported_status[$status_key]="ONLINE"
                    fi
                fi
            else
                (( missed_heartbeats[$sys]++ ))
                if (( missed_heartbeats[$sys] < HEARTBEAT_MISSES_BEFORE_OFFLINE )); then
                    continue
                fi

                if [[ "${system_status[$sys]}" != "OFFLINE" ]]; then
                    system_status[$sys]="OFFLINE"
                    if [[ "${reported_status[$status_key]}" != "OFFLINE" ]]; then
                        log_msg="$sys НЕ ОТВЕЧАЕТ! Связь потеряна"
                        log_message "$SYSTEM_LOG" "$sys" "НЕ ОТВЕЧАЕТ! Связь потеряна"
                        log_message "$LOGFILE" "KP_VKO" "$log_msg"
                        echo "[КП] !!! $log_msg !!!"
                        db_insert "INSERT INTO journal (timestamp, system_name, event_type, message) VALUES ('$timestamp', '$sys', 'HEARTBEAT', '$log_msg');"
                        db_insert "INSERT INTO system_status (timestamp, system_name, status) VALUES ('$timestamp', '$sys', 'OFFLINE');"
                        reported_status[$status_key]="OFFLINE"
                    fi
                fi
            fi
        done
    fi

    sleep "$CHECK_INTERVAL"
done
