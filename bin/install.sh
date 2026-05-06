#!/usr/bin/env bash
# Install claude-watchdog as a macOS LaunchAgent.
# Runs watchdog.sh every N seconds (default 3600 = 1 hour) in the background.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_NAME="com.claude-watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
WATCHDOG_SCRIPT="$WATCHDOG_HOME/bin/watchdog.sh"
JOBS_DIR="$WATCHDOG_HOME/jobs"
LOGS_DIR="$WATCHDOG_HOME/logs"
INTERVAL="${1:-3600}"

echo "claude-watchdog installer"
echo "========================="
echo ""

if ! command -v claude &>/dev/null; then
  echo "ERROR: 'claude' CLI not found."
  echo "Install it first: https://docs.anthropic.com/en/docs/claude-code"
  exit 1
fi

CLAUDE_BIN_DIR=$(dirname "$(command -v claude)")

if [[ ! -f "$WATCHDOG_SCRIPT" ]]; then
  echo "ERROR: watchdog.sh not found at $WATCHDOG_SCRIPT"
  exit 1
fi

chmod +x "$WATCHDOG_SCRIPT"

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 not found. Required for parsing job files."
  exit 1
fi

mkdir -p "$LOGS_DIR" "$WATCHDOG_HOME/state"

# --- Cost estimate ---
echo "Calculating cost estimate from jobs in $JOBS_DIR..."
ENABLED_JOBS=0
DAILY_COST_LOW=0
DAILY_COST_HIGH=0

if [[ -d "$JOBS_DIR" ]]; then
  for job_file in "$JOBS_DIR"/*.md; do
    [[ -f "$job_file" ]] || continue
    PARSED=$(python3 -c "
import re
content = open('$job_file').read()
match = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not match: exit()
fm = {}
for line in match.group(1).strip().split('\n'):
    if ':' in line:
        k, v = line.split(':', 1)
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in (chr(34), chr(39)):
            v = v[1:-1]
        fm[k.strip()] = v
if fm.get('enabled','true') == 'false': exit()
budget = fm.get('max_budget_usd', '0.50')
schedule = fm.get('schedule', 'every_2h')
name = fm.get('name', 'unknown')
intervals = {'every_10m':144,'every_30m':48,'every_1h':24,'every_2h':12,'every_4h':6,'every_6h':4,'every_8h':3,'every_12h':2,'every_24h':1}
runs_per_day = intervals.get(schedule, 12)
print(f'{name}\t{budget}\t{runs_per_day}')
" 2>/dev/null) || continue

    [[ -z "$PARSED" ]] && continue
    ENABLED_JOBS=$((ENABLED_JOBS + 1))

    IFS=$'\t' read -r JOB_NAME JOB_BUDGET RUNS_PER_DAY <<< "$PARSED"
    WORST=$(python3 -c "print(round($JOB_BUDGET * $RUNS_PER_DAY, 2))")
    TYPICAL=$(python3 -c "print(round($JOB_BUDGET * $RUNS_PER_DAY * 0.3, 2))")
    echo "  $JOB_NAME: ~\$$TYPICAL - \$$WORST/day ($RUNS_PER_DAY runs/day, \$$JOB_BUDGET cap each)"
    DAILY_COST_LOW=$(python3 -c "print(round($DAILY_COST_LOW + $TYPICAL, 2))")
    DAILY_COST_HIGH=$(python3 -c "print(round($DAILY_COST_HIGH + $WORST, 2))")
  done
fi

echo ""
if [[ "$ENABLED_JOBS" -eq 0 ]]; then
  echo "No enabled jobs found in $JOBS_DIR."
  echo "The watchdog will install but won't run anything until you create a job."
  echo "See examples/ for sample job files."
else
  echo "Estimated daily cost: \$$DAILY_COST_LOW , \$$DAILY_COST_HIGH"
  echo "(Based on $ENABLED_JOBS enabled jobs. Each job has its own spending cap.)"
fi
echo ""

# --- Unload existing plist if present ---
if launchctl list | grep -q "$PLIST_NAME" 2>/dev/null; then
  echo "Removing existing watchdog..."
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

# --- Generate plist ---
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WATCHDOG_SCRIPT}</string>
    </array>

    <key>StartInterval</key>
    <integer>${INTERVAL}</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${CLAUDE_BIN_DIR}:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>WATCHDOG_HOME</key>
        <string>${WATCHDOG_HOME}</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>${WATCHDOG_HOME}</string>

    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/watchdog-stdout.log</string>

    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/watchdog-stderr.log</string>

    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
PLIST

launchctl load "$PLIST_PATH"

echo "claude-watchdog installed and running."
echo ""
echo "  Check interval: every $((INTERVAL / 60)) minutes"
echo "  Plist:          $PLIST_PATH"
echo "  Jobs:           $JOBS_DIR"
echo "  Logs:           $LOGS_DIR/watchdog-*.log"
echo "  State:          $WATCHDOG_HOME/state/watchdog.state.json"
echo ""
echo "Trigger immediately:  launchctl start $PLIST_NAME"
echo "Tail logs:            tail -f $LOGS_DIR/watchdog-stdout.log"
echo "Uninstall:            bash $WATCHDOG_HOME/bin/uninstall.sh"
echo ""
echo "Jobs run using your Claude plan credits. Each job has a spending cap"
echo "(max_budget_usd in the job file) to prevent runaway costs."
