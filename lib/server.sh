#!/usr/bin/env bash
# Lifecycle of one remote-control server: start, stop, status.

crc_log() {
  local d; d="$(crc_log_dir)"; mkdir -p "$d"
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$d/crc.log"
}

say()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

# The trailing space is load-bearing: without it "100b " also matches "100bx".
srv_pids() { pgrep -f "remote-control --name $1 " 2>/dev/null || true; }
srv_running() { [ -n "$(srv_pids "$1")" ]; }

srv_session() { local p; p="$(reg_get "$1" session_prefix '')"; echo "${p}$1"; }

srv_dir() {
  local d; d="$(reg_get "$1" dir '')"
  [ -n "$d" ] || return 1
  case "$d" in "~"/*) d="$HOME/${d#\~/}" ;; esac
  echo "$d"
}

# Is this directory ready to host a server? Two failures we hit repeatedly.
srv_preflight() {
  local name="$1" dir problems=""
  dir="$(srv_dir "$name")" || { echo "no dir configured"; return 1; }
  [ -d "$dir" ] || problems="$problems directory-missing"
  if [ "$(reg_get "$name" spawn worktree)" = worktree ]; then
    "$(crc_git)" -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
      || problems="$problems not-a-git-repo(worktree-spawn-requires-one)"
  fi
  # Trust is recorded per directory in ~/.claude.json; without it the server exits at once.
  if [ -f "$HOME/.claude.json" ] && command -v python3 >/dev/null 2>&1; then
    python3 - "$dir" <<'PY' || problems="$problems workspace-not-trusted(run:'cd DIR && claude')"
import json, os, sys
p = os.path.expanduser("~/.claude.json")
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)                       # unreadable: do not block on a guess
proj = d.get("projects", {}).get(sys.argv[1])
sys.exit(0 if (proj or {}).get("hasTrustDialogAccepted") else 1)
PY
  fi
  [ -n "$problems" ] && { echo "${problems# }"; return 1; }
  return 0
}

srv_start() {
  local name="$1" dir session cmd tmux claude spawn mode extra logdir
  [ "$(reg_get "$name" enabled true)" = true ] || { say "$name: disabled in registry, skipping"; return 0; }

  # Liveness is checked on the process, never the tmux session: a crashed claude
  # leaves the session alive, and a session-based check would never restart it.
  if srv_running "$name"; then return 0; fi

  dir="$(srv_dir "$name")" || die "$name: no dir in registry"
  local why; why="$(srv_preflight "$name")" || { warn "$name: cannot start: $why"; crc_log "$name preflight failed: $why"; return 1; }

  tmux="$(crc_tmux)"   || die "tmux not found (set CRC_TMUX)"
  claude="$(crc_claude)" || die "claude not found (set CRC_CLAUDE)"
  session="$(srv_session "$name")"
  spawn="$(reg_get "$name" spawn worktree)"
  mode="$(reg_get "$name" permission_mode bypassPermissions)"
  extra="$(reg_get "$name" extra_args '')"
  logdir="$(crc_log_dir)"; mkdir -p "$logdir"

  # A tmux session whose server died is stale: recycle it rather than stacking panes.
  if "$tmux" has-session -t "=$session" 2>/dev/null; then
    "$tmux" kill-session -t "=$session"
    crc_log "$name recycled dead tmux session"
  fi

  cmd="cd $(printf '%q' "$dir") && $(printf '%q' "$claude") remote-control --name $name"
  cmd="$cmd --spawn $spawn --permission-mode $mode"
  cmd="$cmd --debug-file $(printf '%q' "$logdir/rc-$name.log")"
  [ -n "$extra" ] && cmd="$cmd $extra"

  if [ "${CRC_DRY_RUN:-0}" = 1 ]; then say "[dry-run] $session: $cmd"; return 0; fi

  "$tmux" new-session -d -s "$session" -c "$dir"
  sleep 1
  "$tmux" send-keys -t "${session}:0.0" "$cmd" C-m
  crc_log "$name started in $dir"
  say "$name: started"
}

srv_stop() {
  local name="$1" pids tmux session
  pids="$(srv_pids "$name")"
  tmux="$(crc_tmux)"; session="$(srv_session "$name")"
  if [ "${CRC_DRY_RUN:-0}" = 1 ]; then say "[dry-run] would stop $name (pids: ${pids:-none})"; return 0; fi
  if [ -n "$pids" ]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    say "$name: stopped (pid $(echo $pids | tr '\n' ' '))"
    crc_log "$name stopped"
  else
    say "$name: not running"
  fi
  if [ "${CRC_KEEP_SESSION:-0}" != 1 ] && "$tmux" has-session -t "=$session" 2>/dev/null; then
    "$tmux" kill-session -t "=$session" 2>/dev/null || true
  fi
}

# Environment id, from the pointer Claude Code keeps per project directory.
srv_env_id() {
  local dir mangled f
  dir="$(srv_dir "$1")" || return 1
  mangled="$(printf '%s' "$dir" | sed 's|/|-|g')"
  f="$HOME/.claude/projects/${mangled}/bridge-pointer.json"
  [ -f "$f" ] || return 1
  sed -n 's/.*"environmentId":"\([^"]*\)".*/\1/p' "$f"
}

srv_state() {
  local name="$1"
  if srv_running "$name"; then echo running
  elif [ "$(reg_get "$name" enabled true)" != true ]; then echo disabled
  else echo stopped; fi
}
