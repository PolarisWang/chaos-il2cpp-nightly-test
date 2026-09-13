"""Health monitor alerts → Notice.

Two entry points:

  notice_from_alert(...)  — for callers that already computed the narrative
                            (monitor.sh, monitor-il2cpp-review.sh). They know
                            the lock age / outage duration / unreviewed count
                            at the call site, so they pass impact/cause/action
                            as final strings and this module only picks the
                            action level.
  to_notice(checks, ...)  — for a raw set of system checks, where this module
                            derives both the level and the body.

The dedup/hysteresis logic lives in monitor.sh's own python block; this
module only turns a decision into a Notice.
"""

from typing import Dict, List

from ..notice import Notice, InfoLine, RED, YELLOW, INFO, RECOVERED

LEVEL_MAP_CHECKS = {
    'CRIT': RED,
    'WARN': YELLOW,
    'INFO': INFO,
    'OK': INFO,
}

# Which action level each monitor event carries. Kept here rather than at the
# call sites so the escalation policy is reviewable in one place.
EVENT_LEVEL = {
    'new_failure': RED,
    'sustained_failure': RED,
    'stuck_lock': RED,
    'stalled': RED,
    'recovered': RECOVERED,
    'system': INFO,
}


def notice_from_alert(*, event: str = 'system', title: str = '',
                      impact: str = '', cause: str = '', action: str = '',
                      build_link: str = '', report_link: str = '',
                      date_tag: str = '', channel: str = 'health') -> Notice:
    """Build a Notice from an alert whose narrative is already composed.

    Used by monitor.sh / monitor-il2cpp-review.sh, which compute impact text
    from live state (lock age, outage minutes, unreviewed commit count) that
    this module cannot reconstruct.
    """
    level = EVENT_LEVEL.get(event, INFO)

    body = []
    if impact:
        body.append(InfoLine('影响范围', impact))
    if cause:
        body.append(InfoLine('原因', cause))
    if action:
        body.append(InfoLine('建议操作', action))
    if not body:
        body.append(InfoLine('', title or '系统告警'))

    actions = []
    if report_link:
        actions.append(('📊 查看完整报告', report_link))
    if build_link and build_link != report_link:
        actions.append(('🔧 打开 Jenkins', build_link))
    elif build_link:
        actions.append(('🔧 打开 Jenkins', build_link))

    return Notice(
        channel=channel,
        level=level,
        title=title or '系统告警',
        body=body,
        actions=actions,
        footer_text=('chaos-il2cpp 系统监控 · %s' % date_tag) if date_tag
                    else 'chaos-il2cpp 系统监控',
        tags={'event': event},
    )


