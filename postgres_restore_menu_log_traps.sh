#!/bin/bash
#
# pg_restore_menu.sh
# Восстановление дампов pg_dump -Fc с ролями, владельцами и правами.
# Поддерживает все версии PostgreSQL (автовыбор метода удаления БД для версий <13 и 13+).
# Скрипт можно запускать от пользователя postgres или от рута, тогда скрипт сам подставит `sudo -u postgres`.
#


# Строгий режим: выход при ошибках (-e), защита от пустых переменных (-u) и ошибок в пайпах (-o pipefail)
set -euo pipefail

# Фиксируем локаль, чтобы вывод системных утилит (df, du, psql) всегда был на английском
export LANG=C

# Переменные по умолчанию (можно переопределить при запуске: BACKUPBASE=/mnt/bkp ./script.sh)
PGUSER=${PGUSER:-postgres}
PEER_AUTH=${PEER_AUTH:-no}
BACKUPBASE=${BACKUPBASE:-/abc/backup/pgsql}
JOBS=${JOBS:-$(nproc)} # По умолчанию берем количество всех ядер CPU

# Цвета для красивого вывода в консоль
green='\e[32m'; yellow='\e[33m'; red='\e[31m'; reset='\e[0m'

# Глобальные переменные для временных файлов (нужны, чтобы trap знал, что удалять)
TEMP_DUMP=""
DB_ERR_LOG=""

# Функция автоочистки временных файлов при завершении скрипта или нажатии Ctrl+C
cleanup() {
  rm -f "${TEMP_DUMP:-}" "${DB_ERR_LOG:-}"
}

# Ловим сигналы: нормальный выход (EXIT), прерывание с клавиатуры (INT) и убийство процесса (TERM)
trap cleanup EXIT INT TERM


# Если скрипт запущен не от postgres (например, от root), включаем обёртку sudo
if [ "$(whoami)" != "postgres" ]; then
  PEER_AUTH=yes
fi

# Функция-обёртка для запуска psql
psql_cmd() {
  if [ "$PEER_AUTH" = "yes" ]; then
    sudo -u postgres psql -U "$PGUSER" "$@"
  else
    psql -U "$PGUSER" "$@"
  fi
}

# Функция-обёртка для запуска pg_restore
pg_restore_cmd() {
  if [ "$PEER_AUTH" = "yes" ]; then
    sudo -u postgres pg_restore -U "$PGUSER" "$@"
  else
    pg_restore -U "$PGUSER" "$@"
  fi
}


# Проверяем подключение к БД и сразу забираем путь к каталогу данных (PGDATA)
# Флаги: -t (только данные без шапки), -A (без выравнивания пробелами), xargs (убирает лишние переносы)
if ! PGDATA=$(psql_cmd -t -A -c "SHOW data_directory;" 2>/dev/null | xargs) || [ -z "$PGDATA" ]; then
  echo -e "${red}ERROR${reset}: не могу подключиться к PostgreSQL как '$PGUSER' или определить PGDATA" >&2
  exit 1
fi

# Узнаем числовую версию PostgreSQL (например, 120014 для 12.14 или 150003 для 15.3)
PG_VER_NUM=$(psql_cmd -t -A -c "SHOW server_version_num;" 2>/dev/null | xargs)

