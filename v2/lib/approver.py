#!/usr/bin/env python3
"""Scoped auto-approver core: reads opencode's permission dialog from a pane snapshot and decides with approver.policy.

No keys are sent here and no state is written: the bash layer (approver.sh) does the acting.

  approver.py evaluate --cwd DIR --policy FILE      pane text on stdin -> "none" or one tab-separated decision line
  approver.py decide   --cwd DIR --policy FILE "tool|target"   -> "ALLOW <reason>" (rc 0) | "REFUSE <reason>" (rc 1)

Dialog layout (opencode v2.0.21; the real capture in tests/fixtures wins over the binary's component code):
  △ Permission required            (narrow panes: "△ Permission"; mono mode: "! Permission required")
  <blank row>
  $ <command, wrapped by characters at the dialog width>      (no "Shell command" title line in practice)
  <heredoc body rows: data>
  Allow once   Always allow   Reject      ctrl+f fullscreen  ⇆ select  enter confirm
Other kinds: "→ Edit|Read|List <path>", "← Access external directory <dir>" + "- <pattern>" rows, "Path: <p>".
Every title is optional. The dialog opens with "Allow once" selected, so a single Enter answers it.
Paths in titles are relative to the agent's directory when inside it, "~/..." under home, absolute otherwise.
"""
import fnmatch
import hashlib
import itertools
import os
import re
import sys

HOME = os.path.expanduser("~")
BORDER = " \t┃│╹╻▀▄▌▐"
GLOB_CHARS = set("*?[")


# --- policy -----------------------------------------------------------------
class Policy:
    def __init__(self):
        self.roots = []
        self.project_root = False   # root-project: the agent's git repository and its worktrees
        self.bridge_io = False      # root-bridge-io: $BRIDGE_DIR/inbox and outbox, plus the bridge CLI as an executable
        self.tools = []
        self.never = []        # globs matched against each command segment
        self.never_re = []     # regexes matched against the whole command
        self.never_path = []   # prefixes or globs matched against absolute paths
        self.safe_path = []    # globs allowed anywhere in a command (outside the roots)
        self.safe_exec = []    # globs allowed as the executable of a command
        self.max_lines = 8


FLAG_DIRECTIVES = ("root-project", "root-bridge-io")


