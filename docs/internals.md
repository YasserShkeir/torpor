# Notes for anyone reading the code

Things that cost me time, in case they save you some. Everything here was measured
on a real machine rather than reasoned about.

## Don't find sessions by process name

The executable's filename is the Claude Code version string, so the process is
called `2.1.220`, not `claude`. `pgrep -x claude` matched exactly one of my twelve
running sessions, and the one it found was the VS Code extension's binary.

`~/.claude/sessions/<pid>.json` is the reliable list. Every field in it is decoded
as optional, because none of it is documented and it has changed shape more than
once. When files are present but none of them decode, Torpor says so instead of
reporting an empty machine.

## Use `phys_footprint`, not RSS

RSS excludes compressed pages, and an idle process on macOS is mostly compressed
pages. One idle session read 24 MB by RSS against 319 MB by footprint. Any
RSS-based monitor is wrong about an idle process by roughly ten times, which is
exactly why the problem was invisible to me for weeks.

`proc_pid_rusage` with `RUSAGE_INFO_V4` gives you `ri_phys_footprint`, needs no
entitlement, and agrees with `top -stats mem`.

**Don't compute compressed bytes as `footprint - resident`.** It looks obviously
right and it isn't: the two have different accounting bases, the error reached 56%
against `top -stats cmprs`, and 27% of processes had resident greater than
footprint, which clamps the result to zero. The real number needs
`task_info(TASK_VM_INFO)` and a task port, and `task_for_pid` is denied
unentitled. Torpor doesn't show the column.

## Check identity, not liveness

This machine cycles the whole PID space in about 41 minutes under load. After you
signal something, "does a process hold this number" is the wrong question, and it
answers yes for zombies too. Compare the start time from `proc_bsdinfo` as well,
and exclude `SZOMB`.

## KERN_PROCARGS2 is fiddly

The buffer is argc, then the exec path, then argv, then the environment, NUL
separated, with alignment padding between the exec path and `argv[0]`. A truncated
read will hand you a plausible-looking partial final argument, so count what you
parsed against argc and refuse the lot if they disagree.

Keep the exec path rather than trusting `argv[0]`. On this machine `argv[0]` is
the bare string `claude`, so anything built on it has to re-resolve against
whatever PATH the new shell happens to have after `cd`-ing into a project.

## Transcript token counts need three rules

**Dedupe on `(message.id, requestId)`, keeping the largest snapshot.** Streaming
rewrites the same message repeatedly with growing counts, so summing rows
double-counts badly. When you replace a snapshot, back the superseded one out of
the bucket it was actually filed under, not the new record's: a retry served by a
different model otherwise drives the wrong bucket negative. That happens for real,
12 times in this machine's transcripts.

**Read `subagents/**/*.jsonl` too.** An earlier version skipped them, assuming
their usage was counted in the parent. It isn't. Measured on one session: parent
252.1M tokens, subagents 91.1M, and the `(message.id, requestId)` sets intersect
in exactly zero places. Some models appear *only* in subagent transcripts.

**Classify by each record's own `message.model`.** A session can be served by a
different model than the one the UI is showing.

Two traps in the same file. `message.usage.iterations[]` repeats the top-level
counts, so summing it double-counts everything. And a record carrying neither
`message.id` nor `requestId` needs its own identity, or every such record collides
on one key and only the largest survives.

## Reviving into the original tab

Killing `claude` leaves its parent shell alive, so the tab is still sitting at a
prompt. Torpor records the controlling tty and matches it against open Terminal
and iTerm tabs.

The tty does not come from `~/.claude/sessions/<pid>.json`. That file holds cwd,
entrypoint, kind, name, nameSource, peerProtocol, pid, procStart, sessionId,
startedAt, status, statusUpdatedAt, updatedAt and version — there is no `tty`
field and never was. It is read off the live process instead, at hibernate time,
*before* the signal: once the process exits the kernel has no controlling
terminal for it.

A tty on its own doesn't say whether the tab can be reached. Every session on
the development machine has one, and all of them are VS Code's. So the parent
chain is walked as well — `claude → zsh → Code Helper → Code` — skipping helper
processes, which Launch Services either doesn't know or reports as
`.prohibited`, until a real application turns up. Terminal and iTerm are the
whole scriptable set; VS Code, Cursor, Warp and Ghostty are not, and `TIOCSTI`
is not a way round it (measured: EPERM, a process may not inject input into a
tty it doesn't control). Those sessions get a new window and are told which
application their tab was in, before the button is pressed as well as after.

A VS Code-*hosted* binary is a separate matter and is refused rather than
relaunched somewhere it won't work. A CLI session that merely happens to be
running inside VS Code's integrated terminal is an ordinary `cli` entrypoint and
revives normally.

## Effort

`--effort <low|medium|high|xhigh|max>` is a real flag and is in the replay
allowlist, but the level is usually set with the `/effort` command mid-session,
so it is never in argv and there is nothing to capture from the process. The
statusline payload carries it as `effort.level`, which is the only source there
is. It's per-session, like `cost` — `/effort` changes one conversation — so it
comes from the session's own snapshot file, and hibernate reads it at capture
time because that file is pruned once the session stops being live.

Only the five documented levels are replayed — not because the CLI rejects the
others (measured: `claude --effort ultra` warns and falls back to the default,
exit 0) but because the level is the one part of the resume command that comes
from a file Torpor doesn't own, and it lands on a shell line. The allowlist is
what keeps it a bare word. A level already in argv wins, and is not emitted
twice.

## Where the usage numbers come from

Claude Code hands its statusline a JSON payload on stdin. That payload carries
more than the percentages: `cost.total_cost_usd` is an exact figure Claude Code
has already computed, so there's no reason to maintain a price table. It also
carries the context-window position and the model's display name.

What it does **not** carry is any per-model limit. Captured live from 2.1.220,
`rate_limits` holds `five_hour` and `seven_day` and nothing else — the reader
still picks up `seven_day_opus` and `seven_day_sonnet` if they are there, and on
current builds they never are. The per-model rows `/usage` shows you come from
the account endpoint, which is a different source with different consequences.

`rate_limits` is account-wide, so any session's snapshot is authoritative for it.
`cost` is per-session, and every session's shim run writes the same file, so
reading cost from the shared snapshot attributes one arbitrary session's spend to
the whole app. It's keyed by session id instead.

## The account endpoint

`/api/oauth/usage` returns a `limits` array. The model rows look like this:

```json
{"kind": "weekly_scoped", "percent": 12,
 "resets_at": "2026-08-02T00:00:00.465116+00:00",
 "scope": {"model": {"id": null, "display_name": "Fable"}}}
```

Three things to get right, each of which fails silently. The model name is nested
at `scope.model.display_name`, not on the entry. The number is `percent`, not
`utilization` like the top-level windows. And `resets_at` carries six fractional
digits, which `ISO8601DateFormatter` rejects outright without
`.withFractionalSeconds` and still won't take with it, so trim to milliseconds.

The server also still sends the previous shape's keys as explicit nulls
(`seven_day_opus`, `seven_day_sonnet`, and a handful of codenames), which must not
become empty gauges.

Torpor identifies itself as `Torpor/<version>` here. It used to send
`claude-code/<version>` scraped from the installed CLI, which is precisely what
the January 2026 anti-spoofing work was built to catch. The endpoint returns 200
either way, so the disguise was risk with nothing on the other side of it.

One more thing that bites: importing the CLI credential copies it, and that copy
expires in about eight hours while Claude Code refreshes its own and carries on.
Re-read it rather than caching it, or the feature works for a day and then stops
for reasons nobody can see.
