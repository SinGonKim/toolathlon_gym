#!/bin/bash
#SBATCH --job-name=toolathlon-bench-enroot
#SBATCH --partition=cpu
#SBATCH --output=/t1data/users/singon_kim/run_script/logs/tool_benchmark-enroot-%j.out
#SBATCH --error=/t1data/users/singon_kim/run_script/logs/tool_benchmark-enroot-%j.err
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

# Where to cache .sqsh images. Default to repo-local; override to shared storage
# (e.g. /t1data/...) if multiple jobs should share imported images.
export ENROOT_IMAGE_DIR="${ENROOT_IMAGE_DIR:-$REPO_ROOT/.enroot-images}"
# Per-task scratch (PG data, run dirs). Put on fast local disk if available.
export ENROOT_DATA_DIR="${ENROOT_DATA_DIR:-/tmp/enroot-data-$USER-$SLURM_JOB_ID}"

echo "Using repo root:       $REPO_ROOT"
echo "Using env file:        $ENV_FILE"
echo "Image cache dir:       $ENROOT_IMAGE_DIR"
echo "Per-task data dir:     $ENROOT_DATA_DIR"
echo "Max concurrent:        $MAX_CONCURRENT"
echo "Enroot:                $(enroot version || true)"

mkdir -p "$ENROOT_IMAGE_DIR" "$ENROOT_DATA_DIR"

if [[ $# -gt 0 ]]; then
    bash run_parallel_enroot.sh "$MAX_CONCURRENT" "$@"
else
    bash run_parallel_enroot.sh "$MAX_CONCURRENT"
fi
