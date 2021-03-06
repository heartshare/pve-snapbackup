#!/usr/bin/env bash
# exit on any error
set -eo pipefail
# send email on failure
trap 'cleanup' SIGINT ERR
# activate python virtualenv
source /usr/local/benji/bin/activate
# virtualenv is now active.
#
RECEIPIENTS="your@email.com"
TMPDIR=/tmp/benji
TMPFILE=${TMPDIR}/deep_scrub
SCRUB_MAXAGE=86400
LOGDIR="/var/log/pvesnapbackup"
SQLITE_DB="/data/backup/benji/db/benji.sqlite"
SQLITE_BIN="/usr/bin/sqlite3"
BENJI_RETENTION="latest3,days7,weeks4"
logger "$0 Setting up log directory $LOGDIR"
mkdir -p $LOGDIR
logger "$0 Cleanup old logs in $LOGDIR"
find $LOGDIR -type f -name 'pvesnapbackup_*' -mtime +14 -exec rm {} \;
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
LOGFILE="/var/log/pvesnapbackup/pvesnapbackup_$DATE.log"

function cleanup {
    tail -n 20 $LOGFILE | mail -s "Backup failed! Please check..." $RECEIPIENTS
}

logger "$0 Sending logs to $LOGFILE"
echo "$(date +'%Y-%m-%d %H:%M:%S') Checking for locks in benji Database" | tee -a $LOGFILE
if [ "$(echo 'select * from locks;' | $SQLITE_BIN $SQLITE_DB)" != "" ]; then
	echo "$(date +'%Y-%m-%d %H:%M:%S') backing up database before modifying it" | tee -a $LOGFILE
    cp -v $SQLITE_DB $SQLITE_DB.bak_$(date +%s) |& tee -a $LOGFILE
    TRY=1
    while [ "$(echo 'select * from locks;' | $SQLITE_BIN $SQLITE_DB)" != "" ]; do
	    echo "$(date +'%Y-%m-%d %H:%M:%S') trying to delete locks from database" | tee -a $LOGFILE
        echo "DELETE FROM locks WHERE reason = 'NBD';" | $SQLITE_BIN $SQLITE_DB |& tee -a $LOGFILE
	sleep 3
        ((TRY++))
        if [ "$TRY" -gt 5 ]; then
		echo "$(date +'%Y-%m-%d %H:%M:%S') Failed to unlock database.. giving up" | tee -a $LOGFILE 
            exit 1
        fi
    done
fi
echo "$(date +'%Y-%m-%d %H:%M:%S') Starting backup expiration" |& tee -a $LOGFILE
/usr/local/benji/bin/benji enforce ${BENJI_RETENTION} |& tee -a $LOGFILE
echo "$(date +'%Y-%m-%d %H:%M:%S') Backup expiration done" |& tee -a $LOGFILE
cd /data/backup/pvesnapbackup && python -u backupWrapper.py |& tee -a $LOGFILE

# Check logfile for initial backups and inform admins 
BODY="$(grep benji_initial_backup.sh ${LOGFILE})" && echo $BODY | mail -s "Benji Backup - list of initial backups from ${LOGFILE}" ${RECEIPIENTS}

# Start deep scrubbing if it did not run for more than 24 hours
if [ ! -d /tmp/benji ]; then
    mkdir $TMPDIR
    touch $TMPFILE
fi
if [ ! -e /tmp/benji/deep_scrub ]; then
    touch $TMPFILE
fi
MTIME=$(stat -c %Y $TMPFILE)
NOW=$(date +%s)
LASTSCRUB=$(( $NOW-$MTIME ))
if [ $LASTSCRUB -gt $SCRUB_MAXAGE ]; then
    echo "Starting deep scrubbing of 14 % of all images" |& tee -a $LOGFILE
    /usr/local/benji/bin/benji batch-deep-scrub --version-percentage 14 |& tee -a $LOGFILE && touch $TMPFILE
    INVALID=$(benji -m --log-level ERROR ls | jq -r '.versions[] | select(.status|test("invalid"))| .uid, .status' | wc -l)
    if [ $INVALID -ne 0 ]; then 
        echo "One or more backups are invalid! Manual intervention needed!" |& tee -a $LOGFILE
        /usr/local/benji/bin/benji ls 'status != "valid"' | mail -s "Invalid Benji backups found! Please check!" $RECEIPIENTS
    fi
fi

exit 0
