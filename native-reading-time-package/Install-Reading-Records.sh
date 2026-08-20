#!/bin/sh
# Kindle Reading Records v1.3 — safe upgrade from v17.
# Historical TSV files are never replaced or removed.

ROOT="/mnt/us"
PKG="$ROOT/native-reading-time-package"
BASE="$ROOT/reading-time"
APP="$BASE/illusion/ReadingRecords-v33"
APP_ID="com.krt.readingrecords.v33"
OLD_APP_ID="com.krt.readingrecords"
DB="/var/local/appreg.db"
CONF="/etc/upstart/native-reading-time.conf"
JOB="native-reading-time"
SYNC_CONF="/etc/upstart/reading-sync.conf"
SYNC_JOB="reading-sync"
DOC="$ROOT/documents/ReadingRecords.sh"
KUAL_DIR="$ROOT/extensions/reading-records"
LOG="$BASE/reading-time-install.log"
DIAG="$BASE/reading-records-diagnostics.log"
ROOT_LOG="$ROOT/reading-time-install.log"
UI_VERSION="v34-lan-sync"
ROOT_RW=0

say(){ echo "$(date): $*" >> "$LOG"; }
diag(){ echo "$(date): $*" >> "$DIAG"; }
toast(){ lipc-set-prop com.lab126.system toasterMessage "$1" >/dev/null 2>&1 || true; }
fail(){ say "ERROR: $1"; diag "ERROR: $1"; [ -x /sbin/initctl ] && /sbin/initctl start "$JOB" >/dev/null 2>&1 || true; toast "阅读记录安装失败: $1"; exit 1; }

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
diag "mount=/mnt/us base=$BASE app=$APP launcher=$DOC kual=$KUAL_DIR"

for required in native-reading-time-daemon.sh ReadingRecords.sh native-reading-time.conf reading-sync.conf bin/reading-syncd-armv7 bin/reading-syncd-arm64 illusion/ReadingRecords/config.xml illusion/ReadingRecords/index.html illusion/ReadingRecords/style.css illusion/ReadingRecords/script.js kual/reading-records/config.xml kual/reading-records/menu.json; do
    [ -f "$PKG/$required" ] || fail "缺少 $required"
done

# Freeze both writers before upgrading or migrating data.
if [ -x /sbin/initctl ]; then /sbin/initctl stop "$JOB" >/dev/null 2>&1 || true; /sbin/initctl stop "$SYNC_JOB" >/dev/null 2>&1 || true; fi

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
    backup="$BASE/diagnostics/ReadingRecords-v33.previous.$(date +%s)"
    mv "$APP" "$backup" 2>/dev/null || fail "无法备份旧 v33 UI"
fi
mkdir -p "$APP" || fail "无法创建 UI 目录"
cp -R "$PKG/illusion/ReadingRecords/." "$APP/" || fail "复制 WAF UI 失败"
printf '%s\n' "$UI_VERSION" > "$APP/ui-version.txt" || fail "写入 UI 版本失败"

cp "$PKG/ReadingRecords.sh" "$DOC.new" || fail "复制阅读记录入口失败"
chmod 755 "$DOC.new" || fail "设置入口权限失败"
mv -f "$DOC.new" "$DOC" || fail "替换阅读记录入口失败"

# KUAL fallback for older firmware where .sh scriptlets are not indexed in the
# Kindle library (commonly seen on some KV/PW3 jailbreak environments).
[ -d "$ROOT/extensions" ] || mkdir "$ROOT/extensions" || fail "无法创建 KUAL 扩展目录"
[ -d "$KUAL_DIR" ] || mkdir "$KUAL_DIR" || fail "无法创建阅读记录 KUAL 入口"
cp "$PKG/kual/reading-records/config.xml" "$KUAL_DIR/config.xml" || fail "复制 KUAL 配置失败"
cp "$PKG/kual/reading-records/menu.json" "$KUAL_DIR/menu.json" || fail "复制 KUAL 菜单失败"
chmod 644 "$KUAL_DIR/config.xml" "$KUAL_DIR/menu.json" 2>/dev/null || true
diag "installed KUAL fallback: $(ls -l "$KUAL_DIR" 2>&1 | tr '\n' ' ')"

cp "$PKG/native-reading-time-daemon.sh" "$BASE/bin/native-reading-time-daemon.sh.new" || fail "复制统计服务失败"
chmod 755 "$BASE/bin/native-reading-time-daemon.sh.new" || fail "设置统计服务权限失败"
mv -f "$BASE/bin/native-reading-time-daemon.sh.new" "$BASE/bin/native-reading-time-daemon.sh" || fail "替换统计服务失败"

