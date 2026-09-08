# CLAUDE.md — crc

`crc` manages Claude Code **remote-control servers**: one per workspace, each in a detached
tmux session, described by an INI registry, supervised at boot. macOS and Linux.
Read `README.md` for the user-facing picture before changing code.

## Layout

    bin/crc            CLI: list add start restart stop remove trust sessions revive tick doctor supervise env
    lib/platform.sh    OS detection, tool discovery, paths, network probe
    lib/registry.sh    INI read/write (awk; no dependencies)
    lib/server.sh      one server's lifecycle: preflight, start, stop, state, env id
    install.sh         symlink onto PATH, optionally install the supervisor

Config is `~/.crc/servers.ini`; logs follow platform convention (`~/Library/Logs/...` on
macOS, `$XDG_STATE_HOME/...` on Linux) because that is where users and Console.app look.
`crc_migrate_legacy` relocates state from older layouts on first run; it must stay a no-op
when `CRC_HOME`/`CRC_REGISTRY`/`CRC_LOG_DIR` is set, and must never overwrite a destination
that already exists.

`crc` is reached through a symlink (Homebrew, `~/.local/bin`), so it resolves `BASH_SOURCE`
through symlinks before locating `lib/`. Do not replace that with a plain `dirname $0`.

## This code runs unattended

The supervisor executes `crc tick` every 5 minutes on machines nobody is watching, and the
repo is usually symlinked onto PATH, so an edit here is live immediately. There is no deploy
step. Assume every change ships to a running system.

## Rules

1. **`tick` and `start` must stay idempotent and side-effect-free when healthy.** They run
   every 5 minutes; anything that restarts a healthy server would kill live chats 12x an hour.
   After touching either, prove it: capture pids, run it, compare pids.
2. **Never restart servers the user did not ask about.** `restart --all` interrupts every
   in-flight chat on the machine. Default to the named form, and say how many chats will die
   (`pgrep -f "sdk-url" | wc -l`) before doing it.
3. **Match processes with the trailing space** — `pgrep -f "remote-control --name $n "`.
   Without it, `100b` also matches `100bx`.
4. **Check liveness on the process, never the tmux session.** A crashed `claude` leaves the
   session behind; session-based checks never notice and the server stays dead.
5. **Never destroy user data on a guess.** `remove` deletes a directory only on an explicit
   `--purge` or an interactive yes; when stdin is not a tty it keeps the directory.
6. **Respect `CRC_DRY_RUN=1`** in every code path that starts, stops, or deletes anything.
7. **Do not start throwaway servers to test.** Each server start registers an environment,
   and shutdown deliberately skips deregistration, so every experiment leaves a permanent
   ghost entry in the user's app. Test argument parsing in an untrusted temp dir: parsing
   fails before registration. Use `CRC_DRY_RUN=1` and a scratch `CRC_HOME` for everything else.
8. **Verify identity after any restart**: the environment id must not change
   (`crc list`, or `~/.claude/projects/<mangled-dir>/bridge-pointer.json`). A changed id
   means every saved link for that workspace is dead.
9. **Portability**: bash 3.2 (what macOS ships) — no associative arrays, no `mapfile`, no
   `${var,,}`. No GNU-only flags: `sed -i` and `date -d` differ on BSD. Prefer awk.
10. **No new runtime dependencies.** bash, tmux, git, coreutils, awk, sed. `gh` is optional
    and only for `crc add --create`. python3 is used for one optional trust check and must
    stay optional.

## Worktrees belong to sessions

A chat's branch and uncommitted work live in `<repo>/.claude/worktrees/bridge-<sid>`, not in
the repo root. Anything that resumes a session (`crc revive`) must `cd` into that worktree —
resuming from the root hands the conversation back on the default branch with its work
invisible, which is worse than not resuming at all because it looks like it worked.

## Interactive dialogs

`crc trust` drives Claude Code's trust and MCP prompts through tmux. **Never press Enter on a
timer**: the option order varies between repos (a cloned private repo put `No, exit` first),
so a blind Enter can answer the opposite of what was intended. Use `tui_choose`, which finds
the line matching the wanted option, moves the `❯` cursor onto it, and gives up rather than
sending keys into a dialog it does not recognise.

## Verifying a start

`srv_start` must confirm the process is up *and still up* a moment later (`srv_wait_settled`).
A command that dies immediately still appears in `pgrep` for an instant, so "it appeared once"
is not evidence it started. Do not report success from having sent keystrokes into tmux.

When testing failure paths, remember the watchdog: it starts registered servers every 5
minutes and will repair the very failure you are trying to observe. Use a scratch `CRC_HOME`
whose servers the supervisor does not know about. Also note macOS has `/usr/bin/false`, not
`/bin/false` — a non-existent override binary used to fall back silently and invalidate the
test; `crc_find` now refuses an override that is not executable.

## Testing

Never test against the user's live registry:

    export CRC_HOME=/tmp/crc-test CRC_LOG_DIR=/tmp/crc-test/logs CRC_DRY_RUN=1
    # setting CRC_HOME also disables legacy migration, so tests never touch real state
    bash -n bin/crc && bash -n lib/*.sh
    bin/crc add demo --dir /tmp/somerepo && bin/crc list && bin/crc restart demo

`resolve_names` runs in a subshell, so its `die` cannot exit the caller — callers must check
its exit status (`names="$(resolve_names "$@")" || exit 1`). This has already caused a bug
where an unknown server name printed an error and then continued.

## Shell hazard when editing over ssh

These files are often edited through `ssh host '...'`. An apostrophe inside a heredoc
terminates the outer single-quoted string and silently corrupts the file. Write locally and
`scp`, or verify afterwards. This has already produced one mangled script.

## Conventions

- `#!/usr/bin/env bash`, explicit PATH-independent tool discovery via `crc_find`.
- Log state changes to `$(crc_log_dir)/crc.log`; never log tokens or secrets.
- Comment the *why*. Most defensive lines here exist because of a specific production failure;
  keep the reason attached so nobody "simplifies" it away.
- Conventional commits (`feat:`, `fix:`, `docs:`).