def to_notice(checks: Dict[str, Dict],
              *, event: str = 'new_failure', is_sustained: bool = False,
              info: Dict = None) -> Notice:
    """Build a Notice from a set of health check results.

    Args:
        checks: {name: {level, msg}} from monitor.sh.
        event: 'new_failure', 'recovered', 'sustained', 'stuck_lock'.
        is_sustained: True if this is a periodic re-alert.
        info: Optional dict with additional context (see below).

    Returns a Notice.
    """
    info = info or {}
    issues = {n: c for n, c in checks.items()
              if c.get('level') in ('WARN', 'CRIT')}
    any_crit = any(c['level'] == 'CRIT' for c in issues.values())
    channel = info.get('channel', 'health')

    # ── Check-set path ──
    # A caller passing real check data wants a SUMMARY of those checks, not the
    # review-failure narrative. Without this routing, to_notice(checks,
    # event='new_failure') produced a "构建失败" card full of '?' placeholders
    # and forced every level to RED regardless of the actual check levels.
    if issues and event not in ('stuck_lock', 'stalled'):
        msg_lines = []
        for name, c in sorted(issues.items()):
            msg_lines.append('  • [%s] %s' % (c['level'], c.get('msg', name)))
        level = RED if any_crit else YELLOW
        ts = info.get('timestamp', '')
        title = ('%s %s' % ('🚨 系统异常' if any_crit else '⚠️ 系统告警',
                            ('[%s]' % ts) if ts else '')).strip()
        return Notice(
            channel=channel,
            level=level,
            title=title,
            body=[InfoLine('异常项', '\n'.join(msg_lines))],
            tags={'event': 'system_check'},
        )

    if event == 'stuck_lock':
        return Notice(
            channel=channel,
            level=RED,
            title='代码审查已阻塞',
            body=[
                InfoLine('影响范围',
                         '触发锁已持有 %d 分钟（阈值 %d 分钟）\n'
                         '后续所有提交都无法触发审查'
                         % (info.get('age_min', 0), info.get('timeout_min', 0))),
                InfoLine('原因', '上一次审查未正常释放锁（可能构建中断 / 脚本异常退出）'),
                InfoLine('建议操作', '清除锁：rm -f %s'
                         % info.get('lock_path', '/var/lib/report-server/daily/cr-trigger.lock')),
            ],
            tags={'event': 'stuck_lock'},
        )

    if event == 'stalled':
        return Notice(
            channel=channel,
            level=RED,
            title='代码审查可能已停止',
            body=[
                InfoLine('影响范围',
                         '状态落后仓库 HEAD %s 个提交\n'
                         '已 %d 分钟没有新的审查构建（且无锁占用）'
                         % (info.get('behind', '?'), info.get('idle_min', 0))),
                InfoLine('原因',
                         '触发轮询停止 / 状态文件损坏\n'
                         'last_reviewed: %s\nrepo HEAD: %s\n上次构建: #%s %s'
                         % (info.get('last_reviewed', '?')[:10],
                            info.get('repo_head', '?')[:10],
                            info.get('build_num', '?'),
                            info.get('build_when', '?'))),
                InfoLine('建议操作', '检查 poller cron 是否仍在运行'),
            ],
            tags={'event': 'stalled'},
        )

    if event == 'recovered':
        outage_min = info.get('outage_min', 0)
        return Notice(
            channel=channel,
            level=RECOVERED,
            title='代码审查已恢复正常',
            body=[
                InfoLine('', '构建 #%s = SUCCESS\n中断时长约 %d 分钟'
                         % (info.get('build_num', '?'), outage_min)),
            ],
        )

    if event == 'new_failure':
        cause = _cause_text(info.get('error_text', ''))
        return Notice(
            channel=channel,
            level=RED,
            title='代码审查构建失败',
            body=[
                InfoLine('影响范围',
                         '构建 #%s = %s（%s）\n本次提交未被审查，飞书无审查卡片'
                         % (info.get('build_num', '?'),
                            info.get('result', '?'),
                            info.get('build_when', '?'))),
                InfoLine('原因', cause),
                InfoLine('建议操作', '查看构建日志定位失败环节'),
            ],
        )

    if event == 'sustained_failure':
        cause = _cause_text(info.get('error_text', ''))
        return Notice(
            channel=channel,
            level=RED,
            title='代码审查持续失败',
            body=[
                InfoLine('影响范围',
                         '最近完成构建 #%s = %s（%s）\n'
                         '已持续失败约 %d 小时\n期间约 %s 个提交未被审查'
                         % (info.get('build_num', '?'),
                            info.get('result', '?'),
                            info.get('build_when', '?'),
                            info.get('sustained_h', 0),
                            info.get('unreviewed', '?'))),
                InfoLine('原因', '根因与首次告警相同：' + cause),
                InfoLine('建议操作', '该问题不会自愈，需人工修复'),
            ],
        )

    # General health summary (from monitor.sh's system checks)
    msg_lines = []
    for name, c in sorted(issues.items()):
        msg_lines.append('  • [%s] %s' % (c['level'], c.get('msg', name)))
    if msg_lines:
        body = [InfoLine('异常项', '\n'.join(msg_lines))]
    else:
        body = [InfoLine('', '所有系统检查正常')]

    level = RED if any_crit else (YELLOW if issues else INFO)
    title_lvl = '🚨 系统异常' if any_crit else '⚠️ 系统告警'
    title = '%s [%s]' % (title_lvl, info.get('timestamp', ''))

    return Notice(
        channel=channel,
        level=level,
        title=title,
        body=body,
    )


def _cause_text(error_text: str) -> str:
    """Map raw error text to Chinese cause description."""
    if not error_text:
        return '审查流程异常，需查看构建日志定位'
    t = error_text.lower()
    if 'exit code 129' in t:
        return '审查脚本参数错误（git 调用失败），这是已知 bug：在超大 diff 合并 chunk 时触发'
    if 'argument list too long' in t or 'arg_max' in t:
        return '文件列表过长超出系统限制（ARG_MAX），大 diff 时触发'
    if 'timeout' in t:
        return '审查超时（模型响应时间超过阈值）'
    if 'exit code 137' in t:
        return '审查进程被系统 OOM Killer 终止（内存不足）'
    if 'model' in t or 'parse' in t:
        return '模型返回了无法解析的结果'
    return '审查流程异常: %s' % error_text