# Лабораторная работа №3 

## Этап 1. Резервное копирование 

генерируем ssh-key на основном узле для выполнения копирования без запроса пароля
```bash
  ssh-keygen -t rsa -b 4096 -C "postgres7@pg194"
  ssh-copy-id -i $HOME/.ssh/id_rsa.pub postgres8@pg199

```

проверка доступа к резервному узлу без пароля
```
[postgres7@pg194 ~]$ ssh postgres8@pg199
Last login: Thu May 29 23:04:33 2025 from 192.168.11.194
[postgres8@pg199 ~]$ 
```

добавим параметр в `$HOME/tpz50/postgres.conf` для хранения WAL-файлов в составе полной копии
```bash
sed -i '' "s/#wal_level =.*/wal_level = replica/" $HOME/tpz50/postgresql.conf
```

```
[postgres7@pg194 ~]$ grep "wal_level" $HOME/tpz50/postgresql.conf
wal_level = replica			# minimal, replica, or logical
```

создаем раль на резервном узле: 
```bash 
psql -h localhost -p 9787 -d postgres -c "CREATE ROLE backupuser WITH LOGIN PASSWORD 'backup_pass123';" 
psql -h localhost -p 9787 -d postgres -c "GRANT CONNECT ON DATABASE somedb TO backupuser;"
psql -h localhost -p 9787 -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE somedb TO backupuser;"
```
**создание директории для резервных копий **

на основном узле `pg194`:
```bash 
    mkdir -p $HOME/backups
```

на резервном узле `pg199`:
```bash 
    mkdir -p $HOME/backups
```
перезапускаем сервер 
```bash 
    pg_ctl -D $HOME/tpz50 restart
```
создание `backup.sh` для резервного копирования 

```bash 
#!/bin/bash
# === Этап 1: Резервное копирование ===

set -euo pipefail

CURRENT_DATE=$(date "+%Y-%m-%d_%H:%M:%S")

# --- локальная сторона ---
LOCAL_BASE="$HOME/backups"
LOCAL_BACKUP_DIR="$LOCAL_BASE/$CURRENT_DATE"

# --- резервный узел ---
RESERVE_HOST="postgres8@pg199"
REMOTE_BASE='~/backups'          # интерпретируется на pg199
LOG_FILE="$HOME/backup.log"

exec >> "$LOG_FILE" 2>&1
echo "===================="
echo "$(date): Начало резервного копирования"

mkdir -p "$LOCAL_BACKUP_DIR"

echo "Запуск pg_basebackup"
PGPASSWORD="backup_pass123" pg_basebackup \
  -h 127.0.0.1 -p 9787 -U backupuser \
  -D "$LOCAL_BACKUP_DIR" -F tar -z -P

# --- копируем на резервный узел ---
echo "Создание каталога на резервном узле"
ssh "$RESERVE_HOST" "mkdir -p $REMOTE_BASE"

echo "Копирование на резервный узел"
scp "$LOCAL_BACKUP_DIR"/*.tar.gz "$RESERVE_HOST":"$REMOTE_BASE/"

# --- ретеншн-политика ---
echo "Удаление локальных копий старше 7 дней"
find "$LOCAL_BASE" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;

echo "Удаление удалённых копий старше 30 дней"
ssh "$RESERVE_HOST" "find $REMOTE_BASE -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \;"

echo "$(date): Резервное копирование завершено успешно"

```

делаем скрипт исполняемым и запускаем 
```bash 
chmod +x scripts/pg194/backup.sh
bash scripts/pg194/backup.sh

```

результат выполнения скрипта из `backup.sh`

```bash
cat $HOME/backup.log
```

```
Запуск pg_basebackup
ожидание контрольной точки
   18/31398 КБ (0%), табличное пространство 0/2
   18/31398 КБ (0%), табличное пространство 1/2
17772/31398 КБ (56%), табличное пространство 1/2
31411/31411 КБ (100%), табличное пространство 1/2
31411/31411 КБ (100%), табличное пространство 2/2
Создание каталога на резервном узле
Копирование на резервный узел
Удаление локальных копий старше 7 дней
Удаление удалённых копий старше 30 дней
пятница, 30 мая 2025 г. 10:00:34 (MSK): Резервное копирование завершено успешно
```

добавляем задачу в планировщик `cron`

```bash
crontab -e 
```
добавляем строку для выполнения задачи дважды в сутки 
```
0 0 * * * $HOME/scripts/pg194/backup.sh >> $HOME/backup.log 2>&1
0 12 * * * $HOME/scripts/pg194/backup.sh >> $HOME/backup.log 2>&1
```

