# CLAUDE.md — crc

`crc` manages Claude Code **remote-control servers**: one per workspace, each in a detached
tmux session, described by an INI registry, supervised at boot. macOS and Linux.
Read `README.md` for the user-facing picture before changing code.

## Layout

    bin/crc            CLI: list add start restart restart-session stop remove login account fork switch transcripts hooks handoff trust sessions revive tick doctor supervise env
    lib/platform.sh    OS detection, tool discovery, paths, network probe
    lib/registry.sh    INI read/write (awk; no dependencies)
    lib/server.sh      one server's lifecycle: preflight, start, stop, state, env id,
                       and trust_root/trust_ok/trust_conf — identity trust, keyed on
                       the config dir and on the repo root (not the worktree)
    hooks/             session-log.py: the Stop / UserPromptSubmit / SessionStart set
                       that keeps two accounts' sessions aware of each other in a
                       shared worktree. One watermark per reader gates all reads, so
                       adding a read point can never double-inject an entry.
                       transcript-claim.py: the UserPromptSubmit guard that blocks a
                       prompt in the account that does not hold a shared transcript.
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
   Without it, `work` also matches `workx`.
4. **Check liveness on the process, never the tmux session.** A crashed `claude` leaves the
   session behind; session-based checks never notice and the server stays dead.
5. **Never destroy user data on a guess.** `remove` deletes a directory only on an explicit
   `--purge` or an interactive yes; when stdin is not a tty it keeps the directory.
6. **Respect `CRC_DRY_RUN=1`** in every code path that starts, stops, or deletes anything.
   `chat_kill` and `fork_stop` carry the guard themselves, because a call site that
   forgets it stops a live chat while printing a rehearsal — which `crc switch` did for
   a whole release, its dry-run branch sitting *below* the loop that stops the writer.
   Put the check in the primitive, and place a command's dry-run branch above anything
   that acts. When a dry run skips the acting, it must also skip the verification that
   assumed it: switch re-checks for writers only when it actually stopped some.
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
    and only for `crc add --create`. python3 is required for the shared log, the transcript
    guard and `crc transcripts check`; it stays *optional* for servers, trust and everything
    `crc tick` does, so a box without it still runs.
11. **Never move a transcript that something is writing.** A live session opens the file per
    write, so a `mv` under its feet loses whatever it appends next, without an error.
    `crc transcripts centralize` refuses on a live writer; keep that refusal.

## One transcript, two identities

`crc switch` moves a chat between accounts by giving both identities a symlink to one
transcript file under `~/.claude-transcripts/` (`CRC_TRANSCRIPT_HOME`). The mechanics are
load-bearing and were established by measurement, not documentation:

- Claude Code **appends in place** — opens the file per write, appends, closes, never
  renames, holds no handle. That is why a symlink works and why the file can be moved while
  nothing is resuming it.
- `--resume <uuid>` **without** `--fork-session` continues the same file. `--fork-session`
  mints a new uuid, which is exactly what sharing must not do. A registry entry carrying a
  `uuid` key is pinned: resume that id, no `--fork-session`.
- The jsonl is a **tree**, not a chain (`uuid` / `parentUuid`). Two sessions resuming one
  file attach to the same parent; the file keeps both branches and the next resume follows
  one. The dropped branch throws nothing and logs nothing. Verified: 81 valid lines, two
  children of one parent, one account's work gone from the conversation.

So **one writer per chat** is the invariant, enforced in two places that must both stay:

1. `tx_writers` — every crc-driven resume refuses while another writer lives. It returns 2
   when it could not read the process table at all, and callers refuse on that too: "I could
   not look" is not "nothing is there". Do not collapse those cases.
2. `hooks/transcript-claim.py` — blocks the first message of a session whose identity is not
   the claim holder. crc cannot cover this itself: a remote-control server respawns its own
   chat whenever the chat is messaged in the app. The guard fails *open* on its own errors
   (breaking the session is worse than the race) but never on a claim it successfully read.

`crc transcripts check` is the only way to see the damage after the fact — it looks for rows
with two children. Keep it working; nothing else reports this failure.

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

Two things about trust that cost a debugging session each, both verified on 2.1.319:

- **Trust is recorded against the main worktree, not the linked one.** Answering the dialog
  inside `<repo>/.claude/worktrees/bridge-cse_…` writes the entry for `<repo>`; the worktree
  path is never added. A check that asks about the worktree is false forever — which is why
  `trust_root` exists, and why the primary identity has one worktree entry for 49 worktrees.
- **`claude --print` never shows the dialog** and records nothing, so a headless run proves
  nothing about trust. Testing with `--print` is what made it look as though the dialog had
  been removed from the product.

## Verifying a start

`srv_start` must confirm the process is up *and still up* a moment later (`srv_wait_settled`).
A command that dies immediately still appears in `pgrep` for an instant, so "it appeared once"
is not evidence it started. Do not report success from having sent keystrokes into tmux.

When testing failure paths, remember the watchdog: it starts registered servers every 5
minutes and will repair the very failure you are trying to observe. Use a scratch `CRC_HOME`
whose servers the supervisor does not know about. Also note macOS has `/usr/bin/false`, not
`/bin/false` — a non-existent override binary used to fall back silently and invalidate the
test; `crc_find` now refuses an override that is not executable.

## Telling a working chat from an idle one

`chat_mid_turn` reads the chat's own debug log and is what `switch` and `restart-session`
rely on before they stop anything. Two things about it, both paid for:

- **Only `stop=end_turn` ends a turn.** The engine also logs `[engine] turn N end` with
  `stop=tool_use` — an accounting turn closing when the model asks for a tool, after which
  the conversation runs the tool and continues. Matching every `turn N end` made the window
  between that line and the next request read as idle, and `switch` stopped a chat eight
  seconds into a `Bash` call it had just dispatched. Across every session log on the
  machine: 1585 `end_turn` against 25 `tool_use`/`stop_sequence`/`null`, and every one of
  those 25 carried on afterwards — 183 to 652 further requests before the real end.
- **`unknown` is not `idle`.** A process with no readable debug log returns `unknown`, and
  callers must refuse rather than assume quiet.

Test it against a captured `rc-<server>-<sid>.log`, not a hand-written one: replay the real
file truncated to the moment in question and check the verdict flips. `ps` is what supplies
the log path, so fixtures need a process whose argv carries `--debug-file` — and
`bash -c 'sleep 20'` exec-optimises into bare `sleep`, discarding that argv, so write
`bash -c 'sleep 20; true'` or the fixture silently tests nothing.

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
