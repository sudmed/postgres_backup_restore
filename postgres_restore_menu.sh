#!/bin/bash
#
# pg_restore_menu.sh
# Восстановление дампов pg_dump -Fc с ролями, владельцами и правами.
# Скрипт запускать от пользователя postgres. Можно запускать и от рута, скрипт сам подставит `sudo -u postgres`.
#
# При запуске скрипт предложит:
# 1. Выбрать из какого бэкапа (по дню недели) восстанавливать.
# 2. Выбрать нужные для восстановления базы через пробел, либо "all" (все базы).
# 3. Опционально: восстановить роли (из users-only.sql) и глобальные объекты (из globals-only.sql).
# 
# В процессе работы скрипт выполнит для каждой выбранной базы: DROP -> CREATE -> pg_restore.
#

set -euo pipefail
LANG=C

PGUSER=${PGUSER:-postgres}
PEER_AUTH=${PEER_AUTH:-no}                        # yes — оборачивает psql/pg_restore в `sudo -u postgres`
BACKUPBASE=${BACKUPBASE:-/opt/backup/pgsql}
JOBS=${JOBS:-$(nproc)}
green='\e[32m'; yellow='\e[33m'; red='\e[31m'; reset='\e[0m'


# Автоматически включаем sudo
if [ "$(whoami)" != "postgres" ]; then
  PEER_AUTH=yes
fi


# Определяем под каким пользователем выполнять psql и pg_restore
psql_cmd() {
  if [ "$PEER_AUTH" = "yes" ]; then
    sudo -u postgres psql -U "$PGUSER" "$@"
  else
    psql -U "$PGUSER" "$@"
  fi
}
pg_restore_cmd() {
  if [ "$PEER_AUTH" = "yes" ]; then
    sudo -u postgres pg_restore -U "$PGUSER" "$@"
  else
    pg_restore -U "$PGUSER" "$@"
  fi
}


# Проверяем, что можем подключиться к СУБД
if ! psql_cmd -c '\conninfo' >/dev/null 2>&1; then
  echo "${red}ERROR${reset}: не могу подключиться к PostgreSQL как '$PGUSER'" >&2
  exit 1
fi


# 1) Выбор каталога с дампами по дням недели
echo "Доступные бэкапы в $BACKUPBASE:"
mapfile -t DAYS < <(find "$BACKUPBASE" -maxdepth 1 -type d -printf "%f\n" \
                   | grep '^pgsql-' | sort)
