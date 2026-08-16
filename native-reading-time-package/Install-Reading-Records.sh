#!/bin/sh
# Kindle Reading Records v31 — safe upgrade from v17.
# Historical TSV files are never replaced or removed.

ROOT="/mnt/us"
PKG="$ROOT/native-reading-time-package"
BASE="$ROOT/reading-time"
APP="$BASE/illusion/ReadingRecords-v31"
APP_ID="com.krt.readingrecords.v31"
OLD_APP_ID="com.krt.readingrecords"
DB="/var/local/appreg.db"
CONF="/etc/upstart/native-reading-time.conf"
JOB="native-reading-time"
DOC="$ROOT/documents/ReadingRecords.sh"
LOG="$BASE/reading-time-install.log"
DIAG="$BASE/reading-records-diagnostics.log"
ROOT_LOG="$ROOT/reading-time-install.log"
UI_VERSION="v31-unified-summary"
ROOT_RW=0

say(){ echo "$(date): $*" >> "$LOG"; }
diag(){ echo "$(date): $*" >> "$DIAG"; }
toast(){ lipc-set-prop com.lab126.system toasterMessage "$1" >/dev/null 2>&1 || true; }
fail(){ say "ERROR: $1"; diag "ERROR: $1"; toast "阅读记录安装失败: $1"; exit 1; }

rootlog(){ echo "$(date): $*" >> "$ROOT_LOG" 2>/dev/null || true; }
: > "$ROOT_LOG" 2>/dev/null || true
rootlog "preflight begin; uid=$(id -u 2>/dev/null); user=$(id 2>/dev/null)"
rootlog "base status: $(ls -ld "$BASE" 2>&1)"
rootlog "userstoreState=$(lipc-get-prop com.lab126.volumd userstoreState 2>/dev/null)"

[ "$(id -u)" -eq 0 ] || { rootlog "ERROR: installer is not root"; toast "阅读记录安装失败：脚本没有 root 权限"; exit 1; }

# On MTP/USB Kindles, /mnt/us can remain unavailable briefly after copying.
# Wait for an actual write probe instead of trusting the directory listing.
storage_ready=0
attempt=1
while [ "$attempt" -le 8 ]; do
    if [ -d "$BASE" ]; then
        probe="$BASE/.reading-records-write-test"
    else
        probe="$ROOT/.reading-records-write-test"
    fi
    if ( umask 077; : > "$probe" ) 2>> "$ROOT_LOG"; then
        rm -f "$probe" 2>> "$ROOT_LOG" || true
        storage_ready=1
        break
    fi
    rootlog "storage not writable; attempt=$attempt/8; unplug/eject USB and wait"
    sleep 3
    attempt=$((attempt+1))
done
[ "$storage_ready" -eq 1 ] || { rootlog "ERROR: /mnt/us is not writable; safely eject/disconnect USB before ;log runme"; toast "请断开 USB 后重新执行 ;log runme"; exit 1; }

if [ ! -e "$BASE" ]; then
    mkdir "$BASE" 2>> "$ROOT_LOG" || { rootlog "ERROR: cannot create $BASE"; exit 1; }
elif [ ! -d "$BASE" ]; then
    rootlog "ERROR: $BASE exists but is not a directory"
    exit 1
fi
: > "$LOG" 2>/dev/null || true
touch "$DIAG" 2>/dev/null || true
rootlog "storage ready; continuing with log=$LOG"
say "installer start; package=$PKG; ui=$UI_VERSION"
diag "INSTALL BEGIN ui=$UI_VERSION uid=$(id -u) package=$PKG"
diag "mount=/mnt/us base=$BASE app=$APP launcher=$DOC"

for required in native-reading-time-daemon.sh ReadingRecords.sh native-reading-time.conf illusion/ReadingRecords/config.xml illusion/ReadingRecords/index.html illusion/ReadingRecords/style.css illusion/ReadingRecords/script.js; do
    [ -f "$PKG/$required" ] || fail "缺少 $required"
done

if [ ! -d "$BASE/bin" ]; then mkdir "$BASE/bin" 2>> "$ROOT_LOG" || fail "无法创建 $BASE/bin"; fi
if [ ! -d "$BASE/illusion" ]; then mkdir "$BASE/illusion" 2>> "$ROOT_LOG" || fail "无法创建 $BASE/illusion"; fi
if [ ! -d "$BASE/diagnostics" ]; then mkdir "$BASE/diagnostics" 2>> "$ROOT_LOG" || fail "无法创建诊断目录"; fi
if [ ! -d "$BASE/diagnostics/stale-launchers" ]; then mkdir "$BASE/diagnostics/stale-launchers" 2>> "$ROOT_LOG" || fail "无法创建入口备份目录"; fi
[ -d "$ROOT/documents" ] || mkdir "$ROOT/documents" || fail "无法创建 $ROOT/documents"

# Quarantine exact misspellings from test packages. Keep them recoverable.
for stale in readingrecordds.sh ReadingRecordds.sh readingrecords.sh ReadingRecordDS.sh; do
    stale_path="$ROOT/documents/$stale"
    if [ -f "$stale_path" ] && [ "$stale_path" != "$DOC" ]; then
        saved="$BASE/diagnostics/stale-launchers/$stale.disabled"
        mv "$stale_path" "$saved" 2>/dev/null && diag "quarantined stale launcher: $stale_path -> $saved" || diag "WARNING unable to quarantine: $stale_path"
    fi
