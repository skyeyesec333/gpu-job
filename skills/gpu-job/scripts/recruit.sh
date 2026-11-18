#!/usr/bin/env bash
# recruit.sh: find PCs on your network that could take GPU jobs, and check one is ready. Read-only.
#
#   recruit.sh scan                list the tailnet's machines (online first), from `tailscale status`
#   recruit.sh probe <ssh-target>  key-only SSH to one machine: OS, GPU, driver, VRAM free, disk, Blender
#   recruit.sh stanza <name> <ssh-target>
#                                  probe, then print a gpu-workers.json entry to paste in (nothing written)
#
# It never installs, logs in, changes a setting or copies a key: those steps are the machine owner's
# (references/recruit.md has them). SSH runs with BatchMode, so a machine without your key just says so.
set -uo pipefail
die() { echo "recruit: $*" >&2; exit 1; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new)

scan() {
  command -v tailscale >/dev/null || die "tailscale is not installed here (https://tailscale.com/download), or use LAN addresses with 'probe'"
  local js; js=$(tailscale status --json 2>/dev/null) || die "tailscale is installed but not running or not logged in: run 'tailscale up' (or open the app)"
  python3 - "$js" <<'PY'
import json, sys
s = json.loads(sys.argv[1])
if s.get("BackendState") != "Running":
    sys.exit(f"tailscale is {s.get('BackendState')}: log in / connect first")
me = s.get("Self", {})
print(f"this machine: {me.get('HostName')} ({(me.get('TailscaleIPs') or ['?'])[0]}), tailnet {s.get('CurrentTailnet', {}).get('Name', '?')}")
peers = sorted((s.get("Peer") or {}).values(), key=lambda p: (not p.get("Online"), p.get("HostName", "").lower()))
if not peers:
    sys.exit("no other machines on this tailnet yet: install Tailscale on the GPU PC and log in with the same account")
print(f"\n{'':2}{'machine':24}{'os':10}{'address':17}{'MagicDNS name':38}state")
for p in peers:
    dns = (p.get("DNSName") or "").rstrip(".")
    ip = (p.get("TailscaleIPs") or ["?"])[0]
    state = "online" if p.get("Online") else "offline"
    if p.get("Online") and p.get("CurAddr"): state += ", direct"
    elif p.get("Online") and p.get("Relay"): state += f", relayed ({p['Relay']})"
    if p.get("KeyExpiry"): state += f", key expires {p['KeyExpiry'][:10]}"
    print(f"  {p.get('HostName','?')[:23]:24}{p.get('OS','?'):10}{ip:17}{dns[:37]:38}{state}")
print("\nGPU candidates are usually the online windows/linux desktops. Next: recruit.sh probe <user>@<machine>")
PY
}

