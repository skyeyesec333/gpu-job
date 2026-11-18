#!/usr/bin/env bash
# guard.sh: runs ON the worker. Started detached by gpu-job.sh run; you rarely call it yourself.
#
# Runs one command, or the same command once per chunk of frames, under the box's rules:
#   - before each chunk: waits while the STOP file exists, the GPU is too hot, or free VRAM is under the lane's floor
#   - starts the command with nice and a thread cap
#   - every POLL seconds: kills it if STOP appears, if its own VRAM passes the lane cap, or if the time limit is hit
#   - keeps a STATUS file current (who, what, lane, pid, start, ETA, last chunk done, peak VRAM)
#   - records finished chunks in <job>/done, so a rerun resumes and fetch knows what is complete
#
# Usage: guard.sh <jobdir> <id> <eta-minutes> <frames|-> <chunk> -- command...
#   frames "1-120" and chunk 10 run the command 12 times with {start} and {end} replaced;
#   frames "-" runs it once. All other settings come from <jobdir>/guard.env (written by gpu-job.sh).
set -u
JOB=$1 ID=$2 ETA=$3 FRAMES=$4 CHUNK=$5; shift 5
[ "${1:-}" = "--" ] && shift
# shellcheck disable=SC1091
. "$JOB/guard.env"
LOG="$JOB/job.log"; DONE="$JOB/done"; touch "$DONE"
ts() { date -d "@$1" +%FT%T%z 2>/dev/null || date -r "$1" +%FT%T%z; }
now() { date +%FT%T%z; }
T0=$(date +%s); START=$(now); END_BY=$(( $(date +%s) + GJ_MAX_HOURS * 3600 ))
PEAK=0; LAST="-"; PID="-"; STATE="starting"

log() { echo "[$(now)] $*" >> "$LOG"; }

status() {
  STATE=$1
  local body
  body=$(printf "job: %s\nowner: %s\nlane: %s\npurpose: %s\nframes: %s (chunks of %s)\npid: %s\nstart: %s\nexpected end: %s\nlast chunk done: %s\npeak VRAM of job (MiB): %s\nstate: %s\nupdated: %s\n" \
    "$ID" "${GJ_WHO:-unknown}" "$GJ_LANE" "${GJ_PURPOSE:-}" "$FRAMES" "$CHUNK" "$PID" "$START" \
    "$(ts $((T0 + ETA * 60)))" "$LAST" "$PEAK" "$STATE" "$(now)")
  echo "$body" > "$JOB/STATUS"
  [ -n "$GJ_STATUS" ] && echo "$body" > "$GJ_STATUS" 2>/dev/null
}

gpu() { nvidia-smi --query-gpu="$1" --format=csv,noheader,nounits | head -1 | tr -d ' ,'; }

# VRAM used by a process tree (MiB), from nvidia-smi's compute apps.
tree_pids() { local p=$1; echo "$p"; for c in $(pgrep -P "$p" 2>/dev/null); do tree_pids "$c"; done; }
job_vram() {
  local pids sum=0
  pids=" $(tree_pids "$1" | tr '\n' ' ') "
  while IFS=, read -r p m; do
    p=${p// /}; m=${m// /}
    case "$pids" in *" $p "*) sum=$((sum + m));; esac
  done < <(nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null)
  echo "$sum"
}

kill_tree() { for p in $(tree_pids "$1" | sort -rn); do kill "$p" 2>/dev/null; done; sleep 3; for p in $(tree_pids "$1"); do kill -9 "$p" 2>/dev/null; done; }

admit() {
  while :; do
    [ "$(date +%s)" -ge "$END_BY" ] && { status "stopped: time limit"; log "time limit"; exit 4; }
    if [ -n "$GJ_STOP" ] && [ -e "$GJ_STOP" ]; then status "waiting: STOP file present"; sleep 10; continue; fi
    local free temp
    free=$(gpu memory.free); temp=$(gpu temperature.gpu)
    if [ "$temp" -ge "$GJ_MAX_TEMP" ]; then status "waiting: GPU at ${temp}C"; sleep 30; continue; fi
    if [ "$free" -lt "$GJ_MIN_FREE" ]; then status "waiting: ${free} MiB free, need ${GJ_MIN_FREE}"; sleep 20; continue; fi
    return 0
  done
}

run_one() {  # $1 start, $2 end ("-" when not chunked)
  local cmd=() a
  for a in "${ARGS[@]}"; do a=${a//\{start\}/$1}; a=${a//\{end\}/$2}; cmd+=("$a"); done
  local wrap=()
  # shellcheck disable=SC2206
  [ -n "${GJ_WRAP:-}" ] && wrap=($GJ_WRAP)
  log "start $1-$2: ${cmd[*]}"
  OMP_NUM_THREADS=$GJ_THREADS nice -n "$GJ_NICE" ${wrap[@]+"${wrap[@]}"} "${cmd[@]}" >> "$LOG" 2>&1 &
  PID=$!
  status running
  while kill -0 "$PID" 2>/dev/null; do
    local used; used=$(job_vram "$PID"); [ "$used" -gt "$PEAK" ] && PEAK=$used
    if [ -n "$GJ_STOP" ] && [ -e "$GJ_STOP" ]; then log "STOP file: killing $PID"; kill_tree "$PID"; status "killed: STOP file"; return 75; fi
    if [ "$used" -gt "$GJ_CAP" ]; then log "VRAM ${used} > cap ${GJ_CAP}: killing $PID"; kill_tree "$PID"; status "killed: over VRAM cap"; return 76; fi
    if [ "$(date +%s)" -ge "$END_BY" ]; then log "time limit: killing $PID"; kill_tree "$PID"; status "killed: time limit"; return 4; fi
    status running; sleep "$GJ_POLL"
  done
  wait "$PID"; local rc=$?
  log "end $1-$2 rc $rc peak ${PEAK} MiB"
  return $rc
}

why() { case $1 in 76) echo "over the lane VRAM cap (${PEAK} MiB > ${GJ_CAP}): lower the job's memory";; 4) echo "time limit";; *) echo "rc $1, see job.log";; esac; }

ARGS=("$@")
echo $$ > "$JOB/guard.pid"
log "guard up: lane $GJ_LANE cap $GJ_CAP MiB, min free $GJ_MIN_FREE MiB, nice $GJ_NICE, threads $GJ_THREADS"

if [ "$FRAMES" = "-" ]; then
  if grep -qx -- "-" "$DONE"; then status "finished (already done)"; exit 0; fi
  while :; do
    admit; run_one - -; rc=$?
    [ $rc -eq 75 ] && continue          # STOP: wait for it to clear, then run again
    break
  done
  [ $rc -eq 0 ] && { echo "-" >> "$DONE"; LAST="-"; status "finished"; } || status "failed: $(why $rc)"
  exit $rc
fi

S=${FRAMES%-*}; E=${FRAMES#*-}
for ((a = S; a <= E; a += CHUNK)); do
  b=$((a + CHUNK - 1)); [ $b -gt "$E" ] && b=$E
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
