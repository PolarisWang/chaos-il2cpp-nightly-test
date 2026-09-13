#!/usr/bin/env python3
"""incident-card.py — Unified abnormal-case Feishu card builder.

Produces interactive cards with action-level tags, impact/cause/action sections.
Designed to be called from both code-review-card.py (Python import) and
monitor-il2cpp-review.sh (CLI).

Level → tag → color:
  RED       🔴 【需人工处理】  → red        (scripts that need human intervention)
  YELLOW    🟡 【需确认】      → orange     (auto-retried, but needs verification)
  INFO      ℹ️                 → grey/green (normal info, no action needed)
  RECOVERED ✅ 【已恢复】       → green      (recovery from failure)

Usage (CLI):
  python3 scripts/incident-card.py \\
      --level RED|YELLOW|INFO|RECOVERED \\
      --title "..." \\
      [--impact "..."] \\
      [--cause "..."] \\
      [--action "..."] \\
      [--build-link "..."] \\
      [--report-link "..."] \\
      [--extra "key|value"] \\
      [--minimal]   (INFO only: single-line card, no body)
      [--dry-run]

  Environment: FEISHU_WEBHOOK_URL (required for sending)
  --dry-run: print card JSON to stdout instead of sending
"""

import json, os, sys, time, argparse
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

LEVEL_MAP = {
    'RED':       {'emoji': '🔴', 'tag': '【需人工处理】', 'color': 'red'},
    'YELLOW':    {'emoji': '🟡', 'tag': '【需确认】',     'color': 'orange'},
    'INFO':      {'emoji': 'ℹ️', 'tag': '',               'color': 'green'},
    'RECOVERED': {'emoji': '✅', 'tag': '【已恢复】',     'color': 'green'},
}


def build_card(level, title, impact='', cause='', action='',
               build_link='', report_link='', extra_pairs=None,
               minimal=False, date_tag=''):
    """Build a Feishu interactive card dict.

    Args:
        level: RED|YELLOW|INFO|RECOVERED
        title: Short card title (will be prefixed with emoji + tag)
        impact: What happened / what was affected (markdown)
        cause: Why it happened (markdown)
        action: What to do about it (markdown)
        build_link: Jenkins build URL
        report_link: Full report URL
        extra_pairs: list of (key, value) tuples for extra info lines
        minimal: If True, produce a minimal card (header + footer only)
        date_tag: Date string for footer

    Returns:
        dict: Feishu card JSON
    """
    info = LEVEL_MAP.get(level, LEVEL_MAP['INFO'])
    emoji = info['emoji']
    tag = info['tag']
    color = info['color']

    full_title = f'{emoji} {tag} {title}' if tag else f'{emoji} {title}'
    content_lines = []
    rendered = False

    if minimal:
        # Minimal card: just header + footer (for docs_only etc.)
        elements = [
            {'tag': 'note', 'elements': [
                {'tag': 'plain_text', 'content': f'chaos-il2cpp Code Review · {date_tag}' if date_tag else 'chaos-il2cpp Code Review'}
            ]}
        ]
    else:
        # Full card: impact + cause + action sections
        if impact:
            content_lines.append(f'📋 **影响范围**\n{impact}')
        if cause:
            if content_lines:
                content_lines.append('')
            content_lines.append(f'🔍 **原因**\n{cause}')
        if action:
            if content_lines:
                content_lines.append('')
            content_lines.append(f'🔧 **建议操作**\n{action}')
        if extra_pairs:
            if content_lines:
                content_lines.append('')
            parts = []
            for k, v in extra_pairs:
                parts.append(f'  • {k}: {v}')
            content_lines.append('**详细信息**\n' + '\n'.join(parts))

        body_text = '\n'.join(content_lines) if content_lines else ''

        elements = []
        if body_text:
            elements.append({'tag': 'div', 'text': {'tag': 'lark_md', 'content': body_text}})
            elements.append({'tag': 'hr'})

        # Action buttons
        actions = []
        if report_link:
            actions.append({
                'tag': 'button',
                'text': {'tag': 'plain_text', 'content': '📊 查看完整报告'},
                'url': report_link,
                'type': 'default'
            })
        if build_link:
            actions.append({
                'tag': 'button',
                'text': {'tag': 'plain_text', 'content': '🔧 打开 Jenkins'},
                'url': build_link,
                'type': 'default'
            })
        if actions:
            elements.append({'tag': 'action', 'actions': actions})
            elements.append({'tag': 'hr'})

        # Footer
        elements.append({'tag': 'note', 'elements': [
            {'tag': 'plain_text', 'content': f'chaos-il2cpp Code Review · {date_tag}' if date_tag else 'chaos-il2cpp Code Review'}
        ]})

    card = {
        'msg_type': 'interactive',
        'card': {
            'header': {
                'title': {'tag': 'plain_text', 'content': full_title},
                'template': color
            },
            'elements': elements
        }
    }
    return card


