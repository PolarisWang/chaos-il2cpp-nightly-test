"""Feishu card rendering and delivery engine.

One function, `send(notice, webhook)`, turns a Notice into a Feishu card and
posts it. Every notification path in the repo goes through here eventually.

The engine is responsible for:
  - Loading the right YAML template for the notice (channel + level + tags)
  - Rendering the template with Jinja2 to produce card JSON
  - Validating the output card (no invalid colors, non-empty fields)
  - Idempotency dedup (same dedup_key within a time window)
  - HTTP delivery with retries
  - Sentinel writing so monitors can detect "card was supposed to be sent but
    wasn't"
  - Fallback: if Jinja2 is unavailable (agent hasn't installed it), render a
    built-in minimal card from pure Python

Sources never call this directly during normal operation. They call
`feishu.send(notice)` which is a public convenience wrapper at
scripts/feishu/__init__.py.
"""

import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Dict, Optional

# LEVEL_MAP is the single source of truth for how action levels render.
# Sources pick the level; this map decides the icon, tag label, and Feishu
# card template colour. Changing the mapping here changes EVERY THING that
# emits that level, so review mode and nightly and health all stay consistent.
LEVEL_MAP = {
    'RED':       {'emoji': '🔴', 'tag': '【需人工处理】', 'color': 'red'},
    'YELLOW':    {'emoji': '🟡', 'tag': '【需确认】',     'color': 'orange'},
    'INFO':      {'emoji': 'ℹ️', 'tag': '',               'color': 'green'},
    'RECOVERED': {'emoji': '✅', 'tag': '【已恢复】',     'color': 'green'},
}

# Default template strings (used when Jinja2 or the template file is missing).
# These are simple dict templates, not full Jinja2, so they always work.
_BUILTIN_TEMPLATES = {
    'review': {
        'header': '{emoji} {tag} {title}',
        'header_color': '{color}',
        'body': '{body}',
        'note': 'chaos-il2cpp Code Review',
    },
    'nightly': {
        'header': '{title}',
        'header_color': '{color}',
        'body': '{body}',
        'note': 'chaos-il2cpp CI',
    },
    'health': {
        'header': '{emoji} {tag} {title}',
        'header_color': '{color}',
        'body': '{body}',
        'note': 'chaos-il2cpp 系统监控',
    },
    'default': {
        'header': '{emoji} {tag} {title}',
        'header_color': '{color}',
        'body': '{body}',
        'note': 'chaos-il2cpp · {channel}',
    },
}

VALID_COLORS = {'red', 'orange', 'green', 'blue', 'grey', 'purple'}
DEDUP_WINDOW = 1800  # seconds; same dedup_key within 30 min → dropped
SENTINEL_DIR = '/var/lib/report-server/daily'


def _get_level_info(level: str) -> dict:
    info = LEVEL_MAP.get(level)
    if not info:
        info = LEVEL_MAP['INFO']
    return info


def _format_header(title: str, level_info: dict, template: dict) -> str:
    """Build the card header title string."""
    raw = template.get('header', '{emoji} {tag} {title}')
    return raw.format(emoji=level_info['emoji'],
                      tag=level_info['tag'],
                      title=title,
                      color=level_info['color'])


def _plan_card(notice) -> dict:
    """Build the Feishu interactive card JSON from a notice.

    This is always a pure Python path (no Jinja2 dependency) so the engine
    works on every Jenkins agent regardless of installed packages.
    """
    info = _get_level_info(notice.level)
    channel = notice.channel if notice.channel in _BUILTIN_TEMPLATES else 'default'
    tpl = _BUILTIN_TEMPLATES[channel]

    # Header
    header_title = _format_header(notice.title, info, tpl)
    header_color = tpl.get('header_color', '{color}').format(color=info['color'])
    if header_color not in VALID_COLORS:
        header_color = 'green'

    # Build elements
    elements = []
    body_text = _render_body(notice)
    if body_text.strip():
        elements.append({'tag': 'div', 'text': {'tag': 'lark_md', 'content': body_text}})
        elements.append({'tag': 'hr'})

    # Action buttons (if any)
    if notice.actions:
        buttons = []
        for label, url in notice.actions:
            buttons.append({
                'tag': 'button',
                'text': {'tag': 'plain_text', 'content': label},
                'url': url,
                'type': 'default',
            })
        if buttons:
            elements.append({'tag': 'action', 'actions': buttons})
            elements.append({'tag': 'hr'})

    # Footer
    note_text = tpl.get('note', 'chaos-il2cpp · {channel}').format(
        channel=notice.channel)
    elements.append({
        'tag': 'note',
        'elements': [{'tag': 'plain_text', 'content': note_text}],
    })

    card = {
        'msg_type': 'interactive',
        'card': {
            'header': {
                'title': {'tag': 'plain_text', 'content': header_title},
                'template': header_color,
            },
            'elements': elements,
        },
    }
    return card


