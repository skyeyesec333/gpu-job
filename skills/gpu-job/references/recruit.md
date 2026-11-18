# Recruiting a GPU PC on your network

How to turn a PC with an NVIDIA card (a gaming desktop, a spare workstation, a home server) into a worker this skill can use, wherever you are. Three layers, checked in order:

```
1. network   Tailscale: the PC and this machine on the same private network, from anywhere
2. ssh       an SSH server on the PC, a user for jobs, your key in its authorized keys
3. gpu       driver and nvidia-smi answering over SSH, the tools the job needs, no sleeping
4. config    a gpu-workers.json entry, the box's rules, then preflight
```

`recruit.sh` (in this skill's `scripts/` folder; installed as a plugin that is `${CLAUDE_PLUGIN_ROOT}/skills/gpu-job/scripts/recruit.sh`) checks each layer **read-only**: `scan` lists the tailnet's machines, `probe <user>@<machine>` tests SSH and the GPU, `stanza <name> <user>@<machine>` prints a config entry to paste in. Its first connection to a machine records the machine's host key in your `~/.ssh/known_hosts` (`StrictHostKeyChecking=accept-new`); a key that changes later is refused.

**Who does what.** Installing software, logging in to Tailscale, creating users, starting services, opening firewall rules, changing power settings and copying keys are done **by the PC's owner, at the PC or in their own terminal**. Claude gives the exact commands and checks the result with `recruit.sh`; it does not type passwords, approve logins, or change a machine's security or system settings itself. Recruit only machines the owner says may be used.

## 1. Network: Tailscale

Tailscale puts your machines on one private network (a "tailnet") that works across home, office and phone hotspots, without opening ports on the router. Each machine gets a fixed `100.x.y.z` address and, with MagicDNS on, a name like `gamer-pc` or `gamer-pc.tail1234.ts.net`.

**Check this machine first:**

```sh
tailscale status          # lists the tailnet; "Logged out" or "not running" means start it
recruit.sh scan           # the same, sorted, with OS, address, MagicDNS name, direct/relayed, key expiry
```

**Add the GPU PC** (the owner, at the PC):

| OS | Install | Join |
|---|---|---|
| Windows | the installer from tailscale.com/download | sign in from the tray icon with the **same account** as this machine |
| Linux | `curl -fsSL https://tailscale.com/install.sh \| sh` | `sudo tailscale up`, open the printed link, sign in |
| macOS | App Store or tailscale.com/download | sign in from the menu bar |

Then, in the Tailscale admin console (login.tailscale.com, the owner's account):

- **Disable key expiry** for the worker (Machines → ⋯ → Disable key expiry). Otherwise it drops off the tailnet every 180 days, mid-render if unlucky. `recruit.sh scan` shows each machine's expiry.
- **Give it a plain name** (Machines → ⋯ → Edit machine name), e.g. `gpu1`: it becomes the SSH host.
- If several people share the tailnet, an **ACL** can limit who reaches the worker's port 22. Optional for a one-person tailnet.

**Check it worked:** `tailscale ping gpu1` (answers "via DERP" first, then direct once the two find each other; relayed works but is slower for big transfers) and `recruit.sh scan` shows it `online, direct`.

**Without Tailscale:** on one home network the PC's LAN address or `.local` name works the same way for the rest of this guide; give it a fixed address in the router. Don't forward port 22 from the internet to it.

### Tailscale SSH (Linux workers only)

On a Linux worker, `sudo tailscale up --ssh` lets Tailscale handle SSH logins with your tailnet identity, no keys to copy. Logins follow the `ssh` rules in the tailnet's policy. The default rule uses `action: "check"`, which asks for a browser re-authentication now and then; a background agent cannot do that.

**Don't change the default rule** to `accept`: it covers every device and user, root included. Add a narrow rule for the worker alone, for the job user only, and never `root`:

```json
{ "action": "accept", "src": ["autogroup:member"], "dst": ["tag:gpu-worker"], "users": ["gpujobs"] }
```

Tag the worker `tag:gpu-worker` (with the tag's owner declared in `tagOwners`). Tailscale's own check is still the safer default if someone is at the keyboard. Windows workers (and Macs running the App Store app) can't serve Tailscale SSH: use OpenSSH (below).

## 2. SSH: a server, a user, a key

### On this machine: a key for the worker

```sh
ssh-keygen -t ed25519 -f ~/.ssh/gpu_worker -C "gpu-jobs"      # a key just for workers; a passphrase is fine with ssh-agent
cat ~/.ssh/gpu_worker.pub                                      # give this line to the owner
```

And a host alias, so every tool says just `gpu1`:

```
# ~/.ssh/config
Host gpu1
  HostName gpu1                 # the MagicDNS name or 100.x address
  User gpujobs
  IdentityFile ~/.ssh/gpu_worker
  IdentitiesOnly yes
  ServerAliveInterval 30
```

### On a Linux worker (the owner)

```sh
sudo apt install openssh-server rsync             # Fedora: sudo dnf install openssh-server rsync
sudo systemctl enable --now ssh                   # Fedora/Arch: sshd
sudo adduser --disabled-password gpujobs          # a plain user for jobs: no sudo
sudo -u gpujobs nvidia-smi -L                     # lists the GPU? then no group is needed (most NVIDIA setups)
# Only if that fails with a permission error: add the render group, if the distro has one.
# (Avoid `video`: on many distros it also opens the framebuffer and the console.)
getent group render >/dev/null && sudo usermod -aG render gpujobs
sudo -u gpujobs mkdir -p ~gpujobs/.ssh ~gpujobs/gpu-work
echo '<the .pub line>' | sudo -u gpujobs tee -a ~gpujobs/.ssh/authorized_keys
sudo chmod 700 ~gpujobs/.ssh && sudo chmod 600 ~gpujobs/.ssh/authorized_keys
```

A separate, non-admin user keeps jobs away from the owner's files and the system. Turning off password logins (`PasswordAuthentication no` in `/etc/ssh/sshd_config`) is good practice once the key works; it's the owner's call.

### On a Windows worker (the owner, PowerShell as Administrator)

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service sshd -StartupType Automatic
# The installer adds the firewall rule; check it exists and allows the Tailscale interface:
Get-NetFirewallRule -Name *OpenSSH-Server* | Select-Object Name, Enabled, Profile
```

Where the key goes depends on the account:

- **A standard (non-admin) user** (better): `C:\Users\<user>\.ssh\authorized_keys`.
- **An administrator account:** Windows ignores the user's own file and reads `C:\ProgramData\ssh\administrators_authorized_keys`, which must be owned by Administrators and SYSTEM only:
  ```powershell
  Add-Content C:\ProgramData\ssh\administrators_authorized_keys '<the .pub line>'
  icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F"
  ```
  The SIDs are Administrators and SYSTEM; using them rather than the names works on Windows in any language. This is the most common reason a key "doesn't work" on Windows.

The default SSH shell is `cmd`. Making it PowerShell (`New-ItemProperty HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force`) suits references/windows.md; it's optional.

### Check

```sh
ssh -o BatchMode=yes gpu1 'echo ok'      # must print ok with no password prompt
recruit.sh probe gpu1
```

`BatchMode` is how the scripts connect: if this asks for a password or fails, the scripts will too. Common failures: `Permission denied (publickey)` (key in the wrong file, wrong permissions, or the admin-file rule on Windows), `Connection timed out` (sshd not running, firewall, or the PC asleep), `Host key verification failed` (the PC was reinstalled: the owner confirms, then `ssh-keygen -R gpu1`).

## 3. The GPU and the tools

`recruit.sh probe` reports what it finds. What it should see:

- **`nvidia-smi` answering for the job user:** the NVIDIA driver installed (Linux: the distro's `nvidia-driver-XXX` package; Windows: the Game Ready or Studio driver). On Linux, if it works for the owner but not the job user, add the `render` group as above.
- **The job's tools in the job user's reach:** for Blender, the official Linux tarball unpacked into the user's home (`~/blender/blender`) needs no admin rights (in a job command, quote it as `'~/blender/blender'` so your own shell doesn't expand it; the guard expands it on the worker); on Windows, the installer or the portable zip. For Python ML jobs, a venv in the scratch folder.
- **rsync** on a Linux worker (fetch uses it).
- **Disk:** tens of GB free in the scratch folder for renders.
- **It stays awake:** a Windows PC that sleeps after 30 minutes idle drops a running job's SSH session and then the job. The owner sets "When plugged in, put my device to sleep after: Never" (Settings → System → Power), or just while it works. `recruit.sh probe` warns if it sleeps. Wake-on-LAN can wake a sleeping one, but only from the same LAN, not over Tailscale.
- **Headless is fine:** Cycles, bakes and inference need no monitor or logged-in desktop. GUI tools (Unreal's editor) do: see references/windows.md.

## 4. Into the config

```sh
recruit.sh stanza gpu1 gpu1        # probes, then prints an entry to paste into gpu-workers.json
```

Its VRAM caps are a starting guess (60% and 70% of the card). Before the first job, ask the owner:

- What else uses this GPU (a game, a model server, another session) and how much memory it needs: set `vram_cap_mib` / `min_free_mib` so both fit, and list its processes in `protected_processes`.
- Whether they want a STOP file and a status file (`stop_file`, `status_file`): a one-line way to tell every job "stop now" and see who is on the box. The owner keeps the folder and the STOP file; the job user may write the status file only, so no job can remove the owner's STOP:
  ```sh
  sudo mkdir -p /srv/gpu-control                       # owned by root (or the owner), not by gpujobs
  sudo touch /srv/gpu-control/STATUS.txt
  sudo chown gpujobs /srv/gpu-control/STATUS.txt       # the only file the job user can write here
  # to stop every job:  sudo touch /srv/gpu-control/STOP     to let them go on:  sudo rm /srv/gpu-control/STOP
  ```
  Each job keeps its own block in the status file, between `### gpu-job <id> begin` / `end` lines, and takes it out when it ends.
- When the PC is theirs (gaming evenings, work hours): put it in the worker's `notes` and keep jobs out of those hours.

Then `gpu-job.sh preflight gpu1`. The config lives in `~/.config/gpu-job/workers.json` (or wherever `$GPU_WORKERS` points), never in a project folder. `READY` means the skill can use it.

## Retiring a worker

The owner removes the key line from `authorized_keys` (or deletes the job user), and removes the machine from the tailnet in the admin console if it's leaving for good. Delete its entry from `gpu-workers.json`. Fetch anything still in its scratch folder first.
