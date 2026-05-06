---
name: morning-brief
schedule: every_1h
description: Only runs once between 7-8am local time. Demonstrates preflight gating.
model_tier: balanced
max_budget_usd: 0.20
preflight_command: 'h=$(date +%H); if [ "$h" = "07" ]; then echo "RUN: morning window"; else echo "SKIP: outside 7am window (hour=$h)"; fi'
enabled: false
---

You are running as a morning-only background job.

Compose a 3-sentence brief covering:
1. What's the most important thing to do today
2. One thing worth being aware of
3. One small win to start the day

Save to `~/Desktop/brief-{today's date}.md`.
