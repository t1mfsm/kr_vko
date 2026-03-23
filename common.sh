#!/bin/bash
# Общие функции для всех элементов системы ВКО

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

# --- Проверки безопасности ---
check_environment() {
    # Проверка: не root
    if [[ $EUID -eq 0 ]]; then
        echo "ОШИБКА: Запуск от имени root запрещен!" >&2
        exit 1
    fi
    # Проверка: Linux
    if [[ "$(uname -s)" != "Linux" ]]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: Система предназначена для Linux. Текущая ОС: $(uname -s)" >&2
    fi
    # Проверка: bash
    if [[ -z "$BASH_VERSION" ]]; then
        echo "ОШИБКА: Требуется интерпретатор Bash!" >&2
        exit 1
    fi
    if (( BASH_VERSINFO[0] < 4 )); then
        echo "ОШИБКА: Требуется Bash версии 4 или выше!" >&2
        exit 1
    fi
}

# --- Проверка дублирования процесса ---
check_single_instance() {
    local name="$1"
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

# --- Очистка при завершении ---
cleanup() {
    local name="$1"
    rm -f "$PID_DIR/${name}.pid"
}

# --- Декодирование ID цели из имени файла ---
# Формат файла: interleaved random[2] + id_hex[2] по 7 пар, + 2 random hex
# Итого 30 символов в имени
decode_target_id() {
    local filename="$1"
    # Берем только имя файла без пути
    filename=$(basename "$filename")
    local hex_id=""
    local i
    # Извлекаем каждую вторую пару hex-символов (позиции 2-3, 6-7, 10-11, ...)
    for ((i = 2; i < 28; i += 4)); do
        hex_id+="${filename:$i:2}"
    done
    # Конвертируем hex в ASCII
    echo -n "$hex_id" | xxd -r -p 2>/dev/null
}

# --- Вычисление расстояния между двумя точками ---
calc_distance() {
    local x1=$1 y1=$2 x2=$3 y2=$4
    local dx=$((x2 - x1))
    local dy=$((y2 - y1))
    # Используем bc для вычисления sqrt
    echo "scale=0; sqrt($dx * $dx + $dy * $dy)" | bc -l
}

# --- Вычисление скорости цели ---
calc_speed() {
    local x1=$1 y1=$2 x2=$3 y2=$4
    calc_distance "$x1" "$y1" "$x2" "$y2"
}

# --- Определение типа цели по скорости ---
get_target_type() {
    local speed=$1
    if (( speed >= SPEED_BB_MIN && speed <= SPEED_BB_MAX )); then
        echo "BB_BR"  # Боевой блок баллистической ракеты
    elif (( speed >= SPEED_KR_MIN && speed <= SPEED_KR_MAX )); then
        echo "KR"     # Крылатая ракета
    elif (( speed >= SPEED_SAM_MIN && speed <= SPEED_SAM_MAX )); then
        echo "SAM"    # Самолет
    else
        echo "UNKNOWN"
    fi
}

# --- Проверка: находится ли цель в зоне обнаружения (круговой) ---
is_in_range() {
    local cx=$1 cy=$2 range=$3 tx=$4 ty=$5
    local dist
    dist=$(calc_distance "$cx" "$cy" "$tx" "$ty")
    (( dist <= range ))
}

# --- Проверка: находится ли цель в секторе РЛС ---
# Углы в градусах, мат. конвенция (0=восток, CCW)
is_in_sector() {
    local cx=$1 cy=$2 range=$3 center_angle=$4 sector_width=$5 tx=$6 ty=$7

    # Проверка дальности
    local dist
    dist=$(calc_distance "$cx" "$cy" "$tx" "$ty")
    if (( dist > range )); then
        return 1
    fi

    # Вычисление угла до цели
    local dx=$((tx - cx))
    local dy=$((ty - cy))

    # atan2 через bc, результат в градусах
    local angle
    angle=$(echo "scale=4; a = 180 / 3.14159265358979 * a($dy, $dx); if (a < 0) a += 360; a" | bc -l 2>/dev/null)
    # bc не поддерживает atan2, используем альтернативу
    angle=$(awk "BEGIN {
        pi = 3.14159265358979
        a = atan2($dy, $dx) * 180 / pi
        if (a < 0) a += 360
        printf \"%.0f\", a
    }")

    # Проверка попадания в сектор
    local half=$((sector_width / 2))
    local min_angle=$(( (center_angle - half + 360) % 360 ))
    local max_angle=$(( (center_angle + half) % 360 ))

    if (( min_angle <= max_angle )); then
        (( angle >= min_angle && angle <= max_angle ))
    else
        # Сектор пересекает 0 градусов
        (( angle >= min_angle || angle <= max_angle ))
    fi
}

# --- Проверка: движется ли цель в направлении СПРО ---
is_moving_toward_spro() {
    local x1=$1 y1=$2 x2=$3 y2=$4
    local spro_x=$SPRO_X spro_y=$SPRO_Y

    # Вектор скорости
    local vx=$((x2 - x1))
    local vy=$((y2 - y1))

    # Вектор от текущей позиции к СПРО
    local dx=$((spro_x - x2))
    local dy=$((spro_y - y2))

    # Скалярное произведение: если > 0, цель движется в сторону СПРО
    local dot=$((vx * dx + vy * dy))
    (( dot > 0 ))
}

# --- Логирование ---
log_message() {
    local logfile="$1"
    local system_name="$2"
    shift 2
    local message="$*"
    local timestamp
    timestamp=$(date +"%d.%m %H:%M:%S:%3N")

    echo "$timestamp $system_name $message" >> "$logfile"

    # Ротация лога
    local line_count
    line_count=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    if (( line_count > MAX_LOG_LINES )); then
        tail -n $((MAX_LOG_LINES / 2)) "$logfile" > "${logfile}.tmp"
        mv "${logfile}.tmp" "$logfile"
    fi
}

# --- Шифрование сообщения (base64 + HMAC) ---
encrypt_message() {
    local message="$1"
    local encoded
    encoded=$(echo -n "$message" | base64)
    local hmac
    hmac=$(echo -n "$message" | openssl dgst -sha256 -hmac "$HMAC_KEY" 2>/dev/null | awk '{print $NF}')
    echo "${encoded}|${hmac}"
}

# --- Дешифрование и проверка сообщения ---
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

    # Проверка HMAC
    local expected_hmac
    expected_hmac=$(echo -n "$decoded" | openssl dgst -sha256 -hmac "$HMAC_KEY" 2>/dev/null | awk '{print $NF}')

    if [[ "$received_hmac" != "$expected_hmac" ]]; then
        echo "ERROR_HMAC"
        return 1
    fi

    echo "$decoded"
    return 0
}

