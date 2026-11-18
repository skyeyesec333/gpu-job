#!/usr/bin/env bash
# guard.sh: runs ON the worker. Started detached by gpu-job.sh run; you rarely call it yourself.
#
# Runs one command, or the same command once per chunk of frames, under the box's rules:
#   - before each chunk: waits while the STOP file exists, the GPU is too hot, free VRAM is under the lane's
#     floor, or nvidia-smi cannot be read
#   - starts the command with nice and a thread cap, in the job folder (so out/... lands in <job>/out)
#   - every POLL seconds: kills it if STOP appears, if its own VRAM passes the lane cap (or cannot be read
#     three times running), or if the time limit is hit
#   - keeps a STATUS file current (who, what, lane, pid, start, ETA, last chunk done, peak VRAM), and its own
#     block in the box's shared status file, removed again when the guard exits for any reason
#   - records finished chunks in <job>/done, so a rerun resumes and fetch knows what is complete
#
# Usage: guard.sh <jobdir> <id> <eta-minutes> <frames|-> <chunk> -- command...
#   frames "1-120" and chunk 10 run the command 12 times with {start} and {end} replaced;
#   frames "-" runs it once. All other settings come from <jobdir>/guard.env (written by gpu-job.sh).
#   A leading "~/" in the command's first word is expanded to this user's home on the worker.
set -u
JOB=$1 ID=$2 ETA=$3 FRAMES=$4 CHUNK=$5; shift 5
[ "${1:-}" = "--" ] && shift
cd "$JOB" || { echo "guard: no job folder $JOB" >&2; exit 2; }
# shellcheck disable=SC1091
. "$JOB/guard.env"
LOG="$JOB/job.log"; DONE="$JOB/done"; touch "$DONE"
log() { echo "[$(date +%FT%T%z)] $*" >> "$LOG"; }

# Every number below reaches shell arithmetic, where bash would evaluate an expression such as a[$(cmd)].
# gpu-job.sh checks them too; the guard refuses to start on anything but plain digits.
GJ_GPU=${GJ_GPU:-0}
for v in ETA CHUNK GJ_CAP GJ_MIN_FREE GJ_MAX_TEMP GJ_NICE GJ_THREADS GJ_POLL GJ_MAX_HOURS GJ_GPU; do
  [[ ${!v} =~ ^[0-9]+$ ]] || { log "refusing to start: $v is not a whole number"; echo "state: refused: $v is not a whole number" > "$JOB/STATUS"; exit 2; }
done
[ "$FRAMES" = "-" ] || [[ $FRAMES =~ ^[0-9]+-[0-9]+$ ]] || { log "refusing to start: bad frames"; exit 2; }
{ [ "$CHUNK" -ge 1 ] && [ "$GJ_POLL" -ge 1 ]; } || { log "refusing to start: chunk and poll must be at least 1"; exit 2; }

ts() { date -d "@$1" +%FT%T%z 2>/dev/null || date -r "$1" +%FT%T%z; }
now() { date +%FT%T%z; }
T0=$(date +%s); START=$(now); END_BY=$(( T0 + GJ_MAX_HOURS * 3600 ))
PEAK=0; LAST="-"; PID="-"; STATE="starting"; BAD=0

# The shared status file holds one block per job, between these marker lines, so two jobs (or two sessions)
# never overwrite each other. Written in place (the file may be the only thing the job user can write in its
# folder), under flock when the box has it.
B_BEGIN="### gpu-job $ID begin"; B_END="### gpu-job $ID end"
shared() {  # shared <body|"">: replace (or, with "", remove) this job's block
  { [ -n "${GJ_STATUS:-}" ] && [ -w "$GJ_STATUS" ]; } || return 0
  local tmp="$JOB/.status.shared"
  {
    command -v flock >/dev/null && flock -w 5 9
    awk -v b="$B_BEGIN" -v e="$B_END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$GJ_STATUS" > "$tmp" 2>/dev/null
    [ -n "$1" ] && printf '%s\n%s\n%s\n' "$B_BEGIN" "$1" "$B_END" >> "$tmp"
    cat "$tmp" > "$GJ_STATUS"
  } 9>>"$GJ_STATUS"
  rm -f "$tmp"
}

