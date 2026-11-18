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
# Settings come from $GPU_WORKERS or ~/.config/gpu-job/workers.json (see references/config.md). Linux workers only;
# for a Windows worker see references/windows.md.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { echo "gpu-job: $*" >&2; exit 1; }
# Everything that reaches the worker's shell is either checked against these or quoted with printf %q.
valid_id() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]] || die "job id: letters, digits, . _ - only"; }
valid_int() { [[ $2 =~ ^[0-9]+$ ]] || die "$1 must be a whole number"; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }   # need "$@" inside an option loop
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8)

load() {  # load <worker> [lane]
  local envs; envs=$(python3 "$HERE/workers.py" env "$@") || exit 1
  eval "$envs"   # every value is shlex-quoted by workers.py, which has also checked the numbers and the ssh target
  local v; for v in GJ_CAP GJ_MIN_FREE GJ_MAX_TEMP GJ_NICE GJ_THREADS GJ_POLL GJ_MAX_HOURS GJ_DISK_MIN_GB GJ_GPU; do valid_int "$v" "${!v}"; done
  case "$GJ_SSH" in -*) die "ssh target may not start with '-'";; esac
  [ "$GJ_OS" = "windows" ] && die "$GJ_WORKER is a Windows worker: these scripts drive Linux boxes. Follow references/windows.md."
  return 0
}
rsh() { ssh "${SSH_OPTS[@]}" -- "$GJ_SSH" "$@"; }
# Remote shell with the worker's settings exported; tilde in scratch expanded on the far side.
rbash() {
  { printf 'SCRATCH=%q; SCRATCH="${SCRATCH/#\\~/$HOME}"; STOP=%q; STATUSF=%q; MIN_FREE=%q; MAX_TEMP=%q; DISK_MIN=%q; PROTECTED=%q; GPU=%q; ME=$(id -un)\n' \
      "$GJ_SCRATCH" "$GJ_STOP" "$GJ_STATUS" "$GJ_MIN_FREE" "$GJ_MAX_TEMP" "$GJ_DISK_MIN_GB" "$GJ_PROTECTED" "$GJ_GPU"
    cat; } | if [ $# -gt 0 ]; then rsh bash -s -- "$(printf '%q ' "$@")"; else rsh bash -s; fi
}

cmd=${1:-}; [ -n "$cmd" ] || { sed -n '2,20p' "$0"; exit 1; }; shift

case "$cmd" in
list) python3 "$HERE/workers.py" list ;;

