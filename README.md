# crc — Claude Code remote-control servers, managed

Run a Claude Code **remote-control server** per workspace on a Mac or Linux box, so you can
drive each repository from the Claude mobile app or claude.ai/code. Servers live in detached
tmux sessions, survive reboot, restart themselves if they die, and are described by a plain
INI registry you can read, diff, and check into your dotfiles.

Works on macOS (launchd) and Linux (systemd user timer). Requirements: `bash`, `tmux`,
`git`, `claude`, and `gh` only if you want `crc add --create`.

## Install

**Homebrew (macOS):**

    brew install devsecopsinc/tap/crc
    crc supervise install          # boot + watchdog service (asks for sudo)

**Linux, or from source:**

    git clone https://github.com/devsecopsinc/claude-remote-control.git
    cd claude-remote-control
    ./install.sh --supervise       # symlink crc onto PATH + install the boot service

`crc doctor` tells you what is missing.

### Uninstall

    crc supervise uninstall        # remove the boot service first
    brew uninstall crc             # or: rm ~/.local/bin/crc
    rm -rf ~/.crc                  # registry — your repos are never touched

## Use

    crc add work --repo git@github.com:me/work.git     # clone, register, start
    crc add new  --create me/new-project               # create on GitHub first (needs gh)
    crc add here --dir ~/code/existing                 # adopt a directory you already have

    crc list                        # every server: state, pids, environment id, directory
    crc env work                    # the claude.ai URL that opens this workspace
    crc restart work                # one server; every other server keeps running
    crc restart work docs           # several
    crc restart --all               # everything (interrupts all live chats)
    crc stop work
    crc remove work                 # asks whether to delete the directory
    crc remove work --purge         # delete it; --keep-dir to keep it

    crc sessions work               # chat sessions that can be revived, newest first
    crc revive cse_01ABC…           # reattach one, in its own worktree and branch
    crc revive cse_01ABC… --branch x  # ...on a branch you name instead
    crc restart-session cse_01ABC…  # restart one live chat; its server and other chats keep running
    crc login                       # sign this machine in: prints a URL, takes the code
    crc login status --json         # what a remote client polls
    crc account list                # identities on this machine (second subscription)
    crc fork cse_01ABC… --account second   # continue a chat under the other account
    crc doctor                      # tools, registry, per-server readiness

A failed start is reported as such: `crc start` / `crc restart` wait for the server process
to come up and stay up, retry once, and exit non-zero if it does not.

`CRC_DRY_RUN=1` makes any command print what it would do and change nothing.

## Signing in

A headless box cannot read a locked login keychain, so Claude Code keeps its tokens in
`~/.claude/.credentials.json`. When a refresh fails that record is left empty, and every
chat on the machine dies with `OAuth session expired and could not be refreshed`. Nothing
recovers on its own, and `/login` does not exist inside a remote-control session.

    crc login                 # prints a URL, waits for the code, restarts the servers
    crc login --no-restart    # ...leave the servers alone

The sign-in needs a browser and a code pasted back, so it cannot be fully automated. The
steps are also separate commands, so something else — a phone, a small local web service —
can drive the same flow without holding a terminal open:

    crc login start [--json]  # {"url": "https://claude.com/cai/oauth/authorize?..."}
    crc login code <code>     # completes it, then restarts the servers
    crc login status [--json] # {"state":"ok","expires_at":…,"refresh_token":true,…}
    crc login cancel

`start` is idempotent: while a flow is open it hands back the same URL rather than
beginning a second sign-in. `crc doctor` reports the same credential state, including
the empty-record case, so a broken token shows up before every server does.

New credentials are only read at process start, which is why logging in restarts the
servers — and interrupts every live chat. That is unavoidable, not an oversight.

## Two subscriptions, one machine

A chat belongs to the account that created it. Two accounts cannot share a session, and
the app lists only environments owned by the account you are signed into. What they *can*
share is the machine and the worktree on it — `CLAUDE_CONFIG_DIR` gives each account a
complete, separate Claude identity (credentials, transcripts, settings, trust).

    crc account add second            # ~/.claude-second, settings copied from the primary
    crc login --account second        # sign it in; the servers are left alone
    crc account list                  # who each identity is signed in as

When one subscription hits its limit, hand the chat to the other:

    crc fork cse_01ABC… --account second

The conversation cannot move, but its transcript is a file and the local session id is
derived from the cloud one, so the second identity can resume it. You get a *new* session,
owned by the second account, carrying the history, in the same worktree on the same branch.
It appears in that account's app; the original is untouched. `--fork-session` keeps the two
transcripts separate, so the first account's chat still has its own.

### The shared log

Once two sessions work one worktree they diverge immediately, so `crc fork` installs two
hooks there (`hooks/session-log.py`, also installable by hand):

- **Stop** — appends what the turn did: branch, HEAD, commits added, files touched, and the
  closing message. Facts first, because prose drifts and git does not.
- **SessionStart** — injects what the *other* accounts did while this session was away.

It is built for the ways this goes wrong:

- **A watermark per reader**, so resuming ten times does not re-inject the same history ten
  times.
- **Echo suppression.** A turn written right after a sync is flagged, and never fed back to
  the account it came from — otherwise A reads B, paraphrases B, logs it, and B reads its
  own words back as news.
