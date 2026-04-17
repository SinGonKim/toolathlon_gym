#!/bin/bash
# Enroot-based fully parallel benchmark runner for OpenAI / OpenRouter models.
# Mirrors run_parallel.sh but targets clusters where Docker is unavailable and
# Enroot (>=3.4) is used instead — e.g. Slurm CPU partitions without daemon access.
#
# Networking note:
#   Enroot shares the host network namespace (no Docker-style isolated bridges),
#   so each concurrent task is given a UNIQUE postgres port in the range
#   [BASE_PORT .. BASE_PORT + N-1]. The agent connects to localhost:<port>.
#
# Usage:
#   ./run_parallel_enroot.sh <max_concurrent> [task1 task2 ...]
#
# Required env vars (or place in .env):
#   MODEL                 Model name
#   PROVIDER              openai | openrouter
#   MODEL_API_KEY         API key
#
# Optional env vars:
#   MODEL_PROVIDER        default: $PROVIDER
#   MODEL_PLATFORM        default: $PROVIDER
#   MODEL_API_URL         default: empty
#   MAX_STEPS             default: 100
#   BASE_PORT             default: 15432  (postgres ports: BASE_PORT+0, +1, ...)
#   ENROOT_IMAGE          default: toolathlon-pack                (sqsh name w/o .sqsh)
#   ENROOT_IMAGE_SRC      default: docker://ghcr.io/eigent-ai/toolathlon-pack:latest
#   ENROOT_PG_IMAGE       default: postgres+15
#   ENROOT_PG_IMAGE_SRC   default: docker://postgres:15
#   ENROOT_IMAGE_DIR      default: $PROJECT_ROOT/.enroot-images    (where .sqsh live)
#   ENROOT_DATA_DIR       default: /tmp/enroot-data-$USER          (per-task scratch)
#
# Example:
#   MODEL=gpt-4o PROVIDER=openai MODEL_API_KEY=sk-... \
#     bash run_parallel_enroot.sh 5

set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ENV_FILE="${ENV_FILE:-$PROJECT_ROOT/.env}"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

# ─── Arguments ────────────────────────────────────────────────────────────────
MAX_CONCURRENT="${1:?Usage: $0 <max_concurrent> [task1] [task2] ...}"
shift

