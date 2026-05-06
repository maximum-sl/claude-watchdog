#!/usr/bin/env bash
# claude-watchdog: runs scheduled Claude jobs outside interactive sessions.
# Called by launchd every N seconds. Each job is a standalone `claude -p` call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_HOME="${WATCHDOG_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
JOBS_DIR="${WATCHDOG_JOBS_DIR:-$WATCHDOG_HOME/jobs}"
LOGS_DIR="${WATCHDOG_LOGS_DIR:-$WATCHDOG_HOME/logs}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$WATCHDOG_HOME/state}"
STATE_FILE="$STATE_DIR/watchdog.state.json"
LOCK_FILE="$STATE_DIR/.watchdog.lock"

# Schedule intervals in seconds (bash 3.2 compatible, no associative arrays)
get_interval() {
  case "$1" in
    every_10m) echo 600 ;;
    every_30m) echo 1800 ;;
    every_1h)  echo 3600 ;;
    every_2h)  echo 7200 ;;
    every_4h)  echo 14400 ;;
    every_6h)  echo 21600 ;;
    every_8h)  echo 28800 ;;
    every_12h) echo 43200 ;;
    every_24h) echo 86400 ;;
    *)         echo 0 ;;
  esac
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

cleanup() {
  rm -f "$LOCK_FILE"
}

mkdir -p "$LOGS_DIR" "$STATE_DIR"

# --- Lock check ---
if [[ -f "$LOCK_FILE" ]]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    log "Another watchdog is running (PID $OLD_PID). Exiting."
    exit 0
  fi
  log "Stale lock found (PID $OLD_PID). Removing."
  rm -f "$LOCK_FILE"
fi

echo $$ > "$LOCK_FILE"
trap cleanup EXIT

# --- Log rotation (rotate at 500KB, keep 5 copies) ---
rotate_log() {
  local logfile="$1"
  local max_bytes=$((500 * 1024))
  [[ -f "$logfile" ]] || return 0
  local size
  size=$(wc -c < "$logfile" 2>/dev/null || echo 0)
  if [[ "$size" -gt "$max_bytes" ]]; then
    for i in 4 3 2 1; do
      [[ -f "${logfile}.${i}" ]] && mv "${logfile}.${i}" "${logfile}.$((i+1))"
    done
    mv "$logfile" "${logfile}.1"
    log "Log rotated: ${logfile} (was ${size} bytes)"
  fi
}
rotate_log "$LOGS_DIR/watchdog-stdout.log"
rotate_log "$LOGS_DIR/watchdog-stderr.log"

# --- Check claude CLI ---
if ! command -v claude &>/dev/null; then
  log "ERROR: 'claude' CLI not found on PATH. Install it from https://docs.anthropic.com/en/docs/claude-code"
  exit 1
fi

# --- Init state file ---
if [[ ! -f "$STATE_FILE" ]]; then
  echo '{}' > "$STATE_FILE"
fi

# --- Parse YAML frontmatter ---
parse_frontmatter() {
  local file="$1"
  python3 -c "
import sys, re

content = open('$file').read()
match = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not match:
    sys.exit(1)

fm = {}
for line in match.group(1).strip().split('\n'):
    if ':' in line:
        key, val = line.split(':', 1)
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in (chr(34), chr(39)):
            val = val[1:-1]
        if val == 'null':
            val = ''
        fm[key.strip()] = val

# Resolve model: model_tier takes precedence over model.
# Tier names map to current Claude model IDs as of 2026.
tier_map = {
    'fast': 'claude-haiku-4-5-20251001',
    'balanced': 'claude-sonnet-4-6',
    'full': 'claude-opus-4-7',
}
model_tier = fm.get('model_tier', '')
model = tier_map.get(model_tier, fm.get('model', 'sonnet'))

# Tab-separated output. '_NONE_' placeholder prevents bash read from collapsing tabs.
fields = [
    fm.get('name', ''),
    fm.get('schedule', ''),
    model,
    fm.get('max_budget_usd', '0.50'),
    fm.get('enabled', 'true'),
    fm.get('preflight_command', '') or '_NONE_',
    fm.get('allowed_tools', '') or '_NONE_',
    fm.get('max_runtime', '600'),
]
print('\t'.join(fields))
"
}

# --- Extract prompt body (everything after second ---) ---
get_prompt() {
  local file="$1"
  python3 -c "
import re
content = open('$file').read()
match = re.match(r'^---.*?---\s*\n', content, re.DOTALL)
if match:
    print(content[match.end():].strip())
"
}

get_last_run() {
  local job_name="$1"
  python3 -c "
import json
state = json.load(open('$STATE_FILE'))
print(state.get('$job_name', {}).get('last_run', '0'))
"
}

update_state() {
  local job_name="$1"
  local timestamp="$2"
  local status="$3"
  local exit_code="$4"
  local duration="$5"
  python3 -c "
import json
state = json.load(open('$STATE_FILE'))
entry = state.get('$job_name', {})
entry['last_attempt'] = '$timestamp'
entry['last_status'] = '$status'
entry['last_exit_code'] = int('$exit_code')
entry['last_duration_seconds'] = int('$duration')
if '$status' == 'success':
    entry['last_run'] = '$timestamp'
state['$job_name'] = entry
json.dump(state, open('$STATE_FILE', 'w'), indent=2)
"
}

