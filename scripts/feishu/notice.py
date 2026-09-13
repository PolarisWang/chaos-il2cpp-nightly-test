"""The single data contract between "a channel has something to say" and
"a Feishu card gets sent".

Every notification in this repo — code review results, nightly build reports,
system health alerts — is expressed as a Notice and handed to the engine.
Channel code never builds card JSON and never talks to a webhook; it only
decides what to SAY. The engine decides how it LOOKS and how it is delivered.

That split is what makes the system extensible: adding a notification means
writing one `to_notice()` function, not another card builder.

See scripts/feishu/engine.py for the other half.
"""

from dataclasses import dataclass, field
from typing import Dict, List, Tuple

# Action levels. The EMOJI/TAG/COLOR for each lives in engine.LEVEL_MAP —
# sources only choose the level, never the presentation.
RED = 'RED'            # needs a human; will not self-heal
YELLOW = 'YELLOW'      # needs confirmation; auto-retried, may be unreliable
INFO = 'INFO'          # normal information, no action
RECOVERED = 'RECOVERED'  # came back from a failure; sent once on transition

LEVELS = (RED, YELLOW, INFO, RECOVERED)


@dataclass
class InfoLine:
    """One labelled block in a card body.

    `label` renders bold and is the thing a reader scans for ("影响范围",
    "Linux"). `content` is the markdown body under it. An empty label means a
    plain paragraph, which is how single-line rows and warnings are expressed.
    """
    label: str
    content: str

    def is_plain(self) -> bool:
        return not self.label.strip()


@dataclass
class Notice:
    """A notification, before any presentation decisions are made.

    Rendering into Feishu card JSON happens in the engine, driven by a YAML
    template selected on (channel, level, tags). This object is deliberately
    transport- and format-agnostic so the same Notice could be rendered as a
    card, plain text, or an email without the producing code changing.
    """

    # Which source produced this. Drives template selection and log filtering.
    # Known: 'review', 'nightly', 'health'.
    channel: str

    # Action level — see the RED/YELLOW/INFO/RECOVERED constants above.
    level: str

    # Card header text, WITHOUT the level emoji/tag (the engine adds those).
    title: str

    # Card body, as a list of labelled blocks in reading order.
    body: List[InfoLine] = field(default_factory=list)

    # Buttons: (label, url) pairs, rendered in order.
    actions: List[Tuple[str, str]] = field(default_factory=list)

    # Footer override. Empty means the engine uses the channel default.
    footer_text: str = ''

    # Header decoration override.
    #
    # By default the engine prefixes the title with the level's emoji and tag
    # ("🔴 【需人工处理】 ..."). Set `raw_header=True` to suppress that and use
    # `title` verbatim.
    #
    # Why this exists: the code-review card's header has always been a plain
    # "chaos-il2cpp 代码审查 — N 个问题" with the severity conveyed by the card
    # COLOUR, not by a text tag. Forcing the tag on it changed a card the team
    # reads every day. Preserving the published format beats a uniform-looking
    # one; the tag stays the default for genuinely-new notifications.
    raw_header: bool = False

    # Explicit Feishu colour, overriding LEVEL_MAP.
    #
    # The legacy review card's colour is computed in the Jenkinsfile (red for
    # 严重/中, blue for 轻, orange for docs/low-conf/incomplete, else green) and
    # that Groovy expression is the single decision point the whole pipeline
    # already agrees on. Rather than re-derive it here — two places to keep in
    # sync — a source may pass the colour through.
    color_override: str = ''

    # Verbatim body. When set, the engine uses this markdown as the card body
    # instead of rendering `body`. Legacy cards whose body is assembled by
    # string concatenation (and whose exact whitespace readers are used to) set
    # this so the output is byte-identical to what shipped before.
    raw_body: str = ''

    # Idempotency key. Two Notices with the same key inside the dedup window
    # produce ONE card. Empty disables dedup for this notice.
    # Convention: "<channel>:<stable-identity>", e.g. "nightly:20260913:run1".
    dedup_key: str = ''

    # Anything else a template might want to branch on or display: counts,
    # booleans, sub-objects. Templates read these via `tags.<name>`.
    # This is the extension point — new per-channel data does NOT require
    # changing the Notice schema or the engine.
    tags: Dict[str, object] = field(default_factory=dict)

    def __post_init__(self):
        if self.level not in LEVELS:
            raise ValueError(
                'Notice.level must be one of %s, got %r' % (list(LEVELS), self.level))
        if not self.channel:
            raise ValueError('Notice.channel is required')
        if not self.title:
            raise ValueError('Notice.title is required')

    def plain_body(self) -> str:
        """Flatten the body to text. Used by the last-resort text fallback."""
        out = []
        for line in self.body:
            if line.is_plain():
                out.append(line.content)
            else:
                out.append('%s\n%s' % (line.label, line.content))
        return '\n\n'.join(out)
