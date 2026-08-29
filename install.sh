#!/usr/bin/env bash
# Install crc: put it on PATH and (optionally) install the boot supervisor.
#   ./install.sh              symlink into ~/.local/bin
#   ./install.sh --supervise  also install the LaunchDaemon / systemd timer
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="${CRC_BIN_DIR:-$HOME/.local/bin}"

mkdir -p "$BIN"
ln -sf "$ROOT/bin/crc" "$BIN/crc"
echo "installed $BIN/crc -> $ROOT/bin/crc"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not on your PATH — add it:"
     echo "      echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc" ;;
esac

"$ROOT/bin/crc" doctor || true

if [ "${1:-}" = "--supervise" ]; then
  "$ROOT/bin/crc" supervise install
fi

cat <<EOF

next:
  crc add <name> --repo <git-url>      register a workspace and start its server
  crc add <name> --create <owner/repo> create the repo first (needs gh)
  crc list                             see everything
EOF