done

# Replace application code only. Reading history stays intact.
if [ -d "$APP" ]; then
    backup="$BASE/diagnostics/ReadingRecords-v31.previous.$(date +%s)"
    mv "$APP" "$backup" 2>/dev/null || fail "无法备份旧 v31 UI"
fi
mkdir -p "$APP" || fail "无法创建 UI 目录"
cp -R "$PKG/illusion/ReadingRecords/." "$APP/" || fail "复制 WAF UI 失败"
printf '%s\n' "$UI_VERSION" > "$APP/ui-version.txt" || fail "写入 UI 版本失败"

cp "$PKG/ReadingRecords.sh" "$DOC.new" || fail "复制阅读记录入口失败"
chmod 755 "$DOC.new" || fail "设置入口权限失败"
mv -f "$DOC.new" "$DOC" || fail "替换阅读记录入口失败"

cp "$PKG/native-reading-time-daemon.sh" "$BASE/bin/native-reading-time-daemon.sh.new" || fail "复制统计服务失败"
chmod 755 "$BASE/bin/native-reading-time-daemon.sh.new" || fail "设置统计服务权限失败"
mv -f "$BASE/bin/native-reading-time-daemon.sh.new" "$BASE/bin/native-reading-time-daemon.sh" || fail "替换统计服务失败"

[ -f "$BASE/reading-time.tsv" ] || printf 'date\tbook_id\tseconds\ttitle\n' > "$BASE/reading-time.tsv" || fail "无法创建阅读数据文件"
[ -f "$BASE/reading-sessions.tsv" ] || printf 'date\tstart\tend\tbook_id\ttitle\n' > "$BASE/reading-sessions.tsv" || fail "无法创建阅读会话文件"
diag "data preserved: reading-time.tsv=$(wc -l < "$BASE/reading-time.tsv" 2>/dev/null) lines; reading-sessions.tsv=$(wc -l < "$BASE/reading-sessions.tsv" 2>/dev/null) lines"

[ -f "$DB" ] || fail "找不到 appreg.db"
sqlite3 "$DB" <<EOF2 || fail "注册 WAF 应用失败"
INSERT OR IGNORE INTO interfaces (interface) VALUES ('application');
INSERT OR IGNORE INTO handlerIds (handlerId) VALUES ('$APP_ID');
INSERT OR IGNORE INTO associations (handlerId,interface,contentId,defaultAssoc)
 VALUES ('$APP_ID','application','GL:$APP_ID',0);
INSERT OR REPLACE INTO properties (handlerId,name,value) VALUES ('$APP_ID','lipcId','$APP_ID');
INSERT OR REPLACE INTO properties (handlerId,name,value) VALUES ('$APP_ID','command','/usr/bin/mesquite -l $APP_ID -c file://$APP/');
INSERT OR REPLACE INTO properties (handlerId,name,value) VALUES ('$APP_ID','supportedOrientation','U');
EOF2
diag "registration requested: handler=$APP_ID command=/usr/bin/mesquite -l $APP_ID -c file://$APP/"
sqlite3 "$DB" "SELECT handlerId||'|'||name||'|'||value FROM properties WHERE handlerId IN ('$APP_ID','$OLD_APP_ID') ORDER BY handlerId,name;" >> "$DIAG" 2>&1 || true

if [ -x /sbin/initctl ]; then /sbin/initctl stop "$JOB" >/dev/null 2>&1 || true; fi
if mntroot rw >/dev/null 2>&1 || /usr/sbin/mntroot rw >/dev/null 2>&1 || /sbin/mntroot rw >/dev/null 2>&1; then ROOT_RW=1; else fail "无法写入系统服务"; fi
restore_ro(){ if [ "$ROOT_RW" = 1 ]; then mntroot ro >/dev/null 2>&1 || /usr/sbin/mntroot ro >/dev/null 2>&1 || /sbin/mntroot ro >/dev/null 2>&1 || true; ROOT_RW=0; fi; }
trap restore_ro EXIT INT TERM HUP
cp "$PKG/native-reading-time.conf" "$CONF.new" || fail "复制系统服务失败"
chmod 644 "$CONF.new" || fail "设置系统服务权限失败"
mv -f "$CONF.new" "$CONF" || fail "替换系统服务失败"
/sbin/initctl reload-configuration >/dev/null 2>&1 || true
restore_ro
trap - EXIT INT TERM HUP

/sbin/initctl start "$JOB" >/dev/null 2>&1 || true
sleep 1
diag "service status: $(/sbin/initctl status "$JOB" 2>&1)"
diag "installed launcher: $(ls -l "$DOC" 2>&1)"
diag "installed UI files: $(ls "$APP" 2>&1 | tr '\n' ' ')"
lipc-set-prop com.lab126.scanner doFullScan 1 >/dev/null 2>&1 || lipc-set-prop com.lab126.scanner triggerUpdate 1 >/dev/null 2>&1 || true
sync
say "installed successfully; handler=$APP_ID; UI=$UI_VERSION; launcher=ReadingRecords.sh; data=preserved"
diag "INSTALL OK handler=$APP_ID ui=$UI_VERSION launcher=$DOC"
rootlog "installed successfully; detailed logs are inside /mnt/us/reading-time"
toast "阅读记录 v31 已安装"
exit 0
