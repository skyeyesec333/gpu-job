---
name: gpu-job
description: Run heavy GPU jobs (Blender/Cycles renders and bakes, ML inference, upscaling, depth maps) on a shared remote GPU box over SSH without stepping on the other people, services or agent sessions that use it. Use when work should go to a remote GPU worker, render farm box or home lab PC; when the user mentions their GPU worker, a render box, an RTX machine, lanes, a STOP file or STATUS file; when a local render is too slow or freezes the display; or when outputs need fetching back from a worker.
---

# GPU job: borrow a shared GPU politely

A shared GPU box usually has someone else on it: an always-loaded model, another agent session, the owner's own work. This skill runs your job there as a guest: it checks the box first, starts only when the rules say there is room, steps aside the moment the owner asks, keeps a status file others can read, and leaves its working files on the box.

```
1. config     gpu-workers.json: the workers, their lanes and limits           (once)
2. preflight  scripts/gpu-job.sh preflight <worker>                            (read-only)
3. tell       other sessions sharing the box: what, which lane, how long
4. run        scripts/gpu-job.sh run <worker> --id … --purpose … --eta … -- <command>
5. watch      scripts/gpu-job.sh status <worker> <id>
6. fetch      scripts/gpu-job.sh fetch <worker> <id> <dest>                    (copy only)
7. tell       the other sessions it is done; release the lane if it had a grant
```

## 1. The config

