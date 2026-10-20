#!/usr/bin/env python3
"""Adds or removes the usage tap in the Claude Code status-line script.

    statusline.py install <path to ClaudeUsage binary>
    statusline.py uninstall

The tap is a marked block placed right after the script's shebang. It reads the status-line
JSON from stdin, hands a copy to `ClaudeUsage --tap`, then puts the same JSON back on stdin,
so the rest of the script runs exactly as before. The script is backed up before any edit.
If there is no status line yet, a minimal one is created and registered in settings.json.
"""
import json
import os
import shlex
import shutil
import sys
import time

BEGIN = "# >>> claude-usage-tracker tap >>>"
END = "# <<< claude-usage-tracker tap <<<"

CLAUDE_DIR = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
SETTINGS = os.path.join(CLAUDE_DIR, "settings.json")
STATE_DIR = os.path.dirname(os.path.expanduser(
    os.environ.get("CLAUDE_USAGE_CONFIG") or "~/.config/claude-usage-tracker/config.json"))
STATE = os.path.join(STATE_DIR, "install-state.json")

MINIMAL = """#!/bin/bash
# Minimal Claude Code status line created by claude-usage-tracker: model and folder.
input=$(cat)
model=$(printf '%s' "$input" | sed -n 's/.*"display_name":"\\([^"]*\\)".*/\\1/p')
printf '%s %s' "${model:-Claude}" "$(basename "$PWD")"
"""


def block(binary):
    return f"""{BEGIN}
__cut_in=$(cat)
__cut_bin={shlex.quote(binary)}
[ -x "$__cut_bin" ] && printf '%s' "$__cut_in" | "$__cut_bin" --tap >/dev/null 2>&1
exec 0<<__CUT_EOF__
$__cut_in
__CUT_EOF__
unset __cut_in __cut_bin
{END}
"""


def load_json(path, default):
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def save_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def backup(path):
    dest = f"{path}.bak-claude-usage-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(path, dest)
    print(f"  backed up {path} -> {dest}")


def script_path(command):
    """The script file a statusLine command runs, or None if it is not a plain script path."""
    try:
        parts = shlex.split(command)
    except ValueError:
        return None
    if not parts:
        return None
    # Allow "bash ~/x.sh" as well as "~/x.sh".
    if os.path.basename(parts[0]) in ("bash", "sh", "zsh") and len(parts) > 1:
        parts = parts[1:]
    path = os.path.expanduser(os.path.expandvars(parts[0]))
    return path if os.path.isfile(path) else None


def install(binary):
    try:
        settings = load_json(SETTINGS, {})
    except json.JSONDecodeError:
        sys.exit(f"  {SETTINGS} is not valid JSON; fix it and run again.")
    state = load_json(STATE, {})
    command = (settings.get("statusLine") or {}).get("command")

    if not command:
        path = os.path.join(CLAUDE_DIR, "statusline.sh")
        if os.path.exists(path):
            backup(path)
        else:
            with open(path, "w") as f:
                f.write(MINIMAL)
            os.chmod(path, 0o755)
            state["createdScript"] = path
            print(f"  created a minimal status line at {path}")
        if os.path.exists(SETTINGS):
            backup(SETTINGS)
        settings["statusLine"] = {"type": "command", "command": path}
        save_json(SETTINGS, settings)
        state["addedSettings"] = path
        print(f"  registered it in {SETTINGS}")
    else:
        path = script_path(command)
        if path is None:
            sys.exit(f"  Your statusLine command ({command!r}) is not a script file, so it was left alone.\n"
                     f"  To add the tap by hand, pipe the status-line JSON to: {binary} --tap")

    with open(path) as f:
        text = f.read()
    if BEGIN in text:
        print(f"  tap already present in {path}; nothing to do")
    else:
        if "createdScript" not in state or state["createdScript"] != path:
            backup(path)
        lines = text.splitlines(keepends=True)
        if lines and lines[0].startswith("#!"):
            if not lines[0].endswith("\n"):
                lines[0] += "\n"
            lines.insert(1, block(binary))
        else:
            lines.insert(0, block(binary))
        with open(path, "w") as f:
            f.write("".join(lines))
        print(f"  added the tap to {path}")
    state["script"] = path
    save_json(STATE, state)


def uninstall():
    state = load_json(STATE, {})
    path = state.get("script")
    if not path:
        try:
            path = script_path((load_json(SETTINGS, {}).get("statusLine") or {}).get("command") or "")
        except json.JSONDecodeError:
            path = None

    if path and state.get("createdScript") == path and os.path.exists(path):
        os.remove(path)
        print(f"  removed {path} (created by the installer)")
    elif path and os.path.exists(path):
        with open(path) as f:
            text = f.read()
        if BEGIN in text and END in text:
            start = text.index(BEGIN)
            end = text.index(END) + len(END)
            if text[end:end + 1] == "\n":
                end += 1
            with open(path, "w") as f:
                f.write(text[:start] + text[end:])
            print(f"  removed the tap from {path}")

    added = state.get("addedSettings")
    if added:
        try:
            settings = load_json(SETTINGS, {})
            if (settings.get("statusLine") or {}).get("command") == added:
                del settings["statusLine"]
                save_json(SETTINGS, settings)
                print(f"  removed the statusLine entry the installer added to {SETTINGS}")
        except json.JSONDecodeError:
            print(f"  {SETTINGS} is not valid JSON; left it alone")

    if os.path.exists(STATE):
        os.remove(STATE)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "install":
        install(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "uninstall":
        uninstall()
    else:
        sys.exit(__doc__)