status() {
  STATE=$1
  local body
  body=$(printf "job: %s\nowner: %s\nlane: %s\npurpose: %s\nframes: %s (chunks of %s)\npid: %s\nstart: %s\nexpected end: %s\nlast chunk done: %s\npeak VRAM of job (MiB): %s\nstate: %s\nupdated: %s\n" \
    "$ID" "${GJ_WHO:-unknown}" "$GJ_LANE" "${GJ_PURPOSE:-}" "$FRAMES" "$CHUNK" "$PID" "$START" \
    "$(ts $((T0 + ETA * 60)))" "$LAST" "$PEAK" "$STATE" "$(now)")
  echo "$body" > "$JOB/STATUS"
  shared "$body"
}

# One reading from the configured GPU; empty when nvidia-smi fails or prints anything but digits ([N/A], errors).
gpu() {
  local v; v=$(nvidia-smi -i "$GJ_GPU" --query-gpu="$1" --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ,\r')
  [[ $v =~ ^[0-9]+$ ]] && echo "$v"
}

# VRAM used by a process tree (MiB), from nvidia-smi's compute apps on the configured GPU. Prints nothing
# when it cannot be read: the caller treats that as a failed reading, never as zero.
tree_pids() { local p=$1; echo "$p"; for c in $(pgrep -P "$p" 2>/dev/null); do tree_pids "$c"; done; }
job_vram() {
  local pids sum=0 out p m
  pids=" $(tree_pids "$1" | tr '\n' ' ') "
  out=$(nvidia-smi -i "$GJ_GPU" --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null) || return 0
  while IFS=, read -r p m; do
    p=${p// /}; m=${m// /}; m=${m%$'\r'}
    [ -z "$p" ] && continue
    case "$pids" in *" $p "*) [[ $m =~ ^[0-9]+$ ]] || return 0; sum=$((sum + m));; esac
  done <<< "$out"
  echo "$sum"
}

# Sleep in the background and wait for it, so a TERM from cancel runs the trap at once, not after the sleep.
nap() { sleep "$1" & wait $!; }
kill_tree() { local p; for p in $(tree_pids "$1" | sort -rn); do kill "$p" 2>/dev/null; done; sleep 3; for p in $(tree_pids "$1"); do kill -9 "$p" 2>/dev/null; done; }

# Whatever ends the guard (finish, failure, cancel, a crash) takes its block out of the shared file, and a
# cancel stops the running command first.
on_term() { [ "$PID" != "-" ] && kill_tree "$PID"; status "cancelled"; log "cancelled (signal)"; exit 143; }
trap on_term TERM INT HUP
trap 'shared ""' EXIT

admit() {
  while :; do
    [ "$(date +%s)" -ge "$END_BY" ] && { status "stopped: time limit"; log "time limit"; exit 4; }
    if [ -n "$GJ_STOP" ] && [ -e "$GJ_STOP" ]; then status "waiting: STOP file present"; nap 10; continue; fi
    local free temp
    free=$(gpu memory.free); temp=$(gpu temperature.gpu)
    if [ -z "$free" ] || [ -z "$temp" ]; then status "waiting: cannot read the GPU (nvidia-smi)"; nap 20; continue; fi
    if [ "$temp" -ge "$GJ_MAX_TEMP" ]; then status "waiting: GPU at ${temp}C"; nap 30; continue; fi
    if [ "$free" -lt "$GJ_MIN_FREE" ]; then status "waiting: ${free} MiB free, need ${GJ_MIN_FREE}"; nap 20; continue; fi
    return 0
  done
}

run_one() {  # $1 start, $2 end ("-" when not chunked)
  local cmd=() a
  for a in "${ARGS[@]}"; do a=${a//\{start\}/$1}; a=${a//\{end\}/$2}; cmd+=("$a"); done
  # shellcheck disable=SC2088 # a literal "~/" sent from the local machine, expanded here on the worker
  case "${cmd[0]}" in "~/"*) cmd[0]="$HOME/${cmd[0]#\~/}";; esac
  local wrap=()
  # shellcheck disable=SC2206
  [ -n "${GJ_WRAP:-}" ] && wrap=($GJ_WRAP)
  log "start $1-$2: ${cmd[*]}"
  OMP_NUM_THREADS=$GJ_THREADS nice -n "$GJ_NICE" ${wrap[@]+"${wrap[@]}"} "${cmd[@]}" >> "$LOG" 2>&1 &
  PID=$!
  BAD=0
  status running
  while kill -0 "$PID" 2>/dev/null; do
    local used; used=$(job_vram "$PID")
    if [ -z "$used" ]; then
      BAD=$((BAD + 1))
      if [ "$BAD" -ge 3 ]; then log "VRAM unreadable 3 times running: killing $PID"; kill_tree "$PID"; PID="-"; status "killed: VRAM could not be read"; return 77; fi
    else
      BAD=0; [ "$used" -gt "$PEAK" ] && PEAK=$used
      if [ "$used" -gt "$GJ_CAP" ]; then log "VRAM ${used} > cap ${GJ_CAP}: killing $PID"; kill_tree "$PID"; PID="-"; status "killed: over VRAM cap"; return 76; fi
    fi
    if [ -n "$GJ_STOP" ] && [ -e "$GJ_STOP" ]; then log "STOP file: killing $PID"; kill_tree "$PID"; PID="-"; status "killed: STOP file"; return 75; fi
    if [ "$(date +%s)" -ge "$END_BY" ]; then log "time limit: killing $PID"; kill_tree "$PID"; PID="-"; status "killed: time limit"; return 4; fi
    status running; nap "$GJ_POLL"
  done
  wait "$PID"; local rc=$?
  PID="-"
  log "end $1-$2 rc $rc peak ${PEAK} MiB"
  return $rc
}

why() { case $1 in 76) echo "over the lane VRAM cap (${PEAK} MiB > ${GJ_CAP}): lower the job's memory";; 77) echo "the job's VRAM could not be read (nvidia-smi)";; 4) echo "time limit";; *) echo "rc $1, see job.log";; esac; }