if [ ${#DAYS[@]} -eq 0 ]; then
  echo "${red}ERROR${reset}: не найдено каталогов pgsql-*" >&2
  exit 1
fi

PS3="Выберите каталог (день недели) для восстановления: "
select DAY in "${DAYS[@]}"; do
  if [ -n "${DAY:-}" ]; then
    BACKUPDIR="$BACKUPBASE/$DAY"
    echo
    echo "Выбрали каталог: $BACKUPDIR"
    break
  else
    echo "Неверный номер, попробуйте ещё раз."
  fi
done


# 2) Формируем список баз для восстановления
echo
echo "Сканирую дампы в $BACKUPDIR..."
mapfile -t DUMPS < <(find "$BACKUPDIR" -maxdepth 1 -type f -name '*.dump.gz' -printf '%f\n' | sort)
if [ ${#DUMPS[@]} -eq 0 ]; then
  echo "${red}ERROR${reset}: нет файлов *.dump.gz в $BACKUPDIR" >&2
  exit 1
fi
echo "Найдено ${#DUMPS[@]} баз:"
for i in "${!DUMPS[@]}"; do
  printf " %2d) %s\n" $((i+1)) "${DUMPS[i]%.dump.gz}"
done


# 3) Выбор баз
echo
#echo "Введите номера баз через пробел или 'all' для всех:"
#read -r -a SEL
read -r -p "Введите номера баз через пробел или 'all' для всех: " -a SEL
if [[ "${SEL[0],,}" == "all" ]]; then
  IDX=( $(seq 1 ${#DUMPS[@]}) )
else
  IDX=()
  for x in "${SEL[@]}"; do
    if [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -ge 1 ] && [ "$x" -le ${#DUMPS[@]} ]; then
      IDX+=("$x")
    else
      echo "${yellow}WARN: '$x' — невалидный номер, пропускаем ${reset}"
    fi
  done
  if [ ${#IDX[@]} -eq 0 ]; then
    echo "${red}ERROR${reset}: не выбрано ни одной базы" >&2
    exit 1
  fi
fi

echo
echo "Будут восстановлены базы:"
for i in "${IDX[@]}"; do
  echo "  - ${DUMPS[$((i-1))]%.dump.gz}"
done
read -p "Продолжить? [y/N]: " CONF
if [[ "${CONF,,}" != "y" ]]; then
  echo "Отмена."
  exit 0
fi


# 4) Опционально: восстанавливаем глобальные объекты из globals-only
if [ -f "$BACKUPDIR/globals-only.sql" ]; then
  read -p "Восстановить глобальные объекты из globals-only (роли, табл. пространства, подписки для лог. репликации, глоб. переменные, etc.)? [y/N]: " G
  if [[ "${G,,}" == "y" ]]; then
    echo "==> Восстанавливаем глобальные объекты..."
    psql_cmd --quiet -v ON_ERROR_STOP=0 -f "$BACKUPDIR/globals-only.sql"
    echo "Глобальные объекты восстановлены."
  fi
fi


# 5) Опционально: восстанавливаем роли из users-only
if [ -f "$BACKUPDIR/users-only.sql" ]; then
  read -p "Восстановить только роли (пользователи и группы) из users-only? [y/N]: " R
  if [[ "${R,,}" == "y" ]]; then
    echo "==> Восстанавливаем роли..."
    psql_cmd --quiet -v ON_ERROR_STOP=0 -f "$BACKUPDIR/users-only.sql"
    echo "Роли восстановлены."
  fi
fi



# 6) Восстанавливаем выбранные базы: убить сессии -> DROP -> CREATE -> pg_restore
echo
echo "==> Восстанавливаем базы (term sessions → DROP → CREATE → restore)"
for i in "${IDX[@]}"; do
  DB="${DUMPS[$((i-1))]%.dump.gz}"
  FILE="$BACKUPDIR/$DB.dump.gz"

  echo
  echo "---- База: $DB ----"
  
  echo "  * Проверяем свободное место перед восстановлением"
  PGDATA=$(psql_cmd -t -A -c "SHOW data_directory;" 2>/dev/null | xargs) # Добавил -A для psql, чтобы убрать пробелы
  # Проверка, что PGDATA не пустой
  if [ -z "$PGDATA" ]; then
    echo -e "${red}ERROR${reset}: Не удалось определить PGDATA."
    exit 1
  fi
  FREE_SPACE=$(df -k "$(dirname "$PGDATA")" | awk 'NR==2 {print $4}')  
  DUMP_SIZE_BYTES=$(gzip -l "$FILE" | awk 'NR==2 {print $2}')
  DUMP_SIZE_KB=$((DUMP_SIZE_BYTES / 1024))
  # Добавим 20% запас
  REQUIRED_SPACE_KB=$((DUMP_SIZE_KB * 120 / 100))
  if [ "$FREE_SPACE" -lt "$REQUIRED_SPACE_KB" ]; then
    echo -e "${red}ERROR${reset}: Недостаточно свободного места на диске (нужно ${REQUIRED_SPACE_KB}KB, доступно ${FREE_SPACE}KB в $(dirname "$PGDATA"))."
    exit 1
  fi

  echo "  * Завершаем все подключения к $DB"
   
  # --- Функция для проверки и получения количества подключений ---
  # Определяем ее внутри цикла, чтобы она была доступна здесь
  set +e # Временно отключаем exit on error
  get_connections_count() {
    local db_name="$1"
    local count
    local psql_status
    
    count=$(psql_cmd -d postgres -tA -c \
      "SELECT count(*) FROM pg_catalog.pg_stat_activity
        WHERE datname = '$db_name' AND pid <> pg_catalog.pg_backend_pid();" 2>/dev/null)
    psql_status=$?

    if [ $psql_status -ne 0 ]; then
      echo -e "${red}ERROR:${reset} Не удалось выполнить запрос подсчета подключений к $db_name (psql код: $psql_status)."
      return 1 # Ошибка
    fi
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
      echo -e "${red}ERROR:${reset} Запрос подсчета подключений к $db_name вернул нечисловое значение: '$count'."
      return 1 # Ошибка
    fi
    echo "$count" # Возвращаем количество
    return 0 # Успех
  }

  # --- Попытка 1: Однократное мягкое завершение ---
  echo "    Первичная попытка завершить подключения..."
  psql_cmd -d postgres -c \
    "SELECT pg_catalog.pg_terminate_backend(pid)
       FROM pg_catalog.pg_stat_activity
      WHERE datname = '$DB' AND pid <> pg_catalog.pg_backend_pid();" >/dev/null 2>&1 || true
  
  # Небольшая пауза, чтобы дать сеансам завершиться
  sleep 3
  
  CONNECTIONS_EXIST=$(get_connections_count "$DB")
  if [ $? -ne 0 ]; then # Если get_connections_count вернул ошибку
      # Сообщение об ошибке тут не нужно, оно уже выведено самой функцией
      exit 1
  fi

  # --- Если после первой попытки подключения остались, переходим к дополнительным попыткам
  if [ "$CONNECTIONS_EXIST" -ne "0" ]; then
    echo "    После первой попытки осталось $CONNECTIONS_EXIST подключений. Попробуем еще раз..."

    # --- Попытка 2: Несколько мягких с паузами
    NORMAL_TERMINATE_ATTEMPT=0
    MAX_NORMAL_TERMINATE_ATTEMPTS=3 
    
    while [ "$CONNECTIONS_EXIST" -ne "0" ] && [ $NORMAL_TERMINATE_ATTEMPT -lt $MAX_NORMAL_TERMINATE_ATTEMPTS ]; do
      ((NORMAL_TERMINATE_ATTEMPT++))
      echo "    Мягкая попытка $NORMAL_TERMINATE_ATTEMPT/$MAX_NORMAL_TERMINATE_ATTEMPTS завершить $CONNECTIONS_EXIST подключений к БД $DB..."

      psql_cmd -d postgres -c \
        "SELECT pg_catalog.pg_terminate_backend(pid)
           FROM pg_catalog.pg_stat_activity
          WHERE datname = '$DB' AND pid <> pg_catalog.pg_backend_pid();" >/dev/null 2>&1 || true
      sleep 3 

      NEW_CONNECTIONS_EXIST=$(get_connections_count "$DB")
      if [ $? -ne 0 ]; then 
          CONNECTIONS_EXIST="-1" 
          break 
      fi
      CONNECTIONS_EXIST=$NEW_CONNECTIONS_EXIST

      if [ "$CONNECTIONS_EXIST" -eq "0" ]; then
        echo "    Все подключения к $DB завершены во время мягких попыток."
        break 
      fi
    done 

    if [ "$CONNECTIONS_EXIST" -ne "0" ]; then
      if [ "$CONNECTIONS_EXIST" = "-1" ]; then 
          echo -e "${red}ERROR:${reset} Ошибка при подсчете подключений во время мягких попыток. Завершение для $DB."
          exit 1
      fi

      echo "    Мягкие попытки не завершили все сессии ($CONNECTIONS_EXIST осталось). Переходим к агрессивному завершению..."
      
      MAX_AGGRESSIVE_LOOPS=50    
      TOTAL_TIMEOUT_SEC=30       
      
      SECONDS_ELAPSED=0
      START_TIME=$(date +%s)
      AGGRESSIVE_SUCCESS=false 

      while [ $SECONDS_ELAPSED -lt $TOTAL_TIMEOUT_SEC ]; do
          for (( agg_i=1; agg_i<=$MAX_AGGRESSIVE_LOOPS; agg_i++ )); do
              psql_cmd -d postgres -q -c \
                "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity \
                WHERE datname = '$DB' AND pid <> pg_catalog.pg_backend_pid();" >/dev/null 2>&1 || true

              CURRENT_AGGRESSIVE_CONNECTIONS=$(get_connections_count "$DB")
              if [ $? -ne 0 ]; then 
                  AGGRESSIVE_SUCCESS=false
                  CONNECTIONS_EXIST="-1" 
                  break 2 
              fi
              CONNECTIONS_EXIST=$CURRENT_AGGRESSIVE_CONNECTIONS 

              if [ "$CONNECTIONS_EXIST" -eq "0" ]; then
                  AGGRESSIVE_SUCCESS=true
                  break 2 
              fi
          done 

          if $AGGRESSIVE_SUCCESS || [ "$CONNECTIONS_EXIST" = "-1" ]; then 
              break 
          fi
          
          if [ "$CONNECTIONS_EXIST" -ne "0" ]; then
             echo "    После $MAX_AGGRESSIVE_LOOPS агрессивных попыток, осталось $CONNECTIONS_EXIST подключений к $DB."
          fi
          
          CURRENT_TIME=$(date +%s)
          SECONDS_ELAPSED=$((CURRENT_TIME - START_TIME))

          if [ $SECONDS_ELAPSED -ge $TOTAL_TIMEOUT_SEC ]; then
              echo "    Превышен общий таймаут ($TOTAL_TIMEOUT_SEC сек) на агрессивное завершение сессий."
              break 
          fi
          
          sleep 0.5 
      done 

      if $AGGRESSIVE_SUCCESS && [ "$CONNECTIONS_EXIST" -eq "0" ]; then
          echo "    Все подключения к $DB агрессивно завершены."
      else
          # Сообщение об ошибке будет выведено ниже, в финальной проверке
          if [ "$CONNECTIONS_EXIST" != "-1" ]; then # Если не было ошибки подсчета
            echo "    Агрессивное завершение не смогло удалить все подключения (осталось: $CONNECTIONS_EXIST)."
          fi
      fi
    fi 
  else
    echo "    Все подключения к $DB завершены после первой попытки."
  fi 


  if [ "$CONNECTIONS_EXIST" = "-1" ]; then 
      echo -e "${red}ERROR:${reset} Критическая ошибка: не удалось корректно определить количество подключений к $DB."
      exit 1
  elif [ "$CONNECTIONS_EXIST" -ne "0" ]; then
      echo -e "${red}ERROR:${reset} Не удалось завершить все подключения к $DB. Осталось $CONNECTIONS_EXIST подключений."
      echo -e "${yellow}INFO:${reset} Запрос для просмотра оставшихся сессий к $DB:"
      echo "psql_cmd -d postgres -c \"SELECT pid, usename, application_name, client_addr, state, query FROM pg_catalog.pg_stat_activity WHERE datname = '$DB' AND pid <> pg_catalog.pg_backend_pid();\""
      exit 1
  fi 
  set -e # Возвращаем


  echo "  * Все подключения к $DB успешно завершены перед удалением/восстановлением."
  echo "  * Удаляем базу $DB"
  echo "  * Восстанавливаем дамп $DB"
  # --clean попытается удалить объекты в существующей базе
  # --create создаст базу, если ее нет. Если она есть, он завершится ошибкой, если не указан --clean
  # Связка --create --clean: сначала попытается удалить базу (если существует), затем создаст ее
  gunzip -c "$FILE" | pg_restore_cmd --create --clean  -d postgres

  echo -e "${green}✔ База $DB восстановлена${reset}"
  echo
done

echo
echo "Восстановление проведено успешно из архива: $BACKUPDIR"
exit 0
