#!/usr/bin/env bash
# gpu-job.sh: run heavy jobs on a shared remote GPU box without stepping on anyone.
#
#   gpu-job.sh list
#   gpu-job.sh preflight <worker> [--lane L]
#   gpu-job.sh run <worker> --id ID --purpose "..." --eta MIN [--lane L] [--who NAME]
#                  [--put PATH]... [--frames 1-120 --chunk 10] [--owner-approved] [--resume] -- command...
#   gpu-job.sh status  <worker> [ID]
#   gpu-job.sh log     <worker> ID [lines]
#   gpu-job.sh fetch   <worker> ID DEST [--partial]
#   gpu-job.sh cancel  <worker> ID
#   gpu-job.sh release <worker> ID [--lane L]
#
# The command runs in <scratch>/jobs/ID on the worker: read inputs from ./in, write results to ./out.
# {start} and {end} in the command are replaced per chunk when --frames is given.
# Settings come from gpu-workers.json (see references/config.md). Linux workers only;
# for a Windows worker see references/windows.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "gpu-job: $*" >&2; exit 1; }
# Everything that reaches the worker's shell is either checked against these or quoted with printf %q.
valid_id() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || die "job id: letters, digits, . _ - only"; }
valid_int() { [[ $2 =~ ^[0-9]+$ ]] || die "$1 must be a whole number"; }
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

load() {  # load <worker> [lane]
  eval "$(python3 "$HERE/workers.py" env "$@")"
  [ "$GJ_OS" = "windows" ] && die "$GJ_WORKER is a Windows worker: these scripts drive Linux boxes. Follow references/windows.md."
  return 0
}
rsh() { ssh "${SSH_OPTS[@]}" "$GJ_SSH" "$@"; }
# Remote shell with the worker's settings exported; tilde in scratch expanded on the far side.
rbash() {
  { printf 'SCRATCH=%q; SCRATCH="${SCRATCH/#\\~/$HOME}"; STOP=%q; STATUSF=%q; MIN_FREE=%q; MAX_TEMP=%q; DISK_MIN=%q; PROTECTED=%q; ME=$(id -un)\n' \
      "$GJ_SCRATCH" "$GJ_STOP" "$GJ_STATUS" "$GJ_MIN_FREE" "$GJ_MAX_TEMP" "$GJ_DISK_MIN_GB" "$GJ_PROTECTED"
    cat; } | if [ $# -gt 0 ]; then rsh bash -s -- "$(printf '%q ' "$@")"; else rsh bash -s; fi
}

cmd=${1:-}; [ -n "$cmd" ] || { sed -n '2,20p' "$0"; exit 1; }; shift

case "$cmd" in
list) python3 "$HERE/workers.py" list ;;

preflight)
  W=${1:?worker}; shift; LANE=""
  while [ $# -gt 0 ]; do case $1 in --lane) LANE=$2; shift 2;; *) die "unknown $1";; esac; done
  load "$W" ${LANE:+"$LANE"}
  echo "== $GJ_WORKER ($GJ_SSH), lane $GJ_LANE: cap ${GJ_CAP} MiB, start only with ${GJ_MIN_FREE} MiB free, approval: $([ "$GJ_LANE_APPROVAL" = 1 ] && echo REQUIRED || echo no)"
  rbash <<'EOF'
ok=1
command -v nvidia-smi >/dev/null || { echo "FAIL  nvidia-smi not found"; exit 2; }
read -r name total used free temp util < <(nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader,nounits | head -1 | awk -F', ' '{gsub(/ /,"_",$1); print $1,$2,$3,$4,$5,$6}')
echo "gpu   $name  ${used}/${total} MiB used, ${free} free, ${temp}C, ${util}% busy"
[ "$free" -ge "$MIN_FREE" ] && echo "ok    free VRAM ${free} >= ${MIN_FREE}" || { echo "WAIT  free VRAM ${free} < ${MIN_FREE}"; ok=0; }
[ "$temp" -lt "$MAX_TEMP" ] && echo "ok    temperature ${temp}C < ${MAX_TEMP}C" || { echo "WAIT  GPU at ${temp}C"; ok=0; }
if [ -n "$STOP" ] && [ -e "$STOP" ]; then echo "WAIT  STOP file present: $STOP"; ok=0; else echo "ok    no STOP file${STOP:+ ($STOP)}"; fi
echo "--    other GPU users:"
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | while IFS=, read -r p n m; do
  u=$(ps -o user= -p "${p// /}" 2>/dev/null || echo "?"); echo "        pid${p} ${u:-?} ${n##*/} ${m# }"; done
for pr in $PROTECTED; do pgrep -f "$pr" >/dev/null 2>&1 && echo "info  protected service running: $pr (never touch it)"; done
mkdir -p "$SCRATCH" 2>/dev/null
avail=$(df -Pk "$SCRATCH" 2>/dev/null | awk 'NR==2{print int($4/1048576)}')
[ "${avail:-0}" -ge "$DISK_MIN" ] && echo "ok    ${avail} GB free at $SCRATCH" || { echo "WAIT  only ${avail} GB free at $SCRATCH"; ok=0; }
case "$SCRATCH" in /tmp*) echo "WARN  scratch is under /tmp (often RAM-backed): use a disk folder";; esac
if [ -n "$STATUSF" ] && [ -s "$STATUSF" ]; then echo "--    shared status file ($STATUSF):"; sed 's/^/        /' "$STATUSF"; fi
running=$(pgrep -u "$ME" -f 'guard.sh' | wc -l | tr -d ' ')
echo "info  my guarded jobs running: $running"
[ $ok = 1 ] && echo "READY  the lane admits a job now" || echo "NOT READY  a job started now would wait in the guard"
EOF
  ;;

