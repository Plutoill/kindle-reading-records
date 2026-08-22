#!/bin/sh

BASE="/mnt/us/reading-time"
DATA="$BASE/reading-time.tsv"
SESSIONS="$BASE/reading-sessions.tsv"
EVENTS="$BASE/sync-events.tsv"
DEVICE_FILE="$BASE/device-id"
SEQUENCE_FILE="$BASE/event-sequence"
DATA_LOCK="$BASE/.data-lock"
STATE="$BASE/state"
REPORT="$BASE/阅读时长统计.txt"
LOG="$BASE/service.log"
READING_INTERVAL=5
ACTIVE_INTERVAL=5
LOCKED_INTERVAL=60
SAVE_INTERVAL=90
STATE_INTERVAL=90
EDGE_CREDIT_MAX=5

rotate_log(){
    rotate_path="$1"; rotate_limit="$2"
    [ -f "$rotate_path" ] || return 0
    rotate_size="$(wc -c < "$rotate_path" 2>/dev/null)"
    case "$rotate_size" in ''|*[!0-9]*) return 0;; esac
    [ "$rotate_size" -lt "$rotate_limit" ] && return 0
    rm -f "$rotate_path.1" 2>/dev/null || true
    mv -f "$rotate_path" "$rotate_path.1" 2>/dev/null || true
}

mkdir -p "$BASE"
umask 077
rotate_log "$LOG" 131072
[ -f "$DATA" ] || printf 'date\tbook_id\tseconds\ttitle\n' > "$DATA"
[ -f "$SESSIONS" ] || printf 'date\tstart\tend\tbook_id\ttitle\n' > "$SESSIONS"
[ -f "$EVENTS" ] || printf 'event_id\torigin\tsequence\ttype\tdate\tstart\tend\tbook_id\tseconds\ttitle\tcreated_at\n' > "$EVENTS"

device_id="$(sed -n '1p' "$DEVICE_FILE" 2>/dev/null | tr -cd 'A-Za-z0-9._-')"
[ -n "$device_id" ] || device_id="kindle-unknown"

data_lock() {
    lock_try=0
    while ! mkdir "$DATA_LOCK" 2>/dev/null; do
        lock_owner="$(sed -n '1p' "$DATA_LOCK/pid" 2>/dev/null)"
        case "$lock_owner" in ''|*[!0-9]*) :;; *) kill -0 "$lock_owner" 2>/dev/null || { rm -f "$DATA_LOCK/pid" 2>/dev/null; rmdir "$DATA_LOCK" 2>/dev/null; };; esac
        lock_try=$((lock_try+1)); [ "$lock_try" -ge 10 ] && return 1; sleep 1
    done
    printf '%s\n' "$$" > "$DATA_LOCK/pid"
    return 0
}
data_unlock() { rm -f "$DATA_LOCK/pid" 2>/dev/null; rmdir "$DATA_LOCK" 2>/dev/null || true; }
next_event_id() {
    event_seq="$(sed -n '1p' "$SEQUENCE_FILE" 2>/dev/null)"
    case "$event_seq" in ''|*[!0-9]*) event_seq=0;; esac
    event_seq=$((event_seq+1))
    printf '%s\n' "$event_seq" > "$SEQUENCE_FILE.tmp" && mv "$SEQUENCE_FILE.tmp" "$SEQUENCE_FILE"
    event_id="$device_id:$event_seq"
}

prop() { lipc-get-prop "$1" "$2" 2>/dev/null; }

decode_url() {
    printf '%s\n' "$1" | awk '
    function hex(c) { return index("0123456789ABCDEF", toupper(c)) - 1 }
    { out=""; for(i=1;i<=length($0);i++){ c=substr($0,i,1); if(c=="%"&&i+2<=length($0)){h1=hex(substr($0,i+1,1));h2=hex(substr($0,i+2,1));if(h1>=0&&h2>=0){out=out sprintf("%c",h1*16+h2);i+=2}else out=out c}else if(c=="+")out=out " ";else out=out c} print out }'
}

