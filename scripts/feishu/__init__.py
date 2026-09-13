"""Feishu notification system for chaos-il2cpp.

Public API:
  feishu.send(notice, webhook)   → engine.send()
  feishu.Notice(...)             → notice.Notice

Each source module under sources/ turns one kind of raw data into a Notice.
Adding a new notification means adding a source file that produces a Notice;
the engine and its templates stay unchanged.
"""

from .engine import send, LEVEL_MAP
from .notice import Notice, InfoLine, Section, RED, YELLOW, INFO, RECOVERED

__all__ = ['send', 'Notice', 'InfoLine', 'Section', 'LEVEL_MAP',
           'RED', 'YELLOW', 'INFO', 'RECOVERED']
