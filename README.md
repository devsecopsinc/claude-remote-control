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
    crc revive cse_01ABC…           # reattach one; it finds the owning workspace
    crc doctor                      # tools, registry, per-server readiness

`CRC_DRY_RUN=1` makes any command print what it would do and change nothing.

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
  `Workspace not trusted`.
- **Your GitHub account must be linked in claude.ai → Settings → Connectors → GitHub**, for
  every org that owns a registered repo. Without it every session creation fails with
  `GitHub repository access check failed`, no session is created, and the workspace's
  environment id changes on every restart, breaking saved links.
- **Stopping a server does not deregister its environment** (it is kept so sessions can
  resume), so repeatedly recreating servers leaves ghost entries in the app that cannot be
  cleaned up from the CLI. Prefer `crc restart` over remove/add, and open workspaces by the
  `crc env` URL rather than by picking from a list of same-named entries.
- **Old chats do not auto-resume** after a restart. They are on disk: `crc sessions <name>`
  then `crc revive <id>`.
- **`--session-id` cannot be combined with `--spawn`**, so a revived chat runs as its own
  single-session server and exits when the chat ends.
- **Auto mode's classifier can still block commands even in `bypassPermissions`**, because
  the client may switch a running session to auto mode. Configure `autoMode` in
  `~/.claude/settings.json` (the classifier ignores project settings) and keep `"$defaults"`
  in every list you touch.
