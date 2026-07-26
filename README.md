<p align="center">
  <img src="Resources/icon-1024.png" width="128" alt="Torpor">
</p>

<h1 align="center">Torpor</h1>

<p align="center">
  A macOS menu bar app for Claude Code sessions: see what's running, what it
  costs you in memory and quota, and put idle sessions to sleep without losing them.
</p>

<p align="center">
  <a href="https://github.com/YasserShkeir/torpor/stargazers">★ Star</a> ·
  <a href="https://github.com/YasserShkeir/torpor/issues/new/choose">Report a bug</a> ·
  <a href="https://github.com/YasserShkeir/torpor/discussions">Discussions</a> ·
  <a href="https://github.com/YasserShkeir/torpor/releases">Releases</a>
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

Built for the case where you've got a dozen terminal tabs open, six of them
haven't been touched in three days, and your Mac is swapping.

---

## What it does

**Sessions, grouped by project.** Every running Claude Code session, with its
status, idle time, and memory — including its MCP server processes, which are
usually the larger half of the bill. Sessions sharing a working directory are
grouped together, so three sessions in the same repo read as one project with two
working and one idle rather than three unrelated rows.

**Hibernate a whole project at once.** When every session in a group is idle,
the group header offers a single action to end them all and reclaim the memory.
Sessions are terminated concurrently and revive individually.

**Usage.** Your 5-hour and weekly limits, plus model-scoped windows, credits and
Console spend. Four sources are available and they are *not* equivalent — see
below.

**Freeze.** `SIGSTOP` the session and its whole MCP subtree. CPU drops to zero
instantly. Thaw and it picks up exactly where it was.

**Hibernate.** Terminate an idle session and reclaim its entire memory
footprint — then bring it back with one click, at the right directory, with its
original flags intact. You never type `--resume`.

Killing the `claude` process leaves its parent shell alive, so the tab it was
running in is still open and still sitting at a prompt. Torpor records the
session's controlling tty and reopens it **in that same tab**, restoring the
window layout you already had. This works in Terminal and iTerm, which expose a
per-tab `tty` to AppleScript. VS Code's integrated terminal has no external
scripting API, so those sessions get a new window instead — and Torpor says so
rather than pretending otherwise.

**Stays out of the way, if you want.** Optionally the status item removes itself
from the menu bar when no session is running; open Torpor again to bring it back.
Off by default, and always suppressed if the session registry stops parsing, so
the app can never vanish on you at the moment something has gone wrong.

**Six menu bar styles** — icon, percentage, progress bar, battery, icon+bar,
compact — in adaptive, monochrome or accent colour, with an optional reset
countdown (time remaining, clock time, or both).

---

## Install

```sh
git clone <this repo> && cd torpor
./scripts/build-app.sh
open dist/Torpor.app
```

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+).

The binary doubles as a CLI:

```
Torpor --list                   List running sessions with memory
Torpor --groups                 List sessions grouped by project folder
Torpor --preview <pid>          Dry run: what hibernate captures, what revive runs
Torpor --hibernate <pid>        Capture argv, terminate, free its memory
Torpor --revive <session-id>    Reopen it in a terminal, flags replayed
Torpor --freeze <pid>           SIGSTOP a session and its MCP subtree
Torpor --thaw <pid>             SIGCONT it again
Torpor --status                 Show quota and statusline state
Torpor --render <dir>           Render the UI to PNG (development)
```

## Where usage data comes from

Four sources, deliberately not presented as equivalent. Torpor states the
trade-off at the point of choice rather than in a help page.

| Source | What it gives you | Standing |
|---|---|---|
| **Claude Code statusline** (default) | 5-hour and weekly percentages, reset times | Documented. No credentials. |
| **Console API key** | Month-to-date spend, daily cost, per-model breakdown | Anthropic's documented path for third-party tools. Requires a Console organisation — the Admin API is unavailable to individual accounts. |
| **Connect with Claude CLI** | Plan utilisation, model-scoped limits, credits | ⚠️ Account risk — see below |
| **Paste subscription token** | Same as above | ⚠️ Account risk — see below |

The two token paths reuse the OAuth credential Claude Code stores for itself and
call an undocumented endpoint with a `claude-code/<version>` User-Agent.
Anthropic's Claude Code legal documentation states OAuth authentication is
"intended exclusively for … ordinary use of Claude Code and other native
Anthropic applications" and that third-party developers may not "route requests
through Free, Pro, or Max plan credentials on behalf of their users." In January
2026 Anthropic deployed anti-spoofing safeguards, and an Anthropic engineer
confirmed publicly that user accounts were banned for triggering abuse filters
from third-party harnesses using subscription credentials.