preflight)
  W=${1:?worker}; shift; LANE=""
  while [ $# -gt 0 ]; do case $1 in --lane) need "$@"; LANE=$2; shift 2;; *) die "unknown $1";; esac; done
  load "$W" ${LANE:+"$LANE"}
  echo "== $GJ_WORKER ($GJ_SSH), lane $GJ_LANE: cap ${GJ_CAP} MiB, start only with ${GJ_MIN_FREE} MiB free, approval: $([ "$GJ_LANE_APPROVAL" = 1 ] && echo REQUIRED || echo no)"
  rbash <<'EOF'
ok=1
command -v nvidia-smi >/dev/null || { echo "FAIL  nvidia-smi not found"; exit 2; }
read -r name total used free temp util < <(nvidia-smi -i "$GPU" --query-gpu=name,memory.total,memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader,nounits | head -1 | awk -F', ' '{gsub(/ /,"_",$1); print $1,$2,$3,$4,$5,$6}')
echo "gpu   $name  ${used}/${total} MiB used, ${free} free, ${temp}C, ${util}% busy"
case "$free$temp" in *[!0-9]*|"") echo "WAIT  nvidia-smi gave no usable reading (free '$free', temp '$temp')"; ok=0; free=0; temp=999;; esac
[ "$free" -ge "$MIN_FREE" ] && echo "ok    free VRAM ${free} >= ${MIN_FREE}" || { echo "WAIT  free VRAM ${free} < ${MIN_FREE}"; ok=0; }
[ "$temp" -lt "$MAX_TEMP" ] && echo "ok    temperature ${temp}C < ${MAX_TEMP}C" || { echo "WAIT  GPU at ${temp}C"; ok=0; }
if [ -n "$STOP" ] && [ -e "$STOP" ]; then echo "WAIT  STOP file present: $STOP"; ok=0; else echo "ok    no STOP file${STOP:+ ($STOP)}"; fi
echo "--    other GPU users:"
nvidia-smi -i "$GPU" --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | while IFS=, read -r p n m; do
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
    --lane) need "$@"; LANE=$2; shift 2;; --id) need "$@"; ID=$2; shift 2;; --purpose) need "$@"; PURPOSE=$2; shift 2;;
    --eta) need "$@"; ETA=$2; shift 2;; --who) need "$@"; WHO=$2; shift 2;; --put) need "$@"; PUTS+=("$2"); shift 2;;
    --frames) need "$@"; FRAMES=$2; shift 2;; --chunk) need "$@"; CHUNK=$2; shift 2;;
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
    fi
  fi
  GJ_WRAP=${GJ_WRAP//\{id\}/$ID}   # the id is checked above: letters, digits, . _ - only
  JOBREL="jobs/$ID"
  rbash "$JOBREL" "$RESUME" <<'EOF'
J="$SCRATCH/$1"
if [ -e "$J" ] && [ "$2" != 1 ]; then echo "gpu-job: $J exists; use a new --id, or --resume to continue it" >&2; exit 3; fi
g=$(cat "$J/guard.pid" 2>/dev/null)
if [ -n "$g" ] && kill -0 "$g" 2>/dev/null && ps -o args= -p "$g" 2>/dev/null | grep -q guard.sh; then
  echo "gpu-job: $1 is still running (guard $g); --resume is for a stopped job. Cancel it first if you mean to restart." >&2; exit 3
fi
mkdir -p "$J/in" "$J/out"
EOF
  RJOB=$(rsh "printf %s \"\${HOME}\"")/${GJ_SCRATCH#\~/}/$JOBREL
  case "$GJ_SCRATCH" in /*) RJOB="$GJ_SCRATCH/$JOBREL";; esac
  for p in ${PUTS[@]+"${PUTS[@]}"}; do rsync -a --partial -e "ssh ${SSH_OPTS[*]}" "$p" "$GJ_SSH:$RJOB/in/"; done
  scp -q "${SSH_OPTS[@]}" -- "$HERE/guard.sh" "$GJ_SSH:$RJOB/guard.sh"
  {
    for k in GJ_LANE GJ_CAP GJ_MIN_FREE GJ_MAX_TEMP GJ_NICE GJ_THREADS GJ_POLL GJ_MAX_HOURS GJ_GPU GJ_STOP GJ_STATUS GJ_WRAP; do printf '%s=%q\n' "$k" "${!k}"; done
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
echo "--"; nvidia-smi -i "$GPU" --query-gpu=memory.used,memory.free,temperature.gpu,utilization.gpu --format=csv,noheader
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
  case "$DEST" in -*) die "dest may not start with '-'";; esac
  st=$(rbash "$ID" <<'EOF'
sed -n 's/^state: //p' "$SCRATCH/jobs/$1/STATUS" 2>/dev/null
EOF
)
  case "$st" in
    finished*) ;;
    *) [ $PARTIAL = 1 ] || die "job $ID is '$st', not finished. --partial copies out/ as it is now."
       echo "note: job $ID is '$st'. --partial copies out/ as it is now: frames of the chunk being rendered may be missing or half-written (see 'done' for the finished chunks)." >&2;;
  esac
  RJOB=$(rsh "printf %s \"\${HOME}\"")/${GJ_SCRATCH#\~/}/jobs/$ID
  case "$GJ_SCRATCH" in /*) RJOB="$GJ_SCRATCH/jobs/$ID";; esac
  mkdir -p "$DEST"
  # Copy only. Nothing is removed from the worker: scratch stays there.
  # --no-links: a symlink in out/ (made by the job, or by anyone who can write there) is skipped, never followed.
  rsync -a --no-links --partial --exclude '*.tmp' --exclude '*.part' --exclude '*.partial' -e "ssh ${SSH_OPTS[*]}" "$GJ_SSH:$RJOB/out/" "$DEST/"
  echo "copied $ID/out to $DEST ($(du -sh "$DEST" | cut -f1)). The worker's copy is untouched."
  ;;

cancel)
  W=${1:?worker}; ID=${2:?id}; valid_id "$ID"; load "$W"
  rbash "$ID" <<'EOF'
g=$(cat "$SCRATCH/jobs/$1/guard.pid" 2>/dev/null) || { echo "no guard pid for $1"; exit 1; }
case "$g" in ''|*[!0-9]*) echo "bad guard pid for $1"; exit 1;; esac
[ "$(ps -o user= -p "$g" 2>/dev/null | tr -d ' ')" = "$ME" ] || { echo "guard $g is not mine or not running"; exit 1; }
ps -o args= -p "$g" 2>/dev/null | grep -q guard.sh || { echo "pid $g is not a guard (the job has ended)"; exit 1; }
# The guard was started with setsid, so it leads its own process group: signal the whole group, which also
# reaches children that re-parented away from it. TERM first (the guard records "cancelled" and tidies up),
# KILL after a grace period.
pg=$(ps -o pgid= -p "$g" 2>/dev/null | tr -d ' ')
if [ "$pg" = "$g" ]; then kill -TERM -- "-$g" 2>/dev/null; else kill -TERM "$g" 2>/dev/null; fi
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$g" 2>/dev/null || break; sleep 1; done
if kill -0 "$g" 2>/dev/null; then
  if [ "$pg" = "$g" ]; then kill -KILL -- "-$g" 2>/dev/null; else kill -KILL "$g" 2>/dev/null; fi
  # A killed guard can't tidy up: mark its STATUS and take its block out of the shared file here.
  st="$SCRATCH/jobs/$1/STATUS"; sed 's/^state: .*/state: cancelled by owner of the job/' "$st" > "$st.new" 2>/dev/null && cat "$st.new" > "$st"; rm -f "$st.new"
  if [ -n "$STATUSF" ] && [ -w "$STATUSF" ]; then
    awk -v b="### gpu-job $1 begin" -v e="### gpu-job $1 end" '$0==b{s=1;next} $0==e{s=0;next} !s' "$STATUSF" > "$SCRATCH/jobs/$1/.status.shared" && cat "$SCRATCH/jobs/$1/.status.shared" > "$STATUSF"
  fi
fi
echo "cancelled $1 (guard $g and its process group). Its files are left in place."
EOF
  ;;

release)
  W=${1:?worker}; ID=${2:?id}; valid_id "$ID"; shift 2; LANE=""; if [ "${1:-}" = "--lane" ]; then need "$@"; LANE=$2; fi; load "$W" ${LANE:+"$LANE"}
  [ -n "$GJ_RELEASE" ] || { echo "lane $GJ_LANE has no release step"; exit 0; }
  rsh "${GJ_RELEASE//\{id\}/$(printf %q "$ID")}" && echo "released lane $GJ_LANE for $ID"
  ;;

*) die "unknown command '$cmd' (list, preflight, run, status, log, fetch, cancel, release)" ;;
esac