#### подсчет объема резервных копий 

**исходные данные **
Средний объем новых данных в БД за сутки: 850 МБ

Средний объем изменённых данных за сутки: 850 МБ

Частота полного резервного копирования: 2 раза в сутки

Срок хранения:

Основной узел: 7 дней

Резервный узел: 30 дней

расчет для основного узла 
1. 850 МБ (новые данные) + 850 МБ (изменённые) = 1700 МБ = 1.7 ГБ
2. 2 (по расписанию: 00:00 и 12:00)
3. 1.7 ГБ * 2 раза/сутки * 7 дней = 23.8 ГБ

расчет для резервного узла 
1. количество копий за месяц =2 копии/сутки * 30 дней = 60 копий 
2. объем резервных копий за месяц = 1.7 ГБ * 60 = 102 ГБ

   
Вывод и анализ
На основном узле потребуется около 24 ГБ пространства для хранения недельного объема резервных копий.

На резервном узле необходимо не менее 102 ГБ пространства на диске.




## Этап 2. Потеря основного узла 
добавим таблицу в БД на основном узле 
```sql
CREATE TABLE test_table (id SERIAL PRIMARY KEY, data TEXT);
INSERT INTO test_table (data) VALUES ('test data');
```
выполняем резервное копирование на основном узле 
```bash
bash $HOME/scripts/pg180/backup.sh >> $HOME/backup.log 2>&1
```

создаем [скрипт](./script/pg186/restore.sh) `restore.sh` на резервном узле для восстановления БД

```bash
#!/bin/bash
# === Этап 2: Потеря основного узла ===
set -euo pipefail

NOW=$(date '+%Y-%m-%d_%H-%M-%S')
RESERVE_DIR=~/backups
RESTORE_DIR=~/tpz50
LOG_FILE=~/restore.log
exec >>"$LOG_FILE" 2>&1

echo "[$NOW] ▶️  Старт восстановления"

# 1. Останавливаем (если вдруг запущен)
pg_ctl -D "$RESTORE_DIR" stop -m fast || echo "PostgreSQL не был запущен"

# 2. Чистый каталог
rm -rf "$RESTORE_DIR"
mkdir -p "$RESTORE_DIR"

# 3. Файлы архива
BASE_TAR=$(ls -t "$RESERVE_DIR"/base.tar.gz | head -n 1)
[[ -n "$BASE_TAR" ]] || { echo "❌ base.tar.gz не найден"; exit 1; }

echo "▶️  Распаковка $BASE_TAR"
tar --no-same-owner -xzf "$BASE_TAR" -C "$RESTORE_DIR"

# 4. Дополнительные архивы
[[ -f "$RESERVE_DIR/pg_wal.tar.gz" ]] && {
  echo "▶️  Распаковка pg_wal.tar.gz"
  mkdir -p "$RESTORE_DIR/pg_wal"
  tar --no-same-owner -xzf "$RESERVE_DIR/pg_wal.tar.gz" -C "$RESTORE_DIR/pg_wal"
}

for TS_TAR in "$RESERVE_DIR"/*[0-9][0-9][0-9][0-9][0-9].tar.gz; do
  [[ -e "$TS_TAR" ]] || break
  echo "▶️  Распаковка tablespace $(basename "$TS_TAR")"
  tar --no-same-owner -xzf "$TS_TAR" -C "$RESTORE_DIR"
done

# 5. Приводим права (без попытки сменить группу)
chmod 700 "$RESTORE_DIR"

# 6. (необязательно) свежие конфиги — если ключ доступа настроен
scp -q postgres7@pg194:~/tpz50/{postgresql.conf,pg_hba.conf,pg_ident.conf} "$RESTORE_DIR/" \
  || echo "⚠️  Конфиги не скопированы — берём из архива"

# 7. Запуск PostgreSQL
echo "▶️  Запуск PostgreSQL"
pg_ctl -D "$RESTORE_DIR" start

sleep 3
echo "▶️  Проверка данных"
psql -h localhost -p 9787 -U backupuser -d somedb -c "SELECT * FROM recovery_check;"

echo "[$NOW] ✅ Восстановление завершено"
```

