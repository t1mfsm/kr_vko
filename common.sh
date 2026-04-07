#!/bin/bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

check_environment() {
    if [[ $EUID -eq 0 ]]; then
        echo "ОШИБКА: Запуск от имени root запрещен!" >&2
        exit 1
    fi

    if [[ "$(uname -s)" != "Linux" ]]; then
        echo "ОШИБКА: Запуск разрешен только в Linux. Текущая ОС: $(uname -s)" >&2
        exit 1
    fi

    if [[ -z "$BASH_VERSION" ]]; then
        echo "ОШИБКА: Требуется интерпретатор Bash!" >&2
        exit 1
    fi
    if (( BASH_VERSINFO[0] < 4 )); then
        echo "ОШИБКА: Требуется Bash версии 4 или выше!" >&2
        exit 1
    fi
}

check_single_instance() {
    local name="$1"
    mkdir -p "$PID_DIR"
    local pidfile="$PID_DIR/${name}.pid"
    if [[ -f "$pidfile" ]]; then
        local old_pid
        old_pid=$(cat "$pidfile" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
            echo "ОШИБКА: $name уже запущен (PID: $old_pid)" >&2
            exit 1
        fi
        rm -f "$pidfile"
    fi
    echo $$ > "$pidfile"
}

cleanup() {
    local name="$1"
    rm -f "$PID_DIR/${name}.pid"
}


decode_target_id() {
    local filename="$1"
    filename=$(basename "$filename")
    local hex_id=""
    local i
    for ((i = 2; i < 28; i += 4)); do
        hex_id+="${filename:$i:2}"
    done
    echo -n "$hex_id" | xxd -r -p 2>/dev/null
}

calc_distance() {
    local x1=$1 y1=$2 x2=$3 y2=$4
    local dx=$((x2 - x1))
    local dy=$((y2 - y1))
    echo "scale=0; sqrt($dx * $dx + $dy * $dy)" | bc -l
}

calc_speed() {
    local x1=$1 y1=$2 x2=$3 y2=$4
    calc_distance "$x1" "$y1" "$x2" "$y2"
}

calc_speed_mps() {
    local x1=$1 y1=$2 x2=$3 y2=$4 dt_millis=$5
    local distance
    distance=$(calc_distance "$x1" "$y1" "$x2" "$y2")

    if [[ -z "$dt_millis" ]] || (( dt_millis <= 0 )); then
        dt_millis=1000
    fi

    echo $(((distance * 1000) / dt_millis))
}

get_target_type() {
    local speed=$1
    if (( speed >= SPEED_BB_MIN )); then
        echo "BB_BR"
    elif (( speed >= SPEED_KR_MIN )); then
        echo "KR"
    elif (( speed >= SPEED_SAM_MIN )); then
        echo "SAM"
    else
        echo "UNKNOWN"
    fi
}

is_in_range() {
    local cx=$1 cy=$2 range=$3 tx=$4 ty=$5
    local dist
    dist=$(calc_distance "$cx" "$cy" "$tx" "$ty")
    (( dist <= range ))
}

is_in_sector() {
    local cx=$1 cy=$2 range=$3 center_angle=$4 sector_width=$5 tx=$6 ty=$7

    local dist
    dist=$(calc_distance "$cx" "$cy" "$tx" "$ty")
    if (( dist > range )); then
        return 1
    fi

    local dx=$((tx - cx))
    local dy=$((ty - cy))

    local angle
    angle=$(echo "scale=4; a = 180 / 3.14159265358979 * a($dy, $dx); if (a < 0) a += 360; a" | bc -l 2>/dev/null)
    angle=$(awk "BEGIN {
        pi = 3.14159265358979
        a = atan2($dy, $dx) * 180 / pi
        if (a < 0) a += 360
        printf \"%.0f\", a
    }")

    local half=$((sector_width / 2))
    local min_angle=$(( (center_angle - half + 360) % 360 ))
    local max_angle=$(( (center_angle + half) % 360 ))

    if (( min_angle <= max_angle )); then
        (( angle >= min_angle && angle <= max_angle ))
    else
        (( angle >= min_angle || angle <= max_angle ))
    fi
}

is_moving_toward_spro() {
    local x1=$1 y1=$2 x2=$3 y2=$4
    local spro_x=$SPRO_X spro_y=$SPRO_Y

    local vx=$((x2 - x1))
    local vy=$((y2 - y1))

    local dx=$((spro_x - x2))
    local dy=$((spro_y - y2))

    local dot=$((vx * dx + vy * dy))
    (( dot > 0 ))
}

log_message() {
    local logfile="$1"
    local system_name="$2"
    shift 2
    local message="$*"
    local timestamp
    timestamp=$(date +"%d.%m %H:%M:%S:%3N")

    echo "$timestamp $system_name $message" >> "$logfile"

    local line_count
    line_count=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    if (( line_count > MAX_LOG_LINES )); then
        tail -n $((MAX_LOG_LINES / 2)) "$logfile" > "${logfile}.tmp"
        mv "${logfile}.tmp" "$logfile"
    fi
}

encrypt_message() {
    local message="$1"
    local encoded
    encoded=$(echo -n "$message" | base64)
    local hmac
    hmac=$(echo -n "$message" | openssl dgst -sha256 -hmac "$HMAC_KEY" 2>/dev/null | awk '{print $NF}')
    echo "${encoded}|${hmac}"
}

decrypt_message() {
    local encrypted="$1"
    local encoded="${encrypted%%|*}"
    local received_hmac="${encrypted##*|}"

    local decoded
    decoded=$(echo -n "$encoded" | base64 -d 2>/dev/null)
    if [[ -z "$decoded" ]]; then
        echo "ERROR_DECRYPT"
        return 1
    fi

    local expected_hmac
    expected_hmac=$(echo -n "$decoded" | openssl dgst -sha256 -hmac "$HMAC_KEY" 2>/dev/null | awk '{print $NF}')

    if [[ "$received_hmac" != "$expected_hmac" ]]; then
        echo "ERROR_HMAC"
        return 1
    fi

    echo "$decoded"
    return 0
}

send_to_kp() {
    local system_name="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%s%3N")
    local encrypted
    encrypted=$(encrypt_message "$message")
    local msg_file="$MSG_DIR/to_kp/${system_name}_${timestamp}_$$"
    echo "$encrypted" > "$msg_file"
}

