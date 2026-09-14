"""Channel sources — one module per notification channel.

Each module exposes `to_notice(...)` (or `notice_from_alert(...)` for health)
which turns that channel's raw data into a `feishu.notice.Notice`. Sources
decide WHAT to report; the engine decides how it looks and how it is sent.

Known channels:
  review.py   findings.json   -> code-review result card
  nightly.py  platform-payload.json -> nightly build card
  health.py   monitor alerts / check results -> system health card
"""
