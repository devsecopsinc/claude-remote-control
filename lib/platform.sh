#!/usr/bin/env bash
# Platform abstraction: macOS and Linux differ in tmux location, log directory,
# and — the part that actually matters — how a background service survives reboot.

crc_os() {
  case "$(uname -s)" in
    Darwin) echo macos ;;
    Linux)  echo linux ;;
    *)      echo unsupported ;;
  esac
}

# Resolve a tool once, honouring an override, then fall back to common install paths.
# The supervisor runs with a minimal PATH, so nothing here may assume a login shell.
crc_find() {
  local var_override="$1"; shift
  if [ -n "$var_override" ] && [ -x "$var_override" ]; then echo "$var_override"; return 0; fi
  local c
  for c in "$@"; do
    if command -v "$c" >/dev/null 2>&1; then command -v "$c"; return 0; fi
    if [ -x "$c" ]; then echo "$c"; return 0; fi
  done
  return 1
}

crc_tmux() {
  crc_find "${CRC_TMUX:-}" tmux /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux
}

crc_claude() {
  crc_find "${CRC_CLAUDE:-}" claude "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude
}

crc_git() { crc_find "${CRC_GIT:-}" git /opt/homebrew/bin/git /usr/bin/git; }
crc_gh()  { crc_find "${CRC_GH:-}"  gh  /opt/homebrew/bin/gh  /usr/bin/gh;  }

# Config lives in ~/.crc (one obvious place, next to ~/.claude). Logs go where each
# platform keeps logs: Console.app reads ~/Library/Logs, and XDG_STATE_HOME is the
# Linux convention. Both are overridable.
crc_home()    { echo "${CRC_HOME:-$HOME/.crc}"; }
crc_registry(){ echo "${CRC_REGISTRY:-$(crc_home)/servers.ini}"; }

crc_log_dir() {
  if [ -n "${CRC_LOG_DIR:-}" ]; then echo "$CRC_LOG_DIR"; return; fi
  case "$(crc_os)" in
    macos) echo "$HOME/Library/Logs/claude-remote-control" ;;
    *)     echo "${XDG_STATE_HOME:-$HOME/.local/state}/claude-remote-control/logs" ;;
  esac
}

# Older layouts put the registry under XDG config, and 1.1.0 briefly put logs in
# ~/.crc/logs. Move both into place once, so an upgrade never orphans state the user
# still believes is live. Never runs when the location is set explicitly, and never
# overwrites something already at the destination.
crc_migrate_legacy() {
  local home logdir legacy_cfg
  home="$(crc_home)"; logdir="$(crc_log_dir)"
  if [ -z "${CRC_HOME:-}${CRC_REGISTRY:-}" ]; then
    legacy_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/claude-remote-control"
    if [ -f "$legacy_cfg/servers.ini" ] && [ ! -f "$home/servers.ini" ]; then
      mkdir -p "$home"
      mv "$legacy_cfg/servers.ini" "$home/servers.ini"
      rmdir "$legacy_cfg" 2>/dev/null || true
      echo "moved registry -> $home/servers.ini" >&2
    fi
  fi
  if [ -z "${CRC_LOG_DIR:-}" ] && [ -d "$home/logs" ] && [ ! -d "$logdir" ]; then
    mkdir -p "$(dirname "$logdir")"
    mv "$home/logs" "$logdir"
    echo "moved logs -> $logdir" >&2
  fi
}

# Default parent for cloned repos.
crc_workspace_root() { echo "${CRC_WORKSPACE_ROOT:-$HOME/github}"; }

# Reachability probe. At boot the supervisor fires before the network is up, and a
# server started then registers with nothing and sits there dead.
crc_wait_for_network() {
  local tries="${1:-24}" i=1
  while [ "$i" -le "$tries" ]; do
    if curl -sS -o /dev/null --max-time 5 https://api.anthropic.com/ 2>/dev/null; then
      [ "$i" -gt 1 ] && crc_log "network ready after $i probes"
      return 0
    fi
    sleep 5
    i=$((i + 1))
  done
  crc_log "network still unreachable after $((tries * 5))s - starting anyway"
  return 1
}
