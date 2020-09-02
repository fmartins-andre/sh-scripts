#!/bin/bash
# Author: Andre Martins (fmartins.andre@gmail.com).
# This script will make a MySQL dump for each database indicated in the $DBLIST file.
# The dumps will be compressed in a tar.gz file and will be splited in files of $BACKUPSIZECAP size.
# DEPENDENCIES: sendEmail (http://caspian.dotconf.net/menu/Software/SendEmail/) to send email alerts.
# WARNING: This script is not intended to be used automatically, like in cron jobs!
# TO DO:
#    - Test if another instance is running;
#    - Accept arguments.

MYSQLUSER="usrdmp"
MYSQLPASSWORD="123123"
MYSQLSOCKPATH="/tmp/mysql.sock"
MYSQLHOST="127.0.0.1"
MYSQLBINPATH="/usr/local/mysql57/bin" # Path to MySQL binaries.
DBLIST="./databases.txt" # file with the databases list, one per line.
DBEXCLUDEDTABLESLIST="./exclude_tables.txt" # file with the tables to be excluded from the backups, one per line. eg.: "mydatabase.mytable"

LOCALTEMPDIR="/dados/tmp/MySQL_Dump_$(date +"%Y-%m-%d_%H-%M-%S")" # Path to save the dumps (temporary, will be removed at the end)
LOCALBACKUPDIR="/dados/BACKUP_REGISTER" # Path to save locally the backups. Used if the remote path is not availabe.

MOUNTPOINT="/mnt/BKP_REM_MOUNTPOINT" # Mountpoint for the remote share
CIFSSHARE="//192.168.1.234/Backups"
CIFSCREDENTIALS="/root/SCRIPTS/credentials/mycredential01.txt" # credentials file to the remote share

BACKUPNAME="RAGNAR_BD_BKP_$(date +"%Y-%m-%d_%H-%M-%S")"
DAYSTOKEEPBACKUP="12"
BACKUPSIZECAP="4G"
BACKUPLOG="/var/log/mysql_backup_db_cifs.log"
SENDEMAILLOG="/var/log/mysql_backup_db_cifs_sendEmail.log"

BACKUPDIR="" # It'll be filled by the routine with the final path to the backup.

SENDEMAILBIN="/bin/sendemail"
EMAILREPORT="n" # "n" to no, "y" to yes. Do you want to receive an email report?


EmailReport() {
    SMTP="email-ssl.com.br:587"
    SMTPUSER="suporte@asdf.com.br"
    SMTPPASS="asdf"
    MDEST="suporte@asdf.com.br"
    MSUBJECT="Backup BD $(date +"%Y-%m-%d_%H-%M-%S")"
    MMSG="Um backup foi finalizado em $(date +"%d/%m/%Y as %H:%M:%S")!\nSeguem em anexo os ultimos logs."
    MATTCH="$BACKUPLOG" ### cuidado com o tamanho do anexo!!! ###
    
    $SENDEMAILBIN -f "$SMTPUSER" -t "$MDEST" -u "$MSUBJECT" -m "$MMSG" -a "$MATTCH" -s "$SMTP" -xu "$SMTPUSER" -xp "$SMTPPASS" -l "$SENDEMAILLOG"
}


createFolder() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1"
    fi
}


_mountRemoteDisk_() {
    createFolder "$MOUNTPOINT"
    /bin/mount -t cifs "$CIFSSHARE" "$MOUNTPOINT" -o credentials="$CIFSCREDENTIALS,vers=1.0" 2>> "$BACKUPLOG"
    sleep 5s
}
umountRemoteDisk() {
    if [ "$MOUNTPOINT" = "$BACKUPDIR" ]; then
        /bin/umount "$BACKUPDIR" 2>> "$BACKUPLOG"
    fi
}
_isRemoteDiskMounted_() {
    local tryout=0
    while [ $tryout -le 3 ]; do
        if [ ! "$(df | grep -ic $MOUNTPOINT)" -eq 1 ]; then
            _mountRemoteDisk_
        else
            BACKUPDIR="$MOUNTPOINT"
            break
        fi
        tryout=$(( tryout + 1 ))
        if [ $tryout -ge 3 ]; then
            echo "$(date +"%Y-%m-%d %H:%M:%S") The remote server could not be reached. The backup will be saved locally!" >> "$BACKUPLOG"
            BACKUPDIR="$LOCALBACKUPDIR"
            createFolder "$BACKUPDIR"
            break
        fi
    done
}
isTargetOnline() {
    local CIFSHOSTNAME
    CIFSHOSTNAME="$(echo $CIFSSHARE | cut -d"/" -f3)"
    
    online=$(ping -c 1 -W 3 "$CIFSHOSTNAME" | grep -ic icmp)
    if [ "$online" -eq 0 ]; then
        echo "$(date +"%Y-%m-%d %H:%M:%S") The remote server could not be reached. The backup will be saved locally!" >> "$BACKUPLOG"
        BACKUPDIR="$LOCALBACKUPDIR"
    else
        _isRemoteDiskMounted_
    fi
}