def send_card(card, webhook_url):
    """Send a card to Feishu via webhook.

    Returns:
        bool: True if sent successfully
    """
    if not webhook_url:
        print('WARNING: FEISHU_WEBHOOK_URL not set', file=sys.stderr)
        return False

    payload = json.dumps(card, ensure_ascii=False).encode('utf-8')
    req = Request(
        webhook_url, data=payload,
        headers={'Content-Type': 'application/json'},
        method='POST'
    )
    try:
        resp = urlopen(req, timeout=30)
        print(f'Incident card sent (HTTP {resp.status})')
        return True
    except HTTPError as e:
        print(f'WARNING: Feishu webhook returned HTTP {e.code}', file=sys.stderr)
        return False
    except URLError as e:
        print(f'WARNING: Feishu webhook error: {e.reason}', file=sys.stderr)
        return False


def error_code_to_cause(error_text):
    """Translate technical error codes into readable Chinese descriptions."""
    if not error_text:
        return ''
    text = error_text.lower()
    if 'exit code 129' in text:
        return '审查脚本参数错误（git 调用失败），这是已知 bug：在超大 diff 合并 chunk 时触发'
    if 'arg_max' in text or 'argument list too long' in text:
        return '文件列表过长超出系统限制（ARG_MAX），大 diff 时触发'
    if 'timeout' in text or 'timed out' in text:
        return '审查超时（模型响应时间超过阈值）'
    if 'exit code 137' in text:
        return '审查进程被系统 OOM Killer 终止（内存不足）'
    if 'model' in text.lower() or 'parse' in text.lower() or 'claude' in text.lower():
        return '模型返回了无法解析的结果（可能是模型异常或 Diff 过大）'
    if 'tls' in text.lower() or 'handshake' in text.lower() or 'github' in text.lower():
        return 'GitHub 连接不稳定（TLS 握手失败）'
    return f'审查流程异常: {error_text}'


def main():
    parser = argparse.ArgumentParser(description='Build and send incident card to Feishu')
    parser.add_argument('--level', required=True,
                        choices=list(LEVEL_MAP.keys()),
                        help='Incident level')
    parser.add_argument('--title', required=True,
                        help='Card title (short, e.g. "代码审查未完成")')
    parser.add_argument('--impact',
                        help='Impact description (markdown)')
    parser.add_argument('--cause',
                        help='Cause description (markdown)')
    parser.add_argument('--action',
                        help='Suggested action (markdown)')
    parser.add_argument('--build-link',
                        help='Jenkins build URL')
    parser.add_argument('--report-link',
                        help='Full report URL')
    parser.add_argument('--extra', action='append',
                        help='Extra info as "key|value" (repeatable)')
    parser.add_argument('--minimal', action='store_true',
                        help='Minimal card (no body, just header)')
    parser.add_argument('--dry-run', action='store_true',
                        help='Print card JSON instead of sending')
    parser.add_argument('--date-tag',
                        help='Date tag for footer')
    parser.add_argument('--error-text',
                        help='Raw error text (will be auto-translated to cause)')

    args = parser.parse_args()

    # Auto-translate error text to cause if no explicit cause given
    cause = args.cause
    if not cause and args.error_text:
        cause = error_code_to_cause(args.error_text)

    # Parse extra pairs
    extra_pairs = []
    if args.extra:
        for e in args.extra:
            if '|' in e:
                k, v = e.split('|', 1)
                extra_pairs.append((k.strip(), v.strip()))

    card = build_card(
        level=args.level,
        title=args.title,
        impact=args.impact,
        cause=cause,
        action=args.action,
        build_link=args.build_link,
        report_link=args.report_link,
        extra_pairs=extra_pairs,
        minimal=args.minimal,
        date_tag=args.date_tag or time.strftime('%Y-%m-%d'),
    )

    if args.dry_run:
        print(json.dumps(card, ensure_ascii=False, indent=2))
        return

    webhook = os.environ.get('FEISHU_WEBHOOK_URL', '').strip()
    sent = send_card(card, webhook)

    # Write sentinel file so monitoring can cross-check
    outdir = os.environ.get('CARD_OUTDIR', '/var/lib/report-server/daily')
    try:
        os.makedirs(outdir, exist_ok=True)
        sentinel = {
            'type': 'incident_card',
            'level': args.level,
            'title': args.title,
            'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'card_sent': sent,
        }
        with open(os.path.join(outdir, 'last-incident-card.json'), 'w') as f:
            json.dump(sentinel, f, ensure_ascii=False)
    except Exception as e:
        print(f'WARNING: could not write sentinel: {e}', file=sys.stderr)

    # Exit code reflects send success/failure
    sys.exit(0 if sent else 1)


if __name__ == '__main__':
    main()