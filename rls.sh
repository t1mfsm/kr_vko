#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_environment

RLS_NUM="${1:?Использование: $0 <номер_рлс> (1, 2 или 3)}"

if [[ "$RLS_NUM" != "1" && "$RLS_NUM" != "2" && "$RLS_NUM" != "3" ]]; then
    echo "ОШИБКА: номер РЛС должен быть 1, 2 или 3" >&2
    exit 1
fi

eval "RLS_NAME=\$RLS${RLS_NUM}_NAME"
eval "RLS_TYPE=\$RLS${RLS_NUM}_TYPE"
eval "RLS_X=\$RLS${RLS_NUM}_X"
eval "RLS_Y=\$RLS${RLS_NUM}_Y"
eval "RLS_RANGE=\$RLS${RLS_NUM}_RANGE"
eval "RLS_ANGLE=\$RLS${RLS_NUM}_ANGLE"
eval "RLS_SECTOR=\$RLS${RLS_NUM}_SECTOR"

check_single_instance "$RLS_NAME"
trap "cleanup '$RLS_NAME'; exit 0" SIGTERM SIGINT EXIT

LOGFILE="$LOG_DIR/${RLS_NAME}.log"

echo "[$RLS_NAME] Запуск РЛС типа $RLS_TYPE"
echo "[$RLS_NAME] Координаты: X=$RLS_X Y=$RLS_Y"
echo "[$RLS_NAME] Дальность: $RLS_RANGE м, Сектор: $RLS_SECTOR градусов, Направление: $RLS_ANGLE градусов"

log_message "$LOGFILE" "$RLS_NAME" "Запуск РЛС типа $RLS_TYPE. Координаты: X=$RLS_X Y=$RLS_Y"
send_to_kp "$RLS_NAME" "STATUS $RLS_NAME ONLINE"

declare -A reported_targets
declare -A reported_spro

while true; do
    if [[ -f "$MSG_DIR/heartbeat/${RLS_NAME}_request" ]]; then
        rm -f "$MSG_DIR/heartbeat/${RLS_NAME}_request"
        send_heartbeat_response "$RLS_NAME"
    fi

    for msg_file in "$MSG_DIR/from_kp/${RLS_NAME}_"*; do
        [[ -f "$msg_file" ]] || continue
        encrypted=$(cat "$msg_file" 2>/dev/null)
        decoded=$(decrypt_message "$encrypted")
        if [[ "$decoded" == "ERROR_HMAC" ]]; then
            log_message "$LOGFILE" "$RLS_NAME" "ПОПЫТКА НСД! Поддельное сообщение от КП"
            send_to_kp "$RLS_NAME" "NSD $RLS_NAME Обнаружена попытка подмены сообщения"
        fi
        rm -f "$msg_file"
    done

    declare -A current_targets
    declare -A current_target_mtimes

    while read -r target_id tx ty target_mtime; do
        [[ -z "$target_id" ]] && continue
        if is_in_sector "$RLS_X" "$RLS_Y" "$RLS_RANGE" "$RLS_ANGLE" "$RLS_SECTOR" "$tx" "$ty"; then
            current_targets[$target_id]="$tx $ty"
            current_target_mtimes[$target_id]="$target_mtime"
        fi
    done < <(scan_targets)

    for target_id in "${!current_targets[@]}"; do
        tx=$(echo "${current_targets[$target_id]}" | awk '{print $1}')
        ty=$(echo "${current_targets[$target_id]}" | awk '{print $2}')

        if [[ -z "${reported_targets[$target_id]}" ]]; then
            track=$(get_latest_two_visible_marks "sector" "$target_id" "$RLS_X" "$RLS_Y" "$RLS_RANGE" "$RLS_ANGLE" "$RLS_SECTOR") || continue
            read -r prev_x prev_y prev_mtime latest_x latest_y latest_mtime <<< "$track"
            (( latest_mtime <= prev_mtime )) && continue

            speed=$(calc_speed "$prev_x" "$prev_y" "$latest_x" "$latest_y")
            target_type=$(get_target_type "$speed")
            tx=$latest_x
            ty=$latest_y

            timestamp=$(date +"%H:%M:%S:%3N")

            report_msg="В $timestamp Обнаружена цель id:$target_id с координатами $tx $ty тип:$target_type скорость:$speed"
            log_message "$LOGFILE" "$RLS_NAME" "$report_msg"
            send_to_kp "$RLS_NAME" "DETECT $target_id $tx $ty $target_type $speed"
            echo "[$RLS_NAME] $report_msg"

            if [[ "$target_type" == "BB_BR" ]]; then
                if is_moving_toward_spro "$prev_x" "$prev_y" "$tx" "$ty"; then
                    if [[ -z "${reported_spro[$target_id]}" ]]; then
                        spro_msg="Цель id:$target_id движется в направлении СПРО"
                        log_message "$LOGFILE" "$RLS_NAME" "$spro_msg"
                        send_to_kp "$RLS_NAME" "SPRO_ALERT $target_id $tx $ty $speed"
                        echo "[$RLS_NAME] $spro_msg"
                        reported_spro[$target_id]=1
                    fi
                fi
            fi

            reported_targets[$target_id]=1
        fi
    done

    for target_id in "${!reported_targets[@]}"; do
        if [[ -z "${current_targets[$target_id]}" ]]; then
            unset "reported_targets[$target_id]"
            unset "reported_spro[$target_id]"
        fi
    done

    unset current_targets

    sleep "$CHECK_INTERVAL"
done
