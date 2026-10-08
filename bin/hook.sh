#!/bin/sh
# Devin lifecycle hook for Meticulous agent traces.
#
# Spools each event's stdin payload for the uploader and, at session and turn
# boundaries, starts an upload in the background.
#
# Devin runs this synchronously on every tool call, so it must stay cheap:
# plain POSIX sh, no JSON parsing (the uploader groups events by session).
# It must also stay silent and always exit 0, because Devin parses stdout as
# hook output and exit code 2 would block the agent's action.
#
# Usage: hook.sh <EventName>   (the event payload is read from stdin)

event="${1:-unknown}"
data_dir="$HOME/.meticulous/agent-traces"
# Must match getDevinSpoolDir() in src/config/paths.ts.
spool_dir="$data_dir/devin/spool"
max_payload_bytes=20971520

main() {
  umask 077
  if is_opted_out; then
    cat >/dev/null
    return 0
  fi
  spool_event
  case "$event" in
    SessionStart | Stop | SessionEnd) start_upload ;;
  esac
}

# Mirrors the uploader's own check, so opting out also stops local spooling.
is_opted_out() {
  grep -Eq '"enabled"[[:space:]]*:[[:space:]]*false' \
    "$HOME/.meticulous/traces-config.json" 2>/dev/null
}

spool_event() {
  mkdir -p "$spool_dir" || return 0
  # Dot-prefixed files are ignored by the uploader until renamed below.
  payload_file="$(mktemp "$spool_dir/.payload.XXXXXX")" || return 0
  head -c "$max_payload_bytes" >"$payload_file"
  # Drains anything past the cap, so Devin's write never fails.
  cat >/dev/null
  if [ ! -s "$payload_file" ]; then
    printf 'null' >"$payload_file"
  fi
  event_file="$payload_file.event"
  {
    printf '{"version":1,"event":%s,"receivedAtSec":%s,"projectDir":%s,"cwd":%s,"payload":' \
      "$(json_string_or_null "$event")" \
      "$(date +%s)" \
      "$(json_string_or_null "${DEVIN_PROJECT_DIR:-}")" \
      "$(json_string_or_null "$PWD")"
    cat "$payload_file"
    printf '}\n'
  } >"$event_file"
  rm -f "$payload_file"
  # The uploader orders events by mtime, which mv preserves.
  mv "$event_file" "$spool_dir/$(date +%s)-${payload_file##*.}.json"
}

json_string_or_null() {
  if [ -z "$1" ]; then
    printf 'null'
    return
  fi
  printf '"%s"' "$(printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

start_upload() {
  plugin_root="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)" || return 0
  set -- "$plugin_root/bin/run-uploader.sh" upload --agent devin \
    --min-quiet-minutes 0 --wait-for-lock-seconds 100
  # For environments that kill background processes when the turn ends.
  if [ "${METICULOUS_AGENT_TRACES_FOREGROUND_UPLOAD:-}" = "1" ]; then
    sh "$@" </dev/null >/dev/null 2>"$data_dir/devin/last-upload.log"
  else
    nohup sh "$@" </dev/null >/dev/null 2>"$data_dir/devin/last-upload.log" &
  fi
}

main >/dev/null 2>&1
exit 0
