# gpu-workers.json

`$GPU_WORKERS` if it is set, else `~/.config/gpu-job/workers.json`. **Never read from the current folder:** the config's `ssh` target and its `request_cmd` / `wrap_cmd` / `release_cmd` run on your machine and the worker, so a `gpu-workers.json` that came with a cloned repo must not take effect just because you ran the skill there. It holds hostnames and paths, not secrets: SSH keys stay in `~/.ssh`. Keep it out of public repos all the same.

**Numbers are whole numbers** (`3`, not `1.5` or `"3"`): they are checked when the config is read and again on the worker, and a config that breaks the rule is refused. `ssh` must be `user@host` or a `Host` alias (letters, digits, `. _ - @ :`), never starting with `-`.

```json
{
  "defaults": { "nice": 10, "threads": 4, "max_temp_c": 83 },
  "workers": {
    "<name>": {
      "ssh": "user@host",
      "lanes": { "<lane>": { ... } }
    }
  }
}
```

## Worker fields

| Field | Default | Meaning |
|---|---|---|
| `ssh` | required | SSH target (`user@host`, or a `Host` alias from `~/.ssh/config`; not starting with `-`). Key auth: the scripts use `BatchMode`, so a password prompt fails rather than hangs. |
| `scratch` | required | Your working folder on the worker. `~` is expanded there. Jobs go in `<scratch>/jobs/<id>/`. |
| `os` | `linux` | `linux` or `windows` (the scripts refuse Windows; see windows.md). |
| `gpu` | | A label for `list`. |
| `stop_file` | | A file whose presence means "stop now". The box's owner (or their automation) creates it to take the GPU back. |
| `status_file` | | A shared file the owner reads to see who is on the GPU. Each job keeps its own block in it (between `### gpu-job <id> begin` / `end` lines) and removes the block when it ends. The job user needs write access to this file only, not to its folder. |
| `protected_processes` | `[]` | Name patterns of services you must never touch; preflight reports them. |
| `gpu_index` | 0 | Which GPU the guard and preflight read (`nvidia-smi -i`), on a box with more than one. Point the job at the same card yourself (e.g. `CUDA_VISIBLE_DEVICES`). |
| `nice` | 10 | CPU priority of the job (0-19). |
| `threads` | 4 | `OMP_NUM_THREADS`; pass the tool's own thread flag too. |
| `max_temp_c` | 83 | Wait between chunks while the GPU is at or above this. |
| `poll_seconds` | 5 | How often the guard checks STOP, VRAM and time. |
| `max_hours` | 3 | Hard time limit per job, whole hours, at least 1 (a lane can override). |
| `disk_min_free_gb` | 20 | Preflight warns below this in scratch. |
| `notes` | | Free text for the agent: who else uses the box, quiet hours. |

`defaults` sets any of the optional fields for every worker.

## Lane fields

| Field | Default | Meaning |
|---|---|---|
| `vram_cap_mib` | 3000 | The guard kills your job if its own processes use more than this. |
| `min_free_mib` | 5120 | Start a chunk only when this much VRAM is free (cap plus a margin for the others). |
| `approval` | false | true: never used without the box owner's yes in the conversation (`--owner-approved`). |
| `max_hours` | worker's | Time limit for jobs in this lane. |
| `request_cmd` | | Run on the worker before an approval lane starts, e.g. a broker that pauses another service. `{id}` `{eta}` `{need}` `{purpose}` are filled in. Non-zero exit = not granted. |
| `wrap_cmd` | | Put in front of the job's command on the worker (e.g. a broker's guard that kills the job when the grant ends). `{id}` is filled in (in every lane). |
| `release_cmd` | | Run by `gpu-job.sh release` when the job is done. `{id}` is filled in. |

The first lane listed is the default.

## Choosing the numbers

Ask whoever runs the box. If they have not decided: measure what is resident when the box is idle (`nvidia-smi`), leave 1-2 GB for the others to grow into, and set `vram_cap_mib` so cap + resident + margin fits the card. `min_free_mib` is usually the cap plus 1-2 GB.
