# Cleaning up a remote-control host

A box that serves Claude Code sessions accumulates three things that nobody deletes:
per-chat git worktrees, MCP child processes, and debug logs. None of it is noticed until
the disk or the swap runs out — and then it does not look like a resource problem. It
looks like Claude breaking.

This is the recipe, written after a Mac mini running 8 servers and ~36 chats filled 96% of
a 460 GB disk and 97% of swap.

## What it looks like when it is time

The symptoms arrive as bugs:

- `Worktree creation failed … Could not read the repository git config` — a session never
  gets a worktree, and the app says **"Remote Control didn't finish connecting"**.
- A chat's process sits in state `U+` (uninterruptible I/O) with its heartbeats still
  being answered, and the app says **"Can't reach <host>"**.
- `[event-loop-stall] blocked for 2822ms` repeated thousands of times in one session log.
- `Initial heartbeat failed … read ECONNRESET`.

Check the machine before chasing any of those:

    df -h /System/Volumes/Data        # macOS: the data volume, not /
    sysctl -n vm.swapusage
    pgrep -f 'sdk-url' | wc -l        # chats
    pgrep -x node | wc -l             # MCP children — expect several per chat
    du -sh ~/Library/Logs/claude-remote-control

## 1. Worktrees (usually the whole problem)

Every chat gets a worktree, every subagent gets one too, and each is a full checkout —
`node_modules`, build output, media. Ours averaged 500 MB and peaked at 2.1 GB.

    ls ~/github/<repo>/.claude/worktrees | wc -l
    du -sh ~/github/<repo>/.claude/worktrees

**Never delete by age alone.** A worktree is safe to remove only when it holds nothing that
exists nowhere else:

    dirty=$(git -C "$w" status --porcelain | wc -l)          # uncommitted, incl. untracked
    unpushed=$(git -C "$w" rev-list HEAD --not --remotes | wc -l)   # commits on no remote

Both zero means every line of its content is on a remote. Then add two more gates, because
"no uncommitted work" is not the same as "nobody is using it":

    lsof -a -p "$(pgrep -f 'claude|node' | paste -sd, -)" -d cwd -Fn | grep ^n | cut -c2-
    # ...and names mentioned in logs touched in the last 2 days:
    find ~/Library/Logs/claude-remote-control -name 'rc-*.log' -mtime -2

Remove what passes all four, re-checking dirty/unpushed immediately before each removal —
a worktree can wake up between the scan and the delete:

    git -C "$repo" worktree unlock "$w" 2>/dev/null
    git -C "$repo" worktree remove --force "$w"
    git -C "$repo" worktree prune

`git worktree remove` **never touches refs**. Branches survive, commits survive, and any
worktree can be recreated:

    git -C "$repo" worktree add .claude/worktrees/bridge-cse_XXXX worktree-bridge-cse_XXXX

What does not survive is ignored build output (`node_modules`, `.venv`, media caches).
That is the space you are reclaiming; it is also why the directories were so large.

## 2. MCP children

Each chat starts its own copy of every configured MCP server. With 36 chats we had 134 MCP
processes — including **two** chrome-devtools per chat, because the same server was
configured twice: once as a plugin and once as a user-scope entry.

    pgrep -f chrome-devtools-mcp | wc -l
    claude mcp list                      # what each session will start
    claude mcp remove <name> -s user     # drop a duplicate

Removing one duplicate halved that count. Sessions read MCP config at startup, so the
change lands on the next restart, never on a running chat.

## 3. Logs

    du -sh ~/Library/Logs/claude-remote-control
    find . -name 'bridge-transcript-*.jsonl' -mtime +7 -delete   # duplicates ~/.claude/projects
    find . -name 'rc-*-cse_*.log' -mtime +14 -delete             # per-session debug logs

Bridge transcripts are the big ones — ours reached 325 MB each.

## 4. Upgrade and restart, one server at a time

`claude update` installs alongside; running processes keep their version, so nothing breaks
until you restart. Then go **one server at a time** and confirm each before the next:

    crc restart <name>
    for i in $(seq 1 30); do pgrep -f "remote-control --name <name> " >/dev/null && break; sleep 3; done

The first start after an upgrade is slow — the new version unpacks and the servers compete
for its lock. A 15-second settle window is not enough on a loaded box; expect to retry one
or two. Restarting all of them at once turns that into a pile-up.

After restarting servers, check for orphans — chat processes whose parent is gone. They
cannot be reached by anyone and they hold memory:

    for p in $(pgrep -f -- "--session-id cse_"); do
      [ "$(ps -o ppid= -p $p | tr -d ' ')" = 1 ] && echo "orphan $p"
    done

Supervised forks (`crc forks`) are separate processes and need their own restart to pick up
a new binary. Each restart mints a new session link; `crc forks` records the latest.

## 5. Verify

    crc list            # every server running, environment ids unchanged
    crc forks           # every fork running
    crc doctor          # tools, auth, per-server readiness, directory/identity conflicts
    df -h /System/Volumes/Data; sysctl -n vm.swapusage

Environment ids must be the same as before: a changed id means saved links are dead.

## Result, for scale

| | before | after |
|---|---|---|
| disk free | 18 GB (96% full) | 54 GB |
| worktrees in the busiest repo | 199 | 91 |
| MCP processes | 134 | ~12 |
| swap used | 29.8 / 30.7 GB | 21 / 26 GB |
| logs | 2.2 GB | 1.6 GB |

108 worktrees removed, none skipped, nothing lost: every one was verified clean and fully
pushed twice, and the 21 that carried uncommitted or unpushed work were kept.

## Keeping it from coming back

- Close chats you are done with. Each one costs a worktree, a process, and its MCP children.
- Keep one MCP server configured once. Plugin *or* user scope, not both.
- Run the worktree sweep on a schedule — the gates above make it safe to automate.
- Watch `df` and `vm.swapusage`, not the symptoms. By the time Claude misbehaves, the
  machine has been starved for a while.