That risk lands on **your** Anthropic account. Torpor keeps these modes inert
until you have read the notice and explicitly enabled them, stores tokens in the
login Keychain rather than on disk, and never sends them anywhere but
`api.anthropic.com`. Rate limiting is treated as the normal case: 429s are
honoured with `Retry-After`, backed off exponentially, and never retried in a
loop, with the statusline snapshot keeping the UI populated in the meantime.

The default costs you nothing and risks nothing. Use it unless you specifically
need the model-scoped rows.

---

## Two things this app is honest about

### Freezing does not free memory. Hibernating does.

Measured on an 18 GB M3 Pro running eight idle sessions:

| | footprint | still resident (RSS) |
|---|---|---|
| 8 idle sessions | 2,797 MB | 344 MB |

macOS has *already* compressed the overwhelming majority of an idle session.
(Torpor reports footprint only. `footprint − RSS` looks like a compressed-bytes
figure and is not one: the two counters have different accounting bases, and the
difference measured up to 56% wrong. A true figure needs `task_info(TASK_VM_INFO)`
and a task-port entitlement this app cannot obtain.)
Nothing in the kernel's page-reclaim path consults task state — `vm_pageout`
never reads process status, and the app freezer that would proactively compress
a suspended process is compiled out on macOS. A stopped process's pages age out
exactly like an untouched running process's do.

So a perfect freeze reclaims **at most the resident column** — a small fraction
of the total — while hibernating frees the whole 2.8 GB, including everything
sitting in swap. (The resident figure swings wildly between samples, by tens of
megabytes on an idle session, which is the other reason Torpor does not display
it. Footprint is stable to within a megabyte across polls.)

Torpor offers freeze as a **CPU** control — it's genuinely useful against the
idle GC runaway that can take a long-lived session to multiple gigabytes and
several cores — and hibernate as the memory control. It does not market freeze
as a memory tier, because it isn't one.

### Quota comes from the statusline, not from your credentials

Claude Code invokes your configured statusline command on every render and
hands it a JSON payload containing, for Claude.ai subscribers:

```
rate_limits.five_hour.used_percentage    rate_limits.five_hour.resets_at
rate_limits.seven_day.used_percentage    rate_limits.seven_day.resets_at
```

These are the same server-computed numbers `/usage` renders. Torpor installs a
small shim that tees that payload to a snapshot file and then delegates to
whatever statusline you already had, so installing it never costs you your
prompt. Inspect it before installing:

```sh
Torpor --emit-shim /tmp/shim.sh && cat /tmp/shim.sh
Torpor --install-statusline     # backs up settings.json first
```

**On the default setting, Torpor never reads a token and makes no network
requests at all.** It does check whether a Claude Code Keychain item *exists*
(an attribute query that returns no secret and raises no consent prompt) so the
Account tab can tell you whether connecting is even possible. The two token
modes do read the Keychain and do call `api.anthropic.com/api/oauth/usage` — that
is what they are — but they stay completely inert until you select one, read the
warning, and tick the acknowledgement.

The technique doing the rounds is to pull the OAuth token out of the
`Claude Code-credentials` Keychain item and call that undocumented endpoint with
a spoofed `claude-code/<version>` User-Agent, by default and without asking.
Anthropic's Claude Code legal documentation states that OAuth authentication is
"intended exclusively for … ordinary use of Claude Code and other native
Anthropic applications" and that third-party developers may not "route requests
through Free, Pro, or Max plan credentials on behalf of their users." In
January 2026 Anthropic deployed anti-spoofing safeguards, and an Anthropic
engineer confirmed publicly that user accounts were banned for triggering abuse
filters from third-party harnesses using subscription credentials.

That risk lands on *your* account, not the tool author's. Torpor takes the
documented path instead.

**The trade-off, stated plainly:** the snapshot only refreshes while some
session is rendering its statusline. If everything is idle, the numbers age —
so the UI always shows the capture time and marks it stale after 15 minutes.
`rate_limits` is also absent until a session's first API response.

---

## Implementation notes

Things that are non-obvious and cost time to discover:

