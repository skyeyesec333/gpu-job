# Windows workers (OpenSSH + PowerShell)

The scripts drive Linux boxes. A Windows worker follows the same rules by hand, through `ssh user@host powershell -NoProfile -Command "..."`. Put the PowerShell in a `.ps1` in the worker's scratch folder and run that: quoting through two shells is where most mistakes happen.

## Preflight (read-only)

```powershell
nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader
Test-Path C:\gpu-control\STOP                       # the STOP file, if the box has one
Get-PSDrive C | Select-Object Free                  # disk
Get-Process blender, python -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, StartTime
```

On Windows `nvidia-smi` often shows `[N/A]` for a process's memory (WDDM). Watch total `memory.used` instead, and set the lane's numbers on that.

## Run detached

An SSH session's children die with it on Windows. Start the job so it outlives the session:

```powershell
$job = "C:\Users\user\gpu-work\jobs\garden-01"
New-Item -ItemType Directory -Force "$job\in", "$job\out" | Out-Null
Start-Process -FilePath "C:\Program Files\Blender Foundation\Blender 4.5\blender.exe" `
  -ArgumentList '-b', "$job\in\garden.blend", '-t', '4', '-o', "$job\out\f_####", '-s', '1', '-e', '10', '-a' `
  -RedirectStandardOutput "$job\job.log" -RedirectStandardError "$job\job.err" -WindowStyle Hidden -PassThru |
  ForEach-Object { $_.Id | Set-Content "$job\pid"; $_.PriorityClass = 'BelowNormal' }
```

If `Start-Process` children are still killed when SSH closes, register a one-off scheduled task (`Register-ScheduledTask` with a `-Once` trigger a few seconds ahead) and start it with `Start-ScheduledTask`.

Write a small loop (`.ps1`) that does what `guard.sh` does: before each chunk check STOP, temperature and free VRAM; while running, check STOP every 5 s and `Stop-Process -Id <pid>` if it appears; keep `$job\STATUS` current with the same fields.

## Copy back

`scp -r user@host:C:/Users/user/gpu-work/jobs/garden-01/out ./garden-01` (forward slashes work), or rsync if the box has it through WSL or Cygwin. As on Linux: copy, never remove from the worker without asking.

## Unreal, Blender and other GUI tools

Headless Unreal (`UnrealEditor-Cmd.exe ... -run=pythonscript -script=...`) and Movie Render Queue with `-RenderOffscreen` both work over SSH. Anything that needs a desktop session (some launchers, first-run dialogs) has to be done once by a person at the box.
