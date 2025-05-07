#!/bin/bash

# Script for backing up PostgreSQL and rotate backups.
# It creates a folder corresponding to the current day of the week, saves backup in it and creates /latest symlink, where the latest backup is located.
# Thus, there is a natural rotation - only 7 backups are stored like 7 days of week.
# In addition to creating dumps, script creates two beacon files with the date and size of the backup for zabbix monitoring.
# 
# To make script executable: chmod +x pg_backup_cron.sh
#
# To add to cron: vi /etc/crontab
#   add lines:
#       # run PostgreSQL backup script
#       0 4 * * *    root    /abc/bin/pg_backup_cron.sh >>/var/log/pg_backup_cron.log 2>&1
#
# Logs are here: /var/log/pg_backup_cron.log
#

set -e
LANG=C

# use postgres peer auth: yes/no
PEER_AUTH=no
# set base backup dir
backupbase=/opt/backup/pgsql
# set day of week
backupnum=$(date +%a)
# set date and time
backuptime=$(date +'%d-%m-%Y %H:%M')
# set final backup dir like day of week
backupdir="${backupbase}/pgsql-${backupnum}"
# get origin script name without extension
filename=$(basename "$0" | sed 's/\.[^.]*$//')

# get db names except templates and 'postgres' db
if [ "$PEER_AUTH" = "yes" ]; then
    dbs=$(sudo -u postgres psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false and datname<>'postgres'")
else
    dbs=$(psql -U postgres -t -c "SELECT datname FROM pg_database WHERE datistemplate = false and datname<>'postgres'")
fi


# print info for logs
echo -e "\n\n----------------------------------------"
echo "Starting backup at $backuptime $backupnum"
echo -e "----------------------------------------\n"


# create dir and symlink 'latest'
mkdir -p "${backupdir}"
echo "1. Directory ${backupdir} created successfully"
ln -sfn "${backupdir}" "${backupbase}/latest"


# backup all dbs separately in the loop
# pg_dump -Fc -b -U postgres -d <...>
## -Fc == format custom (output a custom-format archive suitable for input into pg_restore)
## -b  == blobs (include large objects in the dump)
## -U  == username (user name to connect as)
## -d  == dbname (specifies the name of the database to connect to)
echo -e "\n2. Backuping each db separately:"
for i in $dbs
do
    echo "  *) $i"
    if [ "$PEER_AUTH" = "yes" ]; then
       sudo -u postgres pg_dump -Fc -b -U postgres -d $i > $backupdir/$i.dump
    else
       pg_dump -Fc -b -U postgres -d $i > $backupdir/$i.dump
    fi
    echo "      - sql dump created"
    gzip -f $backupdir/$i.dump
    echo "      - sql dump gzipped"
    echo "      - db $i backuped successfully"
done


# backup users separately
echo -e "\n3. Backuping users only"
if [ "$PEER_AUTH" = "yes" ]; then
    sudo -u postgres pg_dumpall -U postgres --roles-only > $backupdir/users-only.sql
else
    pg_dumpall -U postgres --roles-only > $backupdir/users-only.sql
fi
echo "  - backup of users created successfully"


# backup global grants: databases, tablespaces
echo -e "\n4. Backuping globals only"
if [ "$PEER_AUTH" = "yes" ]; then
    sudo -u postgres pg_dumpall -U postgres --globals-only > "$backupdir/globals-only.sql"
else
    pg_dumpall -U postgres --globals-only > "$backupdir/globals-only.sql"
fi
echo "  - backup of globals created successfully"


# backup schemas separately
echo -e "\n5. Backuping schema only"
if [ "$PEER_AUTH" = "yes" ]; then
    sudo -u postgres pg_dumpall -U postgres --schema-only > $backupdir/schemas-only.sql
else
    pg_dumpall -U postgres --schema-only > $backupdir/schemas-only.sql
fi
gzip -f $backupdir/schemas-only.sql
echo "  - backup of schemas created successfully"

echo -e "\nBackup completed successfully at $(date +'%H:%M')"


# put size of last backup into file (for monitoring backups with zabbix)
echo `du -sb ${backupbase}/latest/ | awk '{print $1}'` > "$backupbase/$filename"_last.size

# check if file was created properly by printing it
echo "Backup total size: `awk '{printf "%.2f MB\n", $1/1024/1024}' "$backupbase/$filename"_last.size`"
