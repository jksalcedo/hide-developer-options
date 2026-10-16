#!/system/bin/sh
# Hides Developer options / USB debugging from apps listed in packages.txt
# while they launch or are top-app. Only writes settings; never touches the app.

DIR=/data/adb/hide_developer_options
PKGS=$DIR/packages.txt
STATE=$DIR/original.state
LOG=$DIR/log.txt
PIDFILE=$DIR/daemon.pid
HIT=$DIR/hit

# Defaults, overridable in $DIR/config.sh
POLL=1                # seconds between top-app checks
RESTORE_DELAY=3       # seconds after app leaves top before restoring
LAUNCH_GRACE=10       # minimum spoof time after a launch event
HOLD_WHILE_RUNNING=0  # 1 = stay spoofed while the app process is alive
KEYS="global:development_settings_enabled global:adb_enabled global:adb_wifi_enabled"

mkdir -p "$DIR"
[ -f "$PKGS" ] || printf '# One package name per line\n' > "$PKGS"
[ -f "$DIR/config.sh" ] && . "$DIR/config.sh"
[ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 200000 ] && : > "$LOG"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then exit 0; fi
echo $$ > "$PIDFILE"
MAIN_PID=$$

# ---- settings (cmd settings -> settings -> content provider, verified) ----

sget() {
  v=$(cmd settings get "$1" "$2" 2>/dev/null </dev/null)
  [ -n "$v" ] || v=$(settings get "$1" "$2" 2>/dev/null </dev/null)
  [ -n "$v" ] || v=$(content query --uri "content://settings/$1" --where "name='$2'" 2>/dev/null </dev/null | sed -n 's/.*value=\([^,]*\).*/\1/p')
  echo "${v:-null}"
}

sput() {
  [ "$(sget "$1" "$2")" = "$3" ] && return 0
  for m in cmd settings update insert; do
    case $m in
      cmd)      cmd settings put "$1" "$2" "$3" ;;
      settings) settings put "$1" "$2" "$3" ;;
      update)   content update --uri "content://settings/$1" --bind "value:s:$3" --where "name='$2'" ;;
      insert)   content insert --uri "content://settings/$1" --bind "name:s:$2" --bind "value:s:$3" ;;
    esac >/dev/null 2>&1 </dev/null
    [ "$(sget "$1" "$2")" = "$3" ] && return 0
  done
  log "WARN: could not set $1/$2=$3"
  return 1
}

sdel() {
  for m in cmd settings content; do
    case $m in
      cmd)      cmd settings delete "$1" "$2" ;;
      settings) settings delete "$1" "$2" ;;
      content)  content delete --uri "content://settings/$1" --where "name='$2'" ;;
    esac >/dev/null 2>&1 </dev/null
    [ "$(sget "$1" "$2")" = null ] && return 0
  done
  return 1
}

SPOOFED=0

spoof() {
  [ "$SPOOFED" = 1 ] && return 0
  : > "$STATE.tmp"
  for e in $KEYS; do echo "$e=$(sget "${e%%:*}" "${e#*:}")" >> "$STATE.tmp"; done
  mv "$STATE.tmp" "$STATE"   # saved first, so a crash or reboot can recover
  for e in $KEYS; do sput "${e%%:*}" "${e#*:}" 0; done
  SPOOFED=1
  log "spoofed ($(tr '\n' ' ' < "$STATE"))"
}

restore() {
  [ -f "$STATE" ] || { SPOOFED=0; return 0; }
  fail=0
  for line in $(cat "$STATE"); do
    ns=${line%%:*}; rest=${line#*:}; k=${rest%%=*}; v=${rest#*=}
    if [ "$v" = null ]; then sdel "$ns" "$k" || fail=1
    else sput "$ns" "$k" "$v" || fail=1; fi
  done
  if [ "$fail" = 0 ]; then rm -f "$STATE"; SPOOFED=0; log "restored"
  else log "restore incomplete, retrying"; fi
}

# ---- app detection ----

pkgs() { grep -v -e '^#' -e '^$' "$PKGS"; }
is_listed() { [ -n "$1" ] && pkgs | grep -Fxq -- "$1"; }

match_in_line() {
  for p in $(pkgs); do
    case "$1" in *"$p"*) echo "$p"; return 0 ;; esac
  done
  return 1
}

any_running() {
  for p in $(pkgs); do pidof "$p" >/dev/null 2>&1 && return 0; done
  return 1
}

extract() { sed -n 's/.* \([A-Za-z][A-Za-z0-9_.]*\)\/.*/\1/p'; }

top_pkg() {
  p=$(dumpsys activity activities 2>/dev/null | grep -E 'topResumedActivity=|ResumedActivity[:=]' | extract | head -n1)
  [ -n "$p" ] || p=$(dumpsys window 2>/dev/null | grep -E 'mCurrentFocus=|mFocusedApp=' | extract | head -n1)
  [ -n "$p" ] || p=$(dumpsys activity top 2>/dev/null | grep 'ACTIVITY ' | extract | head -n1)
  echo "$p"
}

# Early trigger from the events log, so we spoof before the app's first read.
start_watcher() {
  ( logcat -b events -T 1 -v brief -s am_proc_start:I wm_create_activity:I am_create_activity:I 2>/dev/null |
    while IFS= read -r line; do
      p=$(match_in_line "$line") && { echo "$p" > "$HIT"; kill -USR1 "$MAIN_PID" 2>/dev/null; }
    done ) &
  WATCHER=$!
}

cleanup() {
  [ -n "$CLEANED" ] && return
  CLEANED=1
  restore
  pkill -f 'logcat -b events -T 1 -v brief -s am_proc_start' 2>/dev/null
  rm -f "$PIDFILE" "$HIT"
}

# ---- main ----

trap 'cleanup; exit 0' TERM INT HUP
trap cleanup EXIT
trap : USR1

until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 3; done
until [ -n "$(cmd settings get global adb_enabled 2>/dev/null </dev/null)$(settings get global adb_enabled 2>/dev/null </dev/null)" ]; do sleep 2; done

[ -f "$STATE" ] && { SPOOFED=1; restore; }   # recover from a previous crash

log "started"
start_watcher

last_hit=0; grace_until=0; tick=0
while :; do
  read -r up _ < /proc/uptime; now=${up%.*}

  if [ -f "$HIT" ]; then
    rm -f "$HIT"; spoof
    last_hit=$now; grace_until=$((now + LAUNCH_GRACE))
  fi

  if is_listed "$(top_pkg)"; then
    spoof; last_hit=$now
  elif [ "$HOLD_WHILE_RUNNING" = 1 ] && any_running; then
    last_hit=$now
  fi

  if [ "$SPOOFED" = 1 ] && [ "$now" -ge "$grace_until" ] && [ $((now - last_hit)) -ge "$RESTORE_DELAY" ]; then
    restore
  fi

  tick=$((tick + 1))
  [ $((tick % 30)) -eq 0 ] && ! kill -0 "$WATCHER" 2>/dev/null && start_watcher

  [ -f "$HIT" ] || { sleep "$POLL" & wait $!; }
done
