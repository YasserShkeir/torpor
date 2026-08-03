<p align="center">
  <img src="Resources/icon-1024.png" width="120" alt="Torpor">
</p>

<h1 align="center">Torpor</h1>

<p align="center">
  A macOS menu bar app for Claude Code sessions. See what each one really costs
  in memory, and put the idle ones to sleep without losing them.
</p>

<p align="center">
  <a href="https://github.com/YasserShkeir/torpor/stargazers">Star</a> ·
  <a href="https://github.com/YasserShkeir/torpor/issues/new/choose">Report a bug</a> ·
  <a href="https://github.com/YasserShkeir/torpor/discussions">Discussions</a> ·
  <a href="https://github.com/YasserShkeir/torpor/releases/latest">Releases</a>
</p>

<p align="center">
  <a href="https://github.com/YasserShkeir/torpor/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/YasserShkeir/torpor/actions/workflows/ci.yml/badge.svg?branch=main"></a>
  <a href="https://github.com/YasserShkeir/torpor/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/YasserShkeir/torpor?sort=semver"></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
</p>

<p align="center">
  <img src="docs/images/popover.png" width="560" alt="The Torpor popover: usage gauges and sessions grouped by project">
</p>

---

I had twelve sessions open across six repos and six hadn't been touched in days.
Activity Monitor wasn't much help: most of the memory isn't in the `claude`
process at all, it's in the MCP servers hanging off it, showing up as unrelated
`node` rows.

## What it does

Sessions grouped by folder, each with the real memory of its whole MCP subtree.
Then two things you can do to one:

<p align="center">
  <img src="docs/images/session-detail.png" width="560" alt="An expanded session showing path, age, memory across processes, tokens, and the Freeze and Hibernate buttons">
</p>

**Freeze** stops a session and everything under it. CPU drops to zero. Unfreeze
and it carries on.

**Hibernate** ends an idle session and gives back all its memory. One click
brings it back in the same terminal tab, the same directory, with the flags it
was started with. You never type `--resume`.

Your 5-hour or weekly usage sits in the menu bar — you pick which — with a white
line marking how far through that window you are. Fill behind the line means
you're on pace. Memory used by all sessions sits in the second column.

<p align="center">
  <img src="docs/images/menubar.png" width="560" alt="The menu bar item magnified, in both metrics: a quota bar with time remaining beneath it, and memory used alongside">
</p>

<p align="center">
  <img src="docs/images/settings-appearance.png" width="560" alt="Settings, Appearance tab, with a live preview of the menu bar item above every control that changes it">
</p>

## Install

```sh
brew install --cask yassershkeir/torpor/torpor
```

and it opens. Torpor is signed with a Developer ID and notarised, with the
ticket stapled into the bundle, so there is no `xattr` step and no trip through
System Settings. Notarisation is Apple's automated malware scan, not Apple
vouching for what the app does — and Torpor is not sandboxed and not on the App
Store, because reading another process's memory and signalling it are the
product and the sandbox forbids both.

Or build it yourself. A local build is ad-hoc signed and never quarantined, so
it opens too:

```sh
git clone https://github.com/YasserShkeir/torpor.git
cd torpor && ./scripts/build-app.sh && open dist/Torpor.app
```

macOS 14+ to run. `swift build` wants Swift 6.0 or newer; the universal build in
`./scripts/build-app.sh` goes through Xcode's build system, which wants Swift
6.2.

Reviving a session asks permission to control Terminal or iTerm. macOS binds
that grant to the signing identity, and the Developer ID does not change from
build to build, so it asks once rather than again after every update.

## Freezing doesn't free memory, and I shipped it saying so

I assumed it would. Then I measured eight idle sessions before release:

| | footprint | still in physical RAM |
|---|---|---|
| 8 idle sessions | 2,797 MB | 344 MB |

macOS had already compressed the rest away, and the kernel's reclaim path
doesn't care whether a process is stopped. A perfect freeze gets you that
344 MB; hibernating gives back all 2,797 MB. So freeze is a CPU control, and
that is what the app calls it.

