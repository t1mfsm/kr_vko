#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"

check_environment
check_single_instance "$SPRO_NAME"
trap "cleanup '$SPRO_NAME'; exit 0" SIGTERM SIGINT EXIT

LOGFILE="$LOG_DIR/${SPRO_NAME}.log"
AMMO=$SPRO_AMMO
AMMO_EMPTY_TIME=0
STATE_TTL_SEC="${TARGET_STATE_TTL_SEC:-12}"

echo "[$SPRO_NAME] Запуск СПРО"
echo "[$SPRO_NAME] Координаты: X=$SPRO_X Y=$SPRO_Y, Радиус: $SPRO_RANGE м"
echo "[$SPRO_NAME] Боезапас: $AMMO противоракет"

log_message "$LOGFILE" "$SPRO_NAME" "Запуск СПРО. Координаты: X=$SPRO_X Y=$SPRO_Y, Радиус: $SPRO_RANGE"
send_to_kp "$SPRO_NAME" "STATUS $SPRO_NAME ONLINE AMMO:$AMMO"

declare -A first_x
declare -A first_y
declare -A target_type
declare -A detected_sent
declare -A ignore_target
declare -A shot_pending
declare -A shot_no
declare -A shot_x
declare -A shot_y
declare -A shot_generator_log_start
declare -A shot_seen_after
declare -A shot_seen_x
declare -A shot_seen_y
declare -A last_seen_epoch
declare -A last_x
declare -A last_y

cleanup_stale_targets() {
    local now_epoch="$1" target_id last
    for target_id in "${!last_seen_epoch[@]}"; do
        last="${last_seen_epoch[$target_id]}"
        if (( now_epoch - last > STATE_TTL_SEC )); then
            release_target_engagement "$target_id" "$SPRO_NAME" 2>/dev/null || true
            unset "last_seen_epoch[$target_id]"
            unset "first_x[$target_id]"
            unset "first_y[$target_id]"
            unset "target_type[$target_id]"
            unset "detected_sent[$target_id]"
            unset "ignore_target[$target_id]"
            unset "shot_pending[$target_id]"
            unset "shot_no[$target_id]"
            unset "shot_x[$target_id]"
            unset "shot_y[$target_id]"
            unset "shot_generator_log_start[$target_id]"
            unset "shot_seen_after[$target_id]"
            unset "shot_seen_x[$target_id]"
            unset "shot_seen_y[$target_id]"
            unset "last_x[$target_id]"
            unset "last_y[$target_id]"
        fi
    done
}

send_detect() {
    local target_id="$1" tx="$2" ty="$3" speed="$4"
    local report_msg
    report_msg="Обнаружена цель id:$target_id координаты $tx $ty тип:BB_BR скорость:$speed"
    log_message "$LOGFILE" "$SPRO_NAME" "$report_msg"
    send_to_kp "$SPRO_NAME" "DETECT $target_id $tx $ty BB_BR $speed"
    echo "[$SPRO_NAME] $report_msg"
}

fire_target() {
    local target_id="$1" tx="$2" ty="$3"
    local shot_msg empty_msg generator_log_start

    (( AMMO > 0 )) || return 1

    mkdir -p "$DESTROY_DIR"
    generator_log_start=$(get_generator_log_position)
    printf '%s\n' "$SPRO_NAME" > "$DESTROY_DIR/$target_id"

    shot_no[$target_id]=$(( ${shot_no[$target_id]:-0} + 1 ))
    ((AMMO--))
    shot_msg="Стрельба по цели id:$target_id тип:BB_BR пуск №${shot_no[$target_id]}. Осталось противоракет: $AMMO"
    log_message "$LOGFILE" "$SPRO_NAME" "$shot_msg"
    send_to_kp "$SPRO_NAME" "SHOT $target_id BB_BR AMMO:$AMMO"
    echo "[$SPRO_NAME] $shot_msg"

    shot_pending[$target_id]=1
    shot_x[$target_id]="$tx"
    shot_y[$target_id]="$ty"
    shot_generator_log_start[$target_id]="$generator_log_start"
    shot_seen_after[$target_id]=0
    shot_seen_x[$target_id]="$tx"
    shot_seen_y[$target_id]="$ty"

    if (( AMMO <= 0 )); then
        AMMO_EMPTY_TIME=$(date +%s)
        empty_msg="Боекомплект исчерпан! Переход в режим обнаружения"
        log_message "$LOGFILE" "$SPRO_NAME" "$empty_msg"
        send_to_kp "$SPRO_NAME" "AMMO_EMPTY $SPRO_NAME"
        echo "[$SPRO_NAME] $empty_msg"
    fi
}

