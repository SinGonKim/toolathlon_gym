#!/usr/bin/env python3
"""Export benchmark results to stable JSON files under output/."""

from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
from pathlib import Path
from typing import Any


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export Toolathlon benchmark results into output/ JSON files."
    )
    parser.add_argument("--summary", required=True, help="Path to benchmark summary.csv")
    parser.add_argument("--log-dir", required=True, help="Path to benchmark log directory")
    parser.add_argument("--provider", required=True, help="Provider key used by run_parallel.sh")
    parser.add_argument("--model-name", required=True, help="Model name used by run_parallel.sh")
    parser.add_argument("--model-platform", default="", help="Resolved MODEL_PLATFORM value")
    parser.add_argument("--model-provider", default="", help="Resolved MODEL_PROVIDER value")
    parser.add_argument("--max-steps", type=int, required=True, help="Configured max steps")
    parser.add_argument(
        "--max-concurrent", type=int, required=True, help="Configured benchmark concurrency"
    )
    parser.add_argument("--image", required=True, help="Docker image used for the run")
    parser.add_argument(
        "--dumps-root",
        default="dumps",
        help="Root directory containing task eval_res.json files",
    )
    parser.add_argument(
        "--output-dir",
        default="output",
        help="Root directory where JSON exports will be written",
    )
    return parser.parse_args()


def parse_eval_pass(raw: str) -> bool | None:
    if raw == "True":
        return True
    if raw == "False":
        return False
    return None


def relative_str(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root))
    except ValueError:
        return str(path)


def clear_json_files(directory: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    for child in directory.glob("*.json"):
        child.unlink()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    summary_path = (repo_root / args.summary).resolve()
    log_dir = (repo_root / args.log_dir).resolve()
    dumps_root = (repo_root / args.dumps_root).resolve()
    output_dir = (repo_root / args.output_dir).resolve()

    if not summary_path.exists():
        raise FileNotFoundError(f"Summary CSV not found: {summary_path}")
    if not log_dir.exists():
        raise FileNotFoundError(f"Benchmark log directory not found: {log_dir}")

    raw_dir = output_dir / "raw"
    summary_dir = output_dir / "summary"
    metadata_dir = output_dir / "metadata"
    clear_json_files(raw_dir)
    summary_dir.mkdir(parents=True, exist_ok=True)
    metadata_dir.mkdir(parents=True, exist_ok=True)

    model_dump_dir = dumps_root / f"{args.provider}_{args.model_name}".replace("/", "_")
    benchmark_timestamp = log_dir.name.removeprefix("fully_parallel_")
    api_key_configured = bool(os.environ.get("MODEL_API_KEY"))

    tasks: list[dict[str, Any]] = []
    pass_count = 0
    eval_fail_count = 0
    agent_fail_count = 0
    other_fail_count = 0
    raw_exported_count = 0

    with summary_path.open(newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            task = row["task"]
            status = row["status"]
            eval_pass = parse_eval_pass(row["eval_pass"])
            duration_s = int(row["duration_s"])

            eval_res_source = model_dump_dir / f"SingleUserTurn-{task}" / "eval_res.json"
            log_path = log_dir / f"{task}.log"
            exported_raw_path = None
            raw_payload = None

            if eval_res_source.exists():
                exported_raw = raw_dir / f"{task}.json"
                shutil.copyfile(eval_res_source, exported_raw)
                exported_raw_path = relative_str(exported_raw, repo_root)
                raw_exported_count += 1
                with exported_raw.open(encoding="utf-8") as raw_handle:
                    raw_payload = json.load(raw_handle)

            if eval_pass is True:
                result_label = "PASS"
                pass_count += 1
            elif status == "success":
                result_label = "EVAL_FAIL"
                eval_fail_count += 1
            elif status == "pg_fail":
                result_label = "PG_FAIL"
                other_fail_count += 1
            else:
                result_label = "AGENT_FAIL"
                agent_fail_count += 1

            tasks.append(
                {
                    "task": task,
                    "status": status,
                    "eval_pass": eval_pass,
                    "result_label": result_label,
                    "duration_s": duration_s,
                    "eval_res_path": relative_str(eval_res_source, repo_root)
                    if eval_res_source.exists()
                    else None,
                    "exported_raw_path": exported_raw_path,
                    "task_log_path": relative_str(log_path, repo_root) if log_path.exists() else None,
                    "eval_details": raw_payload.get("details") if isinstance(raw_payload, dict) else None,
                    "eval_failure": raw_payload.get("failure") if isinstance(raw_payload, dict) else None,
                }
            )

    summary_payload = {
        "benchmark_timestamp": benchmark_timestamp,
        "model_platform": args.model_platform or args.provider,
        "model_provider": args.model_provider or args.provider,
        "provider": args.provider,
        "model_name": args.model_name,
        "image": args.image,
        "max_steps": args.max_steps,
        "max_concurrent": args.max_concurrent,
        "total_tasks": len(tasks),
        "pass_count": pass_count,
        "eval_fail_count": eval_fail_count,
        "agent_fail_count": agent_fail_count,
        "other_fail_count": other_fail_count,
        "raw_exported_count": raw_exported_count,
        "raw_missing_count": len(tasks) - raw_exported_count,
        "source_summary_csv": relative_str(summary_path, repo_root),
        "source_log_dir": relative_str(log_dir, repo_root),
        "source_dumps_root": relative_str(model_dump_dir, repo_root),
        "tasks": tasks,
    }

    manifest_payload = {
        "benchmark_timestamp": benchmark_timestamp,
        "provider": args.provider,
        "model_name": args.model_name,
        "model_platform": args.model_platform or args.provider,
        "model_provider": args.model_provider or args.provider,
        "max_steps": args.max_steps,
        "max_concurrent": args.max_concurrent,
        "image": args.image,
        "summary_csv": relative_str(summary_path, repo_root),
        "log_dir": relative_str(log_dir, repo_root),
        "dumps_root": relative_str(model_dump_dir, repo_root),
        "output_dir": relative_str(output_dir, repo_root),
        "env": {
            "MODEL": args.model_name,
            "PROVIDER": args.provider,
            "MODEL_PROVIDER": args.model_provider or args.provider,
            "MODEL_PLATFORM": args.model_platform or args.provider,
            "MAX_STEPS": args.max_steps,
            "IMAGE": args.image,
            "MODEL_API_URL": os.environ.get("MODEL_API_URL") or None,
            "MODEL_API_KEY_CONFIGURED": api_key_configured,
        },
    }

    summary_path_out = summary_dir / "benchmark_summary.json"
    manifest_path_out = metadata_dir / "run_manifest.json"

    with summary_path_out.open("w", encoding="utf-8") as handle:
        json.dump(summary_payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    with manifest_path_out.open("w", encoding="utf-8") as handle:
        json.dump(manifest_payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    print(f"Exported {raw_exported_count} raw eval JSON files to {relative_str(raw_dir, repo_root)}")
    print(f"Wrote summary JSON to {relative_str(summary_path_out, repo_root)}")
    print(f"Wrote manifest JSON to {relative_str(manifest_path_out, repo_root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
