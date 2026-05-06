# claude-watchdog

Run scheduled Claude Code jobs in the background on macOS. Each job is a
markdown file. Each run uses your Claude subscription, not API credits.

## Install

```bash
git clone https://github.com/maximum-sl/claude-watchdog.git
cd claude-watchdog
cp examples/hello-world.md jobs/
# edit the file, set `enabled: true`
bash bin/install.sh
```

That installs a LaunchAgent that ticks every hour. To run more often:
`bash bin/install.sh 1800` (every 30 minutes), or any other interval in
seconds.

You'll need: macOS, the `claude` CLI, python3 (ships with macOS), and a
Claude Pro/Max/Team subscription. API credits work too, they just cost more.

## A job

Drop a markdown file in `jobs/`. The frontmatter says how it runs, the body
is the prompt sent to `claude -p`.

```markdown
---
name: morning-news
schedule: every_24h
model_tier: fast
max_budget_usd: 0.10
enabled: true
---

Pull the top 5 stories from Hacker News, summarize each in one sentence,
save to ~/Desktop/news-{today}.md.
```

Schedules go from `every_10m` to `every_24h`. Model tiers are `fast` (Haiku),
`balanced` (Sonnet), `full` (Opus), or pin a specific model with
`model: claude-sonnet-4-6`. Optional fields: `allowed_tools` (comma list),
`max_runtime` (seconds), and `preflight_command` (bash that gates the run,
see `examples/preflight-gated.md`).

## What people use it for

A morning brief on your desktop at 7am. A digest that scans Slack, Notion,
or your inbox via MCP and only surfaces what actually matters. A weekly
competitor watch that diffs blogs and pricing pages. A research project
that iterates overnight while you sleep. Shape is always: small, scheduled,
one focused task, output to a file. Not "build me a startup overnight."

## Why not just cron?

You can wire `claude -p` into crontab in one line. It works for about a
week, then bites you on three things this fixes.

Cron inherits your shell env. If `ANTHROPIC_API_KEY` is set (and it usually
is), `claude` silently switches from your subscription to API billing. You
notice when the bill arrives. The watchdog strips that env var on every
call.

Cron loads every user-level MCP server you've ever installed. That's often
30KB+ of tool schemas, often enough to 422 small jobs with "context too
large." The watchdog passes `--strict-mcp-config` so jobs run lean.

Cron throws away stdout. A job fails, you find out three days later when
the file isn't there. The watchdog writes per-job logs to
`logs/{name}_{date}.log` and tracks status, exit code, and duration in
`state/watchdog.state.json`. You can `tail -f` and actually debug.

Plus jobs are markdown files, not crontab lines, so they version-control
sanely.

## Common ops

```bash
launchctl start com.claude-watchdog                   # run a tick now
tail -f logs/watchdog-stdout.log                      # watch the watchdog
cat state/watchdog.state.json | python3 -m json.tool  # what ran when
bash bin/uninstall.sh                                 # remove the LaunchAgent
```

Something wrong? `launchctl list | grep claude-watchdog`, non-zero in
column 3 means the script errored, check `logs/watchdog-stderr.log`. If a
job 422s, your prompt's pulling too much context, tighten it.

## Status

v0.1. Running on the author's machine for ~3 months across 20+ jobs.

## Related

[claude-oneshot](https://github.com/maximum-sl/claude-oneshot) is the same
env-stripping + strict-mcp-config pattern as a standalone wrapper, for when
you want it in scripts but don't need the scheduling layer.

## License

MIT.