# --- Отправка сообщения на КП ---
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

# --- Отправка сообщения от КП к системе ---
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

# --- Отправка heartbeat ---
send_heartbeat_response() {
    local system_name="$1"
    local encrypted
    encrypted=$(encrypt_message "ALIVE $system_name $(date +%s)")
    echo "$encrypted" > "$MSG_DIR/heartbeat/${system_name}_response"
}

# --- Чтение координат из файла цели ---
read_target_coords() {
    local filepath="$1"
    local content
    content=$(head -n 1 "$filepath" 2>/dev/null)
    if [[ -z "$content" ]]; then
        return 1
    fi
    # Формат: X:  11059533    Y:   1893638
    local x y
    x=$(echo "$content" | awk -F'[:\t ]+' '{for(i=1;i<=NF;i++){if($i=="X")print $(i+1)}}')
    y=$(echo "$content" | awk -F'[:\t ]+' '{for(i=1;i<=NF;i++){if($i=="Y")print $(i+1)}}')
    if [[ -z "$x" || -z "$y" ]]; then
        return 1
    fi
    echo "$x $y"
}

# --- Получение самого свежего файла для данного ID цели ---
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

# --- Получение всех текущих целей ---
# Возвращает: ID X Y (по одной цели на строку)
scan_targets() {
    declare -A seen_ids
    declare -A latest_files
    declare -A latest_times

    local f decoded_id ftime

    for f in "$TARGETS_DIR"/*; do
        [[ -f "$f" ]] || continue
        decoded_id=$(decode_target_id "$f")
        [[ -z "$decoded_id" ]] && continue

        ftime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)
        if [[ -z "${latest_times[$decoded_id]}" ]] || (( ftime > ${latest_times[$decoded_id]} )); then
            latest_times[$decoded_id]=$ftime
            latest_files[$decoded_id]="$f"
        fi
    done

    for decoded_id in "${!latest_files[@]}"; do
        local coords
        coords=$(read_target_coords "${latest_files[$decoded_id]}")
        if [[ -n "$coords" ]]; then
            echo "$decoded_id $coords"
        fi
    done
}

# --- Вставка записи в БД ---
db_insert() {
    local db_file="$DB_DIR/vko.db"
    local sql="$1"
    sqlite3 "$db_file" "$sql" 2>/dev/null
}

# --- Инициализация БД ---
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