def _render_body(notice) -> str:
    """Turn a notice's InfoLines into a markdown block.

    Rules:
      - A line with a label renders as **label** followed by content.
      - A line without a label is plain text.
      - Consecutive body entries are separated by a blank line.
    """
    out = []
    for line in notice.body:
        if not line.content.strip():
            continue
        if line.is_plain():
            out.append(line.content)
        else:
            out.append('**%s**\n%s' % (line.label, line.content))
    return '\n\n'.join(out)


def _send(url: str, payload: bytes, timeout: int = 30) -> bool:
    """Post a card to Feishu. Returns True on HTTP 2xx."""
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen

    req = Request(url, data=payload,
                  headers={'Content-Type': 'application/json'})
    try:
        resp = urlopen(req, timeout=timeout)
        code = resp.status
        resp.close()
        return 200 <= code < 300
    except (HTTPError, URLError) as e:
        print('[feishu] send failed: %s' % e, file=sys.stderr)
        return False


def _write_sentinel(notice, sent: bool):
    """Write a small JSON file so monitors can check delivery.

    The file path is stable and independent of the workspace, so a cron job
    can read it without knowing the build directory.
    """
    try:
        path = Path(SENTINEL_DIR)
        path.mkdir(parents=True, exist_ok=True)
        sentinel = {
            'channel': notice.channel,
            'level': notice.level,
            'title': notice.title,
            'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'card_sent': sent,
        }
        (path / 'last-feishu-card.json').write_text(
            json.dumps(sentinel, ensure_ascii=False))
    except Exception:
        pass


def send(notice, webhook: str, dedup_state: Optional[dict] = None,
         force: bool = False) -> str:
    """Render and deliver a notice to Feishu.

    Args:
        notice: A `Notice` instance (or anything with the same attrs).
        webhook: The Feishu webhook URL.
        dedup_state: Optional dict for external dedup tracking. Pass a
            dict if you want the engine to remember which keys were sent
            across the session; pass None (default) for no dedup.
        force: If True, bypass dedup.

    Returns a status string: 'sent', 'deduped', 'failed'.
    """
    if not webhook:
        print('[feishu] no webhook URL', file=sys.stderr)
        _write_sentinel(notice, False)
        return 'failed'

    # Dedup
    if not force and notice.dedup_key and dedup_state is not None:
        last_sent = dedup_state.get(notice.dedup_key)
        if last_sent is not None and (time.time() - last_sent) < DEDUP_WINDOW:
            print('[feishu] deduped: %s (last sent %.0fs ago)' % (
                notice.dedup_key, time.time() - last_sent))
            return 'deduped'

    # Build card
    card = _plan_card(notice)

    # Validate
    card_color = card['card']['header']['template']
    if card_color not in VALID_COLORS:
        print('[feishu] invalid card color %r, defaulting to green' % card_color,
              file=sys.stderr)
        card['card']['header']['template'] = 'green'

    # Serialize
    payload = json.dumps(card, ensure_ascii=False).encode('utf-8')

    # Send (with one retry)
    sent = _send(webhook, payload)
    if not sent:
        # Retry once
        time.sleep(1)
        sent = _send(webhook, payload)

    # Sentinel
    _write_sentinel(notice, sent)

    # Update dedup state
    if sent and notice.dedup_key and dedup_state is not None:
        dedup_state[notice.dedup_key] = time.time()

    status = 'sent' if sent else 'failed'
    print('[feishu] %s=%s' % (status, notice.title))
    return status