if [ $# -gt 0 ]; then
    TASKS=("$@")
else
    TASKS=()
    while IFS= read -r t; do TASKS+=("$t"); done < <(ls "$PROJECT_ROOT/tasks/finalpool/")
fi

# ─── Config ───────────────────────────────────────────────────────────────────
MODEL="${MODEL:?MODEL must be set via environment or .env}"
PROVIDER="${PROVIDER:?PROVIDER must be set via environment or .env}"
MAX_STEPS="${MAX_STEPS:-100}"
MODEL_PROVIDER="${MODEL_PROVIDER:-$PROVIDER}"
MODEL_PLATFORM="${MODEL_PLATFORM:-$PROVIDER}"
MODEL_API_KEY="${MODEL_API_KEY:?MODEL_API_KEY must be set via environment or .env}"
MODEL_API_URL="${MODEL_API_URL:-}"
BASE_PORT="${BASE_PORT:-15432}"

ENROOT_IMAGE="${ENROOT_IMAGE:-toolathlon-pack}"
ENROOT_IMAGE_SRC="${ENROOT_IMAGE_SRC:-docker://ghcr.io/eigent-ai/toolathlon-pack:latest}"
ENROOT_PG_IMAGE="${ENROOT_PG_IMAGE:-postgres+15}"
ENROOT_PG_IMAGE_SRC="${ENROOT_PG_IMAGE_SRC:-docker://postgres:15}"
ENROOT_IMAGE_DIR="${ENROOT_IMAGE_DIR:-$PROJECT_ROOT/.enroot-images}"
ENROOT_DATA_DIR="${ENROOT_DATA_DIR:-/tmp/enroot-data-$USER}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="$PROJECT_ROOT/benchmark_logs/enroot_${TIMESTAMP}"
ENROOT="$(command -v enroot || echo /usr/bin/enroot)"

if [[ "$PROVIDER" != "openai" && "$PROVIDER" != "openrouter" ]]; then
    echo "[error] PROVIDER must be 'openai' or 'openrouter' (got: $PROVIDER)" >&2
    exit 1
fi

mkdir -p "$LOG_DIR" "$ENROOT_IMAGE_DIR" "$ENROOT_DATA_DIR"

echo "============================================="
echo "Enroot Fully Parallel Benchmark"
echo "  Max concurrent:   $MAX_CONCURRENT"
echo "  Total tasks:      ${#TASKS[@]}"
echo "  Model:            $PROVIDER/$MODEL"
echo "  Platform:         $MODEL_PLATFORM"
echo "  Provider key:     $MODEL_PROVIDER"
echo "  Max steps:        $MAX_STEPS"
echo "  Enroot image:     $ENROOT_IMAGE (src: $ENROOT_IMAGE_SRC)"
echo "  Enroot PG image:  $ENROOT_PG_IMAGE (src: $ENROOT_PG_IMAGE_SRC)"
echo "  Image dir:        $ENROOT_IMAGE_DIR"
echo "  PG base port:     $BASE_PORT"
echo "  Env file:         $ENV_FILE"
echo "  Log dir:          $LOG_DIR"
echo "============================================="

# ─── Ensure sqsh images exist ────────────────────────────────────────────────
ensure_sqsh() {
    local name="$1" src="$2"
    local sqsh="$ENROOT_IMAGE_DIR/${name}.sqsh"
    if [[ -f "$sqsh" ]]; then
        echo "[info] Found $sqsh"
    else
        echo "[info] Importing $src → $sqsh"
        (cd "$ENROOT_IMAGE_DIR" && "$ENROOT" import -o "${name}.sqsh" "$src")
    fi
}

ensure_sqsh "$ENROOT_IMAGE"    "$ENROOT_IMAGE_SRC"
ensure_sqsh "$ENROOT_PG_IMAGE" "$ENROOT_PG_IMAGE_SRC"

AGENT_SQSH="$ENROOT_IMAGE_DIR/${ENROOT_IMAGE}.sqsh"
PG_SQSH="$ENROOT_IMAGE_DIR/${ENROOT_PG_IMAGE}.sqsh"

# ─── Semaphore via a FIFO (slot index is passed via the token) ───────────────
FIFO="$LOG_DIR/.semaphore"
mkfifo "$FIFO"
exec 3<>"$FIFO"
rm -f "$FIFO"
for ((i = 0; i < MAX_CONCURRENT; i++)); do
    echo "$i" >&3
done

# ─── Summary file ────────────────────────────────────────────────────────────
SUMMARY="$LOG_DIR/summary.csv"
echo "task,status,eval_pass,duration_s" > "$SUMMARY"
SUMMARY_LOCK="$LOG_DIR/.summary.lock"

append_summary() {
    while ! mkdir "$SUMMARY_LOCK" 2>/dev/null; do sleep 0.1; done
    echo "$1" >> "$SUMMARY"
    rmdir "$SUMMARY_LOCK"
}

# ─── Track all enroot containers for cleanup ─────────────────────────────────
CONTAINER_LIST="$LOG_DIR/.containers"
touch "$CONTAINER_LIST"
CONTAINER_LIST_LOCK="$LOG_DIR/.containers.lock"

register_container() {
    while ! mkdir "$CONTAINER_LIST_LOCK" 2>/dev/null; do sleep 0.1; done
    echo "$1" >> "$CONTAINER_LIST"
    rmdir "$CONTAINER_LIST_LOCK"
}

cleanup_all() {
    echo ""
    echo "Cleaning up all enroot containers..."
    if [ -f "$CONTAINER_LIST" ]; then
        while IFS= read -r c; do
            "$ENROOT" remove -f "$c" >/dev/null 2>&1 || true
        done < "$CONTAINER_LIST"
    fi
    # Close semaphore
    exec 3>&- 2>/dev/null || true
    echo "Cleanup done."
}
trap cleanup_all EXIT

# ─── Export for subshells ────────────────────────────────────────────────────
export PROJECT_ROOT MODEL PROVIDER MAX_STEPS LOG_DIR SUMMARY SUMMARY_LOCK
export CONTAINER_LIST CONTAINER_LIST_LOCK
export MODEL_API_KEY MODEL_PLATFORM MODEL_API_URL MODEL_PROVIDER ENV_FILE
export ENROOT AGENT_SQSH PG_SQSH ENROOT_DATA_DIR BASE_PORT
export -f append_summary register_container

# ─── Run a single task with per-task port + per-task scratch ─────────────────
run_one_task() {
    local TASK="$1"
    local SLOT="$2"
    local PORT=$(( BASE_PORT + SLOT ))
    # Short id for container names (avoid collision across Slurm jobs)
    local TASK_HASH
    TASK_HASH=$(printf '%s' "$TASK" | md5sum | cut -c1-8)
    local TASK_ID="$$-${TASK_HASH}"
    local PG_CTR="pg-${TASK_ID}"
    local AGENT_CTR="agent-${TASK_ID}"
    local TASK_LOG="$LOG_DIR/${TASK}.log"
    local PG_DATA="$ENROOT_DATA_DIR/${TASK_ID}/pgdata"
    local PG_RUN="$ENROOT_DATA_DIR/${TASK_ID}/pgrun"
    mkdir -p "$PG_DATA" "$PG_RUN"

    local START_TS
    START_TS=$(date +%s)
    echo "[$(date +%H:%M:%S)] START  $TASK  (slot=$SLOT port=$PORT)"

    register_container "$PG_CTR"
    register_container "$AGENT_CTR"

    # --- Create + start PostgreSQL ---
    # Mount the init.sql.gz so the official postgres entrypoint auto-initializes
    # the database on first start. Postgres listens on $PORT on the host net ns.
    "$ENROOT" create --name "$PG_CTR" "$PG_SQSH" >> "$TASK_LOG" 2>&1 || true

    # Run postgres in background. `enroot start` is foreground, so we use &.
    (
        "$ENROOT" start \
            --root \
            --rw \
            -e POSTGRES_DB=toolathlon_gym \
            -e POSTGRES_USER=eigent \
            -e POSTGRES_PASSWORD=camel \
            -e PGPORT="$PORT" \
            -m "$PG_DATA:/var/lib/postgresql/data" \
            -m "$PG_RUN:/var/run/postgresql" \
            -m "$PROJECT_ROOT/db/init.sql.gz:/docker-entrypoint-initdb.d/init.sql.gz:ro" \
            "$PG_CTR" \
            docker-entrypoint.sh postgres -p "$PORT"
    ) >> "$TASK_LOG" 2>&1 &
    local PG_BG_PID=$!

    # --- Wait for PG to be ready (check from within the PG container itself,
    #     so we don't depend on host pg client tools) ---
    local RETRIES=60 READY=false
    while [ $RETRIES -gt 0 ]; do
        if "$ENROOT" start --root \
                "$PG_CTR" \
                pg_isready -h 127.0.0.1 -p "$PORT" -U eigent -d toolathlon_gym \
                >/dev/null 2>&1; then
            READY=true
            break
        fi
        sleep 2
        RETRIES=$((RETRIES - 1))
    done

    if [ "$READY" != "true" ]; then
        echo "[$(date +%H:%M:%S)] FAIL   $TASK (postgres not ready on :$PORT)" | tee -a "$TASK_LOG"
        local END_TS
        END_TS=$(date +%s)
        append_summary "${TASK},pg_fail,null,$((END_TS - START_TS))"
        kill "$PG_BG_PID" 2>/dev/null || true
        "$ENROOT" remove -f "$PG_CTR"    >> "$TASK_LOG" 2>&1 || true
        "$ENROOT" remove -f "$AGENT_CTR" >> "$TASK_LOG" 2>&1 || true
        rm -rf "$ENROOT_DATA_DIR/${TASK_ID}"
        return 1
    fi

    # --- Fix sent_log foreign key (parity with run_parallel.sh).
    #     Run psql from inside the PG container to avoid needing host client tools. ---
    "$ENROOT" start --root \
        -e PGPASSWORD=camel \
        "$PG_CTR" \
        psql -h 127.0.0.1 -p "$PORT" -U eigent -d toolathlon_gym \
            -c "ALTER TABLE email.sent_log DROP CONSTRAINT IF EXISTS sent_log_message_id_fkey;
                ALTER TABLE email.sent_log ADD CONSTRAINT sent_log_message_id_fkey
                  FOREIGN KEY (message_id) REFERENCES email.messages(id) ON DELETE CASCADE;" \
        >> "$TASK_LOG" 2>&1 || true

    # --- Create + start agent container ---
    "$ENROOT" create --name "$AGENT_CTR" "$AGENT_SQSH" >> "$TASK_LOG" 2>&1 || true

    local ENV_ARGS=()
    [ -n "$MODEL_API_KEY" ]   && ENV_ARGS+=("-e" "MODEL_API_KEY=$MODEL_API_KEY")
    [ -n "$MODEL_PLATFORM" ]  && ENV_ARGS+=("-e" "MODEL_PLATFORM=$MODEL_PLATFORM")
    [ -n "$MODEL_API_URL" ]   && ENV_ARGS+=("-e" "MODEL_API_URL=$MODEL_API_URL")
    [ -n "$MODEL_PROVIDER" ]  && ENV_ARGS+=("-e" "MODEL_PROVIDER=$MODEL_PROVIDER")

    "$ENROOT" start \
        --rw \
        -e PGHOST=127.0.0.1 \
        -e PG_HOST=127.0.0.1 \
        -e PGPORT="$PORT" \
        -e PGUSER=eigent \
        -e PGPASSWORD=camel \
        -e PGDATABASE=toolathlon_gym \
        -e LOCAL_SERVERS_PATH=/opt/local_servers \
        -e PYTHON_BIN=/opt/venv/bin/python3 \
        "${ENV_ARGS[@]}" \
        -m "$PROJECT_ROOT:/workspace" \
        "$AGENT_CTR" \
        /opt/venv/bin/python3 -u /workspace/main.py \
            --provider   "$PROVIDER" \
            --model_name "$MODEL" \
            --task_dir   "$TASK" \
            --max_steps  "$MAX_STEPS" \
        >> "$TASK_LOG" 2>&1 || true

    local END_TS
    END_TS=$(date +%s)
    local DURATION=$((END_TS - START_TS))

    # --- Parse results ---
    local STATUS="unknown" EVAL_PASS="null"
    if   grep -q "Status: success" "$TASK_LOG" 2>/dev/null; then STATUS="success"
    elif grep -q "Status: failed"  "$TASK_LOG" 2>/dev/null; then STATUS="failed"
    fi
    if [ "$STATUS" = "success" ]; then
        if   grep -q "Pass:.*True"  "$TASK_LOG" 2>/dev/null; then EVAL_PASS="True"
        elif grep -q "Pass:.*False" "$TASK_LOG" 2>/dev/null; then EVAL_PASS="False"
        fi
    fi

    append_summary "${TASK},${STATUS},${EVAL_PASS},${DURATION}"

    local RESULT="AGENT_FAIL"
    if   [ "$EVAL_PASS" = "True" ];    then RESULT="PASS"
    elif [ "$STATUS"   = "success" ];  then RESULT="EVAL_FAIL"
    fi
    echo "[$(date +%H:%M:%S)] DONE   $TASK -> $RESULT (${DURATION}s)"

    # --- Stop PG + cleanup ---
    kill "$PG_BG_PID" 2>/dev/null || true
    # Give PG a moment to shut down cleanly
    sleep 1
    "$ENROOT" remove -f "$AGENT_CTR" >> "$TASK_LOG" 2>&1 || true
    "$ENROOT" remove -f "$PG_CTR"    >> "$TASK_LOG" 2>&1 || true
    rm -rf "$ENROOT_DATA_DIR/${TASK_ID}"
}

export -f run_one_task

# ─── Launch all tasks with semaphore-controlled concurrency ──────────────────
PIDS=()
for TASK in "${TASKS[@]}"; do
    read -r -u 3 SLOT
    (
        run_one_task "$TASK" "$SLOT"
        echo "$SLOT" >&3
    ) &
    PIDS+=($!)
done

echo ""
echo "All ${#TASKS[@]} tasks launched (max $MAX_CONCURRENT concurrent). Waiting..."
echo ""

FAILED=0
for pid in "${PIDS[@]}"; do
    wait "$pid" || FAILED=$((FAILED + 1))
done

# ─── Report ──────────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "RESULTS"
echo "============================================="

python3 - "$SUMMARY" << 'PYEOF'
import sys, csv
summary_file = sys.argv[1]
pass_count = eval_fail = agent_fail = other = 0
total_duration = 0
results = []
with open(summary_file) as f:
    for row in csv.DictReader(f):
        task = row["task"]
        status = row["status"]
        eval_pass = row["eval_pass"]
        duration = int(row["duration_s"])
        total_duration += duration
        if eval_pass == "True":       label = "PASS";       pass_count += 1
        elif status == "success":     label = "EVAL_FAIL";  eval_fail += 1
        elif status == "pg_fail":     label = "PG_FAIL";    other += 1
        else:                         label = "AGENT_FAIL"; agent_fail += 1
        results.append((task, label, duration))
for task, label, dur in sorted(results):
    print(f"  {task:<55s} {label:<12s} ({dur}s)")
total = pass_count + eval_fail + agent_fail + other
print()
if total > 0:
    print(f"  PASS:       {pass_count:4d}  ({100*pass_count/total:.1f}%)")
    print(f"  EVAL_FAIL:  {eval_fail:4d}  ({100*eval_fail/total:.1f}%)")
    print(f"  AGENT_FAIL: {agent_fail:4d}  ({100*agent_fail/total:.1f}%)")
    if other:
        print(f"  OTHER_FAIL: {other:4d}  ({100*other/total:.1f}%)")
    print(f"  TOTAL:      {total:4d}")
    print(f"  Wall time sum: {total_duration}s")
else:
    print("  No results.")
PYEOF

echo ""
echo "Summary CSV: $SUMMARY"
echo "Task logs:   $LOG_DIR/<task>.log"

python3 "$PROJECT_ROOT/scripts/export_benchmark_results.py" \
    --summary "$SUMMARY" \
    --log-dir "$LOG_DIR" \
    --provider "$PROVIDER" \
    --model-name "$MODEL" \
    --model-platform "$MODEL_PLATFORM" \
    --model-provider "$MODEL_PROVIDER" \
    --max-steps "$MAX_STEPS" \
    --max-concurrent "$MAX_CONCURRENT" \
    --image "$ENROOT_IMAGE" || true

echo "JSON output: output/raw/*.json"
echo "Summary JSON: output/summary/benchmark_summary.json"
echo "Manifest JSON: output/metadata/run_manifest.json"
echo "Done."
