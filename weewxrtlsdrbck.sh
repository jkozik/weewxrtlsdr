#!/bin/bash
# Weekly backup of the weewxrtlsdr project (rtldavis weewx + mosquitto + nginx).
# Separate from ~/weewx51/weewxbck.sh, which backs up only ~/weewx51.
#
# Runs as root (writes to /backup, reads mosquitto/data owned by uid 1883).
# Suggested root crontab entry (Sunday 23:30, after the weewx51 backup):
#   30 23 * * 0 /home/jkozik/projects/weewxrtlsdr/weewxrtlsdrbck.sh >> /home/jkozik/projects/weewxrtlsdr/weewxrtlsdrbck.log 2>&1
#
# No container shutdown needed: the SQLite databases are copied with
# SQLite's online backup API, which gives a consistent snapshot while
# weewxd keeps writing.
#
# FTP login (same server/user as the weewx51 backup) is read from a
# chmod-600 file so the password isn't stored in this git repo.

PROJ=/home/jkozik/projects/weewxrtlsdr
BCKDIR=/backup/weewxrtlsdrBck
FTPCFG=/home/jkozik/.ncftp-backup.cfg
FTPDIR=/weewx
KEEP_DAYS=84

echo "=== weewxrtlsdr backup $(/bin/date) ==="
mkdir -p ${BCKDIR}/project ${BCKDIR}/db

# Project files; databases are snapshotted separately below
rsync -a --delete --exclude 'data/archive/' --exclude '*.log' \
  ${PROJ}/ ${BCKDIR}/project/ || { echo "rsync FAILED"; exit 1; }

for DB in weewx.sdb weewxwd.sdb; do
  python3 - "${PROJ}/data/archive/${DB}" "${BCKDIR}/db/${DB}" <<'EOF' || { echo "db snapshot of ${DB} FAILED"; exit 1; }
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
src.backup(dst)
print(sys.argv[2], dst.execute("pragma integrity_check").fetchone()[0])
dst.close(); src.close()
EOF
done

touch /backup/weewxrtlsdrbackupage

DATE=`/bin/date +%Y%m%d`
TIME=`/bin/date +%H`
BCKUPFILE="/backup/weewxrtlsdr.$DATE.$TIME.tar.gz"
tar czf $BCKUPFILE -C /backup weewxrtlsdrBck || { echo "tar FAILED"; exit 1; }
ls -l $BCKUPFILE

ncftpput -f $FTPCFG $FTPDIR $BCKUPFILE && echo "ftp upload OK" || echo "ftp upload FAILED"

# Retention: keep ~12 weeks of local tarballs (copies also go to FTP .143).
# Only prune if today's tarball was created, so a failing backup never
# deletes the last good ones.
if [[ -s $BCKUPFILE ]]; then
 echo "pruning tarballs older than ${KEEP_DAYS} days:"
 find /backup -maxdepth 1 -name 'weewxrtlsdr.*.tar.gz' -mtime +${KEEP_DAYS} -print -delete
fi
