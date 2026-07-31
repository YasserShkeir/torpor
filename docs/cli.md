# Torpor CLI

The same binary is the menu bar app and a command line tool. Running it with no
arguments launches the app; any recognised flag runs a command and exits.

If you installed the cask, the binary is inside the bundle:

```sh
/Applications/Torpor.app/Contents/MacOS/Torpor --list
```

Worth an alias if you use it more than once:

```sh
alias torpor='/Applications/Torpor.app/Contents/MacOS/Torpor'
```

## Reading

None of these touch a session. They construct no polling timer, request no
notification permission, make no network call, and cannot trigger auto-hibernate.

| Command | What you get |
|---|---|
| `--list` | Every running session: pid, status, idle time, subtree footprint, subtree resident, MCP child count, project |
| `--groups` | The same, grouped by working directory, which is how the popover shows it |
| `--hibernated` | Sessions Torpor has hibernated and can bring back |
| `--status` | Statusline install state, the 5-hour and weekly percentages, per-model weekly rows if your account has them, and how old the reading is. No percentages until the shim is installed and Claude Code has rendered a prompt |
| `--preview <pid>` | What hibernating that session would capture and replay. Reads argv, changes nothing |
| `--resume-command <session-id>` | The command `--revive` would run. Prints, runs nothing |
| `--version`, `--help` | What they say |

An unrecognised flag prints usage to stderr and exits 2. Only a bare `Torpor`
launches the app.

## Acting

These change something. Each one is also reachable from the popover.

| Command | What happens |
|---|---|
| `--freeze <pid>` | SIGSTOP the session and its whole MCP subtree, deepest first. CPU to zero, memory unchanged |
| `--thaw <pid>` | SIGCONT the same subtree |
| `--hibernate <pid>` | Read argv, write the recovery record, then terminate the session and its subtree |
| `--revive <session-id>` | Reopen it in a terminal, in its original directory, with its replayable flags |

`--hibernate` writes the recovery record **before** it signals anything, so a
crash halfway through cannot leave a terminated session with no way back.

## Statusline

| Command | What happens |
|---|---|
| `--install-statusline` | Add the shim to `settings.json`, keeping whatever statusline you already had |
| `--uninstall-statusline` | Remove it and put your original back |
| `--emit-shim <path>` | Write the shim to a file so you can read it before installing it |

Run the uninstall **before** deleting the app. Nothing else will restore your
original statusline for you: the command the shim chains to is recorded only in
`~/.torpor/statusline-shim.sh`, and timestamped copies of your `settings.json`
sit in `~/Library/Application Support/Torpor` — putting either back is manual,
and `brew uninstall --zap` deletes both.

## Before you hibernate something

`--preview <pid>` shows what a hibernate would capture from a live session, and
`--resume-command <session-id>` prints the line a revive of a hibernated one
would run. Neither changes anything:

```sh
$ Torpor --resume-command 7b3e4cb7-...
cd /Users/you/Documents/GitHub/atlagene && claude --resume 7b3e4cb7-... --mcp-config ./mcp.json --model opus
```

A revive runs the same thing with a `clear` between the `cd` and the `claude`,
so the new terminal starts empty — that is the one difference. The working
directory is quoted only when it holds something a shell would otherwise
interpret.

`claude --resume` on its own is lossy: it restores the conversation but drops
`--mcp-config`, `--settings`, `--plugin-dir`, `--add-dir` and `--model`. Torpor
reads the process's argv before terminating it and replays those.

The replay list is an allowlist, not a passthrough. Two things it deliberately
drops:

- **Inline JSON.** `--mcp-config`, `--settings` and `--agent` accept a JSON blob
  as well as a path, and those blobs routinely carry an `env` block with tokens
  in it. Torpor refuses to write one to disk, and refuses the hibernate rather
  than replaying a command line it has quietly changed.
- **Permission grants.** `--dangerously-skip-permissions` and `--permission-mode`
  were scoped to a decision you made about the old process. Reviving is not the
  moment to re-grant them from a menu bar click.

If argv can't be read at all, hibernate refuses. A session it can't bring back is
one it won't end.

## Memory numbers

Every number Torpor sorts, groups or decides on is `phys_footprint`, not RSS.

RSS excludes compressed pages, and an idle process on macOS is mostly compressed
pages. One idle session here measured 24 MB by RSS against 319 MB by footprint.
Footprint is also far steadier between samples: the same process read 320.8,
321.0 and 320.9 MB on consecutive polls while its RSS swung between 22 and 65 MB.

`--list` is the one surface that also prints RSS, in the RESIDENT column, for
diagnostics. Read the two memory columns carefully: FOOTPRINT and RESIDENT are
the same process tree measured two ways, not the tree against the session on its
own. A row reading 612 MB and 366 MB is one tree, not two numbers to subtract —
and the 366 is the one the paragraph above says not to trust.

Both columns are the session plus every descendant, which is where most of it
lives. A session holding 616 MB across 7 processes is normal, and Activity
Monitor shows those 6 MCP servers as unrelated `node` rows.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Fine |
| 1 | The command ran and failed. The reason goes to stderr |
| 2 | Unrecognised or malformed arguments |