Torpor reports `phys_footprint`, not RSS — one idle session measured 24 MB by
RSS against 319 MB by footprint. Any RSS-based monitor is wrong about idle
processes by roughly ten times, which is why this exists.

## Where the usage numbers come from

| Source | Gives you | Standing |
|---|---|---|
| **Claude Code statusline** (default) | 5-hour and weekly windows, reset times, exact cost | Documented. No credentials, no usage data over the network |
| **Console API key** | Month-to-date spend, daily cost, per-model breakdown | Anthropic's documented path. Org accounts only |
| **Connect with Claude CLI** | The above plus per-model rows and credits | Undocumented endpoint, your credential |
| **Paste subscription token** | Same | Undocumented endpoint, your credential |

The default reads the payload Claude Code already hands your statusline, via a
small script that saves what Torpor needs and then runs whatever statusline you
had. Your prompt looks the same — or, if you had no statusline, you get a
minimal one showing the model and folder. That payload carries a cost figure
Claude Code has already computed, so Torpor prices nothing itself.

It carries no per-model limit, which is why there's no Fable or Opus bar on the
default source. Those rows come from your account, and only the two token
options reach them — your own OAuth credential against an endpoint Anthropic
doesn't document. They stay inert until you pick one and tick a box. Anthropic's
terms say OAuth is for their own clients, so that risk is yours, not mine.

## Updating and uninstalling

Torpor updates itself, checking a static appcast once a day. Updates carry an
EdDSA signature checked against a key built into the app — a check of my own,
independent of Apple's, not a substitute for it. Every release is notarised as
well.

Uninstalling has an order to it. `--uninstall-statusline` puts your original
statusline back in `~/.claude/settings.json`; run it first, and only run the
`brew` line if it succeeded — that is what the `&&` is doing. `--zap` deletes
`~/.torpor` and Application Support, which hold the shim your `settings.json`
points at, the only record of the statusline it was chaining to, and every
backup. In the other order Claude Code fails on every prompt render and there is
nothing left to restore from.

```sh
/Applications/Torpor.app/Contents/MacOS/Torpor --uninstall-statusline && \
  brew uninstall --zap --cask torpor
```

If the first command fails, stop and fix that. `brew uninstall --cask torpor`
without `--zap` is safe either way — it leaves the shim in place, so your
statusline keeps working.

Neither line touches the Keychain. If you saved a subscription token or a
Console API key, `security delete-generic-password -s dev.torpor.Torpor` removes
one — run it again if you saved both.

## Docs

- **[CLI reference](docs/cli.md)** — the same binary is a command line tool
- **[Notes on the internals](docs/internals.md)** — the undocumented Claude Code
  behaviour and the macOS memory accounting, measured rather than assumed

## Contributing

Bug reports are the useful thing. Torpor reads undocumented Claude Code
internals and upstream ships around six releases a week, so it will break and I
often won't have noticed. Include the output of `--list` and `--status`, and
your Claude Code version. The cask puts nothing on `PATH`, so that is:

```sh
/Applications/Torpor.app/Contents/MacOS/Torpor --list
```

[docs/cli.md](docs/cli.md) has an alias for it. More in
[CONTRIBUTING.md](CONTRIBUTING.md).

One hard rule for pull requests: no code path reads a subscription token or
contacts that endpoint without an explicit opt-in.

No telemetry, no analytics, no crash reporting, and there won't be any — Torpor
parses your transcripts to count tokens, and those hold your source code.

## License

MIT. See [LICENSE](LICENSE).

---

<p align="center">
  Built by <strong>Yasser Shkeir</strong><br>
  <a href="https://yasser-shkeir.com">yasser-shkeir.com</a> ·
  <a href="https://github.com/YasserShkeir">GitHub</a> ·
  <a href="https://www.linkedin.com/in/yasser-shkeir">LinkedIn</a>
</p>

<p align="center">
  <sub>Not affiliated with Anthropic. "Claude" is a trademark of Anthropic PBC.</sub>
</p>
