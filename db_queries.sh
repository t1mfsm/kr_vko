#!/bin/bash
# Запросы к БД для вывода статистики работы системы ВКО
# Использование: ./db_queries.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

DB_FILE="$DB_DIR/vko.db"

if [[ ! -f "$DB_FILE" ]]; then
    echo "ОШИБКА: База данных не найдена: $DB_FILE"
    echo "Запустите систему ВКО сначала (./start.sh)"
    exit 1
fi

echo "========================================="
echo "  Статистика работы системы ВКО"
echo "========================================="
echo ""

# 1. Сколько осталось БП у всех ЗРДН
echo "--- 1. Остаток боеприпасов у ЗРДН и СПРО ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       status AS 'Статус',
       ammo_left AS 'Боеприпасов',
       timestamp AS 'Время'
FROM system_status
WHERE id IN (
    SELECT MAX(id) FROM system_status
    WHERE system_name LIKE 'ZRDN%' OR system_name LIKE 'SPRO%'
    GROUP BY system_name
)
ORDER BY system_name;
"
echo ""

# 2. Сколько каждая система сбила целей
echo "--- 2. Количество уничтоженных целей по системам ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       COUNT(*) AS 'Уничтожено'
FROM shots
WHERE result = 'DESTROYED'
GROUP BY system_name
ORDER BY COUNT(*) DESC;
"
echo ""

# 3. Кто сбил больше всего целей
echo "--- 3. Самая результативная система ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       COUNT(*) AS 'Уничтожено'
FROM shots
WHERE result = 'DESTROYED'
GROUP BY system_name
ORDER BY COUNT(*) DESC
LIMIT 1;
"
echo ""

# 4. Самый меткий (наибольший процент попаданий)
echo "--- 4. Самая меткая система (процент попаданий) ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       SUM(CASE WHEN result='DESTROYED' THEN 1 ELSE 0 END) AS 'Попадания',
       SUM(CASE WHEN result='MISS' THEN 1 ELSE 0 END) AS 'Промахи',
       COUNT(*) AS 'Всего_выстрелов',
       ROUND(100.0 * SUM(CASE WHEN result='DESTROYED' THEN 1 ELSE 0 END) / COUNT(*), 1) AS 'Точность_%'
FROM shots
GROUP BY system_name
ORDER BY ROUND(100.0 * SUM(CASE WHEN result='DESTROYED' THEN 1 ELSE 0 END) / COUNT(*), 1) DESC;
"
echo ""

# 5. Видимые цели всеми системами (последние обнаружения)
echo "--- 5. Последние обнаруженные цели ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       target_id AS 'ID_цели',
       target_type AS 'Тип',
       target_x AS 'X',
       target_y AS 'Y',
       timestamp AS 'Время'
FROM journal
WHERE event_type = 'DETECT'
ORDER BY id DESC
LIMIT 20;
"
echo ""

# 6. Сколько целей двигалось в сторону СПРО
echo "--- 6. Цели, двигавшиеся в направлении СПРО ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Обнаружено',
       target_id AS 'ID_цели',
       target_x AS 'X',
       target_y AS 'Y',
       timestamp AS 'Время'
FROM journal
WHERE event_type = 'SPRO_ALERT'
ORDER BY id DESC;
"
echo ""

# 7. Все промахи
echo "--- 7. Промахи ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       target_id AS 'ID_цели',
       target_type AS 'Тип',
       timestamp AS 'Время'
FROM shots
WHERE result = 'MISS'
ORDER BY id DESC
LIMIT 20;
"
echo ""

# 8. Попытки НСД
echo "--- 8. Попытки несанкционированного доступа ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       details AS 'Детали',
       timestamp AS 'Время'
FROM nsd_log
ORDER BY id DESC
LIMIT 10;
"
echo ""

# 9. Общая статистика
echo "--- 9. Общая статистика ---"
echo -n "Всего событий в журнале: "
sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM journal;"
echo -n "Всего выстрелов: "
sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM shots;"
echo -n "Уничтожено целей: "
sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM shots WHERE result='DESTROYED';"
echo -n "Промахов: "
sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM shots WHERE result='MISS';"
echo -n "Попыток НСД: "
sqlite3 "$DB_FILE" "SELECT COUNT(*) FROM nsd_log;"
echo ""

# 10. Сколько ЗРДН сбили за последний час
echo "--- 10. Уничтожено ЗРДН за последний час ---"
sqlite3 -header -column "$DB_FILE" "
SELECT system_name AS 'Система',
       COUNT(*) AS 'Уничтожено_за_час'
FROM shots
WHERE result = 'DESTROYED'
  AND system_name LIKE 'ZRDN%'
  AND timestamp >= datetime('now', '-1 hour')
GROUP BY system_name;
"
echo ""

echo "========================================="
echo "  Конец статистики"
echo "========================================="