read_book() {
    context="$1"
    metadata="$2"
    book_id="$(printf '%s' "$metadata" | sed -n 's/.*"cdeKey":"\([^"]*\)".*/\1/p')"
    [ -n "$book_id" ] || book_id="$(printf '%s' "$context" | sed -n 's/.*_\([A-Fa-f0-9][A-Fa-f0-9]*\)\.kfx.*/\1/p')"
    [ -n "$book_id" ] || book_id="unknown"
    encoded="$(printf '%s' "$context" | sed -n 's|.*file://\([^?]*\).*|\1|p')"
    decoded="$(decode_url "$encoded")"
    book_title="${decoded##*/}"
    book_title="$(printf '%s' "$book_title" | sed "s/_${book_id}\.kfx$//;s/\.kfx$//;s/[\t\r\n]/ /g")"
    [ -n "$book_title" ] || book_title="$book_id"
}

format_time() {
    n="$1"; h=$((n/3600)); m=$(((n%3600)/60)); s=$((n%60))
    if [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"; elif [ "$m" -gt 0 ]; then printf '%dm %ds' "$m" "$s"; else printf '%ds' "$s"; fi
}


write_report() {
    report_total="$(awk -F '\t' 'NR>1{s+=$3}END{print s+0}' "$DATA")"
    report_today="$(awk -F '\t' -v d="$(date +%Y-%m-%d)" 'NR>1&&$1==d{s+=$3}END{print s+0}' "$DATA")"
    {
        echo "Kindle 原生阅读时长统计"
        echo "更新时间：$(date)"
        echo "服务状态：运行中（PID $$）"
        echo "当前状态：$service_state"
        echo "计时方式：原生阅读器前台且屏幕亮起"
        echo "今日阅读：$(format_time "$report_today")"
        echo "累计阅读：$(format_time "$report_total")"
        echo
        echo "按书籍统计："
        awk -F '\t' 'NR>1{k=$2 SUBSEP $4;s[k]+=$3}END{for(k in s){split(k,a,SUBSEP);print s[k]"\t"a[2]"\t"a[1]}}' "$DATA" | sort -nr | awk -F '\t' '{h=int($1/3600);m=int(($1%3600)/60);s=$1%60;if(h>0)t=h"h "m"m";else if(m>0)t=m"m "s"s";else t=s"s";print "- "$2": "t" ("$3")"}'
    } > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
}

bucket=0; bucket_id=""; bucket_title=""; bucket_date=""
flush() {
    if [ "$bucket" -gt 0 ] && [ -n "$bucket_id" ]; then
        if data_lock; then
            next_event_id
            printf '%s\t%s\t%s\tD\t%s\t\t\t%s\t%s\t%s\t%s\n' "$event_id" "$device_id" "$event_seq" "$bucket_date" "$bucket_id" "$bucket" "$bucket_title" "$(date +%s)" >> "$EVENTS"
            printf '%s\t%s\t%s\t%s\n' "$bucket_date" "$bucket_id" "$bucket" "$bucket_title" >> "$DATA"
            data_unlock
        else
            echo "$(date): WARNING data lock timeout while saving duration" >> "$LOG"
        fi
    fi
    bucket=0; bucket_id=""; bucket_title=""; bucket_date=""
}
session_start=""
session_date=""
session_id=""
session_title=""
flush_session() {
    [ -n "$session_start" ] || return
    end_epoch="$(date +%s)"
    end_clock="$(date +%H:%M:%S)"
    [ -n "$session_date" ] || session_date="$(date +%Y-%m-%d)"
    if data_lock; then
        next_event_id
        printf '%s\t%s\t%s\tS\t%s\t%s\t%s\t%s\t0\t%s\t%s\n' "$event_id" "$device_id" "$event_seq" "$session_date" "$session_start" "$end_clock" "$session_id" "$session_title" "$end_epoch" >> "$EVENTS"
        printf '%s\t%s\t%s\t%s\t%s\n' "$session_date" "$session_start" "$end_clock" "$session_id" "$session_title" >> "$SESSIONS"
        data_unlock
    else
        echo "$(date): WARNING data lock timeout while saving session" >> "$LOG"
    fi
    session_start=""; session_date=""; session_id=""; session_title=""
}
cleanup() { flush; flush_session; service_state="已停止"; write_report; }
trap 'cleanup; trap - INT TERM HUP EXIT; exit 0' INT TERM HUP
trap cleanup EXIT

write_state() {
    state_now="$1"
    printf 'state=%s\npid=%s\napp=%s\npower=%s\nbook_id=%s\ntitle=%s\nlast_update=%s\n' "$service_state" "$$" "$app" "$power" "$current_id" "$current_title" "$state_now" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
    last_state_write="$state_now"
}

add_edge_credit() {
    edge_delta="$1"
    edge_id="$2"
    edge_title="$3"
    edge_date="$4"
    edge_credit=$((edge_delta/2))
    [ "$edge_credit" -gt "$EDGE_CREDIT_MAX" ] && edge_credit="$EDGE_CREDIT_MAX"
    if [ "$edge_credit" -gt 0 ] && [ -n "$edge_id" ]; then
        bucket_id="$edge_id"; bucket_title="$edge_title"; bucket_date="$edge_date"
        bucket=$((bucket+edge_credit))
    fi
}

wait_next() {
    wait_mode="$1"
    wait_seconds="$2"
    if [ "$wait_mode" = "locked" ] && command -v lipc-wait-event >/dev/null 2>&1; then
        # Wake immediately with the framework instead of waiting for the full
        # locked interval. Timeout remains a low-frequency safety fallback.
        # If this firmware rejects the event syntax, sleep the remaining time
        # so a failed command can never turn into a battery-draining busy loop.
        wait_started="$(date +%s)"
        if ! lipc-wait-event -s "$wait_seconds" com.lab126.powerd outOfScreenSaver >/dev/null 2>&1; then
            wait_ended="$(date +%s)"
            wait_remaining=$((wait_seconds-(wait_ended-wait_started)))
            [ "$wait_remaining" -gt 0 ] && sleep "$wait_remaining"
        fi
    else
        sleep "$wait_seconds"
    fi
}

previous="$(date +%s)"; was_reader=0; current_id=""; current_title=""; service_state="等待阅读"; last_state=""; last_state_write=0
echo "$(date): upstart service started, pid=$$, timing=foreground-reader-active-screen" >> "$LOG"
write_report

while :; do
    now="$(date +%s)"; today="$(date +%Y-%m-%d)"
    delta=$((now-previous))
    app="$(prop com.lab126.appmgrd activeApp)"; power="$(prop com.lab126.powerd state)"
    reader=0; interval="$ACTIVE_INTERVAL"; wait_mode="active"
    [ "$app" = "com.lab126.booklet.reader" ] && [ "$power" = "active" ] && reader=1

    # Detailed book properties are intentionally skipped outside an active
    # reading session. A sleeping Kindle only gets the two lightweight
    # app/power checks above.
    if [ "$reader" -eq 1 ]; then
        interval="$READING_INTERVAL"
        context="$(prop com.lab126.appmgrd activeContext)"; metadata="$(prop com.lab126.yjr.annotations getCurrentBookMetadata)"
        read_book "$context" "$metadata"
        if [ "$was_reader" -eq 1 ] && [ -n "$current_id" ] && [ "$current_id" != "$book_id" ]; then
            # A book switch is a persistence boundary: never mix two books in
            # one bucket, and save the old book immediately.
            flush; flush_session; service_state="切换书籍"; write_report
        fi
        if [ "$was_reader" -eq 0 ] || [ "$current_id" != "$book_id" ]; then
            current_id="$book_id"; current_title="$book_title"
            if [ "$was_reader" -eq 1 ]; then
                session_start="$(date +%H:%M:%S)"; session_date="$today"; session_id="$current_id"; session_title="$current_title"
            fi
        fi
        if [ "$was_reader" -eq 0 ]; then
            session_start="$(date +%H:%M:%S)"
            session_date="$today"
            session_id="$current_id"
            session_title="$current_title"
            # Sampling can observe an app transition only after it happened.
            # Attribute half of the bounded interval to the new session; this
            # avoids dropping the whole leading edge without overcounting it.
            add_edge_credit "$delta" "$current_id" "$current_title" "$today"
        fi
    elif [ "$power" != "active" ]; then
        interval="$LOCKED_INTERVAL"
        wait_mode="locked"
    fi
    service_state="等待阅读"
    if [ "$was_reader" -eq 1 ] && [ "$reader" -eq 1 ] && [ "$delta" -gt 0 ] && [ "$delta" -le 15 ]; then
        # Foreground timing rule: while the native book reader is in front and
        # the screen is active, the whole interval counts as reading. This is
        # deliberately independent of page-turn, PC:TS, dialog, or touch
        # signals because those are not consistent across books and firmware.
        # Split the bucket at midnight so time lands on the correct day.
        if [ -n "$bucket_date" ] && [ "$bucket_date" != "$today" ]; then
            flush; flush_session; write_report
            session_start="00:00:00"; session_date="$today"; session_id="$current_id"; session_title="$current_title"
        fi
        service_state="正在阅读"; bucket_id="$current_id"; bucket_title="$current_title"; bucket_date="$today"; bucket=$((bucket+delta))
        if [ "$bucket" -ge "$SAVE_INTERVAL" ]; then flush; write_report; fi
    elif [ "$was_reader" -eq 1 ] && [ "$reader" -eq 0 ]; then
        # Leaving the reader or locking the screen saves immediately.
        add_edge_credit "$delta" "$current_id" "$current_title" "$today"
        flush
        flush_session
        [ "$power" = "active" ] && service_state="已退出阅读" || service_state="锁屏暂停"
        write_report
    elif [ "$power" != "active" ]; then
        service_state="锁屏暂停"
    fi

    # Avoid the old two-second state-file write.  Persist periodically or
    # whenever the visible service state changes.
    if [ "$service_state" != "$last_state" ] || [ $((now-last_state_write)) -ge "$STATE_INTERVAL" ]; then
        write_state "$now"
        last_state="$service_state"
    fi
    previous="$now"; was_reader="$reader"; wait_next "$wait_mode" "$interval"
done
