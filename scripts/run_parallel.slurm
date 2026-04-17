#!/bin/bash
#SBATCH --job-name=toolathlon-bench
#SBATCH --partition=cpu
#SBATCH --output=/t1data/users/singon_kim/run_script/logs/tool_benchmark-%j.out
#SBATCH --error=/t1data/users/singon_kim/run_script/logs/tool_benchmark-%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=24:00:00

set -euo pipefail

REPO_ROOT="${SLURM_SUBMIT_DIR:-$(pwd)}"
cd "$REPO_ROOT"

if [[ ! -f ".env" ]]; then
    echo "[error] .env not found in $REPO_ROOT"
    echo "Copy .env.example to .env and fill in MODEL / PROVIDER / MODEL_API_KEY first."
    exit 1
fi

MAX_CONCURRENT="${MAX_CONCURRENT:-${1:-5}}"
if [[ $# -gt 0 ]]; then
    shift
fi

export ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"

echo "Using repo root: $REPO_ROOT"
echo "Using env file:  $ENV_FILE"
echo "Max concurrent:  $MAX_CONCURRENT"

docker build -t toolathlon-pack:latest .

if [[ $# -gt 0 ]]; then
    bash run_parallel.sh "$MAX_CONCURRENT" "$@"
else
    bash run_parallel.sh "$MAX_CONCURRENT"
fi