refire_after_miss() {
    local target_id="$1"
    local latest tx ty _mtime

    (( AMMO > 0 )) || return 1

    latest=$(get_latest_target_mark "$target_id" 2>/dev/null || true)
    [[ -n "$latest" ]] || return 1
    read -r tx ty _mtime <<< "$latest"

    last_x[$target_id]="$tx"
    last_y[$target_id]="$ty"
    last_seen_epoch[$target_id]="$(date +%s)"
    fire_target "$target_id" "$tx" "$ty"
}

while true; do
    now_epoch=$(date +%s)

    if [[ -f "$MSG_DIR/heartbeat/${SPRO_NAME}_request" ]]; then
        rm -f "$MSG_DIR/heartbeat/${SPRO_NAME}_request"
        send_heartbeat_response "$SPRO_NAME"
    fi

    for msg_file in "$MSG_DIR/from_kp/${SPRO_NAME}_"*; do
        [[ -f "$msg_file" ]] || continue
        encrypted=$(cat "$msg_file" 2>/dev/null)
        decoded=$(decrypt_message "$encrypted")
        if [[ "$decoded" == "ERROR_HMAC" ]]; then
            log_message "$LOGFILE" "$SPRO_NAME" "ПОПЫТКА НСД! Поддельное сообщение"
            send_to_kp "$SPRO_NAME" "NSD $SPRO_NAME Обнаружена попытка подмены сообщения"
        elif [[ "$decoded" == REFILL* ]]; then
            AMMO=$SPRO_AMMO
            AMMO_EMPTY_TIME=0
            log_message "$LOGFILE" "$SPRO_NAME" "Боекомплект пополнен: $AMMO противоракет"
            send_to_kp "$SPRO_NAME" "REFILL $SPRO_NAME AMMO:$AMMO"
            echo "[$SPRO_NAME] Боекомплект пополнен: $AMMO"
        fi
        rm -f "$msg_file"
    done

    if (( AMMO <= 0 && AMMO_EMPTY_TIME > 0 )); then
        if (( now_epoch - AMMO_EMPTY_TIME >= AMMO_REFILL_TIME )); then
            AMMO=$SPRO_AMMO
            AMMO_EMPTY_TIME=0
            log_message "$LOGFILE" "$SPRO_NAME" "Боекомплект автоматически пополнен: $AMMO противоракет"
            send_to_kp "$SPRO_NAME" "REFILL $SPRO_NAME AMMO:$AMMO"
            echo "[$SPRO_NAME] Автопополнение боекомплекта: $AMMO"
        fi
    fi

    declare -A present_now=()

    while read -r target_id tx ty _target_mtime; do
        [[ -n "$target_id" ]] || continue
        is_target_destroyed "$target_id" && continue
        present_now[$target_id]=1
        present_now[$target_id]=1
        last_seen_epoch[$target_id]="$now_epoch"
        last_x[$target_id]="$tx"
        last_y[$target_id]="$ty"

        if [[ "${shot_pending[$target_id]:-0}" -eq 1 ]]; then
            generator_result=$(get_generator_result_since "${shot_generator_log_start[$target_id]:-0}" "$target_id" "$SPRO_NAME" 2>/dev/null || true)
            if [[ "$generator_result" == "DESTROYED" ]]; then
                mark_target_destroyed "$target_id" "$SPRO_NAME"
                release_target_engagement "$target_id" "$SPRO_NAME" 2>/dev/null || true
                log_message "$LOGFILE" "$SPRO_NAME" "Цель id:$target_id УНИЧТОЖЕНА после пуска №${shot_no[$target_id]:-1}"
                send_to_kp "$SPRO_NAME" "DESTROYED $target_id BB_BR"
                echo "[$SPRO_NAME] Цель id:$target_id УНИЧТОЖЕНА после пуска №${shot_no[$target_id]:-1}"
                shot_pending[$target_id]=0
                shot_seen_after[$target_id]=0
                ignore_target[$target_id]=1
                continue
            elif [[ "$generator_result" == "MISS" ]]; then
                log_message "$LOGFILE" "$SPRO_NAME" "ПРОМАХ по цели id:$target_id после пуска №${shot_no[$target_id]:-1}"
                send_to_kp "$SPRO_NAME" "MISS $target_id BB_BR"
                echo "[$SPRO_NAME] ПРОМАХ по цели id:$target_id после пуска №${shot_no[$target_id]:-1}"
                shot_pending[$target_id]=0
                shot_seen_after[$target_id]=0
                refire_after_miss "$target_id"
                continue
            else
                if [[ "$tx" != "${shot_x[$target_id]:-}" || "$ty" != "${shot_y[$target_id]:-}" ]]; then
                    if [[ "${shot_seen_after[$target_id]:-0}" -eq 0 ]]; then
                        shot_seen_after[$target_id]=1
                        shot_seen_x[$target_id]="$tx"
                        shot_seen_y[$target_id]="$ty"
                    elif [[ "$tx" != "${shot_seen_x[$target_id]:-}" || "$ty" != "${shot_seen_y[$target_id]:-}" ]]; then
                        log_message "$LOGFILE" "$SPRO_NAME" "ПРОМАХ по цели id:$target_id после пуска №${shot_no[$target_id]:-1}"
                        send_to_kp "$SPRO_NAME" "MISS $target_id BB_BR"
                        echo "[$SPRO_NAME] ПРОМАХ по цели id:$target_id после пуска №${shot_no[$target_id]:-1}"
                        shot_pending[$target_id]=0
                        shot_seen_after[$target_id]=0
                        refire_after_miss "$target_id"
                    fi
                fi
                continue
            fi
        fi

        if [[ ! "$target_id" =~ b$ ]]; then
            ignore_target[$target_id]=1
            continue
        fi

        [[ "${ignore_target[$target_id]:-0}" -eq 1 ]] && continue

        if ! is_in_range "$SPRO_X" "$SPRO_Y" "$SPRO_RANGE" "$tx" "$ty"; then
            continue
        fi

        if [[ -z "${first_x[$target_id]:-}" ]]; then
            first_x[$target_id]="$tx"
            first_y[$target_id]="$ty"
            continue
        fi

        if [[ -z "${target_type[$target_id]:-}" ]]; then
            speed=$(calc_speed "${first_x[$target_id]}" "${first_y[$target_id]}" "$tx" "$ty")
            (( speed > 0 )) || continue
            target_type[$target_id]="$(get_target_type "$speed")"
            if [[ "${target_type[$target_id]}" != "BB_BR" ]]; then
                ignore_target[$target_id]=1
                continue
            fi
        fi

        if [[ "${detected_sent[$target_id]:-0}" -eq 0 ]]; then
            claim_target_engagement "$target_id" "$SPRO_NAME" || continue
            send_detect "$target_id" "$tx" "$ty" "$speed"
            detected_sent[$target_id]=1
        elif ! refresh_target_engagement "$target_id" "$SPRO_NAME"; then
            claim_target_engagement "$target_id" "$SPRO_NAME" || continue
        fi

        (( AMMO > 0 )) || continue
        fire_target "$target_id" "$tx" "$ty"
    done < <(scan_targets)

    for target_id in "${!shot_pending[@]}"; do
        [[ "${shot_pending[$target_id]}" -eq 1 ]] || continue
        if [[ -z "${present_now[$target_id]:-}" ]]; then
            generator_result=$(get_generator_result_since "${shot_generator_log_start[$target_id]:-0}" "$target_id" "$SPRO_NAME" 2>/dev/null || true)
            if [[ "$generator_result" == "MISS" ]]; then
                log_message "$LOGFILE" "$SPRO_NAME" "ПРОМАХ по цели id:$target_id после пуска №${shot_no[$target_id]:-1}"
                send_to_kp "$SPRO_NAME" "MISS $target_id BB_BR"
                echo "[$SPRO_NAME] ПРОМАХ по цели id:$target_id после пуска №${shot_no[$target_id]:-1}"
                shot_pending[$target_id]=0
                shot_seen_after[$target_id]=0
                refire_after_miss "$target_id"
                continue
            fi
            mark_target_destroyed "$target_id" "$SPRO_NAME"
            release_target_engagement "$target_id" "$SPRO_NAME" 2>/dev/null || true
            log_message "$LOGFILE" "$SPRO_NAME" "Цель id:$target_id УНИЧТОЖЕНА после пуска №${shot_no[$target_id]:-1}"
            send_to_kp "$SPRO_NAME" "DESTROYED $target_id BB_BR"
            echo "[$SPRO_NAME] Цель id:$target_id УНИЧТОЖЕНА после пуска №${shot_no[$target_id]:-1}"
            shot_pending[$target_id]=0
            shot_seen_after[$target_id]=0
            ignore_target[$target_id]=1
        fi
    done

    cleanup_stale_targets "$now_epoch"
    sleep "$CHECK_INTERVAL"
done
