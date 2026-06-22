#!/usr/bin/env python3
"""send-feishu.py — Send nightly build notification to Feishu/Lark webhook.

Reads notification data from a JSON file passed as argument, builds an
interactive card, and sends via Feishu webhook API.

Usage:
    python3 send-feishu.py /path/to/notify-data.json

JSON file format (all fields optional):
    {
        "status": "SUCCESS|FAILURE",
        "color": "green|red",
        "build_num": "58",
        "date_tag": "2026-06-22",
        "run_tag": "run1|run2",
        "build_config": "profile",
        "build_link": "http://...",
        "report_link": "http://...",
        "data_dlls": 0,
        "total_dlls": 28,
        "fact_passed": 12501,
        "fact_total": 12650,
        "fact_pct": "98.8%",
        "bmk_methods": 7545,
        "hot_passed": 10568,
        "hot_total": 10568,
        "hot_pct": "100.0%",
        "mem_methods": 6543,
        "mem_alloc": "0.3 MB",
        "mem_gc": "N/A",
        "fail_lines": "__MANY__26" or "Dll1: 2 failed chunk(s)||Dll2: 1 failed chunk(s)"
    }
"""

import json
import os
import sys
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


def build_title(status_val, build_num, date_tag, run_tag):
    """Build card title with Chinese/emoji hardcoded in UTF-8."""
    run_label = "午后" if run_tag == "run2" else "凌晨"  # 午后 / 凌晨
    icon = "✅" if status_val == "SUCCESS" else "❌"  # ✅ / ❌
    return f"{icon} chaos-il2cpp Nightly #{build_num} — {date_tag} ({run_label})"


def build_message(data):
    """Build card message body with Chinese labels hardcoded in UTF-8."""
    parts = [
        f"**构建配置:** {data.get('build_config', '')}",
        f"**状态:** {data.get('status', 'UNKNOWN')}",
        "",
        f"**覆盖范围:** {data.get('data_dlls', 0)}/{data.get('total_dlls', 0)} DLLs 有数据",
        f"**正确率 (Fact):** {data.get('fact_passed', 0)}/{data.get('fact_total', 0)} ({data.get('fact_pct', 'N/A')})",
        f"**基准测试:** {data.get('bmk_methods', 0)} 方法",
        f"**热更新:** {data.get('hot_passed', 0)}/{data.get('hot_total', 0)} ({data.get('hot_pct', 'N/A')})",
        f"**内存 Profile:** {data.get('mem_methods', 0)} 方法 · Nursery={data.get('mem_alloc', 'N/A')} · GC={data.get('mem_gc', 'N/A')}",
    ]
    fail_lines = data.get('fail_lines', '')
    if fail_lines:
        if fail_lines.startswith("__MANY__"):
            count = fail_lines.replace("__MANY__", "")
            parts.append("")
            parts.append(f"**失败详情:** {count} DLL(s) 有失败")
        else:
            detail = fail_lines.replace("||", "\n")
            parts.append("")
            parts.append(f"**失败详情:**")
            parts.append(detail)
    return "\n".join(parts)


def main():
    if len(sys.argv) < 2:
        print("WARNING: No data file specified. Skipping notification.")
        sys.exit(0)

    data_file = sys.argv[1]
    if not os.path.exists(data_file):
        print(f"WARNING: Data file {data_file} not found. Skipping notification.")
        sys.exit(0)

    with open(data_file, 'r') as f:
        data = json.load(f)

    webhook = os.environ.get("FEISHU_WEBHOOK_URL", "")
    if not webhook:
        print("WARNING: FEISHU_WEBHOOK_URL not set. Skipping notification.")
        sys.exit(0)

    status_val = data.get('status', 'UNKNOWN')
    color_val = data.get('color', 'green')
    build_num = data.get('build_num', '?')
    date_tag = data.get('date_tag', '')
    run_tag = data.get('run_tag', 'run1')
    build_link_val = data.get('build_link', '')
    report_link_val = data.get('report_link', '')

    title = build_title(status_val, build_num, date_tag, run_tag)
    message = build_message(data)

    payload = {
        "msg_type": "interactive",
        "card": {
            "header": {
                "title": {"tag": "plain_text", "content": title},
                "template": color_val if color_val in ("red", "blue", "green") else "green",
            },
            "elements": [
                {"tag": "div", "text": {"tag": "lark_md", "content": message}},
                {"tag": "hr"},
            ],
        },
    }

    actions = []
    if report_link_val:
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "\U0001f4ca 查看报告"},  # 📊 查看报告
            "url": report_link_val,
            "type": "default",
        })
    if build_link_val:
        actions.append({
            "tag": "button",
            "text": {"tag": "plain_text", "content": "\U0001f527 Jenkins Build"},  # 🔧
            "url": build_link_val,
            "type": "default",
        })
    if actions:
        payload["card"]["elements"].append({"tag": "action", "actions": actions})
        payload["card"]["elements"].append({"tag": "hr"})

    payload["card"]["elements"].append({
        "tag": "note",
        "elements": [{"tag": "plain_text", "content": "chaos-il2cpp CI"}],
    })

    request_data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = Request(webhook, data=request_data, headers={"Content-Type": "application/json; charset=utf-8"})
    try:
        resp = urlopen(req, timeout=30)
        print(f"Feishu notification sent (HTTP {resp.status})")
        resp.close()
    except HTTPError as e:
        print(f"WARNING: Feishu webhook returned HTTP {e.code}")
        sys.exit(1)
    except URLError as e:
        print(f"WARNING: Feishu webhook error: {e.reason}")
        sys.exit(1)


if __name__ == "__main__":
    main()
