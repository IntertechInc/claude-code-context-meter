# claude-statusline-ctx

A lightweight [Claude Code](https://code.claude.com/docs/en/statusline) status line that shows how full your context window is, **how much each turn added**, and how it has been trending across the session, plus your rate limit usage.

```
Opus (132k/1M, 13%) ▲+3.4k ▁▂▂▃▅ | 5h 22% | 7d 41%
```

Most status lines show a single snapshot of context usage. This one adds the two things a snapshot cannot tell you: the per-turn delta (how much the last turn cost you in context) and a sparkline of the recent trend, so you can see your window filling up before it sneaks up on you.

## What each segment means

```
Opus            (132k/1M, 13%)   ▲+3.4k      ▁▂▂▃▅       | 5h 22% | 7d 41%
^model          ^fill / max, %   ^delta      ^trend       ^rate limits
```

- **Fill / max, percentage.** Tokens currently in the context window over the model's max window size, with the precalculated percentage. Color coded by how close you are to full.
- **Delta.** The net change in window tokens since the previous turn. `▲+3.4k` means the last turn added about 3,400 tokens. A normal turn always grows, so you will almost always see `▲`.
- **Trend.** A sparkline over the last several data points, auto scaled so you can read the shape of the growth at a glance.
- **Rate limits.** Your 5 hour and 7 day usage. These appear only for Claude.ai Pro and Max subscribers and are omitted on API usage.

### Color bands

The fill segment changes color by percentage used:

| Band | Color |
|------|-------|
| under 50% | green |
| 50 to 69% | yellow |
| 70 to 89% | orange |
| 90% and up | red |

### Compaction and clear

When you run `/compact` or `/clear`, the window shrinks. Because the delta is just `current minus previous`, a compaction produces a large negative number. Rather than showing an alarming `▼-372k`, a drop of at least `CTX_COMPACT_MIN` tokens is labeled as a compaction:

```
Opus (38k/1M, 4%) ⟲ -372k ▁▃█▁ | 5h 22% | 7d 41%
```

That reads as "compaction reclaimed about 372k, and you are now sitting at 38k." Smaller negative wobbles (a rare cache rewrite) still show as a minor `▼` so they are not mislabeled.

## Requirements

- `bash`
- [`jq`](https://jqlang.github.io/jq/)

The script itself is one `jq` call plus pure bash arithmetic. No `git`, `date`, or `stat` calls, so it stays well under the 300ms refresh that Claude Code already enforces and never blocks your prompt. Per the Claude Code docs the status line runs locally and does not consume API tokens.

### Installing jq

| Platform | Command |
|----------|---------|
| Debian / Ubuntu / WSL | `sudo apt install jq` |
| macOS (Homebrew) | `brew install jq` |
| Windows (winget) | `winget install jqlang.jq` |
| Windows (Scoop) | `scoop install jq` |

## Install

1. Copy the script into your Claude config directory and make it executable:

   ```bash
   cp statusline-ctx.sh ~/.claude/statusline-ctx.sh
   chmod +x ~/.claude/statusline-ctx.sh
   ```

2. Point Claude Code at it in `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline-ctx.sh"
     }
   }
   ```

3. The status line appears at the bottom of Claude Code on your next interaction.

### Windows notes

On Windows, Claude Code runs the status line through Git Bash when it is installed. Use forward slashes in the path inside `settings.json`, for example `"~/.claude/statusline-ctx.sh"`, since Git Bash treats backslashes as escape characters. The `~` shorthand expands to your Windows home directory. WSL works exactly like Linux.

## Configuration

All optional, set as environment variables before launching Claude Code:

| Variable | Default | Effect |
|----------|---------|--------|
| `CTX_SPARK_WIDTH` | `8` | Number of points in the sparkline window |
| `CTX_COMPACT_MIN` | `5000` | Minimum token drop counted as a compaction (labeled `⟲`) |
| `CTX_NO_COLOR` | unset | Set to `1` to disable ANSI color |

## How it works

A status line script is stateless. Claude Code pipes it a JSON blob after each assistant message and displays whatever the script prints. To compute a per-turn delta and a trend, this script keeps a tiny state file at `/tmp/ccstatus-ctx-<session_id>`, keyed by session ID so concurrent sessions never cross contaminate. The file holds a short list of recent token counts, nothing heavy. On each tick the script reads the last value, subtracts to get the delta, appends the new value, and trims to the sparkline window.

The fill number is `context_window.total_input_tokens` (input plus cache creation plus cache read), which matches the basis of the percentage Claude Code reports. The maximum comes from `context_window.context_window_size`, so the `/1M` or `/200k` denominator is never hardcoded.

### A note on compaction detection

There is no field in the JSON that flags "this update came from a compact," so the `⟲` label is inferred purely from the size of the drop. In practice this is reliable, since the only things that shrink the window meaningfully are `/compact` and `/clear`. If you ever see a `⟲` you did not expect, it means the window dropped by `CTX_COMPACT_MIN` or more for some other reason, which is itself worth noticing.

## Testing

Run it against mock input without launching Claude Code:

```bash
echo '{"model":{"display_name":"Opus"},"context_window":{"total_input_tokens":132000,"context_window_size":1000000,"used_percentage":13},"rate_limits":{"five_hour":{"used_percentage":22},"seven_day":{"used_percentage":41}},"session_id":"test"}' | ./statusline-ctx.sh
```

## Credits

The color thresholds and the idea of surfacing context fill alongside the 5 hour and 7 day rate limits were inspired by [daniel3303/ClaudeCodeStatusLine](https://github.com/daniel3303/ClaudeCodeStatusLine). No code was reused. The per-turn delta, sparkline, single-fork performance design, and compaction labeling are original to this project. JSON field names come from the official [Claude Code status line documentation](https://code.claude.com/docs/en/statusline).