myqlDumpBackup() {
    createFolder "$LOCALTEMPDIR"
    echo "$(date +"%Y-%m-%d %H-%M-%S") Starting the MySQL dumps." >> "$BACKUPLOG"
    
    while IFS= read -r _database; do
        echo "show tables from $_database;" | $MYSQLBINPATH/mysql -u"$MYSQLUSER" -p"$MYSQLPASSWORD" -h"$MYSQLHOST" -S"$MYSQLSOCKPATH" | \
        grep -v "Tables_in_$_database" > "$LOCALTEMPDIR/$_database.tabelas" 2>> "$BACKUPLOG"
    done < "$DBLIST"
    
    while IFS= read -r _database; do
        while IFS= read -r _table; do
            if ! (grep -q -P "^$_database.$_table$" "$DBEXCLUDEDTABLESLIST"); then
                $MYSQLBINPATH/mysqldump -u"$MYSQLUSER" -p"$MYSQLPASSWORD" -h"$MYSQLHOST" -S"$MYSQLSOCKPATH" \
                -r "$LOCALTEMPDIR/$_database.$_table.sql" "$_database" "$_table" 2>> "$BACKUPLOG"
                sleep 1
            fi
        done < "$LOCALTEMPDIR/$_database.tabelas"
    done < "$DBLIST"
    
    echo "$(date +"%Y-%m-%d %H-%M-%S") The MySQL dumps has finished." >> "$BACKUPLOG"
}
compressBackup() {
    BKPFNAME="$BACKUPDIR/$BACKUPNAME.tar.gz."
    tar -zc -C "$LOCALTEMPDIR" . --exclude='*.tabelas' | split -b "$BACKUPSIZECAP" - "$BKPFNAME" -d 2>> "$BACKUPLOG"
    echo "$(date +"%Y-%m-%d %H-%M-%S") The backups were compressed and splited." >> "$BACKUPLOG"
}


removeOldBackups() {
    find "$BACKUPDIR/" -regex '.*\.tar\.gz\.[0-9]*' -type f -ctime +"$DAYSTOKEEPBACKUP" -exec rm -f {} \; 2>> "$BACKUPLOG"
    echo "$(date +"%Y-%m-%d %H:%M:%S") Removed backups older than $DAYSTOKEEPBACKUP days" >> "$BACKUPLOG"
}
removeTempFiles() {
    rm -rf "$LOCALTEMPDIR" 2>> "$BACKUPLOG"
    echo "$(date +"%Y-%m-%d %H:%M:%S") Removed temporary files." >> "$BACKUPLOG"
}


logStart() {
    echo "" >> "$BACKUPLOG"
    echo "$(date +"%Y-%m-%d %H:%M:%S") The $0 job has started." >> "$BACKUPLOG"
}
logEnd() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") The $0 job has finished." >> "$BACKUPLOG"
    if [ "$EMAILREPORT" = "y" ]; then
        EmailReport
    fi
    exit 0
}
_help() {
    echo "This script intends to make MySQL backups."
    echo "Use the -b or --backup arguments to start a backup."
    echo "Exemple: sh $0 -b"
    echo -e "Use the -h or --help arguments to see this help message.\n\n"
}

runAll() {
    logStart
    isTargetOnline
    removeOldBackups
    myqlDumpBackup
    compressBackup
    removeTempFiles
    umountRemoteDisk
    logEnd
}


case "$1" in
    -b | --backup )
        runAll
        exit
    ;;
    
    -h | --help )
        _help
        exit
    ;;
    
    * )
        _help
        exit
    ;;
esac