# Preflight: optional shell command that gates the model run.
# Echo a line starting with "RUN:" to proceed, anything else to skip.
# Non-zero exit means preflight itself broke.
run_preflight() {
  local job_name="$1"
  local preflight="$2"

  if [[ -z "$preflight" || "$preflight" == "_NONE_" ]]; then
    return 0
  fi

  local output
  if ! output=$(/bin/bash -lc "$preflight" 2>&1); then
    log "$job_name: preflight failed, skipping. Output: $output"
    return 2
  fi

  local first_line
  first_line=$(printf '%s\n' "$output" | head -n 1)
  if [[ "$first_line" == RUN:* ]]; then
    log "$job_name: preflight passed. $first_line"
    return 0
  fi

  log "$job_name: skipped by preflight. $first_line"
  return 1
}

# --- Main loop ---
log "Watchdog scanning $JOBS_DIR"

if [[ ! -d "$JOBS_DIR" ]]; then
  log "No jobs directory at $JOBS_DIR. Nothing to do."
  exit 0
fi

JOB_COUNT=0
RUN_COUNT=0

for job_file in "$JOBS_DIR"/*.md; do
  [[ -f "$job_file" ]] || continue

  PARSED=$(parse_frontmatter "$job_file" 2>/dev/null) || {
    log "WARN: could not parse $job_file, skipping"
    continue
  }

  IFS=$'\t' read -r NAME SCHEDULE MODEL BUDGET ENABLED PREFLIGHT ALLOWED_TOOLS MAX_RUNTIME <<< "$PARSED"

  if [[ "$ENABLED" != "true" ]]; then
    continue
  fi

  JOB_COUNT=$((JOB_COUNT + 1))

  INTERVAL=$(get_interval "$SCHEDULE")
  if [[ "$INTERVAL" -eq 0 ]]; then
    log "WARN: unknown schedule '$SCHEDULE' for $NAME, skipping"
    continue
  fi

  LAST_RUN=$(get_last_run "$NAME")
  NOW=$(date +%s)
  ELAPSED=$((NOW - LAST_RUN))

  # 5-minute grace window handles sleep/wake timing gaps.
  # If a job is within 5 min of being due, treat it as due now.
  GRACE=300
  if [[ "$ELAPSED" -lt $((INTERVAL - GRACE)) ]]; then
    REMAINING=$(( (INTERVAL - ELAPSED) / 60 ))
    log "$NAME: not due yet (${REMAINING}m remaining)"
    continue
  fi

  if run_preflight "$NAME" "$PREFLIGHT"; then
    PREFLIGHT_STATUS=0
  else
    PREFLIGHT_STATUS=$?
  fi
  if [[ "$PREFLIGHT_STATUS" -ne 0 ]]; then
    continue
  fi

  DEFAULT_TOOLS="Read,Write,Edit,Bash,Glob,Grep,WebSearch,WebFetch"
  if [[ "$ALLOWED_TOOLS" == "_NONE_" ]]; then
    ALLOWED_TOOLS=""
  fi
  TOOLS="${ALLOWED_TOOLS:-$DEFAULT_TOOLS}"

  log "$NAME: RUNNING (model=$MODEL, budget=\$$BUDGET, max_runtime=${MAX_RUNTIME}s)"
  RUN_COUNT=$((RUN_COUNT + 1))

  PROMPT=$(get_prompt "$job_file")
  TODAY=$(date +%Y-%m-%d)
  LOG_FILE="$LOGS_DIR/${NAME}_${TODAY}.log"

  # Strip API/session env so jobs use Claude subscription auth, not API credits.
  # --strict-mcp-config disables user-level MCPs that would bloat context.
  JOB_START=$(date +%s)
  CLAUDE_EXIT=0
  set +e
  {
    echo "=== Run at $(date '+%Y-%m-%d %H:%M:%S') ==="
    env -u ANTHROPIC_API_KEY -u CLAUDECODE claude -p "$PROMPT" \
      --model "$MODEL" \
      --max-turns 25 \
      --allowedTools "$TOOLS" \
      --strict-mcp-config \
      2>&1
    CLAUDE_EXIT=$?
    if [[ "$CLAUDE_EXIT" -ne 0 ]]; then
      echo "[watchdog] claude exited with code $CLAUDE_EXIT"
    fi
    echo ""
    echo "=== End run ==="
    echo ""
  } >> "$LOG_FILE"
  set -e
  JOB_END=$(date +%s)
  JOB_DURATION=$((JOB_END - JOB_START))
  if [[ "$CLAUDE_EXIT" -eq 0 ]]; then
    JOB_STATUS="success"
  else
    JOB_STATUS="failure"
  fi

  update_state "$NAME" "$NOW" "$JOB_STATUS" "$CLAUDE_EXIT" "$JOB_DURATION"
  if [[ "$JOB_STATUS" == "success" ]]; then
    log "$NAME: completed (${JOB_DURATION}s). Log: $LOG_FILE"
  else
    log "$NAME: failed with exit $CLAUDE_EXIT (${JOB_DURATION}s). Log: $LOG_FILE"
  fi
done

log "Done. $JOB_COUNT enabled jobs found, $RUN_COUNT executed."
