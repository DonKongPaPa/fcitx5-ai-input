#!/usr/bin/env python3
"""协议 v1 对拍器（proto-test 容器核心，纯标准库）。

三件事：
1. envelope 结构校验（镜像 envelope.schema.json 的关键约束；schema 文件
   是规范真源，本检查器保证容器零依赖可跑）
2. 事件参数校验（镜像 events.schema.json 的必填/类型/枚举）
3. 跨通道对拍不变量——回放脚本里 ui 事件必须与 asr/refine 事件语义
   一致（这也是 P3 hub 路由器的参考行为规约）：
   - hello 必须是首事件；seq 单调不减
   - asr/partial 之后必须有携带同文本的 voice/recording
   - asr/final → 后续 refine/request.raw 必须等于 final 文本
   - refine/result.candidates → 后续 voice/candidates.candidates 必须一致
   - voice/idle 终止会话；其后不得再出现 voice/*（除非新一轮 hello）
   - ui/in select 只能出现在 voice/candidates 或 panel/update 之后

用法：python3 proto_check.py [--out report.json] [events目录]
退出码：0=全过；1=有失败。
"""

import json
import sys
from pathlib import Path

CHANNELS = {"ui", "asr", "refine"}
DIRS = {"in", "out"}
UI_OUT_REQUIRED_ARGS = {
    "hello": ("proto",),
    "theme": ("font_size", "anim"),
    "voice/recording": ("partial", "elapsed_ms"),
    "voice/result": ("final", "timeout_ms"),
    "voice/candidates": ("final", "candidates", "hover"),
    "voice/idle": (),
    "panel/hide": (),
    "panel/caret": ("rect", "space"),
}
PANEL_UPDATE_REQUIRED = ("candidates", "layout")
ASR_IN_TEXT_REQUIRED = ("text",)
REFINE_IN_REQUIRED = ("candidates", "engine_tag")


class Fail:
    def __init__(self):
        self.errors = []
        self.checks = 0

    def ok(self, cond, msg):
        self.checks += 1
        if not cond:
            self.errors.append(msg)
        return bool(cond)


def type_of(v):
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "num"
    if isinstance(v, str):
        return "str"
    if isinstance(v, list):
        return "list"
    if isinstance(v, dict):
        return "obj"
    return "null"


def check_envelope(f, env):
    if not isinstance(env, dict):
        return f.ok(False, "行不是 JSON 对象")
    if "_comment" in env:
        return False  # 注释行，跳过后续检查
    f.ok("channel" in env and env.get("channel") in CHANNELS,
         f"channel 非法: {env.get('channel')}")
    has_delay = "_delay_ms" in env
    if "method" not in env and not has_delay:
        f.ok(False, "缺 method 且非控制行")
        return False
    if "method" in env:
        f.ok(isinstance(env["method"], str) and
             ("/" in env["method"] or env["method"].isalpha()),
             f"method 格式可疑: {env.get('method')}")
    if "dir" in env:
        f.ok(env["dir"] in DIRS, f"dir 非法: {env.get('dir')}")
    if "v" in env:
        f.ok(env["v"] == 1, f"协议版本必须为 1: {env.get('v')}")
    if "seq" in env:
        f.ok(type_of(env["seq"]) in ("int", "num") and env["seq"] >= 0,
             f"seq 非法: {env.get('seq')}")
    if has_delay:
        f.ok(type_of(env["_delay_ms"]) in ("int", "num")
             and env["_delay_ms"] >= 0,
             f"_delay_ms 非法: {env.get('_delay_ms')}")
    return "method" in env


def check_args(f, env):
    ch, d, m = env["channel"], env.get("dir", "out"), env["method"]
    args = env.get("args", {})
    if not isinstance(args, dict):
        return f.ok(False, f"{ch}/{d}/{m}: args 不是对象")
    req = None
    if ch == "ui" and d == "out" and m in UI_OUT_REQUIRED_ARGS:
        req = UI_OUT_REQUIRED_ARGS[m]
    elif ch == "ui" and d == "out" and m == "panel/update":
        req = PANEL_UPDATE_REQUIRED
        f.ok(args.get("layout") in ("horizontal", "vertical"),
             "panel/update.layout 枚举非法")
        cands = args.get("candidates")
        if isinstance(cands, list):
            for c in cands:
                f.ok(isinstance(c, dict) and "label" in c and "text" in c,
                     "panel/update.candidates 项缺 label/text")
    elif ch == "asr" and d == "in" and m in ("asr/partial", "asr/final"):
        req = ASR_IN_TEXT_REQUIRED
    elif ch == "refine" and d == "in":
        req = REFINE_IN_REQUIRED
        cands = args.get("candidates")
        f.ok(isinstance(cands, list) and len(cands) >= 1,
             "refine/result.candidates 必须非空数组")
    if req is None:
        # 未知 method：协议向前兼容，忽略（hello 协商语义）
        return True
    for k in req:
        f.ok(k in args, f"{ch}/{d}/{m}: 缺必填 args.{k}")
    return True