probe() {
  local t=${1:?ssh target, e.g. user@machine}
  echo "== $t"
  local err; err=$(mktemp)
  if ! ssh "${SSH_OPTS[@]}" "$t" "exit 0" 2>"$err"; then
    sed 's/^/   ssh: /' "$err"; rm -f "$err"
    echo "NOT READY  key-only SSH failed. See references/recruit.md, section 2 (SSH server, user, key)."
    return 1
  fi
  rm -f "$err"
  local os; os=$(ssh "${SSH_OPTS[@]}" "$t" "uname -s" 2>/dev/null | tr -d '\r')
  # Windows OpenSSH runs cmd by default (where `ver` works) or PowerShell if the owner changed it (`cmd /c ver`).
  if [ -z "$os" ]; then
    local v; v=$({ ssh "${SSH_OPTS[@]}" "$t" "ver"; ssh "${SSH_OPTS[@]}" "$t" "cmd /c ver"; } 2>/dev/null)
    [[ $v == *[Ww]indows* ]] && os=Windows
  fi
  echo "ok    ssh with key, OS: ${os:-unknown}"
  local g; g=$(ssh "${SSH_OPTS[@]}" "$t" "nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version --format=csv,noheader,nounits" 2>/dev/null | tr -d '\r' | head -1)
  if [ -n "$g" ]; then
    IFS=, read -r name total free drv <<<"$g"
    echo "ok    GPU ${name% }: ${total# } MiB, ${free# } MiB free now, driver ${drv# }"
  else
    echo "FAIL  nvidia-smi did not answer: no NVIDIA GPU, no driver, or not on PATH for this user"
  fi
  case $os in
    Linux|Darwin)
      ssh "${SSH_OPTS[@]}" "$t" 'df -Pk ~ | awk "NR==2{printf \"ok    %d GB free in the home folder\n\", \$4/1048576}";
        bl=""; for b in blender ~/blender/blender ~/blender*/blender /opt/blender*/blender /snap/bin/blender; do command -v "$b" >/dev/null 2>&1 && { bl=$("$b" -v 2>/dev/null | head -1); echo "info  blender: $bl ($b)"; break; }; done;
        [ -n "$bl" ] || echo "info  no blender found in the usual places (only matters for Blender jobs)";
        command -v rsync >/dev/null && echo "ok    rsync present" || echo "WARN  no rsync on the worker: fetch needs it";
        id -nG | grep -qwE "sudo|wheel|admin" && echo "WARN  this user is an administrator: a plain guest user is safer for jobs" || echo "ok    plain user (not an administrator)"' 2>/dev/null ;;
    Windows)
      # Sent as -EncodedCommand (UTF-16LE base64) so neither cmd nor PowerShell re-reads the quotes.
      local ps='$d=(Get-PSDrive C).Free/1GB; "ok    {0:N0} GB free on C:" -f $d
$b=Get-ChildItem "C:\Program Files\Blender Foundation" -Filter blender.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if($b){"info  blender: "+$b.FullName}else{"info  no blender in Program Files (only matters for Blender jobs)"}
$l=powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String "Current AC Power Setting Index"
if($l){$p=[Convert]::ToInt32((($l.Line -split ": ")[1]).Trim(),16); if($p -gt 0){"WARN  sleeps after $($p/60) min idle on mains power: a sleeping PC drops jobs (owner: Settings > System > Power)"}else{"ok    does not sleep on mains power"}}'
      local enc; enc=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
      ssh "${SSH_OPTS[@]}" "$t" "powershell -NoProfile -NonInteractive -EncodedCommand $enc" 2>/dev/null | tr -d '\r'
      echo "info  Windows: the job scripts do not drive it; follow references/windows.md" ;;
  esac
  [ -n "$g" ] && echo "READY  $t can be added to gpu-workers.json" || echo "NOT READY  fix the GPU line above first"
}

stanza() {
  local n=${1:?name} t=${2:?ssh target}
  probe "$t" || exit 1
  local os; os=$(ssh "${SSH_OPTS[@]}" "$t" "uname -s" 2>/dev/null | tr -d '\r'); [ -n "$os" ] || os=Windows
  local g; g=$(ssh "${SSH_OPTS[@]}" "$t" "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits" 2>/dev/null | tr -d '\r' | head -1)
  IFS=, read -r name total <<<"$g"; total=${total// /}
  local cap=$(( ${total:-8192} * 6 / 10 )) need=$(( ${total:-8192} * 7 / 10 ))
  local los=linux scratch='~/gpu-work'; [ "$os" = Windows ] && { los=windows; scratch='C:\\Users\\'"${t%@*}"'\\gpu-work'; }
  cat <<EOF

Paste under "workers" (caps are a starting guess, 60% / 70% of ${total:-?} MiB: agree the real ones with the owner):
    "$n": {
      "ssh": "$t",
      "os": "$los",
      "gpu": "${name# } ${total:-?} MiB",
      "scratch": "$scratch",
      "lanes": { "A": { "vram_cap_mib": $cap, "min_free_mib": $need } }
    }
EOF
}

cmd=${1:-}; shift || true
case $cmd in
  scan) scan ;;
  probe) probe "$@" ;;
  stanza) stanza "$@" ;;
  *) sed -n '2,11p' "$0"; exit 1 ;;
esac
