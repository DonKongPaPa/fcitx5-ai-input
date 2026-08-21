#!/usr/bin/env python3
"""方案对比页：汇总本地历史报告，评估各环境/方案的资源占用与延迟差异。

用法: compare.py  →  artifacts/compare.html（不进 git）
关注维度：fcitx5 CPU/内存、宿主合成器与被测合成器开销、录屏器开销、触发延迟。
"""
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REPORTS = ROOT / "artifacts" / "reports"
OUT = ROOT / "artifacts" / "compare.html"


def load_all():
    items = []
    if not REPORTS.exists():
        return items
    for d in sorted(REPORTS.iterdir()):
        f = d / "report.json"
        if f.exists():
            try:
                items.append(json.loads(f.read_text(encoding="utf-8")))
            except json.JSONDecodeError:
                continue
    return items


def main():
    reports = load_all()
    rows = []
    for r in reports:
        perf = r.get("perf") or {}
        procs = perf.get("processes", {})

        def p(name, key, default="–"):
            v = procs.get(name, {}).get(key)
            return v if v is not None else default

        lat = perf.get("latency_ms", {})
        rows.append({
            "run_id": r["run_id"],
            "env": r["env"]["compositor"],
            "commit": r["git"]["commit"][:8],
            "result": f"{r['summary']['passed']}/{r['summary']['total']}",
            "sys_cpu": (perf.get("system") or {}).get("cpu_avg_pct", "–"),
            "fcitx5_cpu": p("fcitx5", "cpu_avg_pct"),
            "fcitx5_mem": p("fcitx5", "rss_peak_mb"),
            "testcomp_cpu": (p("niri", "cpu_avg_pct") if "niri" in procs else
                             p("kwin_wayland", "cpu_avg_pct") if "kwin_wayland" in procs else
                             p("gnome-shell", "cpu_avg_pct") if "gnome-shell" in procs else
                             p("mutter", "cpu_avg_pct")),
            "hostcomp_cpu": (p("sway", "cpu_avg_pct") if "sway" in procs
                             else p("cage", "cpu_avg_pct")),
            "recorder_cpu": p("wf-recorder", "cpu_avg_pct"),
            "lat_avg": lat.get("trigger_avg", "–"),
        })

    header = ["run_id", "环境", "commit", "通过", "系统CPU%",
              "fcitx5 CPU%", "fcitx5 MB", "被测合成器 CPU%", "宿主合成器 CPU%",
              "录屏器 CPU%", "触发延迟ms"]
    trs = []
    for x in rows:
        p_count, t_count = x["result"].split("/")
        cls = "ok" if p_count == t_count else "bad"
        vals = [x["run_id"], x["env"], x["commit"], x["result"], x["sys_cpu"],
                x["fcitx5_cpu"], x["fcitx5_mem"], x["testcomp_cpu"],
                x["hostcomp_cpu"], x["recorder_cpu"], x["lat_avg"]]
        tds = "".join(
            f"<td>{html.escape(str(v))}</td>" for v in vals)
        trs.append(f"<tr class='{cls}'>{tds}</tr>")

    OUT.write_text(f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>aiinput 方案对比</title>
<style>
 body {{ font-family: sans-serif; margin: 2em; }}
 table {{ border-collapse: collapse; }}
 th, td {{ padding: 6px 12px; border: 1px solid #ccc; text-align: right; }}
 th:first-child, td:first-child, th:nth-child(2) {{ text-align: left; }}
 tr.ok td:nth-child(4) {{ color: #2e7d32; }}
 tr.bad td:nth-child(4) {{ color: #c62828; font-weight: bold; }}
</style></head><body>
<h1>fcitx5-ai-input 方案对比</h1>
<p>历史运行汇总（用于评估各环境/录屏方案的资源干扰与延迟）。数值为容器内采样均值。</p>
<table>
<tr>{''.join(f'<th>{h}</th>' for h in header)}</tr>
{''.join(trs)}
</table>
<p style='color:#888'>数据来自 artifacts/reports/，不入 git。</p>
</body></html>""", encoding="utf-8")
    print(f"compare: {OUT}（{len(rows)} 次运行）")


if __name__ == "__main__":
    main()
