#!/usr/bin/env python3
"""Read gpu-workers.json and print one worker's settings as shell variables.

    workers.py list
    workers.py show <worker>
    workers.py env  <worker> [lane]      # shell assignments, for eval

The config is $GPU_WORKERS if set, else ~/.config/gpu-job/workers.json. It is never
picked up from the current folder: its commands run on your machine and the worker,
so a config shipped inside a cloned repo must not take effect by accident.
See references/config.md for every field.
"""
import json
import os
import re
import shlex
import sys

DEFAULTS = {
    "os": "linux",
    "nice": 10,
    "threads": 4,
    "max_temp_c": 83,
    "poll_seconds": 5,
    "max_hours": 3,
    "disk_min_free_gb": 20,
    "gpu_index": 0,
}
# Every number reaches shell arithmetic on the worker: whole numbers only, checked here and again in guard.sh.
INT_FIELDS = ("nice", "threads", "max_temp_c", "poll_seconds", "max_hours", "disk_min_free_gb", "gpu_index")
LANE_INT_FIELDS = ("vram_cap_mib", "min_free_mib", "max_hours")
SSH_TARGET = re.compile(r"^[A-Za-z0-9._%+@:\[\]-]+$")
LANE_DEFAULTS = {"approval": False, "vram_cap_mib": 3000, "min_free_mib": 5120}


def find_config():
    env = os.environ.get("GPU_WORKERS")
    if env:
        if not os.path.isfile(env):
            sys.exit(f"gpu-job: GPU_WORKERS={env} is not a file")
        return env
    p = os.path.expanduser("~/.config/gpu-job/workers.json")
    if os.path.isfile(p):
        return p
    sys.exit("gpu-job: no config found. Copy references/gpu-workers.example.json to "
             "~/.config/gpu-job/workers.json (or point $GPU_WORKERS at one) and edit it.")


def whole(where, key, v, lo=0, hi=None):
    if isinstance(v, bool) or not isinstance(v, int) or v < lo or (hi is not None and v > hi):
        rng = f"{lo}..{hi}" if hi is not None else f">= {lo}"
        sys.exit(f"gpu-job: {where} '{key}' must be a whole number {rng} (got {v!r})")
    return v


def load():
    path = find_config()
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg.get("workers"), dict) or not cfg["workers"]:
        sys.exit(f"gpu-job: {path} has no 'workers' object")
    return path, cfg


def worker(cfg, name):
    w = cfg["workers"].get(name)
    if w is None:
        sys.exit(f"gpu-job: no worker '{name}' (have: {', '.join(cfg['workers'])})")
    for k in ("ssh", "scratch"):
        if k not in w:
            sys.exit(f"gpu-job: worker '{name}' needs '{k}'")
    out = dict(DEFAULTS)
    out.update(cfg.get("defaults", {}))
    out.update(w)
    if not out.get("lanes"):
        out["lanes"] = {"A": {}}
    ssh = out["ssh"]
    if not isinstance(ssh, str) or ssh.startswith("-") or not SSH_TARGET.match(ssh):
        sys.exit(f"gpu-job: worker '{name}' ssh must be user@host or a Host alias "
                 f"(letters, digits, . _ - @ :), not starting with '-' (got {ssh!r})")
    for k in INT_FIELDS:
        whole(f"worker '{name}'", k, out[k], hi=19 if k == "nice" else None)
    if out["poll_seconds"] < 1 or out["threads"] < 1 or out["max_hours"] < 1:
        sys.exit(f"gpu-job: worker '{name}': poll_seconds, threads and max_hours must be at least 1")
    return out


def lane(w, name):
    lanes = w["lanes"]
    if name is None:
        name = next(iter(lanes))
    if name not in lanes:
        sys.exit(f"gpu-job: no lane '{name}' (have: {', '.join(lanes)})")
    out = dict(LANE_DEFAULTS)
    out.update(lanes[name])
    out["name"] = name
    if not re.match(r"^[A-Za-z0-9._-]+$", name):
        sys.exit(f"gpu-job: lane names are letters, digits, . _ - (got {name!r})")
    for k in LANE_INT_FIELDS:
        if k in out:
            whole(f"lane '{name}'", k, out[k], lo=1 if k == "max_hours" else 0)
    return out


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        return
    path, cfg = load()
    cmd = argv[1]
    if cmd == "list":
        for name, w in cfg["workers"].items():
            lanes = ", ".join(w.get("lanes", {"A": {}}))
            print(f"{name:14} {w.get('ssh', '?'):28} {w.get('gpu', ''):22} lanes: {lanes}")
        return
    if len(argv) < 3:
        sys.exit("gpu-job: name a worker")
    w = worker(cfg, argv[2])
    if cmd == "show":
        print(json.dumps(w, indent=2))
        return
    if cmd == "env":
        ln = lane(w, argv[3] if len(argv) > 3 else None)
        vals = {
            "GJ_CONFIG": path,
            "GJ_WORKER": argv[2],
            "GJ_SSH": w["ssh"],
            "GJ_OS": w["os"],
            "GJ_SCRATCH": w["scratch"],
            "GJ_STOP": w.get("stop_file", ""),
            "GJ_STATUS": w.get("status_file", ""),
            "GJ_NICE": w["nice"],
            "GJ_THREADS": w["threads"],
            "GJ_MAX_TEMP": w["max_temp_c"],
            "GJ_POLL": w["poll_seconds"],
            "GJ_MAX_HOURS": ln.get("max_hours", w["max_hours"]),
            "GJ_DISK_MIN_GB": w["disk_min_free_gb"],
            "GJ_PROTECTED": " ".join(w.get("protected_processes", [])),
            "GJ_GPU": w["gpu_index"],
            "GJ_LANE": ln["name"],
            "GJ_LANE_APPROVAL": "1" if ln["approval"] else "0",
            "GJ_CAP": ln["vram_cap_mib"],
            "GJ_MIN_FREE": ln["min_free_mib"],
            "GJ_REQUEST": ln.get("request_cmd", ""),
            "GJ_RELEASE": ln.get("release_cmd", ""),
            "GJ_WRAP": ln.get("wrap_cmd", ""),
        }
        for k, v in vals.items():
            print(f"{k}={shlex.quote(str(v))}")
        return
    sys.exit(f"gpu-job: unknown command '{cmd}'")


if __name__ == "__main__":
    main(sys.argv)