- **Compaction is recorded, not hidden.** Resume, fork and compact each write a marker with
  the tokens re-sent, so both sides can see where the other's picture of the work was
  rebuilt — and the injected text says to trust the tree over any summary.

    crc handoff cse_01ABC… --from-account second   # log an entry by hand, for chats
                                                   # that started before the hooks existed

The log lives in `~/.crc/session-logs/`, never in the repo.

## The registry

Config lives in `~/.crc`; logs go where the platform keeps logs. Override either with
`CRC_HOME`, `CRC_REGISTRY`, or `CRC_LOG_DIR`.

    ~/.crc/servers.ini                              the registry
    ~/Library/Logs/claude-remote-control/           logs (macOS)
    ${XDG_STATE_HOME:-~/.local/state}/claude-remote-control/logs/   logs (Linux)

`~/.crc/servers.ini`:

    [defaults]
    spawn           = worktree
    permission_mode = bypassPermissions
    enabled         = true

    [work]
    dir             = /Users/me/github/work
    repo            = git@github.com:me/work.git
    spawn           = worktree            # worktree | same-dir | session
    permission_mode = bypassPermissions
    enabled         = true                # false: keep it registered, never start it
    # session_prefix = crc-               # optional tmux session name prefix
    # extra_args     = --capacity 8       # appended to the remote-control command

`crc add` and `crc remove` maintain it; hand-editing is fine and takes effect on the next
`crc start` / `tick`.

Upgrading from an older layout? The first `crc` run moves the registry into `~/.crc` and the
logs into the platform log directory, and says what it moved. Nothing moves if you set
`CRC_HOME` / `CRC_LOG_DIR`, and nothing is ever overwritten.

## How it works

- One `claude remote-control --name <n> --spawn worktree` process per workspace, inside a
  detached tmux session named after the server.
- **Every chat gets its own git worktree** under `<repo>/.claude/worktrees/bridge-cse_*` on
  its own branch, so concurrent chats never share a directory. The one pre-created in-dir
  session per server is the exception: it runs in the repo root.
- The supervisor runs `crc tick` at boot and every 5 minutes. `tick` starts only what is not
  running, so it is a no-op on a healthy machine.
- **Liveness is checked on the process, not the tmux session.** A crashed `claude` leaves the
  session alive; a session-based check would never restart it.
- At boot the supervisor can fire before the network is up, which yields a server that never
  registers, so `tick` probes connectivity first (up to 120s) when anything needs starting.
- Environment ids are stable across restarts, upgrades and reboots because Claude Code keeps
  `bridge-pointer.json` per project directory. Bookmark `crc env <name>` and it keeps working.

## Platform notes

**macOS.** The supervisor is a LaunchDaemon, not a LaunchAgent: on a headless Mac nobody logs
in at the console, and LaunchAgents never fire until someone does. Install needs `sudo`.
Also worth setting: `sudo pmset -a sleep 0 autorestart 1`.

**Linux.** A systemd **user** timer. User units stop at logout unless lingering is enabled —
the same trap in different clothing:

    sudo loginctl enable-linger $USER

## Gotchas

- **A workspace must be trusted once** before a server will start there: `crc trust <name>`,
  or `cd <dir> && claude` and accept the dialogs. Otherwise the server exits immediately with
  `Workspace not trusted`. The dialog's option order is not stable — sometimes `No, exit` is
  selected first — so `crc trust` reads the screen and moves the cursor onto the option it
  wants rather than pressing Enter on a timer.
- **Your GitHub account must be linked in claude.ai → Settings → Connectors → GitHub**, and
  the repository must be in the Claude GitHub App's selection
  (`github.com/settings/installations`, or the org's Settings → GitHub Apps → Claude).
  Without it every session creation fails with `GitHub repository access check failed`: the
  server still starts and reports `Ready`, but stays at `0/32` sessions forever and mints a
  new environment id on every restart, breaking saved links. `crc doctor` reports this as
  `running, NO SESSIONS` and names the cause — it is the first thing to check when a server
  looks healthy but nothing works.
- **Stopping a server does not deregister its environment** (it is kept so sessions can
  resume), so repeatedly recreating servers leaves ghost entries in the app that cannot be
  cleaned up from the CLI. Prefer `crc restart` over remove/add, and open workspaces by the
  `crc env` URL rather than by picking from a list of same-named entries.
- **Old chats do not auto-resume** after a restart. They are on disk: `crc sessions <name>`
  then `crc revive <id>`, which puts the chat back in **its own worktree, on its own branch**,
  where its uncommitted work is. Newer Claude Code versions delete a chat's worktree on
  shutdown once it is clean and not ahead of its base; revive then **rebuilds the worktree
  on the branch the chat was last using**, read from that chat's transcripts. If the branch
  is gone too it is recreated at the repo's HEAD, and revive says so. `--branch <name>`
  overrides the branch it picks.
- **One chat can be restarted without its server.** Each live chat is its own process;
  `crc restart-session <cse_id>` stops it (refusing if it is mid-turn, unless `--force`), and
  the next message sent to that chat makes the server resume it in the same worktree. This is
  how a chat picks up startup-time config such as a new `.mcp.json`. It usually returns within
  seconds, but can take a couple of minutes.
- **`--session-id` cannot be combined with `--spawn`**, so a revived chat runs as its own
  single-session server and exits when the chat ends.
- **Auto mode's classifier can still block commands even in `bypassPermissions`**, because
  the client may switch a running session to auto mode. Configure `autoMode` in
  `~/.claude/settings.json` (the classifier ignores project settings) and keep `"$defaults"`
  in every list you touch.