run)
  W=${1:?worker}; shift
  LANE="" ID="" PURPOSE="" ETA="" WHO="${GPU_JOB_WHO:-$(id -un)@$(hostname -s)}" FRAMES="-" CHUNK=10 APPROVED=0 RESUME=0 PUTS=()
  while [ $# -gt 0 ]; do case $1 in
    --lane) LANE=$2; shift 2;; --id) ID=$2; shift 2;; --purpose) PURPOSE=$2; shift 2;; --eta) ETA=$2; shift 2;;
    --who) WHO=$2; shift 2;; --put) PUTS+=("$2"); shift 2;; --frames) FRAMES=$2; shift 2;; --chunk) CHUNK=$2; shift 2;;
    --owner-approved) APPROVED=1; shift;; --resume) RESUME=1; shift;; --) shift; break;; *) die "unknown $1";; esac; done
  [ $# -gt 0 ] || die "give the command after --"
  valid_id "$ID"
  [ -n "$PURPOSE" ] || die "--purpose is required (it goes into the status file others read)"
  [[ $ETA =~ ^[0-9]+$ ]] || die "--eta MINUTES is required"
  [ "$FRAMES" = "-" ] || [[ $FRAMES =~ ^[0-9]+-[0-9]+$ ]] || die "--frames START-END"
  [[ $CHUNK =~ ^[1-9][0-9]*$ ]] || die "--chunk must be a positive whole number"
  load "$W" ${LANE:+"$LANE"}
  if [ "$GJ_LANE_APPROVAL" = 1 ]; then
    [ $APPROVED = 1 ] || die "lane $GJ_LANE needs the box owner's approval. Ask them; pass --owner-approved only after they said yes."
    if [ -n "$GJ_REQUEST" ]; then
      valid_int "the lane's VRAM cap" "$GJ_CAP"
      req=${GJ_REQUEST//\{id\}/$(printf %q "$ID")}; req=${req//\{eta\}/$(printf %q "$ETA")}; req=${req//\{need\}/$(printf %q "$GJ_CAP")}; req=${req//\{purpose\}/$(printf %q "$PURPOSE")}
      echo "requesting lane $GJ_LANE: $req"
      rsh "$req" || die "the lane's request was not granted (exit $?)"
      GJ_WRAP=${GJ_WRAP//\{id\}/$ID}
    fi
  fi
  JOBREL="jobs/$ID"
  rbash "$JOBREL" "$RESUME" <<'EOF'
J="$SCRATCH/$1"
if [ -e "$J" ] && [ "$2" != 1 ]; then echo "gpu-job: $J exists; use a new --id, or --resume to continue it" >&2; exit 3; fi
mkdir -p "$J/in" "$J/out"
EOF
  RJOB=$(rsh "printf %s \"\${HOME}\"")/${GJ_SCRATCH#\~/}/$JOBREL
  case "$GJ_SCRATCH" in /*) RJOB="$GJ_SCRATCH/$JOBREL";; esac
  for p in ${PUTS[@]+"${PUTS[@]}"}; do rsync -a --partial -e "ssh ${SSH_OPTS[*]}" "$p" "$GJ_SSH:$RJOB/in/"; done
  scp -q "${SSH_OPTS[@]}" "$HERE/guard.sh" "$GJ_SSH:$RJOB/guard.sh"
  {
    for k in GJ_LANE GJ_CAP GJ_MIN_FREE GJ_MAX_TEMP GJ_NICE GJ_THREADS GJ_POLL GJ_MAX_HOURS GJ_STOP GJ_STATUS GJ_WRAP; do printf '%s=%q\n' "$k" "${!k}"; done
    printf 'GJ_WHO=%q\nGJ_PURPOSE=%q\n' "$WHO" "$PURPOSE"
  } | rsh "cat > $(printf %q "$RJOB")/guard.env"
  q=$(printf '%q ' "$@")
  rsh "cd $(printf %q "$RJOB") && chmod +x guard.sh && (setsid nohup ./guard.sh $(printf %q "$RJOB") $(printf %q "$ID") $(printf %q "$ETA") $(printf %q "$FRAMES") $(printf %q "$CHUNK") -- $q </dev/null >/dev/null 2>&1 &) && sleep 2 && cat STATUS 2>/dev/null"
  echo "started $ID on $GJ_WORKER in $RJOB (lane $GJ_LANE). Follow it: gpu-job.sh status $W $ID"
  ;;

status)
  W=${1:?worker}; ID=${2:-}; [ -z "$ID" ] || valid_id "$ID"; load "$W"
  rbash "$ID" <<'EOF'
if [ -n "$1" ]; then cat "$SCRATCH/jobs/$1/STATUS" 2>/dev/null || echo "no job $1"; echo "--"; tail -n 5 "$SCRATCH/jobs/$1/job.log" 2>/dev/null
else for s in "$SCRATCH"/jobs/*/STATUS; do [ -e "$s" ] && { echo "== $(basename "$(dirname "$s")")"; grep -E '^(state|lane|last chunk done|peak|updated):' "$s"; }; done; fi
echo "--"; nvidia-smi --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
[ -n "$STOP" ] && [ -e "$STOP" ] && echo "STOP file present: $STOP"
exit 0
EOF
  ;;

log) W=${1:?worker}; ID=${2:?id}; N=${3:-40}; valid_id "$ID"; valid_int "line count" "$N"; load "$W"
  rbash "$ID" "$N" <<'EOF'
tail -n "$2" "$SCRATCH/jobs/$1/job.log"
EOF
  ;;

fetch)
  W=${1:?worker}; ID=${2:?id}; DEST=${3:?dest}; PARTIAL=0; [ "${4:-}" = "--partial" ] && PARTIAL=1; valid_id "$ID"; load "$W"
  st=$(rbash "$ID" <<'EOF'
sed -n 's/^state: //p' "$SCRATCH/jobs/$1/STATUS" 2>/dev/null
EOF
)
  case "$st" in finished*) ;; *) [ $PARTIAL = 1 ] || die "job $ID is '$st', not finished. --partial copies the chunks finished so far.";; esac
  RJOB=$(rsh "printf %s \"\${HOME}\"")/${GJ_SCRATCH#\~/}/jobs/$ID
  case "$GJ_SCRATCH" in /*) RJOB="$GJ_SCRATCH/jobs/$ID";; esac
  mkdir -p "$DEST"
  # Copy only. Nothing is removed from the worker: scratch stays there.
  rsync -a --partial --exclude '*.tmp' --exclude '*.part' --exclude '*.partial' -e "ssh ${SSH_OPTS[*]}" "$GJ_SSH:$RJOB/out/" "$DEST/"
  echo "copied $ID/out to $DEST ($(du -sh "$DEST" | cut -f1)). The worker's copy is untouched."
  ;;

cancel)
  W=${1:?worker}; ID=${2:?id}; valid_id "$ID"; load "$W"
  rbash "$ID" <<'EOF'
g=$(cat "$SCRATCH/jobs/$1/guard.pid" 2>/dev/null) || { echo "no guard pid for $1"; exit 1; }
[ "$(ps -o user= -p "$g" 2>/dev/null | tr -d ' ')" = "$ME" ] || { echo "guard $g is not mine or not running"; exit 1; }
kids() { echo "$1"; for c in $(pgrep -P "$1"); do kids "$c"; done; }
for p in $(kids "$g" | sort -rn); do kill "$p" 2>/dev/null; done
sed -i 's/^state: .*/state: cancelled by owner of the job/' "$SCRATCH/jobs/$1/STATUS" 2>/dev/null
echo "cancelled $1 (guard $g and its children). Its files are left in place."
EOF
  ;;

release)
  W=${1:?worker}; ID=${2:?id}; valid_id "$ID"; shift 2; LANE=""; [ "${1:-}" = "--lane" ] && LANE=$2; load "$W" ${LANE:+"$LANE"}
  [ -n "$GJ_RELEASE" ] || { echo "lane $GJ_LANE has no release step"; exit 0; }
  rsh "${GJ_RELEASE//\{id\}/$(printf %q "$ID")}" && echo "released lane $GJ_LANE for $ID"
  ;;

*) die "unknown command '$cmd' (list, preflight, run, status, log, fetch, cancel, release)" ;;
esac
