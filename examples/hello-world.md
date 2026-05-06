---
name: hello-world
schedule: every_1h
description: Smallest possible job. Writes a single line to a file once an hour.
model_tier: fast
max_budget_usd: 0.05
enabled: false
---

Write a single line to `~/claude-watchdog-test.txt` confirming the watchdog ran.

Format: "Watchdog ran at YYYY-MM-DD HH:MM:SS"

Append, do not overwrite. Exit when done.
