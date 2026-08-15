#!/bin/sh
# Name: 阅读记录
# Kindle Reading Records v29 launcher

APP_ID="com.krt.readingrecords.v29"
APP_DIR="/mnt/us/reading-time/illusion/ReadingRecords-v29"
APPREG_DB="/var/local/appreg.db"
DIAG="/mnt/us/reading-time/reading-records-diagnostics.log"
COVER_MAP="/mnt/us/reading-time/cover-map.tsv"
CC_DB="/var/local/cc.db"
UI_VERSION="v29-daily-month-ranking"

log(){ echo "$(date): LAUNCH $*" >> "$DIAG"; logger -t reading-records "$*"; }
log "begin handler=$APP_ID path=$APP_DIR ui=$UI_VERSION script=$0"

# Build a fresh, read-only cover map from Kindle's content catalog. Entries.p_thumbnail
# is authoritative for both ASIN covers and random personal-document filenames.
if [ -f "$CC_DB" ]; then
    sqlite3 "$CC_DB" "SELECT upper(replace(p_cdeKey,'-',''))||char(9)||p_thumbnail FROM Entries WHERE p_cdeKey IS NOT NULL AND p_thumbnail IS NOT NULL AND p_thumbnail<>'' AND p_location IS NOT NULL;" > "$COVER_MAP.new" 2>> "$DIAG"
    if [ -s "$COVER_MAP.new" ]; then
        mv -f "$COVER_MAP.new" "$COVER_MAP"
        log "cover map updated rows=$(wc -l < "$COVER_MAP" 2>/dev/null)"
    else
        rm -f "$COVER_MAP.new" 2>/dev/null || true
        log "cover map has no matched local entries"
    fi
else
    log "WARNING content catalog missing: $CC_DB"
fi

if [ ! -f "$APP_DIR/index.html" ] || [ ! -f "$APP_DIR/config.xml" ]; then
    log "ERROR missing UI files"
    lipc-set-prop com.lab126.system toasterMessage "阅读记录 UI 文件缺失，请重新安装" >/dev/null 2>&1 || true
    exit 1
fi

if [ -f "$APPREG_DB" ]; then
sqlite3 "$APPREG_DB" <<EOF2
INSERT OR IGNORE INTO interfaces (interface) VALUES ('application');
INSERT OR IGNORE INTO handlerIds (handlerId) VALUES ('$APP_ID');
INSERT OR IGNORE INTO associations (handlerId,interface,contentId,defaultAssoc) VALUES ('$APP_ID','application','GL:$APP_ID',0);
INSERT OR REPLACE INTO properties (handlerId,name,value) VALUES ('$APP_ID','lipcId','$APP_ID');
INSERT OR REPLACE INTO properties (handlerId,name,value) VALUES ('$APP_ID','command','/usr/bin/mesquite -l $APP_ID -c file://$APP_DIR/');
INSERT OR REPLACE INTO properties (handlerId,name,value) VALUES ('$APP_ID','supportedOrientation','U');
EOF2
    rc=$?
    actual="$(sqlite3 "$APPREG_DB" "SELECT value FROM properties WHERE handlerId='$APP_ID' AND name='command';" 2>&1)"
    log "registration rc=$rc actual_command=$actual"
else
    log "ERROR appreg missing: $APPREG_DB"
    exit 1
fi

active_before="$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)"
context_before="$(lipc-get-prop com.lab126.appmgrd activeContext 2>/dev/null)"
log "before activeApp=$active_before activeContext=$context_before"
lipc-set-prop com.lab126.appmgrd start "app://com.lab126.booklet.home" >/dev/null 2>&1
sleep 1
lipc-set-prop com.lab126.appmgrd start "app://$APP_ID" >/dev/null 2>&1
rc=$?
sleep 1
active_after="$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)"
context_after="$(lipc-get-prop com.lab126.appmgrd activeContext 2>/dev/null)"
log "start rc=$rc after activeApp=$active_after activeContext=$context_after"
exit "$rc"
