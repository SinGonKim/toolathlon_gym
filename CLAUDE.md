# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Toolathlon-GYM is a self-contained evaluation environment for LLM tool-use agents. It ships 503 multi-tool tasks backed by a local PostgreSQL database and 25 MCP servers — no external data-service APIs are needed at run time. It extends the infrastructure of HKUST-NLP's [Toolathlon](https://github.com/hkust-nlp/Toolathlon); the task format, evaluator, MCP interfaces, and schema design originate there.

## Common commands

### Build & infrastructure

```bash
docker build -t toolathlon-pack:latest .     # build the agent image (required once)
docker compose up -d postgres                # start toolathlon_pg + toolathlon_net
bash scripts/test_containerized.sh           # smoke-test infra (network, PG, image, lock)
```

### Run a single task (sequential, shares one postgres)

```bash
MODEL_PROVIDER=openai MODEL_NAME=gpt-4o MODEL_API_KEY=sk-... \
  bash scripts/run_containerized.sh <task_name> [max_steps]
```

Output: `dumps/<task>/<timestamp>/...` — `traj.json`, `camel_logs/`, `run.log`, `eval_res.json`. The script acquires `dumps/.run.lock` via `flock` — only one task runs at a time (shared-PG constraint).

### Run benchmarks in parallel (isolated PG+agent per task)

```bash
cp .env.example .env                         # fill MODEL / PROVIDER / MODEL_API_KEY
bash run_parallel.sh 5                       # all 503 tasks, 5 concurrent
bash run_parallel.sh 5 task-a task-b task-c  # specific tasks
sbatch scripts/run_parallel.slurm 5          # same, via Slurm
```

`run_parallel.sh` is restricted to `PROVIDER=openai` or `PROVIDER=openrouter`. Each task spins up its own `pg-<id>` + `agent-<id>` + `net-<id>` — no shared state. Results: `benchmark_logs/fully_parallel_<timestamp>/summary.csv` plus `output/{raw,summary,metadata}/*.json` (exported by `scripts/export_benchmark_results.py`).

### Enroot path (Slurm clusters without Docker daemon access)

For HPC/Slurm environments where Docker is unavailable but Enroot + Pyxis are installed:

```bash
# One-time: have GitHub Actions (.github/workflows/build-image.yml) publish
#   ghcr.io/<owner>/toolathlon-pack:latest
# Then on the cluster:
cp .env.example .env                          # fill model creds
sbatch scripts/run_parallel_enroot.slurm 5    # or: bash run_parallel_enroot.sh 5
```

Key differences from the Docker path:
- **No network isolation.** Enroot shares the host network namespace, so `run_parallel_enroot.sh` assigns each concurrent slot a unique Postgres port (`BASE_PORT + slot_idx`, default `BASE_PORT=15432`) and the agent connects to `localhost:<port>`.
- **Image delivery.** `.sqsh` images are pulled once from GHCR into `ENROOT_IMAGE_DIR` (default `.enroot-images/`) and reused across tasks. Two sqsh files: `toolathlon-pack.sqsh` (agent) and `postgres+15.sqsh` (PG).
- **Per-task scratch.** `ENROOT_DATA_DIR` (default `/tmp/enroot-data-$USER`) holds each task's `pgdata/` + `pgrun/` and is wiped at task end.
- **CI workflow.** `.github/workflows/build-image.yml` builds on push to `main` (or via `workflow_dispatch`) and pushes to `ghcr.io/${owner}/toolathlon-pack:latest` — fork the repo or have write access to the upstream for this to produce an image under your namespace.

### Running `main.py` directly (inside an interactive container)

```bash
docker compose up -d                         # brings up the dev shell (toolathlon_agent)
docker exec -it toolathlon_agent bash
/opt/venv/bin/python3 main.py --task_dir <task> --max_steps 100 --debug
```

There is no test suite, linter, or formatter configured. `test_containerized.sh` is infra smoke-testing only.

## High-level architecture

### Two-container model (critical to understand)

1. **`toolathlon_pg`** — `postgres:15` initialized once from `db/init.sql.gz` (8.2 MB compressed). Holds the mock data for all MCP domains (canvas, snowflake, woocommerce, yahoo_finance, youtube, train, plus email/calendar/etc.). Credentials: `eigent / camel @ toolathlon_gym`.
2. **Agent container** — `toolathlon-pack:latest`, built from `Dockerfile`. Contains Python venv at `/opt/venv`, Node 22, MCP servers pre-built under `/opt/local_servers/` (kept **outside** `/workspace` so the bind mount does not shadow compiled artifacts), Playwright chromium, and the project source.

