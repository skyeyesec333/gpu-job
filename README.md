# gpu-job

Runs heavy jobs, like 3D renders or AI models, on a shared GPU computer on your network, without disturbing anyone else using it.

It was built for a home lab where one graphics card also runs an always-on voice model and is shared by several Claude sessions.

## Good for

- Sending slow renders or AI jobs from a laptop to a faster desktop PC
- Setting up a gaming PC or spare workstation as a GPU worker for the first time
- Sharing one GPU safely between people, services and Claude sessions
- Stopping a job at once when the PC's owner needs the machine back

## Install

In Claude Code, run:

```
/plugin marketplace add skyeyesec333/gpu-job
/plugin install gpu-job@gpu-job
```

Or copy the skill into your own skills folder:

```sh
git clone https://github.com/skyeyesec333/gpu-job
cp -r gpu-job/skills/gpu-job ~/.claude/skills/
```

You can also copy it into one project's `.claude/skills/` folder instead.

No worker yet? Ask Claude to "recruit my gaming PC as a GPU worker". It checks Tailscale, gives the PC's owner the setup commands, and writes the config entry once the PC answers. Or describe your worker yourself in `~/.config/gpu-job/workers.json`, starting from [`references/gpu-workers.example.json`](skills/gpu-job/references/gpu-workers.example.json).

## Try asking Claude

- "Render frames 1-120 of garden.blend on the GPU box"
- "Is the worker free? Run the depth model on these three images there"
- "Check on the render and pull the finished frames back"

## You'll need

- [Claude Code](https://claude.com/claude-code)
- On your computer: bash, Python 3, ssh, rsync
- [Tailscale](https://tailscale.com) to reach workers away from home, or the worker on the same local network
- The worker: Linux with an NVIDIA GPU (`nvidia-smi`), bash, and SSH key access. Windows workers are covered by a manual guide (`references/windows.md`).

## How it works

```
config → preflight (read-only) → tell the others → run under a guard → status → fetch (copy only) → release
```

1. **Recruits PCs on your network** (`recruit.sh`, [guide](skills/gpu-job/references/recruit.md)). It lists the machines on your Tailscale network (a private network across your devices). It walks the PC's owner through Tailscale, an SSH server, a job user and a key, on Linux or Windows. Then it checks the PC's driver, free GPU memory, disk, Blender and sleep settings, and prints its config entry.
2. **Reads a small config** (`gpu-workers.json`) listing your workers and their **lanes**. A lane sets your job's GPU memory cap, the free memory needed before it starts, a time limit, and whether the owner must approve it.
3. **Checks the box first, read-only**: SSH, free GPU memory, temperature, who else is on the GPU, the STOP file, disk space and the shared status file.
4. **Runs your job in the background under a guard** (`guard.sh`, on the worker). The guard:
   - waits for room before each chunk of work;
   - runs the job at low priority with a thread cap;
   - stops it if a STOP file appears, or it passes its memory cap or time limit;
   - keeps a STATUS file current for everyone sharing the box;
   - resumes from finished chunks.
5. **Follows the etiquette.** Free lanes run without asking. Approval lanes never run without the owner's yes. It tells the other sessions before and after, keeps working files on the worker, and never deletes there without asking.
6. **Fetches results back with rsync, copy only.** Nothing on the worker is removed.

The scripts also work by hand. They live in the skill's `scripts/` folder, not on your PATH: `~/.claude/skills/gpu-job/scripts/` for a copied skill, or inside Claude Code's plugin cache for a plugin install (`/plugin` shows where). Claude finds them through `${CLAUDE_SKILL_DIR}`.

```sh
S=~/.claude/skills/gpu-job/scripts
$S/gpu-job.sh preflight gpu1
$S/gpu-job.sh run gpu1 --id garden-01 --purpose "Night garden" --eta 90 --put garden.blend \
  --frames 1-120 --chunk 10 -- '~/blender/blender' -b in/garden.blend -o out/f_#### -s '{start}' -e '{end}' -a
$S/gpu-job.sh status gpu1 garden-01
$S/gpu-job.sh fetch gpu1 garden-01 ./renders/garden
```

The command runs in the job's folder on the worker. Write results to `out/` (relative), and quote a `~/` program path so your own shell doesn't expand it.

## Licence

MIT. See [LICENSE](LICENSE).