def git_lines(cwd, *args):
    import subprocess
    try:
        r = subprocess.run(["git", "-C", cwd, *args], capture_output=True, text=True, timeout=10,
                           env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
    except (OSError, subprocess.SubprocessError):
        return []
    return r.stdout.splitlines() if r.returncode == 0 else []


def project_roots(cwd):
    """The git repository containing cwd and every worktree of it; [] when cwd is not inside a git repository."""
    if not cwd or not os.path.isdir(cwd):
        return []
    top = git_lines(cwd, "rev-parse", "--show-toplevel")
    if not top:
        return []
    found = [top[0]]
    found += [l[len("worktree "):] for l in git_lines(cwd, "worktree", "list", "--porcelain") if l.startswith("worktree ")]
    out = []
    for d in found:
        for v in (d, os.path.realpath(d)):
            v = os.path.normpath(v)
            if v != "/" and v not in out:
                out.append(v)
    return out


def resolve_dynamic_roots(pol, cwd):
    """Add the roots that depend on where the agent is (root-project) and on the bridge data dir (root-bridge-io)."""
    if pol.project_root:
        pol.roots += [r for r in project_roots(cwd) if r not in pol.roots]
    bridge = os.environ.get("BRIDGE_DIR", "")
    if pol.bridge_io and bridge.startswith("/"):
        b = os.path.normpath(bridge)
        for v in {b, os.path.realpath(b)}:
            pol.roots += [os.path.join(v, "inbox"), os.path.join(v, "outbox")]
            pol.safe_exec += [os.path.join(v, "bridge.sh"), os.path.join(v, "v2", "bridge.sh")]


def expand_home(p):
    p = p.replace("${HOME}", HOME).replace("$HOME", HOME)
    if p == "~" or p.startswith("~/"):
        p = HOME + p[1:]
    return p


def load_policy(path):
    pol = Policy()
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except OSError:
        sys.exit(f"cannot read the policy file {path}")
    for raw in lines:
        line = raw.split("  #")[0].strip() if "  #" in raw else raw.strip()
        if not line or line.startswith("#"):
            continue
        key, _, val = line.partition(" ")
        val = val.strip()
        if not val and key not in FLAG_DIRECTIVES:
            continue
        if key == "root":
            pol.roots.append(os.path.normpath(expand_home(val)))
        elif key == "root-project":
            pol.project_root = True
        elif key == "root-bridge-io":
            pol.bridge_io = True
        elif key == "tool":
            pol.tools += val.split()
        elif key == "never":
            pol.never.append(val)
        elif key == "never-regex":
            pol.never_re.append(re.compile(val))
        elif key == "never-path":
            pol.never_path.append(expand_home(val))
        elif key == "safe-path":
            pol.safe_path.append(expand_home(val))
        elif key == "safe-exec":
            pol.safe_exec.append(expand_home(val))
        elif key == "max-command-lines":
            pol.max_lines = int(val)
        else:
            sys.exit(f"unknown policy directive {key!r} in {path}")
    return pol


# --- path helpers -----------------------------------------------------------
def absolute(p, cwd):
    p = expand_home(p)
    if not p.startswith("/"):
        p = os.path.join(cwd, p)
    return os.path.normpath(p)


def in_roots(pol, p, strict=False):
    for r in pol.roots:
        if p.startswith(r + "/") or (p == r and not strict):
            return True
    return False


def never_path_hit(pol, p):
    for pat in pol.never_path:
        if GLOB_CHARS & set(pat):
            if fnmatch.fnmatchcase(p, pat):
                return pat
        elif p == pat or p.startswith(pat + "/"):
            return pat
    return None


def check_path(pol, p, strict=False):
    """None when the absolute path may be touched, else the refusal reason."""
    hit = never_path_hit(pol, p)
    if hit:
        return f"touches the protected path {hit}"
    if not in_roots(pol, p, strict):
        return f"path {p} is outside the allowed roots"
    return None


# --- bash commands ----------------------------------------------------------

def split_segments(cmd):
    """Split on && || ; | & and newlines outside quotes; $( and backticks start a new segment even inside "..."."""
    segs, cur, q, i = [], [], None, 0

    def cut():
        segs.append("".join(cur))
        cur.clear()

    while i < len(cmd):
        c = cmd[i]
        if q == "'":
            cur.append(c)
            q = None if c == "'" else q
        elif c == "\\":
            cur.append(cmd[i:i + 2])
            i += 1
        elif q == '"':
            if c == '"':
                q = None
                cur.append(c)
            elif cmd.startswith("$(", i):
                cut()
                i += 1
            elif c == "`":
                cut()
            else:
                cur.append(c)
        elif c in "'\"":
            q = c
            cur.append(c)
        elif cmd.startswith(("&&", "||"), i):
            cut()
            i += 1
        elif c == "&" and (cmd[i - 1:i] == ">" or cmd[i + 1:i + 2] == ">"):
            cur.append(c)
        elif c in ";|&\n`()":
            cut()
        elif cmd.startswith("$(", i):
            cut()
            i += 1
        else:
            cur.append(c)
        i += 1
    cut()
    return segs


ASSIGN_RE = re.compile(r"^(?:\w+=\S*\s+)+")
PATH_RE = re.compile(r"""(?<![\w.$:/-])(~(?:/[^\s'"`;|&)(<>]*)?|/[^\s'"`;|&)(<>]*)""")
TOKEN_SPLIT = re.compile(r"""[\s'"`;|&()<>=]+""")


def normalize_segment(seg):
    seg = re.sub(r"""["'`(){}]""", " ", seg)
    seg = re.sub(r"\s+", " ", seg).strip()
    return ASSIGN_RE.sub("", seg + " ").strip()


# `git commit -m "text"`: the message is inert data, so path-like words in it must not be treated as paths.
# A message with $(...), backticks or ${...} is kept: the shell would run it.
COMMIT_MSG_RE = re.compile(r"""(?P<flag>\s(?:-m|--message)(?:=|\s+))(?:"(?P<dq>(?:[^"\\]|\\.)*)"|'(?P<sq>[^']*)')""")


def strip_commit_messages(cmd):
    def repl(m):
        body = m.group("dq") if m.group("dq") is not None else m.group("sq")
        if "$(" in body or "`" in body or "${" in body:
            return m.group(0)
        return m.group("flag") + "MSG"
    return COMMIT_MSG_RE.sub(repl, cmd)


def decide_bash(pol, cmd, cwd):
    cmd = cmd.strip()
    if not cmd:
        return False, "empty command"
    lines = cmd.splitlines()
    if len(lines) > pol.max_lines:
        return False, f"long command ({len(lines)} lines): the dialog may hide part of it"
    if any(l.rstrip().endswith(("…", "...")) for l in lines):
        return False, "the command looks truncated in the dialog"
    flat = re.sub(r"\s+", " ", cmd.replace("$HOME", HOME).replace("${HOME}", HOME))
    for rx in pol.never_re:
        if rx.search(flat):
            return False, f"matches never rule /{rx.pattern}/"
    # from here on only the command's shape matters: commit message text is not scanned for paths
    cmd = strip_commit_messages(cmd)
    flat = re.sub(r"\s+", " ", cmd.replace("$HOME", HOME).replace("${HOME}", HOME))
    segs = [normalize_segment(s) for s in split_segments(cmd)]
    segs = [s for s in segs if s]
    for s in segs:
        for pat in pol.never:
            if fnmatch.fnmatchcase(s, pat) or fnmatch.fnmatchcase(s, "* " + pat):
                return False, f"matches never rule '{pat}'"
    # protected paths, however they are spelled (relative tokens are resolved against the agent's directory)
    tokens = [t for t in TOKEN_SPLIT.split(expand_home(flat)) if t and not t.startswith("-")]
    for t in tokens:
        hit = never_path_hit(pol, absolute(t, cwd))
        if hit:
            return False, f"touches the protected path {hit}"
    # recursive deletes must stay strictly inside a root
    for s in segs:
        words = s.split()
        if "rm" in words:
            ops = words[words.index("rm") + 1:]
            flags = [w for w in ops if w.startswith("-")]
            if any(re.fullmatch(r"-[A-Za-z]*[rR][A-Za-z]*", f) or f == "--recursive" for f in flags):
                targets = [w for w in ops if not w.startswith("-")]
                if not targets:
                    return False, "rm -r without a clear target"
                for w in targets:
                    if "$" in w:
                        return False, "rm -r with an unresolved variable"
                    p = absolute(w, cwd)
                    if not in_roots(pol, p, strict=True):
                        return False, f"rm -r target {p} is not strictly inside the allowed roots"
    # every absolute or home path must be inside the roots; ".." must not climb out of them
    execs = {s.split(" ")[0] for s in segs}
    for m in PATH_RE.finditer(flat):
        raw = m.group(1).rstrip(",.:")
        p = absolute(raw, cwd)
        if raw in execs and any(fnmatch.fnmatchcase(p, g) for g in pol.safe_exec):
            continue
        if any(fnmatch.fnmatchcase(p, g) for g in pol.safe_path):
            continue
        why = check_path(pol, p)
        if why:
            return False, why
    for t in tokens:
        if ".." in t.split("/") and not t.startswith(("/", "~")):
            why = check_path(pol, absolute(t, cwd))
            if why:
                return False, why
    return True, "bash command inside the allowed roots"


# --- decision ---------------------------------------------------------------
def decide(pol, tool, targets, cwd):
    if tool not in pol.tools:
        return False, f"tool '{tool}' is not allowed (only {' '.join(pol.tools) or 'none'})"
    if not targets or not any(t.strip() for t in targets):
        return False, "no target to check"
    if tool == "bash":
        return decide_bash(pol, targets[0], cwd)
    for t in targets:
        t = t.strip()
        if tool == "external_directory":
            i = t.find("*")
            if i == 0 or (i > 0 and t[i - 1] != "/"):
                return False, "wildcard that is not a whole path segment"
            if i > 0:
                t = t[:i].rstrip("/")
        why = check_path(pol, absolute(t, cwd))
        if why:
            return False, why
    return True, f"{tool} inside the allowed roots"


# --- dialog parsing ---------------------------------------------------------
HEADER_RE = re.compile(r"[△!]\s*Permission(?: required)?")
HEREDOC_RE = re.compile(r"(?<!<)<<(-?)\s*(['\"]?)([A-Za-z_][\w.-]*)\2")
WIDE_GAP = re.compile(r" {8,}")
MAX_VARIANTS = 16


def clean(line):
    return line.strip(BORDER)


def split_heredocs(lines):
    """(command lines without heredoc bodies, True when every heredoc terminator was seen, marker lines)."""
    out, pending, marked = [], [], []
    for line in lines:
        if pending:
            term, dash = pending[0]
            if (line.lstrip("\t") if dash else line).rstrip() == term:
                pending.pop(0)
            continue
        out.append(line)
        found = HEREDOC_RE.findall(line)
        if found:
            marked.append(line)
            pending += [(m[2], m[0] == "-") for m in found]
    return out, not pending, marked


def command_variants(rows):
    """Readings of the rows of a bash command, as (command text, problem). The dialog wraps long lines by
    characters at its width, so a row as wide as the widest one continues in the next row; whether the break fell
    inside a token or replaced a space is unknowable, so both readings are produced (a request is approved only
    if EVERY reading is allowed). A break after a shorter row is a real newline."""
    width = max((len(r) for r in rows), default=0)
    wraps = [k for k in range(len(rows) - 1) if width >= 20 and len(rows[k]) >= width]
    choices = [("", " ")] * len(wraps)
    combos = [()] if not wraps else None
    if combos is None:
        if len(wraps) <= 4:
            combos = [c for c in itertools.product(*choices)]
        else:
            combos = [tuple([""] * len(wraps)), tuple([" "] * len(wraps))]
    out = []
    for combo in combos[:MAX_VARIANTS]:
        glue = dict(zip(wraps, combo))
        lines, cur = [], rows[0] if rows else ""
        for k in range(1, len(rows)):
            if k - 1 in glue:
                cur += glue[k - 1] + rows[k]
            else:
                lines.append(cur)
                cur = rows[k]
        lines.append(cur)
        cmd_lines, complete, marked = split_heredocs(lines)
        if not complete:
            if all(re.search(r"\bgit\b.*\bcommit\b", m) for m in marked):
                note = ""   # the hidden tail is the commit message (data); see the README for the residual risk
            else:
                out.append(("", "truncated command: the heredoc terminator is not visible"))
                continue
        else:
            note = ""
        text = "\n".join(cmd_lines).strip("\n")
        if any(WIDE_GAP.search(l) for l in cmd_lines):
            out.append(("", "wide gap inside a command row (side panel text?)"))
            continue
        out.append((text, note))
    return out


def parse_dialog(text):
    """The permission dialog at the bottom of the snapshot as {tool, targets, variants, sig, rows}, or None.
    tool is None for a dialog whose kind could not be recognised (the caller logs its rows)."""
    lines = [clean(l) for l in text.splitlines()]
    heads = [i for i, l in enumerate(lines) if HEADER_RE.fullmatch(l)]
    if not heads:
        return None
    h = heads[-1]
    a = next((i for i in range(h + 1, len(lines)) if "Allow once" in lines[i]), None)
    if a is None or a - h > 80 or len(lines) - a > 10:
        return None
    if not any("Reject" in l for l in lines[a:a + 4]):
        return None
    if any("Tell OpenCode what to do differently" in l for l in lines[h:]):
        return None
    rows = lines[h + 1:a]
    while rows and rows[0] == "":
        rows.pop(0)
    while rows and rows[-1] == "":
        rows.pop()
    if not rows:
        return None
    sig = hashlib.sha1("\n".join(lines[h:a + 1]).encode()).hexdigest()[:16]
    first_rows = [l for l in lines[h:a + 1] if l][:10]
    res = {"tool": None, "targets": [], "variants": None, "sig": sig, "rows": first_rows}
    body = [l for l in rows if l]
    title = re.sub(r"^\S\s+", "", body[0]) if not body[0][0].isalnum() and not body[0].startswith("$") else body[0]
    # bash: recognised by its "$ " command line, with or without a "Shell command" title
    cmd_at = next((k for k, l in enumerate(rows) if l == "$" or l.startswith("$ ")), None)
    if cmd_at is not None and (cmd_at == 0 or title == "Shell command" or all(l == "" for l in rows[:cmd_at])
                               or re.fullmatch(r"\S?\s*Shell command", rows[0])):
        cmd_rows = rows[cmd_at:]
        cmd_rows[0] = cmd_rows[0][2:]
        res.update(tool="bash", variants=command_variants(cmd_rows))
        res["targets"] = [(res["variants"][-1][0] or " ".join(cmd_rows))]
        return res
    m = re.fullmatch(r"(?:\S\s+)?(Edit|Read|List) (.+)", body[0])
    if m:
        res.update(tool=m.group(1).lower(), targets=[m.group(2)])
    elif (m := re.fullmatch(r"(?:\S\s+)?Access external directory (.+)", body[0])):
        res.update(tool="external_directory", targets=[m.group(1)] + [l[2:] for l in body[1:] if l.startswith("- ")])
    elif body[0].startswith("- /") or all(l.startswith("- ") for l in body):
        res.update(tool="external_directory", targets=[l[2:] for l in body if l.startswith("- ")])
    elif any(l.startswith("Operation:") for l in body):
        res.update(tool="lsp", targets=[title])
    elif body[0].startswith("Path: "):
        res.update(tool="read", targets=[body[0][6:]])
    elif title.startswith("WebFetch") or body[0].startswith("URL: "):
        res.update(tool="webfetch", targets=[title])
    elif title.startswith(("Glob ", "Grep ")):
        res.update(tool=title.split(" ")[0].lower(), targets=[title])
    elif title.endswith("Subagent"):
        res.update(tool="subagent", targets=[title])
    elif title.startswith("Continue after repeated failures"):
        res.update(tool="doom_loop", targets=[title])
    elif title.startswith("Call tool "):
        res.update(tool="call:" + title[len("Call tool "):], targets=[title])
    return res


def one_line(s, n=300):
    s = re.sub(r"\s+", " ", s).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def evaluate(pol, d, cwd):
    """(kind, tool, target, reason) with kind allow | refuse | unrecognised."""
    if d["tool"] is None:
        return "unrecognised", "-", one_line(" ⏎ ".join(d["rows"]), 700), "unrecognised dialog"
    if d["tool"] == "bash":
        why = ""
        for cmd, problem in d["variants"]:
            if cmd == "":
                return "refuse", "bash", one_line(d["targets"][0]) or "-", problem
            ok, why = decide(pol, "bash", [cmd], cwd)
            if not ok:
                return "refuse", "bash", one_line(d["targets"][0]) or "-", why
        return "allow", "bash", one_line(d["targets"][0]) or "-", why
    ok, why = decide(pol, d["tool"], d["targets"], cwd)
    return ("allow" if ok else "refuse"), d["tool"], one_line(" ".join(d["targets"])) or "-", why


# --- CLI --------------------------------------------------------------------
def parse_args(argv):
    opts = {"cwd": os.getcwd(), "policy": None, "file": None}
    rest = []
    it = iter(argv)
    for a in it:
        if a == "--cwd":
            opts["cwd"] = next(it)
        elif a == "--policy":
            opts["policy"] = next(it)
        elif a == "--file":
            opts["file"] = next(it)
        else:
            rest.append(a)
    if not opts["policy"]:
        sys.exit("approver.py: --policy is required")
    return opts, rest


def main(argv):
    if not argv:
        sys.exit("usage: approver.py evaluate|decide --cwd DIR --policy FILE [--file CAPTURE] [tool|target]")
    cmd = argv[0]
    opts, rest = parse_args(argv[1:])
    pol = load_policy(opts["policy"])
    resolve_dynamic_roots(pol, opts["cwd"])
    if cmd == "evaluate":
        d = parse_dialog(open(opts["file"], encoding="utf-8").read() if opts["file"] else sys.stdin.read())
        if not d:
            print("none")
            return 0
        kind, tool, target, why = evaluate(pol, d, opts["cwd"])
        print("\t".join(["dialog", kind, d["sig"], tool, target, one_line(why)]))
        return 0
    if cmd == "decide":
        if opts["file"]:
            d = parse_dialog(open(opts["file"], encoding="utf-8").read())
            if not d:
                print("NO DIALOG no permission dialog found in the capture")
                return 1
            kind, tool, target, why = evaluate(pol, d, opts["cwd"])
            print({"allow": "ALLOW", "refuse": "REFUSE", "unrecognised": "UNRECOGNISED"}[kind] + f" {why} [{tool}: {target}]")
            return 0 if kind == "allow" else 1
        if len(rest) != 1 or "|" not in rest[0]:
            print("usage: bridge.sh approve test \"<tool>|<target>\" | --file <capture>", file=sys.stderr)
            return 2
        tool, target = rest[0].split("|", 1)
        ok, why = decide(pol, tool.strip(), [target], opts["cwd"])
        print(("ALLOW " if ok else "REFUSE ") + why)
        return 0 if ok else 1
    sys.exit(f"unknown command {cmd}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