def check_script(path):
    f = Fail()
    events = []
    for i, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            env = json.loads(line)
        except json.JSONDecodeError as e:
            f.ok(False, f"第 {i} 行 JSON 解析失败: {e}")
            continue
        if check_envelope(f, env):
            check_args(f, env)
            if "_comment" not in env:
                events.append((i, env))
    name = path.name

    # —— 跨通道对拍不变量 ——
    seq_last = -1
    hello_seen = False
    session_live = False   # voice 会话进行中（idle 后关闭）
    ui_state = None        # 最近 ui 状态：recording/candidates/panel
    pending_partial = None  # 最近 asr/partial 文本
    pending_final = None    # 最近 asr/final 文本
    pending_refine = None   # 最近 refine/result.candidates
    has_voice = any(e["method"].startswith("voice/") for _, e in events)
    # ui 镜像规则只对携带 asr 侧的脚本生效（多通道/hub 视角）；纯 ui
    # 脚本是 UI 视角夹具，没有 asr 侧可对拍
    has_asr = any(e["channel"] == "asr" for _, e in events)
    for ln, env in events:
        ch, d, m = env["channel"], env.get("dir", "out"), env["method"]
        if "seq" in env:
            f.ok(env["seq"] >= seq_last, f"{name}:{ln} seq 回退")
            seq_last = env["seq"]
        if m == "hello":
            hello_seen = True
            session_live = False
            continue
        if not hello_seen:
            f.ok(False, f"{name}:{ln} {m} 出现在 hello 之前")
            hello_seen = True  # 只报一次
        if m == "asr/partial":
            pending_partial = env["args"]["text"]
        elif m == "voice/recording":
            if has_asr:
                # 空 partial=会话开场宣告（无 asr 侧对应）；否则必须镜像
                # 最近一次 asr/partial
                f.ok((pending_partial is not None
                      and env["args"]["partial"] == pending_partial)
                     or (pending_partial is None
                         and env["args"]["partial"] == ""),
                     f"{name}:{ln} voice/recording.partial 与 asr/partial 不"
                     f"一致（ui 镜像规则）")
            pending_partial = None
            session_live = True
            ui_state = "recording"
        elif m == "asr/final":
            pending_final = env["args"]["text"]
        elif m == "refine/request":
            f.ok(pending_final is not None
                 and env["args"].get("raw") == pending_final,
                 f"{name}:{ln} refine/request.raw 与 asr/final 不一致")
        elif m == "refine/result":
            pending_refine = env["args"]["candidates"]
        elif m == "voice/candidates":
            if pending_refine is not None:
                f.ok(env["args"]["candidates"] == pending_refine,
                     f"{name}:{ln} voice/candidates.candidates 与 "
                     f"refine/result 不一致")
                pending_refine = None
            session_live = True
            ui_state = "candidates"
        elif m == "voice/idle":
            f.ok(session_live, f"{name}:{ln} voice/idle 无进行中会话")
            session_live = False
            ui_state = None
            pending_partial = pending_final = pending_refine = None
        elif m.startswith("voice/") and not session_live:
            f.ok(False, f"{name}:{ln} {m} 出现在 idle 之后无新 hello")
        elif m == "select" and ch == "ui" and d == "in":
            f.ok(ui_state in ("candidates", "panel"),
                 f"{name}:{ln} select 时无候选面板（{ui_state}）")
        elif m == "panel/update":
            ui_state = "panel"
    has_voice = any(e["method"].startswith("voice/") for _, e in events)
    if has_voice:
        f.ok(not session_live, f"{name} 会话未以 voice/idle 收尾")
    return f, len(events)


def main():
    args = sys.argv[1:]
    out_path = None
    if args and args[0] == "--out":
        out_path = args[1]
        args = args[2:]
    ev_dir = Path(args[0]) if args else Path(__file__).parent / "events"
    scripts = sorted(ev_dir.glob("*.jsonl"))
    report = {"scripts": [], "total_checks": 0, "failures": 0}
    for s in scripts:
        f, n = check_script(s)
        report["scripts"].append(
            {"file": s.name, "events": n, "checks": f.checks,
             "errors": f.errors})
        report["total_checks"] += f.checks
        report["failures"] += len(f.errors)
        status = "PASS" if not f.errors else "FAIL"
        print(f"[{status}] {s.name}: {n} 事件, {f.checks} 断言")
        for e in f.errors:
            print(f"    - {e}")
    print(f"== {len(scripts)} 个脚本, {report['total_checks']} 断言, "
          f"{report['failures']} 失败")
    if out_path:
        Path(out_path).write_text(
            json.dumps(report, ensure_ascii=False, indent=1))
    sys.exit(1 if report["failures"] else 0)


if __name__ == "__main__":
    main()
