#!/usr/bin/env python3
"""Refuse a prompt in a session that is not the one holding a shared transcript.

'crc switch' hands a conversation to a second account by giving both identities a
symlink to one transcript file. One file is what makes the handover exact — there is
no copy to be stale — but it only works while exactly one session writes it.

Two writers do not corrupt the file. That is the problem. The jsonl is a tree: rows
carry uuid and parentUuid, so two sessions prompted at once attach to the same parent,
the file keeps both branches, and the next resume follows one and silently drops the
other. Measured: 81 valid lines, two children of one parent, and a reply that had
never heard of half of them. No error, no warning, one account's work simply gone.

crc refuses to start a second writer itself. It cannot refuse on behalf of a
remote-control server, which respawns its own chat whenever the chat gets a message
in the app — and that is precisely the case this hook exists for. The holder is
recorded in a claim file beside the transcript; a session whose identity is not the
holder gets exit 2, which blocks the prompt before it can be answered.

Blocks only when all of these hold: the session's transcript really is the shared
file, a claim sits beside it, and the claim names a different config dir. Everything
else — no central store, no claim, our own claim, an unreadable claim — goes through,
loudly where it matters.

The log hook (session-log.py) may still have consumed its watermark for a prompt this
one blocks: hooks on one event are not ordered, so there is nothing to sequence
against. Losing one injection beats losing a branch of the conversation.

Installed as a UserPromptSubmit hook by 'crc fork', 'crc switch' and 'crc hooks'.
"""
import json
import os
import sys

HOME = os.path.expanduser("~")


def central_home():
    return os.path.realpath(
        os.environ.get("CRC_TRANSCRIPT_HOME") or os.path.join(HOME, ".claude-transcripts"))


def config_dir():
    """This session's identity. CLAUDE_CONFIG_DIR is what separates two accounts."""
    return os.path.realpath(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"))


def account_hint():
    """What to put in '--to <name>': accounts live at ~/.claude-<name> by convention."""
    base = os.path.basename(config_dir())
    return base[len(".claude-"):] if base.startswith(".claude-") else "default"


def chat_id(cwd):
    """The id to name in a crc command. A chat's worktree is .../bridge-<session id>."""
    base = os.path.basename(os.path.abspath(cwd or "."))
    return base[len("bridge-"):] if base.startswith("bridge-") else base


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    path = payload.get("transcript_path")
    if not path:
        return 0

    real = os.path.realpath(path)
    root = central_home()
    if real != root and not real.startswith(root + os.sep):
        return 0                      # not a shared transcript: nothing to arbitrate

    claim_path = real + ".claim"
    try:
        with open(claim_path) as fh:
            claim = json.load(fh) or {}
    except FileNotFoundError:
        return 0                      # shared but unclaimed: no exclusivity asked for
    except Exception as exc:
        # Unreadable, not absent. Say so where someone will see it rather than
        # enforcing a rule read out of a broken file.
        sys.stderr.write("transcript-claim: cannot read %s (%s) — prompt allowed through\n"
                         % (claim_path, exc))
        return 0

    holder = claim.get("config_dir")
    if not holder or os.path.realpath(holder) == config_dir():
        return 0

    sid = chat_id(payload.get("cwd"))
    sys.stderr.write(
        "This conversation's transcript is held by account '%s' (since %s).\n"
        "\n"
        "Both accounts share one transcript file, and two sessions writing it at once\n"
        "fork the conversation: the file keeps both branches, the next resume follows\n"
        "one, and the other is dropped without a word. So this prompt was not sent.\n"
        "\n"
        "Take the chat over first:\n"
        "    crc switch %s --to %s\n"
        "\n"
        "If that claim is stale — nothing is running under '%s' — clear it with:\n"
        "    crc transcripts release %s\n"
        % (claim.get("account") or os.path.basename(holder),
           claim.get("set_at") or "an earlier switch",
           sid, account_hint(),
           claim.get("account") or os.path.basename(holder), sid))
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:          # noqa: BLE001
        # A guard that breaks the session it guards is worse than the race it
        # prevents. Fail open, and make the failure impossible to miss.
        sys.stderr.write("transcript-claim hook failed, prompt allowed through: %s\n" % exc)
        sys.exit(0)
