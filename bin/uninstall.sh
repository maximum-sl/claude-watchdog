#!/usr/bin/env bash
# Uninstall claude-watchdog. Stops the LaunchAgent and removes the plist.
# Does not delete jobs, logs, or state.

set -euo pipefail

PLIST_NAME="com.claude-watchdog"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

if launchctl list | grep -q "$PLIST_NAME" 2>/dev/null; then
  echo "Stopping watchdog..."
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

if [[ -f "$PLIST_PATH" ]]; then
  rm -f "$PLIST_PATH"
  echo "Removed $PLIST_PATH"
fi

echo "claude-watchdog uninstalled."
echo "Your jobs/, logs/, and state/ directories were left in place."
