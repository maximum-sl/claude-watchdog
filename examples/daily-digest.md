---
name: daily-digest
schedule: every_24h
description: Pull top items from a few RSS feeds, summarize, save to a markdown file.
model_tier: balanced
max_budget_usd: 0.30
allowed_tools: Read,Write,WebFetch,WebSearch
max_runtime: 600
enabled: false
---

You are running as a scheduled background job.

Fetch the latest 5 posts from each of these sources:
- https://news.ycombinator.com/rss
- https://www.theverge.com/rss/index.xml

For each, write a 1-sentence summary capturing what's interesting and why.

Save the result to `~/Desktop/daily-digest-{today's date in YYYY-MM-DD format}.md` with this structure:

```
# Daily Digest, YYYY-MM-DD

## Hacker News
- [Title](url) , one-sentence summary
...

## The Verge
- [Title](url) , one-sentence summary
...
```

Keep summaries short. Skip anything that's clearly low-signal (job posts, "show HN" without a link, etc.).
