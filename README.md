# Имитационная модель ВКО

Проект моделирует работу системы ВКО в Bash под Linux с использованием генератора целей, РЛС, СПРО, зрдн, командного пункта и SQLite-базы для журналов и статистики.

## Вариант

- РЛС1: Минск, `Дарьял`, дальность `6000 км`, сектор `90°`, азимут `135°`
- РЛС2: `x=7000 км`, `y=3000 км`, `Днепр`, дальность `3500 км`, сектор `120°`, азимут `45°`
- РЛС3: Казань, `Воронеж-ДМ`, дальность `4000 км`, сектор `200°`, азимут `225°`
- зрдн1: Крым, радиус `650 км`
- зрдн2: Петрозаводск, радиус `400 км`
- зрдн3: Уфа, радиус `550 км`
- СПРО: Новосибирск, радиус `800 км`

## Состав проекта

- [GenTargets.sh](/C:/kr_vko/GenTargets.sh) - генератор целей
- [config.sh](/C:/kr_vko/config.sh) - параметры варианта и общие настройки
- [common.sh](/C:/kr_vko/common.sh) - общие функции
- [rls.sh](/C:/kr_vko/rls.sh) - работа РЛС
- [spro.sh](/C:/kr_vko/spro.sh) - работа СПРО
- [zrdn.sh](/C:/kr_vko/zrdn.sh) - работа зрдн
- [kp.sh](/C:/kr_vko/kp.sh) - командный пункт
- [start.sh](/C:/kr_vko/start.sh) - запуск системы
- [stop.sh](/C:/kr_vko/stop.sh) - остановка системы
- [db_queries.sh](/C:/kr_vko/db_queries.sh) - SQL-статистика
- [map.png](/C:/kr_vko/map.png) - карта варианта

## Требования

- Linux
- Bash
- `sqlite3`
- `bc`
- `openssl`
- `xxd`

Для Ubuntu:

```bash
sudo apt update
sudo apt install -y sqlite3 bc openssl xxd
```

## Подготовка

После переноса проекта в Ubuntu:

```bash
cd ~/kr_vko
find . -type f -name "*.sh" -exec sed -i 's/\r$//' {} +
chmod +x *.sh
```

## Запуск

Полный запуск всей системы:

```bash
./start.sh
```

Скрипт запускает:

1. генератор целей
2. КП ВКО
3. РЛС1, РЛС2, РЛС3
4. СПРО
5. зрдн1, зрдн2, зрдн3

Запуск отдельного компонента:

```bash
./start.sh gen
./start.sh kp
./start.sh rls1
./start.sh rls2
./start.sh rls3
./start.sh spro
./start.sh zrdn1
./start.sh zrdn2
./start.sh zrdn3
```

## Остановка

Остановить всю систему:

```bash
./stop.sh
```

Остановить отдельный компонент:

```bash
./stop.sh gen
./stop.sh kp
./stop.sh rls1
./stop.sh rls2
./stop.sh rls3
./stop.sh spro
./stop.sh zrdn1
./stop.sh zrdn2
./stop.sh zrdn3
```

## Журналы

Основной журнал:

```bash
tail -f logs/system_journal.log
```

Примеры журналов компонентов:

```bash
tail -f logs/KP_VKO.log
tail -f logs/RLS1_Daryal_Minsk.log
tail -f logs/RLS2_Dnepr.log
tail -f logs/RLS3_Voronezh_Kazan.log
tail -f logs/SPRO_Novosibirsk.log
tail -f logs/ZRDN1_Crimea.log
tail -f logs/ZRDN2_Petrozavodsk.log
tail -f logs/ZRDN3_Ufa.log
```

## База данных и статистика

Файл базы данных создаётся автоматически:

```bash
db/vko.db
```

Запуск готовых SQL-запросов:

```bash
./db_queries.sh
```

Примеры ручных запросов:

```bash
sqlite3 db/vko.db "SELECT * FROM journal ORDER BY id DESC LIMIT 20;"
sqlite3 db/vko.db "SELECT * FROM shots ORDER BY id DESC LIMIT 20;"
sqlite3 db/vko.db "SELECT * FROM nsd_log ORDER BY id DESC LIMIT 20;"
```

## Что делает система

- РЛС обнаруживают цели в своих секторах обзора
- тип цели определяется по скорости на второй засечке
- РЛС сообщают на КП об обнаружении и о движении ББ в сторону СПРО
- СПРО уничтожает только баллистические цели
- зрдн уничтожают самолёты и крылатые ракеты
- КП собирает журналы, ведёт БД и проверяет работоспособность элементов через heartbeat
- сообщения между элементами защищаются HMAC-подписью
- при исчерпании боекомплекта предусмотрено автопополнение

## Полезно для проверки

Если после переноса с Windows скрипты не запускаются:

```bash
find . -type f -name "*.sh" -exec sed -i 's/\r$//' {} +
chmod +x *.sh
```

Если нужно проверить синтаксис:

```bash
find . -type f -name "*.sh" -exec bash -n {} \;
```