send_from_kp() {
    local target_system="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +"%s%3N")
    local encrypted
    encrypted=$(encrypt_message "$message")
    local msg_file="$MSG_DIR/from_kp/${target_system}_${timestamp}_$$"
    echo "$encrypted" > "$msg_file"
}

send_heartbeat_response() {
    local system_name="$1"
    local encrypted
    encrypted=$(encrypt_message "ALIVE $system_name $(date +%s)")
    echo "$encrypted" > "$MSG_DIR/heartbeat/${system_name}_response"
}

read_target_coords() {
    local filepath="$1"
    local content
    content=$(head -n 1 "$filepath" 2>/dev/null)
    if [[ -z "$content" ]]; then
        return 1
    fi
    local x y
    x=$(echo "$content" | awk -F'[:\t ]+' '{for(i=1;i<=NF;i++){if($i=="X")print $(i+1)}}')
    y=$(echo "$content" | awk -F'[:\t ]+' '{for(i=1;i<=NF;i++){if($i=="Y")print $(i+1)}}')
    if [[ -z "$x" || -z "$y" ]]; then
        return 1
    fi
    echo "$x $y"
}

get_latest_target_file() {
    local target_id="$1"
    local latest=""
    local latest_time=0
    local f decoded_id

    for f in "$TARGETS_DIR"/*; do
        [[ -f "$f" ]] || continue
        decoded_id=$(decode_target_id "$f")
        if [[ "$decoded_id" == "$target_id" ]]; then
            local ftime
            ftime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
            if (( ftime > latest_time )); then
                latest_time=$ftime
                latest="$f"
            fi
        fi
    done
    echo "$latest"
}

get_latest_target_mtime() {
    local target_id="$1"
    local latest_file
    latest_file=$(get_latest_target_file "$target_id")
    [[ -z "$latest_file" ]] && return 1
    get_file_mtime "$latest_file"
}

get_latest_fresh_target_mtime() {
    local target_id="$1"
    local latest_mtime current_time

    latest_mtime=$(get_latest_target_mtime "$target_id" 2>/dev/null) || return 1
    current_time=$(date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )))

    (( current_time - latest_mtime > TARGET_STALE_SECONDS * 1000 )) && return 1
    echo "$latest_mtime"
}

track_shot_result_async() {
    local system_name="$1" logfile="$2" target_id="$3" shot_type="$4" observed_mtime="$5"
    local result_dir="$TEMP_DIR/shot_results"
    mkdir -p "$result_dir"

    (
        sleep "$SHOT_RESULT_DELAY"

        local first_post_shot_mtime second_post_shot_mtime miss_msg destroy_msg
        first_post_shot_mtime=$(get_latest_target_mtime "$target_id" 2>/dev/null || echo 0)

        if (( first_post_shot_mtime > observed_mtime )); then
            sleep "$SHOT_RESULT_CONFIRM_DELAY"
            second_post_shot_mtime=$(get_latest_target_mtime "$target_id" 2>/dev/null || echo 0)
        else
            second_post_shot_mtime=$first_post_shot_mtime
        fi

        if (( second_post_shot_mtime > first_post_shot_mtime )); then
            miss_msg="ПРОМАХ по цели id:$target_id"
            log_message "$logfile" "$system_name" "$miss_msg"
            send_to_kp "$system_name" "MISS $target_id $shot_type"
            echo "[$system_name] $miss_msg"
            printf "MISS\n" > "$result_dir/${system_name}_${target_id}"
        else
            destroy_msg="Цель id:$target_id УНИЧТОЖЕНА"
            log_message "$logfile" "$system_name" "$destroy_msg"
            send_to_kp "$system_name" "DESTROYED $target_id $shot_type"
            echo "[$system_name] $destroy_msg"
            printf "DESTROYED\n" > "$result_dir/${system_name}_${target_id}"
        fi
    ) &
}

get_file_mtime() {
    local filepath="$1"
    local mtime_ms
    mtime_ms=$(find "$filepath" -maxdepth 0 -printf '%T@\n' 2>/dev/null | awk '{printf "%.0f\n", $1 * 1000}')
    if [[ -n "$mtime_ms" ]]; then
        echo "$mtime_ms"
    else
        echo $(( ($(stat -f %m "$filepath" 2>/dev/null || echo 0)) * 1000 ))
    fi
}

scan_targets() {
    declare -A latest_files
    declare -A latest_times
    local current_time
    current_time=$(date +%s%3N 2>/dev/null || echo $(( $(date +%s) * 1000 )))

    local f decoded_id ftime

    for f in "$TARGETS_DIR"/*; do
        [[ -f "$f" ]] || continue
        decoded_id=$(decode_target_id "$f")
        [[ -z "$decoded_id" ]] && continue

        ftime=$(get_file_mtime "$f")
        if [[ -z "${latest_times[$decoded_id]}" ]] || (( ftime > ${latest_times[$decoded_id]} )); then
            latest_times[$decoded_id]=$ftime
            latest_files[$decoded_id]="$f"
        fi
    done

    for decoded_id in "${!latest_files[@]}"; do
        (( current_time - ${latest_times[$decoded_id]} > TARGET_STALE_SECONDS * 1000 )) && continue

        local coords
        coords=$(read_target_coords "${latest_files[$decoded_id]}")
        if [[ -n "$coords" ]]; then
            echo "$decoded_id $coords ${latest_times[$decoded_id]}"
        fi
    done
}

get_latest_two_visible_marks() {
    local mode="$1" target_id="$2" cx="$3" cy="$4" range="$5" angle="${6:-0}" sector="${7:-360}"
    local latest_file="" latest_time=0 prev_file="" prev_time=0
    local f decoded_id ftime coords tx ty

    for f in "$TARGETS_DIR"/*; do
        [[ -f "$f" ]] || continue
        decoded_id=$(decode_target_id "$f")
        [[ "$decoded_id" != "$target_id" ]] && continue

        coords=$(read_target_coords "$f")
        [[ -z "$coords" ]] && continue
        read -r tx ty <<< "$coords"

        ftime=$(get_file_mtime "$f")

        if (( ftime > latest_time )); then
            prev_time=$latest_time
            prev_file="$latest_file"
            latest_time=$ftime
            latest_file="$f"
        elif (( ftime > prev_time )); then
            prev_time=$ftime
            prev_file="$f"
        fi
    done

    [[ -z "$prev_file" || -z "$latest_file" ]] && return 1

    local prev_coords latest_coords
    prev_coords=$(read_target_coords "$prev_file")
    latest_coords=$(read_target_coords "$latest_file")
    [[ -z "$prev_coords" || -z "$latest_coords" ]] && return 1

    read -r tx ty <<< "$latest_coords"
    if [[ "$mode" == "sector" ]]; then
        is_in_sector "$cx" "$cy" "$range" "$angle" "$sector" "$tx" "$ty" || return 1
    else
        is_in_range "$cx" "$cy" "$range" "$tx" "$ty" || return 1
    fi

    echo "$prev_coords $prev_time $latest_coords $latest_time"
}

db_insert() {
    local db_file="$DB_DIR/vko.db"
    local sql="$1"
    sqlite3 "$db_file" "$sql" 2>/dev/null
}

init_database() {
    local db_file="$DB_DIR/vko.db"
    sqlite3 "$db_file" <<'EOSQL'
CREATE TABLE IF NOT EXISTS journal (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    system_name TEXT NOT NULL,
    event_type TEXT NOT NULL,
    target_id TEXT,
    target_x INTEGER,
    target_y INTEGER,
    target_type TEXT,
    message TEXT
);

CREATE TABLE IF NOT EXISTS system_status (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    system_name TEXT NOT NULL,
    status TEXT NOT NULL,
    ammo_left INTEGER
);

CREATE TABLE IF NOT EXISTS shots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    system_name TEXT NOT NULL,
    target_id TEXT NOT NULL,
    target_type TEXT,
    result TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS nsd_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL,
    system_name TEXT NOT NULL,
    details TEXT
);
EOSQL
}