machine="$(uname -m 2>/dev/null)"
case "$machine" in
    aarch64|arm64) sync_binary="$PKG/bin/reading-syncd-arm64" ;;
    arm*|*) sync_binary="$PKG/bin/reading-syncd-armv7" ;;
esac
cp "$sync_binary" "$BASE/bin/reading-syncd.new" || fail "复制同步服务失败"
chmod 755 "$BASE/bin/reading-syncd.new" || fail "设置同步服务权限失败"
mv -f "$BASE/bin/reading-syncd.new" "$BASE/bin/reading-syncd" || fail "替换同步服务失败"
diag "sync binary installed: machine=$machine source=$sync_binary"

hardware_id="$(sed -n '1p' /proc/usid 2>/dev/null | tr -cd 'A-Za-z0-9')"
if [ -n "$hardware_id" ] && command -v md5sum >/dev/null 2>&1; then
    hardware_hash="$(printf '%s' "$hardware_id" | md5sum | awk '{print $1}')"
    printf 'kindle-%s\n' "$hardware_hash" > "$BASE/device-id" || fail "创建设备标识失败"
elif [ ! -s "$BASE/device-id" ]; then
    new_device_id="$(sed -n '1p' /proc/sys/kernel/random/uuid 2>/dev/null | tr -cd 'A-Za-z0-9-')"
    [ -n "$new_device_id" ] || new_device_id="kindle-$(date +%s)-$$"
    printf '%s\n' "$new_device_id" > "$BASE/device-id" || fail "创建设备标识失败"
fi
chmod 600 "$BASE/device-id" 2>/dev/null || true
diag "sync identity ready: $(wc -c < "$BASE/device-id" 2>/dev/null) bytes"

"$BASE/bin/reading-syncd" --migrate-only >> "$BASE/sync.log" 2>&1 || fail "迁移历史同步数据失败"
diag "sync journal ready: $(wc -l < "$BASE/sync-events.tsv" 2>/dev/null) lines"

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

if mntroot rw >/dev/null 2>&1 || /usr/sbin/mntroot rw >/dev/null 2>&1 || /sbin/mntroot rw >/dev/null 2>&1; then ROOT_RW=1; else fail "无法写入系统服务"; fi
restore_ro(){ if [ "$ROOT_RW" = 1 ]; then mntroot ro >/dev/null 2>&1 || /usr/sbin/mntroot ro >/dev/null 2>&1 || /sbin/mntroot ro >/dev/null 2>&1 || true; ROOT_RW=0; fi; }
trap restore_ro EXIT INT TERM HUP
cp "$PKG/native-reading-time.conf" "$CONF.new" || fail "复制系统服务失败"
cp "$PKG/reading-sync.conf" "$SYNC_CONF.new" || fail "复制同步系统服务失败"
chmod 644 "$CONF.new" || fail "设置系统服务权限失败"
chmod 644 "$SYNC_CONF.new" || fail "设置同步系统服务权限失败"
mv -f "$CONF.new" "$CONF" || fail "替换系统服务失败"
mv -f "$SYNC_CONF.new" "$SYNC_CONF" || fail "替换同步系统服务失败"
/sbin/initctl reload-configuration >/dev/null 2>&1 || true
restore_ro
trap - EXIT INT TERM HUP

/sbin/initctl start "$JOB" >/dev/null 2>&1 || true
/sbin/initctl start "$SYNC_JOB" >/dev/null 2>&1 || true
sleep 1
diag "service status: $(/sbin/initctl status "$JOB" 2>&1)"
diag "sync service status: $(/sbin/initctl status "$SYNC_JOB" 2>&1)"
diag "installed launcher: $(ls -l "$DOC" 2>&1)"
diag "installed UI files: $(ls "$APP" 2>&1 | tr '\n' ' ')"
lipc-set-prop com.lab126.scanner doFullScan 1 >/dev/null 2>&1 || lipc-set-prop com.lab126.scanner triggerUpdate 1 >/dev/null 2>&1 || true
sync
say "installed successfully; handler=$APP_ID; UI=$UI_VERSION; launcher=ReadingRecords.sh; kual=installed; data=preserved"
diag "INSTALL OK handler=$APP_ID ui=$UI_VERSION launcher=$DOC kual=$KUAL_DIR"
rootlog "installed successfully; detailed logs are inside /mnt/us/reading-time"
toast "阅读记录 v1.3 已安装"
exit 0
