# gpu-job

A Claude Code skill for running heavy jobs (Blender/Cycles renders and bakes, ML inference, upscaling) on a **shared** remote GPU box over SSH, without stepping on the people, services or other agent sessions that also use it.

```
config → preflight (read-only) → tell the others → run under a guard → status → fetch (copy only) → release
```

It was built for a home lab where one RTX card also hosts an always-on voice model and is shared by several Claude sessions: renders ran there for days next to the other services without a collision.

## What the skill does

1. **Recruits PCs on your network** (`recruit.sh`, [guide](skills/gpu-job/references/recruit.md)): checks Tailscale and lists the machines on your tailnet, walks the PC's owner through Tailscale, an SSH server, a job user and a key (Linux and Windows), then probes the PC over SSH for the driver, free VRAM, disk, Blender and sleep settings, and prints its config entry.
2. **Reads a small config** (`gpu-workers.json`) listing your workers and their **lanes**: a VRAM cap for your job, the free VRAM needed before it starts, a time limit, and whether the lane needs the box owner's approval.
3. **Preflights the box, read-only:** SSH, free VRAM, temperature, who else is on the GPU, the STOP file, disk space, the shared status file.
4. **Runs your job detached under a guard** (`guard.sh`, on the worker) that waits for room before each chunk, runs it with `nice` and a thread cap, kills it if a STOP file appears, if it passes its VRAM cap or its time limit, keeps a STATUS file current, and resumes from finished chunks.
5. **Follows the etiquette:** free lanes without asking, approval lanes never without the owner's yes, tell the other sessions before and after, keep scratch on the worker, never delete there without asking.
6. **Fetches results back with rsync, copy only**: nothing on the worker is removed.

## Install

**As a Claude Code plugin** (from inside Claude Code):

```
/plugin marketplace add skyeyesec333/gpu-job
/plugin install gpu-job@gpu-job
```

**Or as a plain skill:** copy `skills/gpu-job` into `~/.claude/skills/` (all your projects) or into a project's `.claude/skills/`.

No worker yet? Ask Claude to "recruit my gaming PC as a GPU worker": it checks Tailscale, gives the PC's owner the setup commands, and writes the config entry once the PC answers. Or describe your worker yourself in `~/.config/gpu-job/workers.json`, starting from [`references/gpu-workers.example.json`](skills/gpu-job/references/gpu-workers.example.json), or just ask Claude to set it up and answer its questions.

## Use

Just ask:

- "Render frames 1-120 of garden.blend on the GPU box"
- "Is the worker free? Run the depth model on these three images there"
- "Check on the render and pull the finished frames back"

The scripts also work by hand. They live in the skill's `scripts/` folder, not on your PATH: `~/.claude/skills/gpu-job/scripts/` for a plain-skill install, `${CLAUDE_PLUGIN_ROOT}/skills/gpu-job/scripts/` inside Claude Code for a plugin install.

```sh
S=~/.claude/skills/gpu-job/scripts
$S/gpu-job.sh preflight gpu1
$S/gpu-job.sh run gpu1 --id garden-01 --purpose "Night garden" --eta 90 --put garden.blend \
  --frames 1-120 --chunk 10 -- '~/blender/blender' -b in/garden.blend -o out/f_#### -s '{start}' -e '{end}' -a
$S/gpu-job.sh status gpu1 garden-01
$S/gpu-job.sh fetch gpu1 garden-01 ./renders/garden
```

The command runs in the job's folder on the worker: write results to `out/` (relative), and quote a `~/` program path so your own shell doesn't expand it.

## Requirements

- [Claude Code](https://claude.com/claude-code)
- Locally: bash, Python 3, ssh, rsync; [Tailscale](https://tailscale.com) to reach workers away from home (or the same LAN)
- The worker: Linux with an NVIDIA GPU (`nvidia-smi`), bash, SSH key access. Windows workers are covered by a manual guide (`references/windows.md`).

## Licence

MIT. See [LICENSE](LICENSE).