The scripts read `$GPU_WORKERS`, else `./gpu-workers.json`, else `~/.config/gpu-job/workers.json`. Start from [references/gpu-workers.example.json](references/gpu-workers.example.json); every field is in [references/config.md](references/config.md). If there is no config, ask the user for each worker's SSH target, GPU, scratch folder and the box's rules (whoever runs the box usually has them written down: read them, don't guess), then write it.

`scripts/gpu-job.sh list` shows what is configured.

## 2. Lanes: what you may do without asking

A **lane** is a set of limits the box's owner agreed to: a VRAM cap for your job, the free VRAM that must be there before it starts, and how long it may run.

- **A lane without `approval`** (a "free lane") may be used without asking anyone, as long as the preflight passes.
- **A lane with `"approval": true`** (for example one that pauses another service to free memory, or that notifies the owner) is **never used without the box owner's yes in this conversation.** Ask, quote their answer back, then pass `--owner-approved`. A yes for one job is not a yes for the next. If the lane has a `request_cmd` (a broker), the script asks it for a grant; exit codes other than 0 mean no.
- Pick the smallest lane the job fits. If you do not know the job's peak VRAM, run one chunk in the free lane first and read `peak VRAM` in its STATUS.

## 3. Before every job

1. **Preflight** (`gpu-job.sh preflight <worker> [--lane L]`). It is read-only: SSH up, `nvidia-smi` free VRAM and temperature, who else is on the GPU (and as which user), the STOP file, free disk in scratch, the shared STATUS file, protected services. `READY` or `NOT READY` at the end; NOT READY is fine (the guard waits), but say why to the user.
2. **Tell the other sessions** that share the box before you start and after you finish: one line with the job, lane, expected VRAM and ETA. Use whatever channel the user has for that (a message to another agent session, a shared notes file, chat). If you don't know who shares it, ask once.
3. **Know what you must not touch:** `protected_processes` in the config, anyone else's processes and files, power limits, clocks, drivers and system settings. You run as a guest user in the scratch folder only.

## 4. Run

```sh
S=<skill>/scripts
# one command
$S/gpu-job.sh run gpu1 --id depth-tile-07 --purpose "Depth map for the city plate" --eta 15 \
  --put ./inputs/plate.png -- python3 depth.py in/plate.png out/plate-depth.png

# a render in chunks: {start} {end} per chunk; it resumes from the chunks already done
$S/gpu-job.sh run gpu1 --id garden-01 --purpose "Night garden, 120 frames" --eta 90 \
  --put ./garden.blend --frames 1-120 --chunk 10 -- \
  ~/blender/blender -b in/garden.blend -t 4 -o //out/f_#### -s {start} -e {end} -a
```

The job runs in `<scratch>/jobs/<id>/`: inputs in `in/`, results in `out/`, the log in `job.log`, its own `STATUS`. It is started detached (it survives your SSH session) under `scripts/guard.sh`, which:

- **waits before each chunk** while the STOP file exists, the GPU is at or above `max_temp_c`, or free VRAM is under the lane's `min_free_mib`;
- runs the command with `nice` and a thread cap (`OMP_NUM_THREADS`; also pass the tool's own flag, e.g. Blender `-t 4`);
- **every few seconds checks** the STOP file (kills the job, waits for STOP to clear, runs the chunk again), the job's own VRAM (kills it above the lane cap) and the time limit;
- **keeps STATUS current**: job, who, lane, purpose, frames, pid, start, expected end, last chunk done, peak VRAM, state. It also writes the box's shared `status_file` if there is one, so the owner can see who is on the GPU without asking;
- records finished chunks in `done`, so `--resume` with the same id continues where it stopped.

**Chunks are what make pre-emption cheap.** A STOP costs at most one chunk. For Blender, render 5-10 frames per chunk with overwrite off and placeholders on, so a rerun skips frames already on disk.

Use a new `--id` for each job; the script refuses to reuse one unless you pass `--resume`.

## 5. Watch, cancel

- `gpu-job.sh status <worker> [<id>]`: the job's STATUS, the last log lines, the GPU now. Without an id, every job of yours on that worker.
- `gpu-job.sh log <worker> <id> [lines]`.
- `gpu-job.sh cancel <worker> <id>`: stops your own job (the guard and its children). It never touches anyone else's process, and leaves the files.
- If the box's owner or another session asks you to stop, cancel at once, and say so. Their jobs come first.

Report progress honestly: say a job is running only when STATUS says `running` and the updated time is recent.

## 6. Fetch, and where files live

- `gpu-job.sh fetch <worker> <id> <dest>` copies `out/` back with rsync, skipping `*.tmp`/`*.part`, only once the job is `finished` (`--partial` for the chunks done so far). **It copies; it never removes anything from the worker.**
- **Scratch stays on the worker:** bake caches, test frames, intermediate renders and exports belong in the worker's scratch folder, not on the local machine's disk. Pull back only what a local step needs, and only when it needs it.
- **Never delete on the worker (or locally) without asking.** That includes your own old jobs. Offer a list with sizes; move to a holding folder rather than `rm` if the user agrees to tidy.
- Don't put scratch under `/tmp` on Linux boxes: it is often RAM-backed.

## 7. When the job is done

1. Check the result (open a frame, read the log's last lines, compare sizes), then fetch.
2. `gpu-job.sh release <worker> <id> [--lane L]` if the lane had a broker grant. Release as soon as you are done, not when the grant runs out.
3. Tell the other sessions the GPU is free again, with the peak VRAM you saw (useful for picking a lane next time).

## Why not just render locally?

On a Mac, a heavy Cycles frame on the GPU can run past macOS's GPU watchdog, which then **resets the display for every app** (the screen freezes or goes black for seconds). A laptop CPU is often several times slower than one desktop RTX card on the same frame. If the user has a worker, heavy Cycles, bakes and model inference go there; quick previews can stay local on the CPU.

## Windows workers

The scripts drive Linux workers. For a Windows box over OpenSSH, follow [references/windows.md](references/windows.md): the same rules, with PowerShell for the checks and a scheduled task or `Start-Process` for the detached run.

## Files

- `scripts/gpu-job.sh`: the local command (list, preflight, run, status, log, fetch, cancel, release).
- `scripts/guard.sh`: runs on the worker around your command; copied there by `run`.
- `scripts/workers.py`: reads the config (Python 3, standard library only).
- `references/config.md`, `references/gpu-workers.example.json`, `references/windows.md`.
