# Security policy

## What Torpor can reach

Torpor is a local macOS app. It has no account and no backend. Being honest
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
- **`https://yassershkeir.github.io/torpor/appcast.xml`**, once a day, to see
  whether there is an update. This is the only outbound request Torpor makes on
  default settings, and Sparkle makes it, not Torpor's own code. It sends what
  any HTTPS GET sends — your IP address, and a User-Agent naming Torpor and its
  version. Nothing about your sessions, your usage or your machine goes with it:
  `SUEnableSystemProfiling` is not set, so Sparkle's optional hardware and OS
  profile is never appended. To stop it, run
  `defaults write dev.torpor.Torpor SUEnableAutomaticChecks -bool false`
  and use **Check for Updates…** in Settings when you want one.

## What Torpor never does

- **No transcript content, no token, and no usage data leaves your machine.**
  No telemetry, no analytics, no crash reporting. This is deliberate: any
  third-party crash reporter would sweep transcript paths and message content
  into breadcrumbs. The one outbound request on default settings is the daily
  update check above, and it carries none of that.
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