**Discover sessions from the registry, never by process name.** The Claude Code
executable's basename is the *version string* — `2.1.220`, not `claude`. On a
machine with 12 sessions, `pgrep -x claude` matched exactly one (the VS Code
extension's binary, which lives at a different path). `~/.claude/sessions/<pid>.json`
is the only reliable enumeration source.

**Measure `phys_footprint`, not RSS.** RSS excludes compressed pages. One idle
session measured 24 MB RSS against 319 MB footprint — a 13x understatement.
Every RSS-based monitor is wrong about idle sessions by roughly an order of
magnitude.

**Cross-check the registry against live process state.** `status` is stamped on
transition, not as a heartbeat, so a session that crashes while `busy` leaves a
permanently stale `busy` file. Torpor treats a dead PID as gone regardless of
what the file says, and guards against PID reuse via start time.

**`updatedAt` is a real idle clock.** It records when status last *changed*, so
for an idle session it genuinely means "went idle at" — verified on a session
where it was written 43.6 hours after `startedAt`. It is not a heartbeat and
never refreshes while status is unchanged.

**`status` is absent entirely on the VS Code entrypoint.** Those sessions show
as `unknown` and are never auto-hibernated, because we can't tell whether
they're mid-task.

**`claude --resume` is lossy.** It restores conversation history but drops
`--mcp-config`, `--settings`, `--plugin-dir`, `--add-dir` and `--model`. Torpor
captures argv *before* terminating and replays those flags on revive — which
makes its resume more faithful than typing the command yourself. Flags are an
allowlist, not a passthrough: stream plumbing (`--output-format stream-json`,
`--input-format`, `--replay-user-messages`) must not be replayed or you get a
session reading JSON from the keyboard. Sessions hosted by VS Code or the
desktop app revive with the plain `claude` on PATH for the same reason.

**Deduplicate transcript usage on `(message.id, requestId)`, keeping the largest
snapshot.** Streaming rewrites a message repeatedly with growing counts; summing
rows double-counts. Also skip `subagents/*.jsonl` — on this machine 3,329 of
3,490 transcript files are subagent transcripts already reflected in the parent.

**`stats-cache.json` is not a usage source.** Its `costUSD` field is `0` for
every model (subscription users aren't billed per token), `dailyModelTokens` is
empty, and it only recomputes periodically.

---

## Stability

This depends on undocumented Claude Code internals — the session registry shape
and the transcript schema. Claude Code ships roughly six releases a week, and
three different versions were running concurrently on the development machine.
Torpor decodes every registry field as optional, falls back to the filename for
the pid and to the live process for the working directory, and — if registry
files exist but none of them parse — refuses to auto-hide from the menu bar, so
an upstream format change can never make the app silently disappear. Expect
breakage anyway, and file issues.

The statusline `rate_limits` contract is documented and is the stable part.

## Contributing and feedback

Bug reports are genuinely valuable here. Torpor reads undocumented Claude Code
internals and upstream ships roughly six releases a week, so breakage is a
question of when, not whether. If the session list empties out or the numbers
look wrong after a Claude Code update, that is worth an issue.

- **[Open an issue](https://github.com/YasserShkeir/torpor/issues/new/choose)** —
  bugs, especially anything that broke after a Claude Code release. Include the
  output of `Torpor --list` and `Torpor --status`.
- **[Start a discussion](https://github.com/YasserShkeir/torpor/discussions)** —
  ideas, questions, or "does this work on your machine too?"
- **[Star the repo](https://github.com/YasserShkeir/torpor/stargazers)** if it
  saved you some RAM.

Pull requests welcome. The one hard rule: **no code path may read a subscription
OAuth token without an explicit, informed opt-in from the user.** See
[Where usage data comes from](#where-usage-data-comes-from).

## Deliberately absent

**Crash reporting and analytics.** Torpor parses `~/.claude/projects/**/*.jsonl`,
which are full conversation transcripts — source code, file paths, and whatever
you have pasted into a prompt. Any third-party crash reporter would sweep that
into breadcrumbs. Nothing in this app phones home, and adding something that
does would need a much better reason than convenience.

## License

MIT — see [LICENSE](LICENSE).

---

<p align="center">
  Built by <strong>Yasser Shkeir</strong> — fullstack engineer &amp; business consultant.<br>
  <em>Systems that move the numbers.</em>
</p>

<p align="center">
  <a href="https://yasser-shkeir.com">yasser-shkeir.com</a> ·
  <a href="https://github.com/YasserShkeir">GitHub</a> ·
  <a href="https://www.linkedin.com/in/yasser-shkeir">LinkedIn</a>
</p>

<p align="center">
  <sub>Also: <a href="https://github.com/YasserShkeir/django-smart-ratelimit">django-smart-ratelimit</a> ·
  <a href="https://github.com/YasserShkeir/django-safe-migrations">django-safe-migrations</a></sub>
</p>

<p align="center">
  <sub>Not affiliated with Anthropic. "Claude" is a trademark of Anthropic PBC.</sub>
</p>