результат:
```bash
[postgres8@pg199 ~]$ bash ~/scripts/pg199/restore.sh
(postgres7@pg194.cs.ifmo.ru) Password for postgres7@pg194.cs.ifmo.ru:
(postgres7@pg194.cs.ifmo.ru) Password for postgres7@pg194.cs.ifmo.ru:
(postgres7@pg194.cs.ifmo.ru) Password for postgres7@pg194.cs.ifmo.ru:
Пароль пользователя backupuser: 
[postgres8@pg199 ~]$ cat restore.log 
[2025-05-30_12-19-57] ▶️  Старт восстановления
pg_ctl: файл PID "/var/db/postgres8/tpz50/postmaster.pid" не существует
Запущен ли сервер?
PostgreSQL не был запущен
▶️  Распаковка /var/db/postgres8/backups/base.tar.gz
▶️  Распаковка pg_wal.tar.gz
▶️  Распаковка tablespace 16388.tar.gz
▶️  Запуск PostgreSQL
ожидание запуска сервера....2025-05-30 12:20:15.112 MSK [13138] СООБЩЕНИЕ:  передача вывода в протокол процессу сбора протоколов
2025-05-30 12:20:15.112 MSK [13138] ПОДСКАЗКА:  В дальнейшем протоколы будут выводиться в каталог "log".
 готово
сервер запущен
▶️  Проверка данных
 id |       note        
----+-------------------
  1 | backup successful
  2 | recovery check
  3 | final test
(3 строки)

[2025-05-30_12-19-57] ✅ Восстановление завершено
[postgres8@pg199 ~]$ 
```
#### этап 3
напишим новой таблица 
```bash
psql -h localhost -p 9787 -U postgres7 -d somedb
```
```bash
CREATE TABLE test_table (
    id SERIAL PRIMARY KEY,
    data TEXT
);

INSERT INTO test_table (data)
VALUES 
('row 1'), ('row 2'), ('row 3');
```
Сделайте новый бэкап с этой таблицей
```bash
bash ~/scripts/pg194/backup.sh
```
напишем file_corruption.sh :
```bash
#!/bin/bash
# === Этап 3. Повреждение файлов БД и полное восстановление ===
#     (вариант 555, primary pg194  →  reserve pg199)
set -euo pipefail

##############################################################################
# ---- ПЕРАМЕТРЫ -------------------------------------------------------------
PGDATA="$HOME/tpz50"            # каталог кластера на pg194
TBS_OLD="$HOME/gcj98"           # старое табличное пространство
TBS_NEW="$HOME/gcj98_new"       # новое место для TBS
BACKUP_WORK="$HOME/backups/recovery_$(date +%Y-%m-%d_%H-%M-%S)"  # куда копируем архивы

RESERVE_HOST="postgres8@pg199"
REMOTE_BACKUPS="~/backups"      # на pg199 — здесь «валятся» *.tar.gz

PORT=9787                       # порт кластера (задан в postgresql.conf)
PGUSER=postgres7
DBNAME=somedb
TEST_TABLE=public.test_table    # любая таблица-«маяк»

LOG_FILE="$HOME/file_corruption.log"
##############################################################################

exec >>"$LOG_FILE" 2>&1
echo "========== $(date)  ЭТАП 3 START =========="

################### 1. СИМУЛИРУЕМ СБОЙ #######################################
echo "Удаляем каталoг табличного пространства: $TBS_OLD"
rm -rf "$TBS_OLD" || true

################### 2. ПРОВЕРКА РАБОТОСПОСОБНОСТИ ###########################
echo "Пробуем перезапустить сервер (должно упасть)"
pg_ctl -D "$PGDATA" restart && echo "⚠️  Неожиданно перезапустился" || echo "✅  Ошибка перезапуска — как и ожидалось"

if psql -h localhost -p "$PORT" -U "$PGUSER" -d "$DBNAME" -c "SELECT 1;" >/dev/null 2>&1 ; then
  echo "⚠️  Сессия всё ещё устанавливается — это странно"
else
  echo "✅  База недоступна — повреждение подтверждено"
fi

################### 3. ОСТАНАВЛИВАЕМ КЛАСТЕР ################################
pg_ctl -D "$PGDATA" stop -m fast || true

################### 4. КОПИРУЕМ АРХИВЫ С pg199 ##############################
echo "Копируем *.tar.gz с $RESERVE_HOST:$REMOTE_BACKUPS → $BACKUP_WORK"
mkdir -p "$BACKUP_WORK"
scp "$RESERVE_HOST":"$REMOTE_BACKUPS"/*.tar.gz "$BACKUP_WORK/"

# контроль наличия обязательно-минимального набора
[ -f "$BACKUP_WORK/base.tar.gz" ] || { echo "❌  base.tar.gz не найден — бэкап повреждён"; exit 1; }

################### 5. ГОТОВИМ КАТАЛОГИ #####################################
mv "$PGDATA" "${PGDATA}_corrupted_$(date +%s)"
mkdir -p "$PGDATA" && chmod 700 "$PGDATA"
mkdir -p "$TBS_NEW" && chmod 700 "$TBS_NEW"

################### 6. РАСПАКОВКА base.tar.gz ###############################
echo "Распаковываем base.tar.gz"
tar -xzf "$BACKUP_WORK/base.tar.gz" -C "$PGDATA" --no-same-owner

echo "Распаковываем WAL (если есть)"
if [ -f "$BACKUP_WORK/pg_wal.tar.gz" ]; then
  mkdir -p "$PGDATA/pg_wal"
  tar -xzf "$BACKUP_WORK/pg_wal.tar.gz" -C "$PGDATA/pg_wal" --no-same-owner
fi

echo "Пересоздаём pg_tblspc"
mkdir -p "$PGDATA/pg_tblspc"
rm -f "$PGDATA/pg_tblspc"/*

################### 7. ТАБЛИЧНЫЕ ПРОСТРАНСТВА ###############################
for TS_TAR in "$BACKUP_WORK"/[0-9][0-9][0-9][0-9][0-9].tar.gz; do
    [ -f "$TS_TAR" ] || continue
    OID=$(basename "$TS_TAR" .tar.gz)
    echo "  • TBS OID=$OID  →  $TBS_NEW/$OID"
    mkdir -p "$TBS_NEW/$OID"
    tar -xzf "$TS_TAR" -C "$TBS_NEW/$OID" --no-same-owner
    ln -sfn "$TBS_NEW/$OID" "$PGDATA/pg_tblspc/$OID"
done

################### 8. ЗАПУСК КЛАСТЕРА #######################################
echo "Запускаем восстановленный кластер"
pg_ctl -D "$PGDATA" start
sleep 3

################### 9. КОНТРОЛЬНЫЙ ЗАПРОС ###################################
echo "Контрольная выборка из $TEST_TABLE"
psql -h localhost -p "$PORT" -U "$PGUSER" -d "$DBNAME" \
     -c "SELECT count(*) AS rows_after_recovery FROM $TEST_TABLE;"

echo "✅  Восстановление успешно завершено"
echo "========== $(date)  ЭТАП 3 END =========="
```
запустим и прверям :
```bash
[postgres7@pg194 ~]$ bash ~/scripts/pg194/file_corruption.sh
[postgres7@pg194 ~]$ tail -n 40 ~/file_corruption.log   
========== пятница, 30 мая 2025 г. 12:54:31 (MSK)  ЭТАП 3 START ==========
Удаляем каталoг табличного пространства: /var/db/postgres7/gcj98
Пробуем перезапустить сервер (должно упасть)
ожидание завершения работы сервера.... готово
сервер остановлен
ожидание запуска сервера....2025-05-30 12:54:32.153 MSK [17253] СООБЩЕНИЕ:  передача вывода в протокол процессу сбора протоколов
2025-05-30 12:54:32.153 MSK [17253] ПОДСКАЗКА:  В дальнейшем протоколы будут выводиться в каталог "log".
 готово
сервер запущен
⚠️  Неожиданно перезапустился
⚠️  Сессия всё ещё устанавливается — это странно
ожидание завершения работы сервера.... готово
сервер остановлен
Копируем *.tar.gz с postgres8@pg199:~/backups → /var/db/postgres7/backups/recovery_2025-05-30_12-54-31
Распаковываем base.tar.gz
Распаковываем WAL (если есть)
Пересоздаём pg_tblspc
  • TBS OID=16388  →  /var/db/postgres7/gcj98_new/16388
Запускаем восстановленный кластер
ожидание запуска сервера....2025-05-30 12:54:35.144 MSK [17288] СООБЩЕНИЕ:  передача вывода в протокол процессу сбора протоколов
2025-05-30 12:54:35.144 MSK [17288] ПОДСКАЗКА:  В дальнейшем протоколы будут выводиться в каталог "log".
 готово
сервер запущен
Контрольная выборка из public.test_table
 rows_after_recovery 
---------------------
                   3
(1 строка)

✅  Восстановление успешно завершено
========== пятница, 30 мая 2025 г. 12:54:38 (MSK)  ЭТАП 3 END ==========
[postgres7@pg194 ~]$ psql -h localhost -p 9787 -U postgres7 -d somedb -c "SELECT count(*) FROM public.test_table;"
 count 
-------
     3
(1 строка)

[postgres7@pg194 ~]$ ls -l ~/tpz50/pg_tblspc/
total 1
lrwxr-xr-x  1 postgres7 postgres 33 30 мая   12:54 16388 -> /var/db/postgres7/gcj98_new/16388
[postgres7@pg194 ~]$ 
```


