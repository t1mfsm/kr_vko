#!/bin/bash
# Конфигурация системы ВКО - Вариант
# Все координаты в метрах, расстояния в метрах, углы в градусах (мат. конвенция)

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="$BASE_DIR/db"
LOG_DIR="$BASE_DIR/logs"
MSG_DIR="$BASE_DIR/messages"
TEMP_DIR="$BASE_DIR/temp"
PID_DIR="$BASE_DIR/pids"
DESTROYED_TARGETS_DIR="$TEMP_DIR/destroyed_targets"

TARGETS_DIR="/tmp/GenTargets/Targets"
DESTROY_DIR="/tmp/GenTargets/Destroy"
GEN_TARGETS_LOG="/tmp/GenTargets/GenTargets.log"

# Ключ шифрования для HMAC (общий секрет)
HMAC_KEY="VKO_SECRET_KEY_2024_kr"

# Интервал проверки целей (секунды)
CHECK_INTERVAL=0.5

# Через сколько секунд считать отметку цели устаревшей, если новых файлов не было
TARGET_STALE_SECONDS=2

# Задержка перед фиксацией результата выстрела
SHOT_RESULT_DELAY=0

# Максимально допустимое время между выстрелом и публикацией результата.
SHOT_RESULT_MAX_WAIT=3

# Через сколько миллисекунд после выстрела можно считать цель пораженной,
# если новая отметка так и не появилась.
SHOT_RESULT_DESTROY_CONFIRM_MS=1500

# Шаг опроса при ожидании результата выстрела
SHOT_RESULT_POLL_INTERVAL=0.1

# Как долго удерживать цель в сопровождении после промаха или при ожидании
# отложенного выстрела, даже если отметка временно пропала из current_targets.
TARGET_RETRY_HOLD_SECONDS=3

# Интервал проверки работоспособности КП (секунды)
HEARTBEAT_INTERVAL=30

# Сколько ждать heartbeat-ответ после запроса
HEARTBEAT_RESPONSE_TIMEOUT=10

# Сколько подряд пропусков считать отказом системы
HEARTBEAT_MISSES_BEFORE_OFFLINE=4

# Максимальный размер лог-файла (строк)
MAX_LOG_LINES=5000

# Время автопополнения боекомплекта (секунды)
AMMO_REFILL_TIME=120

# --- РЛС ---
# РЛС1: Кишинев, Воронеж-ДМ, дальность 4000 км, обзор 200 градусов, направление 225 градусов
RLS1_NAME="RLS1_Voronezh"
RLS1_TYPE="Voronezh-DM"
RLS1_X=2600000
RLS1_Y=2900000
RLS1_RANGE=4000000
RLS1_ANGLE=225       # центральное направление (мат. угол)
RLS1_SECTOR=200      # ширина сектора обзора

# РЛС2: x=8000000 y=7000000, Дарьял, дальность 6000 км, обзор 90 градусов, направление 45 градусов
RLS2_NAME="RLS2_Daryal"
RLS2_TYPE="Daryal"
RLS2_X=8000000
RLS2_Y=7000000
RLS2_RANGE=6000000
RLS2_ANGLE=45
RLS2_SECTOR=90

# РЛС3: Иркутск, Днепр, дальность 3500 км, обзор 120 градусов (2*60), направление 270 градусов
RLS3_NAME="RLS3_Dnepr"
RLS3_TYPE="Dnepr"
RLS3_X=7500000
RLS3_Y=3400000
RLS3_RANGE=3500000
RLS3_ANGLE=270
RLS3_SECTOR=120

# --- ЗРДН ---
# ЗРДН1: Оренбург, радиус 600 км, обзор 360, 20 ракет
ZRDN1_NAME="ZRDN1_Orenburg"
ZRDN1_X=4250000
ZRDN1_Y=3300000
ZRDN1_RANGE=600000
ZRDN1_AMMO=20

# ЗРДН2: Волгоград, радиус 400 км, обзор 360, 20 ракет
ZRDN2_NAME="ZRDN2_Volgograd"
ZRDN2_X=3600000
ZRDN2_Y=3100000
ZRDN2_RANGE=400000
ZRDN2_AMMO=20

# ЗРДН3: Махачкала, радиус 550 км, обзор 360, 20 ракет
ZRDN3_NAME="ZRDN3_Mahachkala"
ZRDN3_X=3750000
ZRDN3_Y=2500000
ZRDN3_RANGE=550000
ZRDN3_AMMO=20

# --- СПРО ---
# СПРО: Омск, радиус 1500 км, обзор 360, 10 противоракет
SPRO_NAME="SPRO_Omsk"
SPRO_X=5500000
SPRO_Y=3800000
SPRO_RANGE=1500000
SPRO_AMMO=10

# --- Скорости целей (м/с) ---
SPEED_BB_MIN=8000
SPEED_BB_MAX=10000
SPEED_KR_MIN=250
SPEED_KR_MAX=1000
SPEED_SAM_MIN=50
SPEED_SAM_MAX=249
