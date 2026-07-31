# Contributing

Bug reports are the most useful thing you can send. Torpor reads Claude Code
internals that Anthropic does not document, and Claude Code ships roughly six
releases a week — so things break, and I often will not have noticed.

## Reporting a bug

Include the output of:

```sh
Torpor --list
Torpor --status
Torpor --version
```

If sessions are missing or the numbers look wrong after a Claude Code update,
that is exactly the report worth filing. Say which Claude Code version you are
on — `claude --version`.

Those commands print project folder names. Redact anything you would rather not
share; nothing in them is needed verbatim.

## Building

```sh
swift build
./scripts/build-app.sh     # produces dist/Torpor.app
```

Requires macOS 14+ and a Swift 6 toolchain (Xcode 16+). There is no Xcode
project — it is a Swift package.

Useful while developing:

```sh
Torpor --preview <pid>          # what hibernate would capture, no side effects
Torpor --render /tmp/ui         # render the UI to PNG
Torpor --render-live /tmp/l.png # render the exact menu bar item, magnified
```

`--render-live` exists because a 1.8pt marker inside an 18pt status item cannot
be debugged by reading source.

## The one hard rule

**No code path may read a subscription OAuth token, or contact
`api.anthropic.com/api/oauth/usage`, without an explicit per-mode opt-in from
the user.** Anthropic banned accounts for that traffic pattern in January 2026,
and the risk lands on the user, not on us. The default usage source needs no
credentials at all and must stay that way.

## Style

Match what is there. In particular: when a decision is non-obvious, the reason
goes in a comment next to it, not in a commit message. Most of the tricky parts
of this codebase — why discovery cannot use the process name, why freezing frees
no memory, why the fill is clipped rather than rounded — are documented that way
because I had to learn each of them the hard way.
