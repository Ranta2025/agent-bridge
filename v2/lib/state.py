#!/usr/bin/env python3
"""Bridge state core: atomic JSON state files, audit log and data commands.

Everything that touches JSON lives here; the bash layer only orchestrates herdr.
Environment: BRIDGE_DIR (required), BRIDGE_NOW (simulated epoch), STALL_S, DELIVER_S.
"""
import contextlib
import fcntl
import json
import os
import re
import sys
import time

BR = os.environ.get("BRIDGE_DIR") or sys.exit("BRIDGE_DIR is not set")
STATE_DIR = os.path.join(BR, "state")
INBOX = os.path.join(BR, "inbox")
OUTBOX = os.path.join(BR, "outbox")
LOG = os.path.join(BR, "log.jsonl")
STALL_S = int(os.environ.get("STALL_S", "180"))
DELIVER_S = int(os.environ.get("DELIVER_S", "30"))
MAX_TRIES = 3  # first prompt + 2 retries

STAGES = ["sent", "verified", "reviewed", "recorded", "merged"]
TERMINAL = {"done", "failed", "cancelled", "undelivered"}
OPEN = {"sent", "working", "stalled"}
TRANSITIONS = {
    "queued": {"sent", "cancelled"},
    "sent": {"working", "done", "failed", "undelivered", "cancelled", "stalled"},
    "working": {"done", "failed", "stalled", "cancelled"},
    "stalled": {"working", "done", "failed", "cancelled", "sent"},
    "undelivered": {"sent", "cancelled"},
    "failed": {"sent"},
    "done": {"sent"},
    "cancelled": {"sent"},
}
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")


def now():
    n = os.environ.get("BRIDGE_NOW")
    if not n:
        return int(time.time())
    try:
        with open(os.path.join(BR, ".vclock")) as f:
            off = int(f.read().strip() or 0)
    except (OSError, ValueError):
        off = 0
    return int(n) + off


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def check_id(i):
    if not i or not ID_RE.fullmatch(i):
        die(f"invalid task id: {i!r}", 2)
    return i


# --- files -----------------------------------------------------------------
def spath(i):
    return os.path.join(STATE_DIR, i + ".json")


