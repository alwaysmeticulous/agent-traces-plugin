#!/bin/sh
# Meticulous agent traces hook, shared by every agent traced through hooks:
# the Devin plugin, and the hooks `meticulous-agent-traces install-repo-hooks`
# commits to a repository for Claude Code, Cursor and Conductor.
#
# For agents that keep no usable transcript of their own (Devin, and Cursor's
# tool outputs), it spools each event's stdin payload for the uploader. At
# turn and session boundaries it starts an upload in the background.
#
# Copies committed to a repository never update themselves, so they hand over
# to the newest released copy that run-uploader.sh has cached, if any.
#
# Agents run this synchronously, some on every tool call, so it must stay
# cheap: plain POSIX sh, no JSON parsing (the uploader groups events by
# session) and no network outside the backgrounded upload. It must also
# always exit 0 and print nothing (or, for Cursor, which counts empty output
# as a failed hook, an empty JSON object), because agents parse stdout as
# hook output and exit code 2 would block the agent's action.
#
# Usage: hook.sh <agent> <EventName>   (the event payload is read from stdin)
#        hook.sh <EventName>           (the Devin plugin's original form)

if [ $# -ge 2 ]; then
  agent="$1"
  event="$2"
else
  agent="devin"
  event="${1:-unknown}"
fi
bin_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
data_dir="$HOME/.meticulous/agent-traces"
# Must match kit_dir in run-uploader.sh.
latest_kit_bin_dir="$data_dir/kit/current/bin"

# Only repository copies: the Devin plugin pins its release in release.txt,
# and copies installed with the binary update with it.
if [ -z "${METICULOUS_AGENT_TRACES_LATEST_KIT:-}" ] &&
  [ -f "$bin_dir/run-uploader.sh" ] && [ ! -f "$bin_dir/release.txt" ] &&
  [ -f "$latest_kit_bin_dir/hook.sh" ]; then
  METICULOUS_AGENT_TRACES_LATEST_KIT=1 exec sh "$latest_kit_bin_dir/hook.sh" "$@"
fi

# Must match getSpoolDir() in src/config/paths.ts.
spool_dir="$data_dir/$agent/spool"
system_dir="/Library/Application Support/Meticulous/agent-traces"
system_config="$system_dir/config.json"
max_payload_bytes=20971520

main() {
  umask 077
  if is_opted_out || ! has_token || defers_to_installed_hook; then
    cat >/dev/null
    return 0
  fi
  if should_spool; then
    spool_event
  else
    cat >/dev/null
  fi
  case "$agent:$event" in
    devin:SessionStart | devin:Stop | devin:SessionEnd)
      start_upload --agent devin ;;
    # The transcript is written asynchronously and may lag the hook.
    claude-code:Stop | claude-code:SessionEnd)
      start_upload --agent claude-code --delay-seconds 5 ;;
    # A cloud VM starts empty: download the uploader while the agent works,
    # so the first turn's upload is quick and uses the latest hooks.
    claude-code:SessionStart | cursor:beforeSubmitPrompt)
      prepare_uploader ;;
    cursor:stop)
      start_upload --agent cursor --delay-seconds 5 ;;
    # The workspace is about to go, so upload every agent's sessions now.
    conductor:archive)
      foreground=1
      start_upload ;;
  esac
}

# Mirrors the uploader's own check, so opting out also stops local spooling.
is_opted_out() {
  grep -Eq '"enabled"[[:space:]]*:[[:space:]]*false' \
    "$HOME/.meticulous/traces-config.json" 2>/dev/null
}

# Without a token nothing would ever upload, or prune, what's spooled.
has_token() {
  [ -n "${METICULOUS_AGENT_TRACES_TOKEN:-}" ] ||
    [ -f "$data_dir/config.json" ] ||
    [ -f "$system_config" ]
}

# Cursor runs every hooks.json it finds, so a repository's copy defers to one
# `install --cursor-hooks` registered for the machine, rather than spooling
# each event twice. Must match installCursorHooks() in the uploader.
defers_to_installed_hook() {
  [ "$agent" = "cursor" ] || return 1
  case "$bin_dir" in
    "$data_dir/bin" | "$system_dir/bin") return 1 ;;
  esac
  grep -qF "$data_dir/bin/hook.sh" "$HOME/.cursor/hooks.json" 2>/dev/null ||
    grep -qF "$system_dir/bin/hook.sh" \
      "/Library/Application Support/Cursor/hooks.json" 2>/dev/null
}

should_spool() {
  case "$agent:$event" in
    devin:*) return 0 ;;
    cursor:beforeSubmitPrompt | cursor:afterAgentResponse | \
      cursor:afterAgentThought | cursor:postToolUse | \
      cursor:postToolUseFailure | cursor:subagentStart | \
      cursor:subagentStop | cursor:preCompact | cursor:stop)
      return 0 ;;
    *) return 1 ;;
  esac
}

spool_event() {
  mkdir -p "$spool_dir" || return 0
  # Dot-prefixed files are ignored by the uploader until renamed below.
  payload_file="$(mktemp "$spool_dir/.payload.XXXXXX")" || return 0
  head -c "$max_payload_bytes" >"$payload_file"
  # Drains anything past the cap, so the agent's write never fails.
  cat >/dev/null
  if [ ! -s "$payload_file" ]; then
    printf 'null' >"$payload_file"
  fi
  event_file="$payload_file.event"
  {
    printf '{"version":1,"event":%s,"receivedAtSec":%s,"projectDir":%s,"cwd":%s,"payload":' \
      "$(json_string_or_null "$event")" \
      "$(date +%s)" \
      "$(json_string_or_null "${DEVIN_PROJECT_DIR:-${CURSOR_PROJECT_DIR:-}}")" \
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

# Devin's plugin is also how Devin CLI and Desktop sessions upload on machines
# without the LaunchAgent, using the config file's token. Hooks committed to a
# repository also fire on developers' machines, where the LaunchAgent uploads,
# so they only upload when the environment supplies a token, as cloud agents'
# secrets do. The binary is only installed alongside run-uploader.sh.
start_upload() {
  if [ ! -f "$bin_dir/run-uploader.sh" ]; then
    return 0
  fi
  if [ "$agent" != "devin" ] && [ -z "${METICULOUS_AGENT_TRACES_TOKEN:-}" ]; then
    return 0
  fi
  mkdir -p "$data_dir/$agent" || return 0
  log_file="$data_dir/$agent/last-upload.log"
  set -- "$bin_dir/run-uploader.sh" upload --min-quiet-minutes 0 \
    --wait-for-lock-seconds 100 "$@"
  # For environments that kill background processes when the turn ends.
  if [ "${foreground:-}" = "1" ] ||
    [ "${METICULOUS_AGENT_TRACES_FOREGROUND_UPLOAD:-}" = "1" ]; then
    sh "$@" </dev/null >/dev/null 2>"$log_file"
  else
    nohup sh "$@" </dev/null >/dev/null 2>"$log_file" &
  fi
}

# Downloads (and checks) the uploader and the latest hooks, once per machine.
prepare_uploader() {
  if [ -d "$data_dir/kit/current" ] || [ ! -f "$bin_dir/run-uploader.sh" ] ||
    [ -z "${METICULOUS_AGENT_TRACES_TOKEN:-}" ]; then
    return 0
  fi
  mkdir -p "$data_dir/$agent" || return 0
  nohup sh "$bin_dir/run-uploader.sh" version </dev/null >/dev/null \
    2>"$data_dir/$agent/last-prepare.log" &
}

main >/dev/null 2>&1
if [ "$agent" = "cursor" ]; then
  printf '{}\n'
fi
exit 0