ARGS=("$@")
echo $$ > "$JOB/guard.pid"
log "guard up: GPU $GJ_GPU, lane $GJ_LANE cap $GJ_CAP MiB, min free $GJ_MIN_FREE MiB, nice $GJ_NICE, threads $GJ_THREADS"

if [ "$FRAMES" = "-" ]; then
  if grep -qx -- "-" "$DONE"; then status "finished (already done)"; exit 0; fi
  while :; do
    admit; run_one - -; rc=$?
    [ $rc -eq 75 ] && continue          # STOP: wait for it to clear, then run again
    break
  done
  if [ $rc -eq 0 ]; then echo "-" >> "$DONE"; LAST="-"; status "finished"; else status "failed: $(why $rc)"; fi
  exit $rc
fi

S=${FRAMES%-*}; E=${FRAMES#*-}
for ((a = S; a <= E; a += CHUNK)); do
  b=$((a + CHUNK - 1)); [ "$b" -gt "$E" ] && b=$E
  grep -qx "$a-$b" "$DONE" && { LAST="$a-$b"; continue; }
  while :; do
    admit; run_one "$a" "$b"; rc=$?
    [ $rc -eq 75 ] && continue
    break
  done
  if [ $rc -ne 0 ]; then status "failed at $a-$b: $(why $rc)"; exit $rc; fi
  echo "$a-$b" >> "$DONE"; LAST="$a-$b"; status running
done
status finished
log "all chunks done"
