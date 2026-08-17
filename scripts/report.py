#!/usr/bin/env python3
"""组装测试报告。

用法: report.py <run_id> <env> <image> <duration_s>

读取 artifacts/reports/<run_id>/case-results.jsonl，按 tests/schema/report.schema.json
组装 report.json，渲染 report.html（失败用例并排播放本次录屏 vs 基准录屏），
并把录屏归档到 artifacts/recordings/<env>/。全部产物留在 artifacts/（不进 git）。
"""
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "artifacts"
SCHEMA_VERSION = "1"


def git_info():
    def run(*args):
        try:
            return subprocess.run(
                ["git", *args], cwd=ROOT, capture_output=True, text=True, check=True
            ).stdout.strip()
        except subprocess.CalledProcessError:
            return ""

    commit = run("rev-parse", "HEAD")[:12]
    branch = run("rev-parse", "--abbrev-ref", "HEAD") or "unknown"
    dirty = bool(run("status", "--porcelain"))
    return {"commit": commit, "branch": branch, "dirty": dirty}


def load_cases(run_dir: Path):
    results_file = run_dir / "case-results.jsonl"
    cases = []
    if results_file.exists():
        for line in results_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line:
                cases.append(json.loads(line))
    return cases


def main():
    run_id, env, image, duration_s = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    run_dir = ARTIFACTS / "reports" / run_id
    rec_dir = ARTIFACTS / "recordings" / env
    ref_dir = ARTIFACTS / "reference" / env
    rec_dir.mkdir(parents=True, exist_ok=True)

    env_info = ""
    info_file = run_dir / "env-info.txt"
    if info_file.exists():
        env_info = info_file.read_text(encoding="utf-8").strip().splitlines()[0] if \
            info_file.read_text(encoding="utf-8").strip() else ""

    cases = load_cases(run_dir)
    for c in cases:
        # 归档录屏：报告目录 → recordings/<env>/<case>.mp4
        src = run_dir / c["recording"]
        if src.exists():
            dst = rec_dir / f"{c['id']}.mp4"
            dst.write_bytes(src.read_bytes())
            src.unlink()
            c["recording"] = f"recordings/{env}/{c['id']}.mp4"
        else:
            c["recording"] = ""
        baseline = ref_dir / f"{c['id']}.mp4"
        c["baseline"] = f"reference/{env}/{c['id']}.mp4" if baseline.exists() else ""

    passed = sum(1 for c in cases if c["status"] == "pass")
    perf = None
    perf_file = run_dir / "perf-summary.json"
    if perf_file.exists():
        try:
            perf = json.loads(perf_file.read_text(encoding="utf-8"))
            lat = [c["latency_ms"] for c in cases if c.get("latency_ms") is not None]
            if lat:
                perf["latency_ms"] = {
                    "trigger_avg": round(sum(lat) / len(lat), 1),
                    "trigger_max": max(lat),
                }
        except json.JSONDecodeError:
            pass
    report = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "git": git_info(),
        "env": {"image": image, "compositor": env, "fcitx5": env_info},
        "build": {"addon": "ok", "flutter": "skip"},
        "summary": {
            "total": len(cases),
            "passed": passed,
            "failed": len(cases) - passed,
            "duration_s": duration_s,
        },
        "perf": perf,
        "cases": cases,
    }

    (run_dir / "report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    (run_dir / "report.html").write_text(render_html(report), encoding="utf-8")
    print(f"report: {run_dir}/report.json  ({passed}/{len(cases)} passed)")


def vid(path: str) -> str:
    return (ARTIFACTS / path).as_uri() if path else ""


def render_html(r: dict) -> str:
    s = r["summary"]
    rows = []
    for c in r["cases"]:
        color = "#2e7d32" if c["status"] == "pass" else "#c62828"
        rec = vid(c.get("recording", ""))
        base = vid(c.get("baseline", ""))
        video_block = ""
        if rec:
            video_block = f"<video controls width='360' src='{rec}'></video>"
            if c["status"] == "fail" and base:
                video_block = (
                    f"<div><b>本次录屏</b><br>{video_block}"
                    f"<b>基准录屏（bug 对照）</b><br>"
                    f"<video controls width='360' src='{base}'></video></div>"
                )
        rows.append(f"""
        <div class='case'>
          <h3>{c['id']} <span style='color:{color}'>[{c['status']}]</span></h3>
          <table>
            <tr><th>期望</th><td>{c['expected']}</td></tr>
            <tr><th>实际</th><td>{c['actual']}</td></tr>
            <tr><th>延迟</th><td>{c.get('latency_ms', '?')} ms</td></tr>
            <tr><th>差异说明</th><td>{c.get('diff_note', '')}</td></tr>
          </table>
          {video_block}
        </div>""")

    return f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<title>voiceinput 测试报告 {r['run_id']}</title>
<style>
 body {{ font-family: sans-serif; margin: 2em; background: #fafafa; }}
 h1 {{ font-size: 1.4em; }}
 .meta {{ color: #555; margin-bottom: 1em; }}
 .case {{ background: #fff; border: 1px solid #ddd; border-radius: 8px;
         padding: 1em; margin: 1em 0; }}
 table {{ border-collapse: collapse; }}
 th, td {{ text-align: left; padding: 4px 10px; border-bottom: 1px solid #eee; }}
</style></head><body>
<h1>fcitx5-voice-input 测试报告</h1>
<div class='meta'>
  <b>run_id</b> {r['run_id']} ｜ <b>环境</b> {r['env']['compositor']}（{r['env']['image']}）
   ｜ <b>fcitx5</b> {r['env'].get('fcitx5', '')}<br>
  <b>commit</b> {r['git']['commit']}（{r['git']['branch']}{'，有未提交改动' if r['git']['dirty'] else ''}）
   ｜ <b>时间</b> {r['created_at']} ｜ <b>总耗时</b> {r['summary']['duration_s']}s
</div>
<h2 style='color:{"#2e7d32" if s["failed"] == 0 else "#c62828"}'>
  通过 {s['passed']} / {s['total']}，失败 {s['failed']}</h2>
{''.join(rows)}
<p style='color:#888'>报告与录屏位于 artifacts/，不入 git。</p>
</body></html>"""


if __name__ == "__main__":
    main()
