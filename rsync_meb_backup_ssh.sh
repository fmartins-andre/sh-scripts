#!/bin/bash
#Author: André Martins <https://github.com/fmartins-andre>
#Description: rsync the MEB backup to a remote location through ssh/rsync.
#Notes:
#      * It syncronizes the MEB backup folder to the remote destination.
#        As it is designed to work with a MEB weekly full backup and a series of incremental backups,
#        it'll create a week folder with the week number of the year, starting on sundays.
#        As it expect that every sunday there'll be a new backup chain started by a full MEB backup,
#        it'll create a new week folder and sync all backups of the week to it. This way, the week
#        backup chain will stay isolated from the other backup chains and may make easier to remove
#        older backup chains.
#      * This script will not remove any file for now. To cleanup old backup chains from source or
#        destination directories, you may need another script.
#      * This script was designed to be started by cron job or a systemd timer, so you may need to do your
#        own schedules.
#      * The 'backupUser' must have write permissions at the remote server.
#      * 'sendemail' package is required to send emails.


weekYear="$(date +'%U')"
if [ "$weekYear" == "00" ] && [ $(date +'%w' -d "$(date +'%Y')-01-01") -gt 0 ]; then weekYear="53"; fi
backupServer=''
backupUser=''
backupRepo=''  ## remote place where data will be saved
backupBaseDir="$backupRepo/MY-MEB-BACKUP"  ## where inside the repo the backup will be set
backupFolderName="$(date +'%Y')-$weekYear"  ## the name of the backup folder for current job
backupDir="$backupBaseDir/$backupFolderName"  ## final path to save the backup
backupLog='/var/log/rsync_meb_backup_ssh.log'
sourceDir=''  ## put a / at the end to sync only the files inside the directory

lockPath="/var/run/rsync_meb_backup_ssh"
lockPid="$lockPath/rsync_meb_backup_ssh.pid"

emailReport="n"
emailLog="/var/log/rsync_meb_backup_ssh_email.log"


preRunningCheck() {
  mkdir $lockPath &>/dev/null
  if [ $? -eq 0 ]; then
    trap 'rm -rf $lockPath; echo -e "$(date +"%Y/%m/%d %R:%S") [$$]  ERROR: Something stopped the job.\n\n\n" >> $backupLog' 1 2 3 15
    trap 'rm -rf $lockPath' 0
    echo "$$" > $lockPid 2>> $backupLog
  else
    local prevLockPid="$(cat $lockPid)"

    if ! kill -0 $prevLockPid &>/dev/null; then
      echo -e "$(date +"%Y/%m/%d %R:%S") [$$]  Found a zombie lockfile. Removing it and restarting the job." >> $backupLog
      rm -rf $lockPath
      preRunningCheck
    else
      echo "$(date +"%Y/%m/%d %R:%S") [$$]  WARNING: There is another backup job running. Skipping this run." >> $backupLog
      exit 0
    fi

  fi
}

function getConnectionStatus() {
  local server="$1"
  local user="$2"
  local repository="$3"
  local attempt=${4:-1}
  if ssh $user@$server "[ -d $repository ]"; then
    echo "ok"
  else
    echo "$(date +'%Y/%m/%d %R:%S') [$$]  WARNING: Connection failed. Trying again..." >> $backupLog

    if [ $attempt -le 3 ]; then
      local new_attempt=$( expr $attempt + 1 )
      sleep 1s
      echo "$(date +'%Y/%m/%d %R:%S') [$$]  Attempt #$attempt: Failed to make a connection to the host." >> $backupLog
      getConnectionStatus $server $user $repository $new_attempt
    fi

  fi
}

function createRemoteDirectory() {
  local server=$1
  local user=$2
  local directory=$3
  ssh $user@$server mkdir -p "$directory"
  if ssh $user@$server "[ ! -d $directory ]"; then
    echo "fail"
  fi
}

function backupToRemote() {
  local server=$1
  local user=$2
  local sourceFolder=$3
  local destinationFolder=$4
  rsync -rlumzhD --partial --inplace --stats \
       $sourceFolder $user@$server:$destinationFolder \
       | sed '/^\s*$/d' \
       | sed "s/^/\ \ \.\.\.\ \[$$\]\ \ /" \
       >> $backupLog 2>&1
  echo $?
}

function emailReport() {
  ## WARNING: this function requires sendEmail application installed@ (yum install sendemail)
  local backupStatusReport=${1:-"Not informed"}
  local smtp='smtp-server:587'
  local smtpUser=''
  local smtpPass="$(cat /root/SCRIPTS/rsync_meb_backup_ssh/smtp_password.txt)"
  local emailReplyTo=''
  local emailTo=''
  local emailSubject="Backup Rsync MEB - $(date +'%Y-%m-%d_%H-%M-%S') - $backupStatusReport"
  local emailMessage="A new backup was finished on $(date +'%F %X' | sed 's/\ /\ at\ /').\
                      \nStatus: $backupStatusReport.\
                      \nThe logs are attached."
  local emailAttachment=$backupLog  ## keep an eye on the attachment size

  sendEmail -q \
    -f $smtpUser \
    -t $emailTo \
    -u "$emailSubject" \
    -m "$emailMessage" \
    -a $emailAttachment \
    -s $smtp \
    -xu $smtpUser \
    -xp $smtpPass \
    -l $emailLog \
    &> /dev/null
}

function startBackup() {
  if [[ "$(getConnectionStatus $backupServer $backupUser $backupRepo)" == "ok" ]]; then
    echo "$(date +'%Y/%m/%d %R:%S') [$$]  Host reached. Trying to start the backup routine..." >> $backupLog

    if [[ "$(createRemoteDirectory $backupServer $backupUser $backupDir)" == "fail" ]]; then
      echo -e "$(date +'%Y/%m/%d %R:%S') [$$]  ERROR: Backup directory could'nt be created. No backup can be done.\n\n\n" >> $backupLog
    else
      echo "$(date +'%Y/%m/%d %R:%S') [$$]  Backup directory '$backupFolderName' created. Starting the backup job." >> $backupLog

      if [ $(backupToRemote $backupServer $backupUser $sourceDir $backupDir) -eq 0 ]; then
        echo -e "$(date +'%Y/%m/%d %R:%S') [$$]  Backup finished successfully.\n\n\n" >> $backupLog
        echo "ok"
      else
        echo -e "$(date +'%Y/%m/%d %R:%S') [$$]  ERROR: The backup job finished with errors.\n\n\n" >> $backupLog
      fi

    fi

  else
    echo -e "$(date +'%Y/%m/%d %R:%S') [$$]  ERROR: It could'nt access the host or find the repository. No backup done.\n\n\n" >> $backupLog
  fi
}


preRunningCheck
backupStatus=$(startBackup)
if [ "$backupStatus" == "ok" ]; then
  backupStatusReport='Success'
else
  backupStatusReport='Failure'
fi

if [ "$emailReport" == "y" ]; then
  emailReport $backupStatusReport
fi