# 1) Выбор каталога с дампами по дням недели
echo "Доступные бэкапы в $BACKUPBASE:"
# Читаем названия папок pgsql-* в массив DAYS
mapfile -t DAYS < <(find "$BACKUPBASE" -maxdepth 1 -type d -printf "%f\n" | grep '^pgsql-' | sort)
if [ ${#DAYS[@]} -eq 0 ]; then
  echo -e "${red}ERROR${reset}: не найдено каталогов pgsql-* в $BACKUPBASE" >&2
  exit 1
fi

# Строим интерактивное меню выбора папки с помощью встроенной конструкции select
PS3="Выберите каталог (день недели) для восстановления: "
select DAY in "${DAYS[@]}"; do
  if [ -n "${DAY:-}" ]; then
    BACKUPDIR="$BACKUPBASE/$DAY"
    echo -e "\nВыбрали каталог: $BACKUPDIR"
    break
  else
    echo "Неверный номер, попробуйте ещё раз."
  fi
done

# 2) Формируем список баз (исключаем системные postgres и template*, чтобы случайно не сломать кластер)
echo -e "\nСканирую дампы в $BACKUPDIR..."
mapfile -t DUMPS < <(find "$BACKUPDIR" -maxdepth 1 -type f -name '*.dump.gz' \
                     ! -name 'postgres.dump.gz' ! -name 'template*.dump.gz' -printf '%f\n' | sort)
if [ ${#DUMPS[@]} -eq 0 ]; then
  echo -e "${red}ERROR${reset}: нет файлов *.dump.gz в $BACKUPDIR" >&2
  exit 1
fi

# Выводим нумерованный список найденных баз (конструкция %.dump.gz отрезает расширение от имени файла)
echo "Найдено ${#DUMPS[@]} баз:"
for i in "${!DUMPS[@]}"; do
  printf " %2d) %s\n" $((i+1)) "${DUMPS[i]%.dump.gz}"
done

# 3) Выбор баз пользователем
echo
# Читаем ввод пользователя в массив SEL (разделитель — пробел)
read -r -p "Введите номера баз через пробел или 'all' для всех: " -a SEL
# Проверяем, ввел ли пользователь слово "all" в любом регистре
if [[ "${SEL[0]:-}" =~ ^[aA][lL][lL]$ ]]; then
  IDX=( $(seq 1 ${#DUMPS[@]}) ) # Заполняем массив всеми номерами по порядку
else
  IDX=()
  for x in "${SEL[@]}"; do
    # Проверяем, что введено число и оно входит в диапазон списка
    if [[ "$x" =~ ^[0-9]+$ ]] && [ "$x" -ge 1 ] && [ "$x" -le ${#DUMPS[@]} ]; then
      IDX+=("$x")
    else
      echo -e "${yellow}WARN: '$x' — невалидный номер, пропускаем${reset}"
    fi
  done
  if [ ${#IDX[@]} -eq 0 ]; then
    echo -e "${red}ERROR${reset}: не выбрано ни одной базы" >&2
    exit 1
  fi
fi

# Подтверждение перед стартом опасных операций
echo -e "\nБудут ПЕРЕСОЗДАНЫ и восстановлены базы:"
for i in "${IDX[@]}"; do
  echo "  - ${DUMPS[$((i-1))]%.dump.gz}"
done
read -r -p "ВНИМАНИЕ: Текущие данные этих баз будут удалены! Продолжить? [y/N]: " CONF
# ${CONF,,} переводит ответ пользователя в нижний регистр
if [[ "${CONF,,}" != "y" ]]; then
  echo "Отмена."
  exit 0
fi

# 4) Восстановление глобальных объектов ИЛИ ролей
# Используем if/elif, так как globals-only уже включает в себя все роли из users-only
if [ -f "$BACKUPDIR/globals-only.sql" ]; then
  read -r -p "Восстановить глобальные объекты из globals-only.sql (роли, tablespaces и т.д.)? [y/N]: " G
  if [[ "${G,,}" == "y" ]]; then
    echo "==> Восстанавливаем глобальные объекты..."
    # ON_ERROR_STOP=0 позволяет продолжать скрипт, даже если роль "postgres" уже существует
    psql_cmd --quiet -v ON_ERROR_STOP=0 -f "$BACKUPDIR/globals-only.sql"
    echo "Глобальные объекты восстановлены."
  fi
elif [ -f "$BACKUPDIR/users-only.sql" ]; then
  read -r -p "Восстановить роли из users-only.sql? [y/N]: " R
  if [[ "${R,,}" == "y" ]]; then
    echo "==> Восстанавливаем роли..."
    psql_cmd --quiet -v ON_ERROR_STOP=0 -f "$BACKUPDIR/users-only.sql"
    echo "Роли восстановлены."
  fi
fi

# 5) Основной цикл восстановления баз
echo -e "\n==> Начинаем восстановление баз..."

# Итоговый лог ошибок (с датой) и временный лог для текущей базы ($$ — это PID текущего скрипта)
ERROR_LOG="/tmp/pg_restore_errors_$(date +%Y%m%d_%H%M%S).log"
DB_ERR_LOG="/tmp/pg_restore_current_$$.log"

for i in "${IDX[@]}"; do
  # Получаем чистое имя базы (массивы в bash нумеруются с 0, поэтому i-1)
  DB="${DUMPS[$((i-1))]%.dump.gz}"
  FILE="$BACKUPDIR/$DB.dump.gz"

  echo -e "\n---- База: $DB ----"
  
  # Проверка свободного места на разделе, где лежит PGDATA
  echo "  * Проверяем свободное место..."
  # Флаг -P гарантирует, что df выведет данные в одну строку даже при длинных путях LVM
  FREE_SPACE_KB=$(df -Pk "$PGDATA" | awk 'NR==2 {print $4}')
  # Оцениваем требуемое место как: размер архива * 4 (на распаковку + само восстановление)
  ARCHIVE_SIZE_KB=$(du -k "$FILE" | awk '{print $1}')
  REQUIRED_SPACE_KB=$((ARCHIVE_SIZE_KB * 4))
  
  if [ "$FREE_SPACE_KB" -lt "$REQUIRED_SPACE_KB" ]; then
    echo -e "${red}ERROR${reset}: Мало места в $PGDATA (нужно ~${REQUIRED_SPACE_KB}KB, доступно ${FREE_SPACE_KB}KB)."
    exit 1
  fi

  # Распаковываем дамп в папку с бэкапом (а не в /tmp, чтобы не переполнить оперативную память tmpfs)
  TEMP_DUMP="$BACKUPDIR/.${DB}_restore_$$.tmp"
  echo "  * Распаковываем архив во временный файл (для работы в $JOBS потоков)..."
  gunzip -c "$FILE" > "$TEMP_DUMP"
  # Выдаем права на чтение, чтобы юзер postgres смог прочитать файл, созданный рутом
  chmod 644 "$TEMP_DUMP"

  echo "  * Принудительно отключаем клиентов и удаляем старую базу $DB..."
  # Если версия PostgreSQL 13 или новее (130000+) — используем современный DROP WITH (FORCE)
  if [ "$PG_VER_NUM" -ge 130000 ]; then
    psql_cmd -d postgres -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE);" >/dev/null
  else
    # Для старых версий (PG 12 и ниже) запрещаем коннекты, убиваем сессии и дропаем базу по старинке
    psql_cmd -d postgres -c "UPDATE pg_database SET datallowconn = 'false' WHERE datname = '$DB';" >/dev/null 2>&1 || true
    psql_cmd -d postgres -c "SELECT pg_catalog.pg_terminate_backend(pid) FROM pg_catalog.pg_stat_activity WHERE datname = '$DB' AND pid <> pg_catalog.pg_backend_pid();" >/dev/null 2>&1 || true
    sleep 1
    psql_cmd -d postgres -c "DROP DATABASE IF EXISTS \"$DB\";" >/dev/null
  fi

  echo "  * Восстанавливаем базу $DB ($JOBS потоков)..."
  > "$DB_ERR_LOG" # Очищаем временный лог перед запуском
  
  # Флаг --create заставляет pg_restore самому создать базу с правильной локалью, кодировкой и владельцем из дампа
  if ! pg_restore_cmd -d postgres --create -j "$JOBS" "$TEMP_DUMP" 2> "$DB_ERR_LOG"; then
    echo -e "  ${yellow}⚠ База $DB восстановлена с ошибками/предупреждениями!${reset}"
    # Если были ошибки, переносим их из временного лога в итоговый файл
    {
      echo "========================================"
      echo "ОШИБКИ ВОССТАНОВЛЕНИЯ БАЗЫ: $DB"
      echo "========================================"
      cat "$DB_ERR_LOG"
      echo ""
    } >> "$ERROR_LOG"
  else
    echo -e "  ${green}✔ База $DB восстановлена успешно${reset}"
  fi
  
  # Удаляем временный распакованный дамп и временный лог
  rm -f "$TEMP_DUMP" "$DB_ERR_LOG"
  
  # Собираем статистику по таблицам, чтобы планировщик запросов сразу использовал индексы
  echo "  * Обновляем статистику планировщика (ANALYZE)..."
  psql_cmd -d "$DB" -c "ANALYZE;" >/dev/null
done

echo -e "\n========================================"
echo "Восстановление завершено из архива: $BACKUPDIR"
# Проверяем: если итоговый файл ошибок существует и его размер больше нуля (-s)
if [ -s "$ERROR_LOG" ]; then
  chmod 644 "$ERROR_LOG"
  echo -e "${yellow}ВНИМАНИЕ: Были ошибки. Проверьте лог: $ERROR_LOG${reset}"
else
  echo -e "${green}Все операции прошли без единой ошибки!${reset}"
fi
