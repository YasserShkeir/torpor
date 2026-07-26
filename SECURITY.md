# Security policy

## What Torpor can reach

Torpor is a local macOS app. It has no server and no account. Being honest
about its access matters more than a version table, because it reaches things
most menu bar apps do not:

- **Your Claude Code conversation transcripts** (`~/.claude/projects/**/*.jsonl`)
  are parsed to compute per-session token counts. These contain source code,
  file paths, and whatever you have pasted into a prompt. Torpor reads them,
  counts tokens, and keeps the totals in memory. It never copies, uploads, or
  logs their contents.
- **`~/.claude/settings.json`** is modified when you install the usage reporter,
  and copied to a timestamped backup in Application Support before any change.
- **Your login Keychain**, only if you choose a token-based usage source. Torpor
  stores its own item; it reads Claude Code's item only when you press Connect,
  and macOS shows you a consent dialog when it does.
- **Process signals.** Hibernate sends `SIGTERM` (escalating to `SIGKILL`) and
  Freeze sends `SIGSTOP`, to Claude Code sessions and their child processes.
- **AppleEvents**, to open a terminal window when reviving a session.

## What Torpor never does

- **Nothing leaves your machine** on the default settings. No telemetry, no
  analytics, no crash reporting. This is deliberate: any third-party crash
  reporter would sweep transcript paths and message content into breadcrumbs.
- **No token is written outside the Keychain**, and none is logged or shown in
  an error message.
- **The token-based usage sources are inert** until you select one and accept a
  disclosure that names the risk. See the README.

## Reporting a vulnerability

Email **shkeiryasser@gmail.com** with `[torpor]` in the subject, or open a
[private security advisory](https://github.com/YasserShkeir/torpor/security/advisories/new).
Please do not open a public issue for anything exploitable.

I am one person and this is not a funded project — expect a first reply within
a few days, not a few hours. I will tell you honestly if something is out of
scope or will not be fixed.

## Scope

In scope: anything that lets a third party read your transcripts or credentials,
escalate privileges, execute code via a crafted directory name or settings file,
or signal a process Torpor should not touch.

Out of scope: the fact that Torpor can end your Claude Code sessions — that is
the product. Also out of scope: the token-based usage sources being against
Anthropic's terms. That is documented, disclosed in the UI, and opt-in.