def write_json(path, obj):
    """Atomic write: temp file in the same directory, fsync, rename."""
    tmp = os.path.join(os.path.dirname(path), "." + os.path.basename(path) + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    if os.environ.get("BRIDGE_TEST_CRASH_BEFORE_REPLACE"):
        os._exit(9)  # simulates a kill between the write and the rename
    os.replace(tmp, path)


@contextlib.contextmanager
def locked(i):
    os.makedirs(STATE_DIR, exist_ok=True)
    fd = os.open(os.path.join(STATE_DIR, f".{i}.json.lock"), os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def exists(i):
    return os.path.isfile(spath(check_id(i)))


def load(i):
    check_id(i)
    try:
        with open(spath(i)) as f:
            return json.load(f)
    except FileNotFoundError:
        die(f"no state for {i}")
    except ValueError:
        die(f"corrupt state file for {i}")


def save(s):
    os.makedirs(STATE_DIR, exist_ok=True)
    write_json(spath(s["id"]), s)


def all_states():
    out = []
    if not os.path.isdir(STATE_DIR):
        return out
    for name in sorted(os.listdir(STATE_DIR)):
        if name.startswith(".") or not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(STATE_DIR, name)) as f:
                out.append(json.load(f))
        except (OSError, ValueError):
            continue
    return out


def log(i, event, data=None):
    line = json.dumps({"ts": now(), "id": i, "event": event, "data": data or {}}, ensure_ascii=False)
    with open(LOG, "a") as f:
        f.write(line + "\n")


def blank(i, agent, repo, base, state, title="", force=False):
    return {
        "id": i, "agent": agent, "repo": repo, "base": base, "state": state,
        "title": title, "kind": i.split("-")[0],
        "created": now(), "sent": 0, "started": 0, "done": 0,
        "attempts": 0, "deliver_tries": 0, "last_prompt": 0, "idle_since": 0,
        "force": bool(force),
        "progress": {"done": 0, "total": 0, "current": "", "at": 0},
        "stages": {k: 0 for k in STAGES},
        "summary": {"status": "", "commits": [], "tests": ""},
        "note": "",
        "approvals": 0, "refusals": 0,
        "approval": {"pending": False, "sig": "", "decision": "", "last_prompt": {}},
    }


def transition(s, new, note=None):
    old = s["state"]
    if new == old:
        return
    if new not in TRANSITIONS.get(old, ()):
        die(f"invalid transition {old} -> {new} for {s['id']}")
    s["state"] = new
    if note is not None:
        s["note"] = note
    if new in TERMINAL:
        s["done"] = now()
    log(s["id"], "state", {"from": old, "to": new, "note": note or ""})


def parse_value(v):
    try:
        return json.loads(v)
    except ValueError:
        return v


def set_path(obj, dotted, value):
    keys = dotted.split(".")
    for k in keys[:-1]:
        obj = obj.setdefault(k, {})
    obj[keys[-1]] = value


def get_path(obj, dotted):
    for k in dotted.split("."):
        if not isinstance(obj, dict) or k not in obj:
            die(f"no such key: {dotted}")
        obj = obj[k]
    return obj


def emit(v):
    if isinstance(v, (dict, list)):
        print(json.dumps(v, ensure_ascii=False))
    elif isinstance(v, bool):
        print("true" if v else "false")
    else:
        print(v)


# --- B01 commands ------------------------------------------------------------
def cmd_exists(i):
    sys.exit(0 if exists(i) else 1)


def cmd_get(i, path=None):
    s = load(i)
    emit(get_path(s, path) if path else s)


def cmd_set(i, *pairs):
    with locked(i):
        s = load(i)
        for p in pairs:
            if "=" not in p:
                die(f"expected key=value, got {p!r}", 2)
            k, v = p.split("=", 1)
            if k in ("state", "id"):
                die(f"{k} cannot be set directly (state changes go through 'transition')", 2)
            set_path(s, k, parse_value(v))
        save(s)


def cmd_transition(i, new, note=None):
    with locked(i):
        s = load(i)
        transition(s, new, note)
        save(s)


def cmd_log(i, event, data=None):
    log(check_id(i), event, parse_value(data) if data else {})


def cmd_mark_sent(i, agent, repo, base, title=""):
    """Record that a prompt for the task has just been (or is being) sent."""
    check_id(i)
    with locked(i):
        t = now()
        if exists(i):
            s = load(i)
            if s["state"] in ("sent", "working"):
                die(f"{i} is already {s['state']}", 3)
            first = False
        else:
            s = blank(i, agent, repo, base, "sent", title)
            first = True
        prev_attempts = s["attempts"]
        # A report left by a previous attempt is kept as evidence; a never-tracked one is dropped.
        rep = os.path.join(OUTBOX, i + ".md")
        if os.path.exists(rep):
            if prev_attempts > 0:
                os.replace(rep, os.path.join(OUTBOX, f"{i}.attempt{prev_attempts}.md"))
            else:
                os.remove(rep)
        s.update(agent=agent, repo=repo, base=base)
        if title:
            s["title"] = title
        s.update(sent=t, started=0, done=0, last_prompt=t, idle_since=0, deliver_tries=1)
        s["attempts"] = prev_attempts + 1
        s["summary"] = {"status": "", "commits": [], "tests": ""}
        if not s["stages"].get("sent"):
            s["stages"]["sent"] = t
        if first:
            log(i, "created", {"agent": agent, "state": "sent"})
        else:
            old = s["state"]
            s["state"] = "sent"
            s["note"] = ""
            log(i, "state", {"from": old, "to": "sent", "note": "resent" if prev_attempts else ""})
        save(s)


# --- B02 commands: queue, lint, templates ------------------------------------
def cmd_check_id(i):
    check_id(i)


def repo_key(path):
    """Identity of a project: the git common dir of the path (any worktree), else the path itself."""
    import subprocess
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return path


def cmd_agent_busy(agent, repo=None, pane=None):
    """Print the id of an open (sent/working/stalled) task of the agent (in that project when repo is given), if any.

    With a pane the lock is per session: only an open task sent to that very pane counts, so two sessions of the
    same agent in one project take a task each."""
    key = repo_key(repo) if repo else None
    for s in all_states():
        if s["agent"] != agent or s["state"] not in OPEN:
            continue
        if pane:
            if s.get("pane") == pane:
                print(s["id"])
                return
        elif key is None or repo_key(s.get("repo", "")) == key:
            print(s["id"])
            return


def cmd_list_active():
    """Tasks the auto-approver may act for: sent or working."""
    for s in all_states():
        if s["state"] in ("sent", "working"):
            print(f"{s['id']}\t{s['agent']}")


APPROVAL_EVENTS = ("auto_approved", "approval_refused", "approval_failed", "approval_unrecognised", "would_approve")


def cmd_approve_record(i, event, agent, tool, target, reason, sig):
    """Log one auto-approver decision and update the counters of the task."""
    if event not in APPROVAL_EVENTS:
        die(f"unknown approval event {event!r}", 2)
    with locked(i):
        s = load(i)
        ap = s.setdefault("approval", {})
        prompt = {"tool": tool, "target": target, "reason": reason, "decision": event, "at": now()}
        ap["last_prompt"] = prompt
        ap["decision"] = event
        if event == "auto_approved":
            s["approvals"] = s.get("approvals", 0) + 1
            ap["pending"], ap["sig"] = False, ""
        else:
            if event == "approval_refused":
                s["refusals"] = s.get("refusals", 0) + 1
            ap["pending"] = event != "would_approve"
            ap["sig"] = sig
        save(s)
        log(i, event, {"agent": agent, "tool": tool, "target": target, "reason": reason, "sig": sig})


def cmd_approve_seen(i):
    """Print the signature of the dialog already recorded for the task (empty when none)."""
    print(load(i).get("approval", {}).get("sig", ""))


def cmd_approve_clear(i):
    """The dialog is gone: forget its signature and the pending flag."""
    with locked(i):
        s = load(i)
        ap = s.get("approval") or {}
        if ap.get("sig") or ap.get("pending"):
            ap["sig"], ap["pending"], ap["decision"] = "", False, ""
            s["approval"] = ap
            save(s)


def cmd_list_open():
    for s in all_states():
        if s["state"] in OPEN:
            print(f"{s['id']}\t{s['agent']}")


def cmd_enqueue(i, agent, repo, title="", force="0"):
    check_id(i)
    with locked(i):
        attempts = 0
        if exists(i):
            prev = load(i)
            if prev["state"] in OPEN or prev["state"] == "queued":
                die(f"{i} is already {prev['state']}", 3)
            attempts = prev["attempts"]
        s = blank(i, agent, repo, "", "queued", title, force == "1")
        s["attempts"] = attempts
        log(i, "queued", {"agent": agent})
        save(s)


def cmd_next_queued():
    """Oldest queued task of each agent that has no open task: id, agent, repo, force."""
    states = all_states()
    busy = {(s["agent"], repo_key(s.get("repo", ""))) for s in states if s["state"] in OPEN}
    seen = set()
    for s in sorted((x for x in states if x["state"] == "queued"), key=lambda x: (x["created"], x["id"])):
        k = (s["agent"], repo_key(s.get("repo", "")))
        if k in busy or k in seen:
            continue
        seen.add(k)
        print(f"{s['id']}\t{s['agent']}\t{s['repo']}\t{1 if s.get('force') else 0}")


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def section(text, names):
    """Lines of the first `## <name>` section (case-insensitive), or None if absent."""
    out = None
    for ln in text.splitlines():
        if out is None:
            m = re.match(r"^##\s+(.*?)\s*$", ln)
            if m and m.group(1).lower() in names:
                out = []
        elif re.match(r"^#{1,6}\s", ln):
            break
        else:
            out.append(ln)
    return out


def surface_entries(text):
    """The entries of the '## Allowed edit surfaces' section (bullets and backticks stripped)."""
    entries = []
    for ln in section(text, {"allowed edit surfaces"}) or []:
        e = re.sub(r"^\s*[-*]\s+", "", ln).strip().strip("`").strip()
        if e:
            entries.append(e)
    return entries


def _stem(e):
    """The literal part of a path pattern, up to its first glob character."""
    m = re.search(r"[*?\[]", e)
    return e[:m.start()] if m else e


def surfaces_overlap(a, b):
    """Pairs (x, y) of entries of the lists a and b that can touch the same file: equal, one glob matching the
    other, or one directory-like stem containing the other (src/** and src/lib/*.js)."""
    import fnmatch
    out = []
    for x in a:
        for y in b:
            x0, y0 = _stem(x), _stem(y)
            if (x == y or fnmatch.fnmatchcase(x, y) or fnmatch.fnmatchcase(y, x)
                    or (x0 and y0 and (x0.startswith(y0) or y0.startswith(x0)) and (x0 != x or y0 != y))):
                out.append((x, y))
    return out


def toplevel(path):
    import subprocess
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return os.path.realpath(r.stdout.strip())
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.realpath(path)


def cmd_overlap(i, repo):
    """Print the surface entries of task <i> that overlap those of any open task working in the same worktree as
    <repo>; exit 1 when there is any overlap."""
    mine = surface_entries(read_text(os.path.join(INBOX, check_id(i) + ".md")) or "")
    top = toplevel(repo)
    found = False
    for s in all_states():
        if s["id"] == i or s["state"] not in OPEN or toplevel(s.get("repo") or "") != top:
            continue
        theirs = surface_entries(read_text(os.path.join(INBOX, s["id"] + ".md")) or "")
        for x, y in surfaces_overlap(mine, theirs):
            print(f"{x} overlaps {y} (task {s['id']})")
            found = True
    if found:
        sys.exit(1)


def cmd_busy_worktrees(agent, repo):
    """Print the worktree (toplevel) of every open task of <agent> in the project of <repo>."""
    key = repo_key(repo)
    seen = set()
    for s in all_states():
        if s["agent"] == agent and s["state"] in OPEN and repo_key(s.get("repo") or "") == key:
            top = toplevel(s["repo"])
            if top not in seen:
                seen.add(top)
                print(top)


def lint_task(i):
    errors = []
    text = read_text(os.path.join(INBOX, i + ".md"))
    if text is None:
        return [f"missing task file inbox/{i}.md"]
    for n, ln in enumerate(text.splitlines(), 1):
        if "TODO-replace" in ln:
            errors.append(f"placeholder 'TODO-replace' still present (line {n})")
    surf = section(text, {"allowed edit surfaces"})
    if surf is None:
        errors.append("missing '## Allowed edit surfaces' section")
    else:
        entries = []
        for ln in surf:
            e = re.sub(r"^\s*[-*]\s+", "", ln).strip().strip("`").strip()
            if e:
                entries.append(e)
        if not entries:
            errors.append("'## Allowed edit surfaces' is empty")
        for e in entries:
            if e.startswith(("/", "~")) or re.match(r"^[A-Za-z]:[\\/]", e):
                errors.append(f"surface '{e}' must be a repository-relative path, not absolute")
            elif e in (".", "./", "..", "*", "**", "**/*", "./**"):
                errors.append(f"surface '{e}' is too broad; list exact files or narrow globs")
            elif ".." in e.split("/"):
                errors.append(f"surface '{e}' must not contain '..'")
    if section(text, {"report", "reporte"}) is None:
        errors.append("missing '## Report' (or '## Reporte') section")
    if not re.search(r"sub-?agent", text, re.I):
        errors.append("missing the sub-agents instruction (mention how to use sub-agents)")
    if f"outbox/{i}.md" not in text:
        errors.append(f"report path outbox/{i}.md is not mentioned")
    return errors


def lint_warnings(i):
    text = read_text(os.path.join(INBOX, i + ".md")) or ""
    if not re.search(r"todowrite", text, re.I):
        return ["no TODO-list instruction: ask the agent to keep a visible list with todowrite (see templates/task.md)"]
    return []


def cmd_lint(i):
    check_id(i)
    errors = lint_task(i)
    for e in errors:
        print(f"lint {i}: {e}", file=sys.stderr)
    for w in lint_warnings(i) if not errors else []:
        print(f"lint {i}: warning: {w}", file=sys.stderr)
    if errors:
        sys.exit(1)
    print(f"lint {i}: ok")


def cmd_task_title(i):
    text = read_text(os.path.join(INBOX, check_id(i) + ".md")) or ""
    for ln in text.splitlines():
        if ln.startswith("#"):
            h = ln.lstrip("#").strip()
            m = re.match(r"^Task\s+\S+\s*[-:\u2014\u2013]\s*(.*)$", h)
            print(m.group(1) if m else h)
            return


def cmd_task_repo(i):
    text = read_text(os.path.join(INBOX, check_id(i) + ".md")) or ""
    m = re.search(r"<!--\s*bridge:repo=(.*?)\s*-->", text)
    if m:
        print(m.group(1))


def cmd_render(template, i, title, repo):
    text = read_text(template)
    if text is None:
        die(f"missing template {template}")
    for k, v in (("ID", i), ("TITLE", title), ("REPO", repo), ("BRIDGE", BR)):
        text = text.replace("{{" + k + "}}", v)
    sys.stdout.write(text)


# --- report parsing and the tick decision ------------------------------------
FAIL_RE = re.compile(r"bloquead|blocked|\bfall(?:o|\u00f3|a|ido|ida)\b|\bfail|parcial|partial|incomplet", re.I)
STATUS_RE = re.compile(r"^[\s>*_#-]*(?:estado|status)[\s*_]*:[\s*_]*(.+?)[\s*_]*$", re.I | re.M)
TESTS_RE = re.compile(r"^[\s>*_#-]*(?:pruebas|tests?)[\s*_]*:[\s*_]*(.+?)[\s*_]*$", re.I | re.M)
LEAD_RE = re.compile(r"[^\W\d_]+")
OK_WORDS = {
    "done", "ok", "okay", "complete", "completed", "success", "successful", "succeeded", "finished", "passed",
    "listo", "lista", "hecho", "hecha", "completado", "completada", "terminado", "terminada", "exitoso", "exitosa",
}


def status_failed(status):
    """The leading word decides; an unrecognised one falls back to a failure-word search of the whole line."""
    if not status:
        return False
    lead = LEAD_RE.search(status)
    word = lead.group(0).lower() if lead else ""
    if word and FAIL_RE.search(word):
        return True
    if word in OK_WORDS:
        return False
    return bool(FAIL_RE.search(status))


def parse_report(text):
    """Return (status_text, failed, tests_text) from the report's status line."""
    m = STATUS_RE.search(text)
    status = m.group(1).strip() if m else ""
    t = TESTS_RE.search(text)
    return status, status_failed(status), (t.group(1).strip() if t else "")


def commits_since(repo, base):
    import subprocess
    if not repo or not base or not os.path.isdir(repo):
        return []
    try:
        r = subprocess.run(["git", "-C", repo, "log", "--format=%h", f"{base}..HEAD"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return []
    return r.stdout.split()[:20] if r.returncode == 0 else []


def cmd_tick(i, agent_status):
    """One idempotent evaluation of a task. Prints the action: none, working, done, failed,
    stalled, resumed, reprompt or undelivered. 'reprompt' asks the caller to send the prompt again."""
    check_id(i)
    with locked(i):
        s = load(i)
        t = now()
        st = s["state"]
        if st not in OPEN:
            print("none")
            return
        report = read_text(os.path.join(OUTBOX, i + ".md"))
        if report and report.strip():
            status, failed, tests = parse_report(report)
            s["summary"] = {"status": status, "commits": commits_since(s["repo"], s["base"]), "tests": tests}
            if not s["started"]:
                s["started"] = s["sent"]
            if not failed and s["progress"]["total"]:
                s["progress"]["done"] = s["progress"]["total"]
            new = "failed" if failed else "done"
            transition(s, new, f"report status: {status}" if failed else None)
            save(s)
            print(new)
            return
        if st == "sent":
            if agent_status in ("working", "unknown"):
                s["started"] = t
                s["idle_since"] = 0
                transition(s, "working")
                save(s)
                print("working")
            elif t - s["last_prompt"] >= DELIVER_S:
                if agent_status != "missing" and s["deliver_tries"] < MAX_TRIES:
                    s["attempts"] += 1
                    s["deliver_tries"] += 1
                    s["last_prompt"] = t
                    log(i, "retry", {"attempt": s["attempts"]})
                    save(s)
                    print("reprompt")
                else:
                    transition(s, "undelivered", f"no sign of work after {s['deliver_tries']} prompt(s)")
                    save(s)
                    print("undelivered")
            else:
                print("none")
            return
        # working / stalled
        if agent_status == "working":
            was_idle = s["idle_since"]
            s["idle_since"] = 0
            if st == "stalled":
                transition(s, "working")
                save(s)
                print("resumed")
                return
            if was_idle:
                save(s)
            print("none")
            return
        if agent_status in ("missing", "unknown"):
            print("none")
            return
        if not s["idle_since"]:
            s["idle_since"] = t
            save(s)
        elif st == "working" and t - s["idle_since"] >= STALL_S:
            transition(s, "stalled", f"agent idle for {t - s['idle_since']}s without a report")
            save(s)
            print("stalled")
            return
        print("none")


# --- B03 commands: progress and stages ----------------------------------------
def cmd_progress(i, done, total, text=""):
    try:
        d, t = int(done), int(total)
    except ValueError:
        die("progress: <done> and <total> must be integers", 2)
    if d < 0 or t < 0 or d > t:
        die("progress: need 0 <= done <= total", 2)
    with locked(i):
        s = load(i)
        s["progress"] = {"done": d, "total": t, "current": text, "at": now()}
        log(i, "progress", s["progress"])
        save(s)


def cmd_stage(i, name, note=""):
    if name not in STAGES[1:]:
        die(f"unknown stage {name!r}; use one of: {' '.join(STAGES[1:])}", 2)
    with locked(i):
        s = load(i)
        s["stages"][name] = now()
        log(i, "stage", {"stage": name, "note": note})
        save(s)


# --- B04 commands: listing, statistics, estimates, cleaning ---------------------
def fmt_dur(sec):
    sec = int(sec)
    if sec < 90:
        return f"{sec}s"
    if sec < 5400:
        return f"{sec // 60}m"
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"


def last_stage(s):
    reached = [k for k in STAGES if s["stages"].get(k)]
    return reached[-1] if reached else ""


def task_row(s, t):
    live = s["state"] in OPEN
    commits = commits_since(s["repo"], s["base"]) if live else s["summary"].get("commits", [])
    begin = s["started"] or s["sent"]
    end = s["done"] if s["state"] in TERMINAL and s["done"] else t
    p = s["progress"]
    return {
        "id": s["id"], "agent": s["agent"], "state": s["state"], "title": s["title"],
        "kind": s["kind"], "repo": s["repo"], "pane": s.get("pane", ""),
        "created": s["created"], "sent": s["sent"], "started": s["started"], "done": s["done"],
        "age_s": max(0, t - s["created"]),
        "duration_s": max(0, end - begin) if begin else 0,
        "attempts": s["attempts"],
        "progress": {"done": p["done"], "total": p["total"], "current": p["current"], "at": p["at"]},
        "stage": last_stage(s),
        "stages": {k: s["stages"].get(k, 0) for k in STAGES},
        "commits": commits, "commit_count": len(commits),
        "note": s["note"],
        "approvals": s.get("approvals", 0), "refusals": s.get("refusals", 0),
        "approval_pending": bool(s.get("approval", {}).get("pending")),
        "approval_sig": s.get("approval", {}).get("sig", ""),
        "approval_tool": s.get("approval", {}).get("last_prompt", {}).get("tool", ""),
        "approval_target": s.get("approval", {}).get("last_prompt", {}).get("target", "") if s.get("approval", {}).get("pending") else "",
    }


def cmd_ls(*flags):
    t = now()
    rows = [task_row(s, t) for s in sorted(all_states(), key=lambda x: (x["created"], x["id"]), reverse=True)]
    if "--json" in flags:
        emit({"version": 1, "now": t, "tasks": rows})
        return
    if not rows:
        print("no tasks")
        return
    print(f"{'ID':<16} {'AGENT':<9} {'STATE':<12} {'AGE':>6} {'PROGRESS':<9} {'COMMITS':>7}  STAGE")
    for r in rows:
        prog = f"{r['progress']['done']}/{r['progress']['total']}" if r["progress"]["total"] else "-"
        print(f"{r['id']:<16} {r['agent']:<9} {r['state']:<12} {fmt_dur(r['age_s']):>6} {prog:<9} "
              f"{r['commit_count']:>7}  {r['stage'] or '-'}")


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if not n:
        return None
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) // 2


def duration_of(s):
    begin = s["started"] or s["sent"]
    return max(0, s["done"] - begin) if begin and s["done"] else None


def group_stats(states):
    fin = [s for s in states if s["state"] in TERMINAL]
    done = [s for s in states if s["state"] == "done"]
    durs = [d for d in (duration_of(s) for s in done) if d is not None]
    return {
        "n": len(states), "done": len(done),
        "failed": sum(1 for s in states if s["state"] == "failed"),
        "cancelled": sum(1 for s in states if s["state"] == "cancelled"),
        "undelivered": sum(1 for s in states if s["state"] == "undelivered"),
        "open": sum(1 for s in states if s["state"] in OPEN or s["state"] == "queued"),
        "success_rate": round(len(done) / len(fin), 3) if fin else None,
        "median_duration_s": median(durs),
        "mean_duration_s": round(sum(durs) / len(durs)) if durs else None,
        "retries": sum(max(0, s["attempts"] - 1) for s in states),
    }


def cmd_stats(*flags):
    states = all_states()
    out = {"agents": {}, "kinds": {}, "overall": group_stats(states)}
    for key, bucket in (("agent", "agents"), ("kind", "kinds")):
        for name in sorted({s[key] for s in states}):
            out[bucket][name] = group_stats([s for s in states if s[key] == name])
    if "--json" in flags:
        emit(out)
        return
    if not states:
        print("no tasks yet")
        return
    print(f"{'GROUP':<14} {'N':>3} {'DONE':>4} {'FAIL':>4} {'SUCCESS':>8} {'MEDIAN':>7} {'RETRIES':>7}")
    rows = [("all", out["overall"])] + [(f"agent:{k}", v) for k, v in out["agents"].items()] + \
           [(f"kind:{k}", v) for k, v in out["kinds"].items()]
    for name, g in rows:
        rate = f"{round(g['success_rate'] * 100)}%" if g["success_rate"] is not None else "-"
        med = fmt_dur(g["median_duration_s"]) if g["median_duration_s"] is not None else "-"
        print(f"{name:<14} {g['n']:>3} {g['done']:>4} {g['failed']:>4} {rate:>8} {med:>7} {g['retries']:>7}")


def cmd_eta(i, *flags):
    s = load(i)
    t = now()
    remaining, basis = None, "unknown"
    if s["state"] in TERMINAL:
        remaining, basis = 0, "finished"
    else:
        begin = s["started"] or s["sent"] or s["created"]
        elapsed = max(0, t - begin)
        p = s["progress"]
        peers = [x for x in all_states() if x["state"] == "done" and x["id"] != i]
        pools = [[x for x in peers if x["agent"] == s["agent"] and x["kind"] == s["kind"]],
                 [x for x in peers if x["agent"] == s["agent"]], peers]
        if p["total"] and p["done"] > 0:
            remaining, basis = int(elapsed * (p["total"] - p["done"]) / p["done"]), "progress"
        else:
            for pool in pools:
                m = median([d for d in (duration_of(x) for x in pool) if d is not None])
                if m is not None:
                    remaining, basis = max(0, m - elapsed), "median"
                    break
    if "--json" in flags:
        emit({"id": i, "state": s["state"], "remaining_s": remaining, "basis": basis})
    elif remaining is None:
        print(f"eta {i}: unknown (no finished tasks to compare with and no progress reported)")
    else:
        print(f"eta {i}: ~{fmt_dur(remaining)} remaining (basis: {basis})")


def cmd_clean(*args):
    days, dry = 7, False
    it = iter(args)
    for a in it:
        if a == "--days":
            try:
                days = int(next(it))
            except (StopIteration, ValueError):
                die("clean: --days needs an integer", 2)
        elif a == "--dry-run":
            dry = True
        else:
            die(f"clean: unknown argument {a}", 2)
    cutoff = now() - days * 86400
    moved = []
    for s in all_states():
        if s["state"] not in TERMINAL or (s["done"] or s["created"]) >= cutoff:
            continue
        i = s["id"]
        moved.append(i)
        if dry:
            continue
        for sub in ("inbox", "outbox", "state"):
            src_dir = os.path.join(BR, sub)
            names = [n for n in os.listdir(src_dir) if n in (f"{i}.md", f"{i}.sent", f"{i}.json")
                     or re.fullmatch(re.escape(i) + r"\.attempt\d+\.md", n)]
            for n in names:
                dst_dir = os.path.join(BR, "archive", sub)
                os.makedirs(dst_dir, exist_ok=True)
                os.replace(os.path.join(src_dir, n), os.path.join(dst_dir, n))
        for n in (f".{i}.json.lock", f".{i}.tick.lock", f".{i}.json.tmp"):
            with contextlib.suppress(OSError):
                os.remove(os.path.join(STATE_DIR, n))
        log(i, "archived", {})
    if dry:
        print(f"dry-run: would archive {len(moved)} task(s): {' '.join(moved)}")
    else:
        print(f"archived {len(moved)} task(s)" + (f": {' '.join(moved)}" if moved else ""))


# --- B05: migration of the legacy inbox/outbox pair --------------------------------
def cmd_migrate():
    """Create state for legacy tasks (inbox/<id>.sent and/or outbox/<id>.md). Read-only on inbox/outbox."""
    ids = set()
    for n in os.listdir(INBOX) if os.path.isdir(INBOX) else []:
        if n.endswith(".sent"):
            ids.add(n[:-5])
    for n in os.listdir(OUTBOX) if os.path.isdir(OUTBOX) else []:
        if n.endswith(".md") and ID_RE.fullmatch(n[:-3]):
            ids.add(n[:-3])
    count = 0
    for i in sorted(x for x in ids if ID_RE.fullmatch(x)):
        if exists(i):
            continue
        agent, sent = "unknown", 0
        raw = read_text(os.path.join(INBOX, i + ".sent"))
        if raw:
            parts = raw.split()
            if parts:
                agent = parts[0]
            if len(parts) > 1 and parts[1].isdigit():
                sent = int(parts[1])
        rep_path = os.path.join(OUTBOX, i + ".md")
        report = read_text(rep_path)
        has_report = bool(report and report.strip())
        mtime = int(os.path.getmtime(rep_path)) if has_report else 0
        first = sent or mtime or now()
        s = blank(i, agent, "", "", "working", "")
        s["created"] = first
        s["sent"] = sent or first
        s["started"] = s["sent"]
        s["attempts"] = 1
        s["deliver_tries"] = 1
        s["last_prompt"] = s["sent"]
        s["stages"]["sent"] = s["sent"]
        s["note"] = "imported from the legacy inbox/outbox files"
        title = read_text(os.path.join(INBOX, i + ".md"))
        if title:
            for ln in title.splitlines():
                if ln.startswith("#"):
                    s["title"] = ln.lstrip("#").strip()[:120]
                    break
        if has_report:
            status, failed, tests = parse_report(report)
            s["summary"] = {"status": status, "commits": [], "tests": tests}
            s["state"] = "failed" if failed else "done"
            s["done"] = mtime
        log(i, "imported", {"state": s["state"], "agent": agent})
        with locked(i):
            save(s)
        count += 1
    print(f"migrated {count} task(s)")


COMMANDS = {}


def register():
    for name, fn in list(globals().items()):
        if name.startswith("cmd_"):
            COMMANDS[name[4:].replace("_", "-")] = fn


def main(argv):
    register()
    if not argv or argv[0] not in COMMANDS:
        die("usage: state.py <command> [args]\ncommands: " + " ".join(sorted(COMMANDS)), 2)
    try:
        COMMANDS[argv[0]](*argv[1:])
    except TypeError as e:
        die(f"bad arguments for {argv[0]}: {e}", 2)


if __name__ == "__main__":
    main(sys.argv[1:])
