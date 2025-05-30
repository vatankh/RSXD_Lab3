# Лабораторная работа №3 по АСУБД
[полный текст задания](./full_task.md)

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

добавим параметр в `$HOME/ckf15/postgres.conf` для хранения WAL-файлов в составе полной копии
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
psql -h localhost -p 9787 -d postgres -c "GRANT CONNECT ON DATABASE longgreenmath TO backupuser;"
psql -h localhost -p 9787 -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE longgreenmath TO backupuser;"
```
**создание директории для резервных копий **

на основном узле `pg180`:
```bash 
    mkdir -p $HOME/backups
```

на резервном узле `pg186`:
```bash 
    mkdir -p $HOME/backups
```
перезапускаем сервер 
```bash 
    pg_ctl -D $HOME/ckf15 restart
```
создание [скрипта](./script/pg180/backup.sh) `backup.sh` для резервного копирования 

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
- Средний объем новых данных в БД за сутки: `700МБ`.
- Средний объем измененных данных за сутки: `800МБ`.
- Частота полного резервного копирования: 2 раза в сутки 
- срок храниения 
  - основной узел: 7 дней 
  - резервный узел: 30 дней 

расчет для основного узла 
1. объем одной копии = 700МБ + 800МБ = 1500МБ ~ 1.5ГБ
2. количество копий за сутки = 2 
3. объем резервных копий за неделю = 1500 * 2 * 7 = 21000МБ ~ 21ГБ

расчет для резервного узла 
1. количество копий за месяц = 2 * 30 = 60 
2. объем резервных копий за месяц = 1500 * 60 = 90000МБ ~ 88ГБ
   
> расчеты не учитывают сжатия 

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

```

копируем файлы .conf с основного узла и папку с табличными пространствами 
```bash
scp postgres0@pg180:$HOME/ckf15/postgresql.conf $HOME/ckf15/
scp postgres0@pg180:$HOME/ckf15/pg_hba.conf $HOME/ckf15/
scp postgres0@pg180:$HOME/ckf15/pg_ident.conf $HOME/ckf15/

scp -r postgres0@pg180:$HOME/het47/ $HOME/

```

применим изменения 
```bash 
pg_ctl -D $HOME/ckf15 restart 
```

симулируем сбой, удалив директорию с табличным пространством 
```bash
    rm -rf $HOME/het47
```

#### проверка работоспособности
