#!/usr/bin/env bash
# INI registry. Human-editable and greppable on purpose: the whole point of this file
# is that you can read it, diff it, and check it into a dotfiles repo.
#
#   [checklist]
#   dir             = /Users/you/github/checklist
#   repo            = git@github.com:you/checklist.git
#   spawn           = worktree
#   permission_mode = bypassPermissions
#   enabled         = true
#
# A [defaults] section supplies values for keys a server omits.

reg_file() { crc_registry; }

reg_init() {
  local f; f="$(reg_file)"
  [ -f "$f" ] && return 0
  mkdir -p "$(dirname "$f")"
  cat > "$f" <<EOF
# Claude remote-control server registry.
# Managed by 'crc add' / 'crc remove', but safe to edit by hand.

[defaults]
spawn           = worktree
permission_mode = bypassPermissions
enabled         = true
EOF
}

# List server section names, excluding [defaults], in file order.
reg_names() {
  local f; f="$(reg_file)"
  [ -f "$f" ] || return 0
  awk '/^[[:space:]]*\[/ {
         s=$0; sub(/^[[:space:]]*\[/,"",s); sub(/\][[:space:]]*$/,"",s)
         if (s != "defaults") print s
       }' "$f"
}

reg_has() {
  local n="$1"
  reg_names | grep -qxF "$n"
}

# Raw lookup in one section; empty output means unset.
reg_get_raw() {
  local f section key; f="$(reg_file)"; section="$1"; key="$2"
  [ -f "$f" ] || return 0
  awk -v want="$section" -v key="$key" '
    /^[[:space:]]*\[/ {
      s=$0; sub(/^[[:space:]]*\[/,"",s); sub(/\][[:space:]]*$/,"",s); sec=s; next
    }
    sec == want {
      line=$0
      sub(/^[[:space:]]*[;#].*$/,"",line)           # whole-line comment
      if (line ~ /=/) {
        k=line; sub(/=.*$/,"",k)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
        if (k == key) {
          v=substr(line, index(line,"=")+1)
          gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
          print v; exit
        }
      }
    }' "$f"
}

# Lookup with [defaults] fallback, then a caller-supplied default.
reg_get() {
  local name="$1" key="$2" fallback="${3:-}" v
  v="$(reg_get_raw "$name" "$key")"
  [ -n "$v" ] && { echo "$v"; return 0; }
  v="$(reg_get_raw defaults "$key")"
  [ -n "$v" ] && { echo "$v"; return 0; }
  echo "$fallback"
}

# Set a key, creating the section when needed. Rewrites atomically.
# Blank lines at the end of a section are held back so an appended key lands
# with the other keys rather than after the separator.
reg_set() {
  local f section key val tmp; f="$(reg_file)"; section="$1"; key="$2"; val="$3"
  reg_init
  tmp="$(mktemp "${TMPDIR:-/tmp}/crc.XXXXXX")"
  awk -v want="$section" -v key="$key" -v val="$val" '
    function emit_pending() {
      if (in_want && !done) { printf "%-15s = %s\n", key, val; done=1 }
    }
    function flush_blanks(   i) {
      for (i = 1; i <= nblank; i++) print ""
      nblank = 0
    }
    /^[[:space:]]*$/ { if (in_want) { blank[++nblank] = ""; next } print; next }
    /^[[:space:]]*\[/ {
      emit_pending(); flush_blanks()
      s=$0; sub(/^[[:space:]]*\[/,"",s); sub(/\][[:space:]]*$/,"",s)
      sec=s; in_want=(sec==want); if (in_want) seen=1
      print; next
    }
    in_want {
      flush_blanks()
      line=$0
      if (line ~ /=/) {
        k=line; sub(/=.*$/,"",k); gsub(/^[[:space:]]+|[[:space:]]+$/,"",k)
        if (k == key) { printf "%-15s = %s\n", key, val; done=1; next }
      }
      print; next
    }
    { print }
    END {
      emit_pending(); flush_blanks()
      if (!seen) { printf "\n[%s]\n", want; printf "%-15s = %s\n", key, val }
    }' "$f" > "$tmp" && mv "$tmp" "$f"
}

reg_remove_section() {
  local f section tmp; f="$(reg_file)"; section="$1"
  [ -f "$f" ] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/crc.XXXXXX")"
  awk -v want="$section" '
    /^[[:space:]]*\[/ {
      s=$0; sub(/^[[:space:]]*\[/,"",s); sub(/\][[:space:]]*$/,"",s)
      skip=(s==want); if (skip) next
    }
    !skip { print }' "$f" > "$tmp" && mv "$tmp" "$f"
}