The two containers talk over the user-defined bridge network `toolathlon_net` (created by `docker compose`). `run_parallel.sh` bypasses this shared network and creates per-task networks for full isolation.

### Entry point flow

`main.py` → `TaskRunner.run_single_task` (`utils/task_runner/runner.py`) → `TaskAgent` (`utils/roles/task_agent.py`, CAMEL `ChatAgent`-based) → MCP clients spun up via `utils/mcp/tool_servers.build_mcp_clients` reading `configs/mcp_servers/*.yaml` and the per-task `task_config.json`.

Model selection goes through `utils/api_model/model_provider.build_model`, which maps a `provider` string to a CAMEL `ModelPlatformType`. Env vars `MODEL_PLATFORM`, `MODEL_API_KEY`, `MODEL_API_URL` override the provider map; `MODEL_PROVIDER` / `MODEL_NAME` override `eval_config.json` values.

### Task anatomy (`tasks/finalpool/<task_name>/`)

```
task_config.json         # needed_mcp_servers, needed_local_tools, meta
docs/task.md             # task brief shown to the agent (service names are obfuscated)
docs/agent_system_prompt.md
evaluation/main.py       # deterministic grader, writes eval_res.json
preprocess/main.py       # DB/workspace setup, run automatically before each task
initial_workspace/       # input files copied into the agent workspace
groundtruth_workspace/   # reference outputs used by evaluation/main.py
```

`TaskConfig.build` (in `utils/data_structures/task_config.py`) wires these paths together, applies template substitutions in the system prompt (e.g. `!!<<<<||||workspace_dir||||>>>>!!`), and resolves `task_root` under `dumps/<provider>_<model>/<timestamp>/<task>/` so repeated runs don't collide.

### MCP server layer

Each MCP server has a YAML manifest in `configs/mcp_servers/` (command to launch, env vars, connection type) and a source tree in `local_servers/`. Node-based servers are `npm install && npm run build`-ed at image build time; Python servers are `uv sync`-ed. Only the servers listed in a task's `needed_mcp_servers` get booted for that task. Local "tools" (e.g. `claim_done`, `python_execute`, `handle_overlong_tool_outputs`) are implemented in `utils/aux_tools/` and injected as `FunctionTool`s alongside the MCP tools.

### Obfuscated task prompts

Tasks refer to tools by generic names ("knowledge base", "shared calendar", "learning management system") instead of brand names (Notion, Google Calendar, Canvas). Preserve this convention when editing `docs/task.md` — it's a deliberate anti-shortcut measure inherited from Toolathlon.

### The `sent_log` FK workaround

Both `scripts/run_containerized.sh` and `run_parallel.sh` run the same inline SQL after PG is healthy: drop and re-add `email.sent_log.sent_log_message_id_fkey` with `ON DELETE CASCADE`. This compensates for a missing cascade in `db/init.sql.gz` — don't remove it without updating the dump.

### Output artifacts

- `dumps/<task>/<ts>/<provider>_<model>/traj.json` — full agent trajectory
- `dumps/<task>/<ts>/<provider>_<model>/camel_logs/` — per-turn raw LLM request/response (enabled by `CAMEL_MODEL_LOG_ENABLED=true` in `main.py`)
- `dumps/<task>/<ts>/eval_res.json` — `{pass: bool, details: ...}`
- `benchmark_logs/fully_parallel_<ts>/summary.csv` — parallel run summary
- `output/raw/<task>.json`, `output/summary/benchmark_summary.json`, `output/metadata/run_manifest.json` — JSON exports (manifest scrubs API keys)

## Conventions and gotchas

- Python is pinned to `==3.12.11` (`pyproject.toml`); dependencies are locked via `uv.lock`.
- Inside the agent image, always invoke Python via `/opt/venv/bin/python3` (set as `PYTHON_BIN`). `TaskConfig` uses this to construct `preprocess` / `evaluation` commands.
- `run_parallel.sh` rejects providers other than `openai` / `openrouter`; `run_containerized.sh` additionally supports `aihubmix`, `anthropic`, `openai_compatible`, etc. via `MODEL_PROVIDER`.
- When adding a task, match the existing directory layout exactly — `TaskConfig.build` and the runners assume all five subpaths (`task_config.json`, `docs/`, `evaluation/`, `preprocess/`, `initial_workspace/`, `groundtruth_workspace/`) exist.
- CN-mode variants (`*_cn.md`, `initial_workspace_cn/`, `groundtruth_workspace_cn/`) are picked up automatically when `--cn_mode` is passed.
