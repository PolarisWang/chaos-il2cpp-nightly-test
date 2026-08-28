#!/bin/bash
# review-with-claude.sh — Invoke Claude Code CLI to review git diff
#
# Reviews the diff between two commits for high-risk patterns, producing a rage
# standard JSON result (severity 严重/中/轻/建议 + `[Repo] file:line` findings).
#
# Reliability: the model (deepseek-v4-flash via the llm proxy) is unreliable on
# LARGE multi-file diffs — it flips between real findings, raw Python tracebacks,
# and valid-but-empty "0 findings".  To keep results trustworthy WITHOUT the
# unbounded runtime of a naive per-file loop, three levers are combined:
#   1. DYNAMIC CHUNKING  — group many small changed files into a single prompt
#      (each chunk stays a small, focused diff the model handles reliably), and
#      cap the number of chunks (REVIEW_MAX_CHUNKS).  Large files still get their
#      own chunk so high-risk changes are never diluted.
#   2. DIFF-HASH CACHE   — keyed by (from, to, changed-file set).  A repeated diff
#      reuses the prior NON-EMPTY findings (never cache an empty result, which
#      could be a model glitch mistaken for a clean pass).
#   3. LOW-CONFIDENCE MARK — a 0-findings result on substantive (non-docs) code is
#      flagged low_confidence in the meta so it is not blindly reported as
#      "✅ 本次未发现代码问题".
#
# Usage:
#   review-with-claude.sh --repo-dir <path> --from-commit <sha> --to-commit <sha> \
#       --output <path> [--max-diff-lines 50000]
#
# Env:
#   REVIEW_MAX_EMPTY_RETRIES (default 2)   retries per chunk on empty/error
#   REVIEW_CHUNK_MAX_LINES   (default 300) pack files into a chunk while combined
#                                           diff lines stay under this
#   REVIEW_MAX_CHUNKS        (default 4)   cap on number of chunks
#   REVIEW_CACHE_DIR         (default <repo>-review-cache) diff-hash result cache
#
# Output:
#   - Writes findings JSON to --output path
#   - Prints summary line to stdout for pipeline consumption

set -eu

REPO_DIR=""
FROM_COMMIT=""
TO_COMMIT=""
OUTPUT_FILE=""
MAX_DIFF_LINES=3000

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-dir)     REPO_DIR="$2";     shift 2 ;;
        --from-commit)  FROM_COMMIT="$2";  shift 2 ;;
        --to-commit)    TO_COMMIT="$2";    shift 2 ;;
        --output)       OUTPUT_FILE="$2";  shift 2 ;;
        --max-diff-lines) MAX_DIFF_LINES="$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# Validate required args
for arg in REPO_DIR FROM_COMMIT TO_COMMIT OUTPUT_FILE; do
    if [[ -z "${!arg}" ]]; then
        echo "ERROR: --${arg,,} is required" >&2
        exit 1
    fi
done

if [[ ! -d "$REPO_DIR" ]]; then
    echo "ERROR: Repo directory not found: ${REPO_DIR}" >&2
    exit 1
fi

# Verify claude CLI is available
if ! command -v claude &>/dev/null; then
    echo "ERROR: claude CLI not found in PATH" >&2
    echo "Install: pip install claude-code or see https://claude.ai/code" >&2
    exit 1
fi

cd "$REPO_DIR"

# Verify commits exist
if ! git cat-file -e "${FROM_COMMIT}"^{commit} 2>/dev/null; then
    echo "ERROR: from-commit '${FROM_COMMIT}' not found" >&2
    exit 1
fi
if ! git cat-file -e "${TO_COMMIT}"^{commit} 2>/dev/null; then
    echo "ERROR: to-commit '${TO_COMMIT}' not found" >&2
    exit 1
fi

# Gather commit log
COMMIT_LOG=$(git log --oneline "${FROM_COMMIT}..${TO_COMMIT}" 2>/dev/null || echo "")
COMMIT_COUNT=$(echo "$COMMIT_LOG" | grep -c . || true)

if [[ "$COMMIT_COUNT" -eq 0 ]]; then
    echo "No new commits between ${FROM_COMMIT} and ${TO_COMMIT}"
    echo '{"meta":{"from":"'"${FROM_COMMIT}"'","to":"'"${TO_COMMIT}"'"},"summary":{"严重":0,"中":0,"轻":0,"建议":0,"total_findings":0},"findings":[],"commits":[]}' > "$OUTPUT_FILE"
    echo "Reviewed 0 commits"
    echo "Findings: 0"
    exit 0
fi

# ──────────────────────────────────────────────
# File-level smart filtering (A)
# Exclude low-value / generated / binary files
# ──────────────────────────────────────────────
CHANGED_FILES_LIST=$(git diff --name-status "${FROM_COMMIT}".."${TO_COMMIT}" 2>/dev/null || true)

if [[ -z "$CHANGED_FILES_LIST" ]]; then
    echo "WARNING: git diff --name-status returned empty" >&2
    echo '{"meta":{"from":"'"${FROM_COMMIT}"'","to":"'"${TO_COMMIT}"'"},"summary":{"严重":0,"中":0,"轻":0,"建议":0,"total_findings":0},"findings":[],"commits":[]}' > "$OUTPUT_FILE"
    exit 0
fi

FILTERED_PATHS_FILE=$(mktemp)
echo "$CHANGED_FILES_LIST" | python3 -c '
import sys

# NOTE text/docs are kept (reviewed via the docs-mode prompt) as well as code.
EXTS_KEEP = (".cs", ".cpp", ".h", ".hpp", ".py", ".scriban", ".cmake", ".yaml", ".yml",
             ".md", ".txt")

def is_excluded(path):
    """Return True if a file path should be excluded from code review."""
    if path.startswith("third_party/"):
        return True
    if "/generated/" in path:
        return True
    if path.startswith(".hephaestus-cache/"):
        return True
    if path.startswith("test/snapshots/"):
        return True
    if path.startswith("wiki/"):
        return True

    basename = path.split("/")[-1] if "/" in path else path

    if basename == "CombinedSubjects.cs":
        return True
    if basename.endswith(".deps.json"):
        return True
    if ".generated." in basename:
        return True
    if "/obj/" in path and basename.endswith(".g.cs"):
        return True

    # Keep reviewable NOTE/text docs (.md, .txt): they are routed through a lighter
    # docs-review prompt (see all_note handling) rather than silently discarded, so a
    # docs-only change is never presented as a confident "no issues". Binary /
    # generated / non-text artifacts stay excluded.
    for ext in (".html", ".dll", ".pdb", ".exe", ".lib",
                ".svg", ".png", ".jpg", ".jpeg", ".jdata", ".jsonl"):
        if path.endswith(ext):
            return True

    if any(basename.endswith(e) for e in EXTS_KEEP):
        return False
    return True

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) >= 3:
        new_path = parts[2]
        if not is_excluded(new_path):
            print(new_path)
    elif len(parts) >= 2:
        path = parts[1]
        if not is_excluded(path):
            print(path)
' > "$FILTERED_PATHS_FILE" 2>/dev/null || true

FILTERED_COUNT=$(wc -l < "$FILTERED_PATHS_FILE" | tr -d ' ')

FILTERED_FILE_NAMES=""
if [[ "$FILTERED_COUNT" -gt 0 ]]; then
    FILTERED_FILE_NAMES=$(cat "$FILTERED_PATHS_FILE" 2>/dev/null || true)
fi

if [[ "$FILTERED_COUNT" -eq 0 ]]; then
    echo "WARNING: All files excluded by noise filters (no reviewable changes)" >&2
    rm -f "$FILTERED_PATHS_FILE"
    echo "Reviewed 0 reviewable files"
    echo "Findings: 0"
    # Nothing reviewable: flag docs_only + low_confidence so the card can never be
    # mistaken for a trustworthy code clean-pass. See commit 89a61b3 follow-up.
    echo '{"meta":{"from":"'"${FROM_COMMIT}"'","to":"'"${TO_COMMIT}"'"},"summary":{"严重":0,"中":0,"轻":0,"建议":0,"total_findings":0},"findings":[],"commits":[],"low_confidence":true,"incomplete":false,"docs_only":true}' > "$OUTPUT_FILE"
    exit 0
fi

echo "Filtered ${FILTERED_COUNT} reviewable files (out of $(echo "$CHANGED_FILES_LIST" | grep -c . || true) total changed)"

rm -f "$FILTERED_PATHS_FILE"

# ──────────────────────────────────────────────────────────────
# Config / cache setup
# ──────────────────────────────────────────────────────────────
MAX_EMPTY_RETRIES="${REVIEW_MAX_EMPTY_RETRIES:-2}"
# Use deepseek-v4-flash (the available model). Per-chunk hard timeout below keeps
# a hung call from blocking the build. Override with REVIEW_AGENT_MODEL if a
# different tier becomes available.
REVIEW_MODEL="${REVIEW_AGENT_MODEL:-deepseek-v4-flash}"
# Small enough that no single chunk exceeds what the model handles reliably
# (dense GC/pointer code starts glitching around ~200 diff lines), but large
# enough to still merge many tiny files into one call. A file larger than this
# threshold becomes its own chunk (never diluted).
CHUNK_MAX_LINES="${REVIEW_CHUNK_MAX_LINES:-150}"
MAX_CHUNKS="${REVIEW_MAX_CHUNKS:-4}"
CACHE_DIR="${REVIEW_CACHE_DIR:-}"
[ -z "$CACHE_DIR" ] && CACHE_DIR="${REPO_DIR}-review-cache"
PROMPT_FILE=$(mktemp)
trap "rm -f '$PROMPT_FILE'" EXIT

# Multi-file diff between the two commits.
chunk_diff_for() {
    # $@ = one or more paths
    git diff "${FROM_COMMIT}".."${TO_COMMIT}" -- "$@" 2>/dev/null
}

# is_note_path <path>: 1 if it's a markdown/text (no code findings expected)
is_note_path() {
    case "$1" in
        *.md) echo 1 ;;
        *.txt) echo 1 ;;
        *) echo 0 ;;
    esac
}

# cache key: sha1 of (from,to,sorted file list)
CACHE_KEY=$(printf '%s\n%s\n%s' "$FROM_COMMIT" "$TO_COMMIT" "$FILTERED_FILE_NAMES" | sha1sum | cut -c1-40)
CACHE_FILE="${CACHE_DIR}/${CACHE_KEY}.json"

# ──────────────────────────────────────────────────────────────
# Dynamic chunking — pack small files together, cap chunk count.
# Output chunks are stored in bash arrays: CHUNK_PATHS[i] = space-joined paths.
# ──────────────────────────────────────────────────────────────
CHUNKS=()          # each element = space-joined list of file paths in a chunk

# 1) compute each file's diff line-count + note status
mapfile -t ALL_FILES <<<"$FILTERED_FILE_NAMES"
declare -a FILE_LINES=()
FILE_CT=0
for f in "${ALL_FILES[@]:-}"; do
    [ -z "$f" ] && continue
    f="${f//$'\r'/}"
    fl=$(chunk_diff_for "$f" | wc -l | tr -d ' ')
    FILE_LINES[FILE_CT]="$fl"
    FILE_CT=$((FILE_CT+1))
done

# 2) greedy pack: large files get their own chunk; small files accumulate until
#    CHUNK_MAX_LINES or MAX_CHUNKS is reached.
cur=""; cur_lines=0
_i=0
for f in "${ALL_FILES[@]:-}"; do
    [ -z "$f" ] && continue
    f="${f//$'\r'/}"
    fl="${FILE_LINES[_i]:-0}"
    fl="${fl:-0}"
    _i=$((_i+1))
    # each file alone is its own chunk if large
    if [ "$fl" -gt "$CHUNK_MAX_LINES" ]; then
        # flush pending small-file chunk
        if [ -n "$cur" ]; then CHUNKS+=("$cur"); cur=""; cur_lines=0; fi
        CHUNKS+=("$f")
        continue
    fi
    # would adding push us over the line budget? then flush
    if [ -n "$cur" ] && [ $((cur_lines + fl)) -gt "$CHUNK_MAX_LINES" ]; then
        CHUNKS+=("$cur"); cur=""; cur_lines=0
    fi
    cur="$cur $f"
    cur_lines=$((cur_lines + fl))
done
if [ -n "$cur" ]; then CHUNKS+=("$cur"); fi

# enforce MAX_CHUNKS: if we have too many, merge the remainder into one final chunk.
if [ "${#CHUNKS[@]}" -gt "$MAX_CHUNKS" ]; then
    echo "packing ${#CHUNKS[@]} chunks down to ${MAX_CHUNKS}"
    _merged=""
    while [ "${#CHUNKS[@]}" -gt "$MAX_CHUNKS" ]; do
        _last="${CHUNKS[-1]}"
        unset 'CHUNKS[${#CHUNKS[@]}-1]'
        CHUNKS=("${CHUNKS[@]}")
        _merged="$_merged $_last"
    done
    if [ -n "$_merged" ]; then
        _last="${CHUNKS[-1]}"
        unset 'CHUNKS[${#CHUNKS[@]}-1]'
        CHUNKS=("${CHUNKS[@]}")
        CHUNKS+=("$_last$_merged")
    fi
fi
CHUNK_COUNT=${#CHUNKS[@]}

# ── diff-hash cache check (feature 2) ───────────────────────
CACHED_JSON=""
if [ -f "$CACHE_FILE" ]; then
    cached=$(cat "$CACHE_FILE" 2>/dev/null || echo "")
    ct=$(echo "$cached" | python3 -c "import sys,json;print(json.load(sys.stdin).get('summary',{}).get('total_findings',0))" 2>/dev/null || echo "")
    # Never reuse an empty ("clean") cache entry — it could be a model-glitch false clean.
    if [ -n "$ct" ] && [ "${ct:-0}" -gt 0 ]; then
        CACHED_JSON="$cached"
        echo "diff-hash cache hit: ${CACHE_KEY:0:10} (reusing ${ct} findings)"
    else
        echo "cache present but empty/low-confidence — re-reviewing (do not poison cache with a false clean)"
    fi
fi

# ── review_one_diff: review a single chunk (one or more files) ──
# $1 cdiff, $2 cpaths, $3 mode ("code"|"docs"). docs = all-note chunk → lighter
# review of the technical substance/claims, not code-bug hunting.
review_one_diff() {
    local cdiff="$1" cpaths="$2" mode="${3:-code}"
    [ -z "$cdiff" ] && { echo ""; return; }

    # Token-aware truncation (safety net).
    local trunc allowed lines
    trunc=$(printf '%s\n' "$cdiff" | python3 -c '
import sys
MAX_TOTAL_TOKENS = 1048500
COMPLETION_TOKENS = 138000
PROMPT_OVERHEAD_TOKENS = 2000
CHARS_PER_TOKEN = 3.0
available = MAX_TOTAL_TOKENS - COMPLETION_TOKENS - PROMPT_OVERHEAD_TOKENS
diff_text = sys.stdin.read()
n = len(diff_text.split("\n"))
if n > 0 and diff_text.split("\n")[-1] == "": n -= 1
if n == 0:
    print("FULL"); sys.exit(0)
if len(diff_text)/CHARS_PER_TOKEN <= available:
    print("FULL"); sys.exit(0)
lo, hi = 0, n
while lo < hi:
    mid = (lo + hi + 1)//2
    partial = "\n".join(diff_text.split("\n")[:mid])
    if len(partial)/CHARS_PER_TOKEN <= available: lo = mid
    else: hi = mid-1
print("TRUNCATED:%d" % lo if lo > 0 else "ALL_TRUNCATED")
' 2>/dev/null || echo "FULL")
    case "$trunc" in
        ALL_TRUNCATED) cdiff="" ;;
        TRUNCATED:*)
            allowed="${trunc#TRUNCATED:}"
            lines=$(printf '%s\n' "$cdiff" | wc -l | tr -d ' ')
            [ "$allowed" -lt "$lines" ] && cdiff=$(printf '%s\n' "$cdiff" | head -"$allowed")
            ;;
    esac

    {
        # Docs-mode (all-note chunk): lighter review of the technical substance —
        # the claims, evidence, and plan in a handoff/notes file — rather than
        # hunting for code bugs in prose. Findings still use the same JSON schema.
        if [ "$mode" = "docs" ]; then
            cat << 'PROMPT_HEADER'
请 review 以下文档 diff（.md / .txt 技术文档或交接笔记），输出 JSON 格式的审查结果。
**重要：所有审查消息（message 字段）必须使用中文，不得使用英文。**

## 背景
这是 booming-il2cpp 项目的技术文档/交接笔记变更。它通常是既有代码调查的结论固化、
或给接续者看的执行方案。**不要寻找代码 bug**——这里没有代码可查；请审查文档本身的
内容质量与技术可信度。

## 文档审查维度
1. **技术结论是否站得住**：断言是否有实测证据支撑，是否混淆了"断言"与"证据"。
2. **事实与推断分离**：哪些是观测到的硬事实、哪些是推测/假设，是否可能误导读者。
3. **交接完整性**：接续者看是否足够复现/承接，必要的复现步骤、命令、上下文上下文是否缺失。
4. **风险与后续行动**：文中声明的执行计划/方案是否有明显漏洞、遗漏或前后矛盾。
5. **一致性与命名**：与关联文档/代码术语是否一致，是否有自相矛盾的表述。
6. **不含敏感信息**：文档是否硬编码了进程私有/运行时的一次性地址、密钥、token、绝对路径
   （同类内容在本次 handoff 中已明确要求"泛化"）。

严重级别定义（rage 标准 · 4 级）：
- **严重**: 技术结论错误/无证据支撑却当作定论、交接信息会导致接续者误操作、敏感信息泄漏
- **中**: 事实与推断未分清可能误导、复现步骤缺失导致无法承接、方案存在明显漏洞
- **轻**: 前后矛盾、术语不一致、一次性绝对值未被泛化（非敏感但易误导）
- **建议**: 可选的措辞/结构/命名改进

**每个 finding 必须绑定到文档的准确位置**（`file` + `line`，可给 `line_range`）。
没有真实问题的文档应如实给 0 findings，不要为了凑数而编造。
PROMPT_HEADER
        else
            cat << 'PROMPT_HEADER'
请 review 以下 git diff，输出 JSON 格式的审查结果。
**重要：所有审查消息（message 字段）必须使用中文，不得使用英文。**

## 仓库背景

这是 booming-il2cpp 项目——一个基于 IL2CPP 技术的 C#/C++ 互操运行时。
项目定义了严格的分层架构（ATG/Codegen/TPG/Python），同时支持 AOT 和 JIT 两种执行模式。

## 七维审查体系

请从以下 7 个维度审查代码变更（每个维度同等重要）:

### 维度 1: 四层边界 — ATG / Codegen / TPG / Python 各司其职

项目有严格的分层写入规则，各层必须恪守职责:

| 层 | 路径特征 | 允许写入 | 红线 |
| ATG (AutoTestGenerator) | AutoTestGenerator | .cs, .csproj, .json | 不得生成C++ |
| Codegen (Chaos.IL2CPP.Generator) | Chaos.IL2CPP.Generator | .generated.cpp, .generated.h, .json | 必须自包含 |
| TPG (TestProjectGenerator) | TestProjectGenerator | .cpp, .h, .scriban, .cmake | 不得改.generated.* |
| Python (verification) | verification/ | .py, .json, .yaml | 不得write_text到.cpp/.h |

审核要点:
- 各层代码是否写了不属于自己职责范围的文件类型
- BOUNDARY_OVERRIDE 标记是否必要、是否已过期
- Python 脚本有没有直接 write_text 写 C++ 文件
- Codegen 的 .generated.* 输出是否自包含（没有 #include "../"）
- ATG 是否生成了 C++ 代码

### 维度 2: 测试诚信 — 禁止通过 Skip / Hack 美化数据

审核要点:
- @pytest.mark.skip / [Ignore] / [Fact(Skip=)] 是否合理，还是掩盖失败
- 测试循环中 catch 后 continue 吞掉失败
- 测试条件过于宽松（Assert.True(true)、空验证体）
- Benchmark 只跑 warmup 不跑实际测量
- 测试数据经过"挑选"只展示最好结果
- 超时时间设置不合理导致测试"假通过"

### 维度 3: 空桩实现要劲爆

暂未实现的代码必须让调用者明显感知到它是桩，不能默默返回假数据。

正确做法（劲爆）:
- throw new NotImplementedException()
- NOT_IMPLEMENTED() / NOT_SUPPORTED() 宏
- #error "not implemented for this platform"
- static_assert(false, "need implementation")
- abort() / std::terminate() + 日志
- 返回明确标记的 sentinel 值

错误做法（不劲爆，要报 中 以上）:
- return 0 / return null / return false 静默返回
- 空函数体 {} 什么也不做
- // TODO 注释但没有运行时告警
- 返回错误码但调用方不检查

### 维度 4: 平台适配性风险评估

项目通过 PAL 层支持 linux-x64 / linux-arm64 / android-arm64 / ios / windows 等多平台。

审核要点:
- 新增平台相关代码时，其他平台的对应实现是否已添加或至少声明
- #ifdef / #if 守卫是否正确（平台宏是否遗漏）
- PAL 接口变更是否同步了所有平台实现
- Android/iOS 特有代码是否有合理的 fallback 机制
- 新增依赖库是否跨平台可用
- 平台宏使用是否正确（CHAOS_IL2CPP_* vs _WIN32 vs __linux__）
- CMakeLists.txt 中平台条件编译是否完整

### 维度 5: AOT / JIT 链路正确性

项目同时支持 AOT（NativeAOT 代码生成）和 JIT（分层 JIT 编译器），两条链路不能混淆。

审核要点:
- AOT 路径代码是否调用了 JIT 特有的函数（反之亦然）
- #ifdef CHAOS_IL2CPP_JIT_MODE 守卫是否正确使用
- JIT encoder (arm64/x64) 修改是否意外影响了 AOT 代码生成
- AOT 生成的代码是否假设了 JIT 运行时结构
- 解释器 (interpreter) 中 AOT dispatch 和 JIT dispatch 是否混淆
- 预热/precode 路径在 AOT only 模式下是否正确
- 反优化(deopt)路径在 AOT 模式下是否被正确排除

### 维度 6: 文件系统合理性

审核要点:
- 不该提交的文件: *.tmp, *.log, *.user, *.suo, *.pidb
- 大型二进制文件被意外提交
- 临时构建产物（build/, output/, artifacts/ 下的生成文件）
- 目录结构是否符合项目惯例（src/managed/ vs src/native/）
- .gitignore 是否遗漏了新模式
- 敏感信息硬编码: 密钥、连接字符串、token
- 绝对路径 vs 相对路径的使用是否合理

### 维度 7: 常规 Code Review（IL2CPP 专业标准）

- 内存安全: GC 对象固定、原生指针管理、内存泄漏
- 线程安全: 全局可变状态同步、锁的正确性
- 性能: 热点路径分配、虚函数开销、缓存局部性
- 正确性: IL 语义保持、异常处理完整性
- 可维护性: 命名规范、函数长度、重复代码
- 错误处理: 所有错误路径是否被处理、日志是否恰当

## 严重级别定义（rage 标准 · 4 级：严重 / 中 / 轻 / 建议）

按高到低排序，逐级判定:

- **严重**: 维度1/2/5 违规、内存安全漏洞、安全漏洞、四层边界越界、数据损坏/错误结果
- **中**: 维度3/4 风险、线程安全缺陷、平台适配遗漏、测试诚信问题、明确的功能错误
- **轻**: 维度6 问题、错误处理不完善、性能隐患、可维护性/风格欠佳但非错误
- **建议**: 可选的优化、微重构、注释/命名改进（非必须）

**每个 finding 必须绑定到真实代码行**（`file` + `line`，可给 `line_range`），
禁止无法定位到实际代码的问题。判断失败宁可降级为 建议 也不要点到未改动的代码。

## 变更范围
PROMPT_HEADER
        fi

        echo ""
        echo "变更文件: ${cpaths}"
        echo "提交范围: ${FROM_COMMIT}..${TO_COMMIT}"
        echo "${COMMIT_LOG}"
        echo ""
        echo '```diff'
        printf '%s\n' "$cdiff"
        echo '```'
        if [ "$mode" = "docs" ]; then
            cat << 'PROMPT_FOOTER'

## 输出格式要求（rage 标准）

每条 finding 必须包含:
- **repo**: 仓库标签（本项目统一 "il2cpp"）
- **file**: 文档文件相对路径
- **line**: 问题起始行号
- **line_range**: 如适用，形如 "85-120"（跨行）或与 line 相同（单行）
- **severity**: "严重" | "中" | "轻" | "建议"
- **message**: 中文问题描述
- **fix**: 建议的修改方向（言简意赅，一行）
- **verify**: 修订后的验证目标（言简意赅，一行）

请严格输出**纯 JSON 对象**（一个合法的 JSON object，最外层必须以 `{` 开头、以 `}` 结尾）。禁止输出任何前置/后置解释文字、禁止 markdown 代码块（` ``` `）、禁止注释或尾随逗号。`summary` 必须是一个 JSON 对象（含 `严重`/`中`/`轻`/`建议`/`total_findings` 五个数字键），绝不能是字符串。直接输出以下 JSON 结构:
{
  "summary": { "严重": 0, "中": 0, "轻": 0, "建议": 0, "total_findings": 0 },
  "findings": [
    {
      "severity": "中",
      "repo": "il2cpp",
      "category": "documentation",
      "dimension": 2,
      "file": "docs/dev/in-progress/gc-align-coreclr/notes/young-collector-emptiness-refactor-handoff.md",
      "line": 85,
      "line_range": "85-90",
      "message": "文档把某次运行的进程私有绝对地址当作通用结论，接续者会误以为常量",
      "fix": "将具体地址泛化为稳定的相对关系描述",
      "verify": "文档不再包含一次性运行地址"
    }
  ],
  "commits": [
    { "sha": "abc1234", "message": "docs: handoff" }
  ]
}
PROMPT_FOOTER
        else
            cat << 'PROMPT_FOOTER'

## 输出格式要求（rage 标准）

每条 finding 必须包含:
- **repo**: 仓库标签（本项目统一 "il2cpp"）
- **file**: 文件相对路径
- **line**: 问题起始行号
- **line_range**: 如适用，形如 "85-120"（跨行）或与 line 相同（单行）；整文件问题可省略
- **severity**: "严重" | "中" | "轻" | "建议"
- **message**: 中文问题描述
- **fix**: 精确修复方案（言简意赅，一行）
- **verify**: 修复后的验证目标（言简意赅，一行）

请严格输出**纯 JSON 对象**（一个合法的 JSON object，最外层必须以 `{` 开头、以 `}` 结尾）。禁止输出任何前置/后置解释文字、禁止 markdown 代码块（` ``` `）、禁止注释或尾随逗号。`summary` 必须是一个 JSON 对象（含 `严重`/`中`/`轻`/`建议`/`total_findings` 五个数字键），绝不能是字符串。直接输出以下 JSON 结构:
{
  "summary": { "严重": 0, "中": 0, "轻": 0, "建议": 0, "total_findings": 0 },
  "findings": [
    {
      "severity": "严重",
      "repo": "il2cpp",
      "category": "layer_boundary",
      "dimension": 1,
      "file": "AutoTestGenerator/Verification/verification/some_script.py",
      "line": 85,
      "line_range": "85-90",
      "message": "Python层调用了 write_text 写入 .cpp 文件，违反四层边界",
      "fix": "将 write_text 移到 TPG 层对应的脚本中处理",
      "verify": "CPP 文件不再由 Python 脚本生成，四层边界检查通过"
    }
  ],
  "commits": [
    { "sha": "abc1234", "message": "feat: add GC optimization" }
  ]
}
PROMPT_FOOTER
        fi
    } > "$PROMPT_FILE"

    # Call claude --print for this chunk, with the configured model + a hard
    # per-chunk timeout (a hung model/proxy must NEVER block the whole build).
    OUT_CAP=$(mktemp); ERR_CAP=$(mktemp)
    set +e
    timeout "${REVIEW_CHUNK_TIMEOUT:-180}" claude --model "$REVIEW_MODEL" --print < "$PROMPT_FILE" > "$OUT_CAP" 2> "$ERR_CAP"
    RC=$?
    set -e
    CLAUDE_OUT=$(cat "$OUT_CAP")
    [ -z "$CLAUDE_OUT" ] && CLAUDE_OUT=$(cat "$ERR_CAP")
    rm -f "$OUT_CAP" "$ERR_CAP"
    if [ "$RC" != "0" ]; then
        echo ""; return
    fi

    # Robust JSON extraction (finding messages may contain braces).
    local extracted
    extracted=$(echo "$CLAUDE_OUT" | python3 -c '
import sys, json
content = sys.stdin.read()
def strip_fences(s):
    out = []; in_block = False
    for line in s.splitlines():
        st = line.strip()
        if st.startswith("```"):
            in_block = not in_block; continue
        if not in_block: out.append(line)
    return "\n".join(out)
def find_json_object(s):
    depth = 0; start = None
    for i, ch in enumerate(s):
        if ch == "{":
            if depth == 0: start = i
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0 and start is not None:
                cand = s[start:i+1]
                try:
                    obj = json.loads(cand)
                    if isinstance(obj, dict) and isinstance(obj.get("summary"), dict):
                        return obj
                except Exception:
                    pass
                start = None
    return None
obj = None
for src in (strip_fences(content), content):
    obj = find_json_object(src)
    if obj is not None: break
if obj is None:
    sys.exit(2)
print(json.dumps(obj, ensure_ascii=False))
' 2>/dev/null)
    echo "$extracted"
}

# ── If cached, short-circuit to the cached result ───────────
if [ -n "$CACHED_JSON" ]; then
    echo "$CACHED_JSON" > "$OUTPUT_FILE"
    CRIT=$(echo "$CACHED_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin); s = d.get('summary', {})
    print(s.get('严重', 0), s.get('中', 0), s.get('轻', 0), s.get('建议', 0), s.get('total_findings', 0))
except Exception:
    print('0 0 0 0 0')
")
    read -r SEV_CRIT SEV_MED SEV_LIGHT SEV_ADV TOTAL_COUNT <<< "$CRIT"
    echo "Reviewed ${FILTERED_COUNT} reviewable files, ${COMMIT_COUNT} commits (${FROM_COMMIT}..${TO_COMMIT}) [cached]"
    echo "Findings: ${SEV_CRIT} 严重 · ${SEV_MED} 中 · ${SEV_LIGHT} 轻 · ${SEV_ADV} 建议"
    echo "Output: ${OUTPUT_FILE}"
    exit 0
fi

# ── Aggregation over chunks ─────────────────────────────────
AGG_SUM=$'{"严重":0,"中":0,"轻":0,"建议":0,"total_findings":0}'
AGG_FIND="[]"
CHUNK_FAILED=0
INCOMPLETE=0
CHUNK_IDX=0
# The chunk loop calls claude and pipes its output through extractors; a glitchy
# model answer or a transient pipe failure must NOT abort the whole script under
# `set -e` with a cryptic code. Run the loop under set +e and let the explicit
# CHUNK_FAILED/empty-retry logic below own error reporting.
set +e
for chunk_paths in "${CHUNKS[@]:-}"; do
    [ -z "${chunk_paths// /}" ] && continue
    CHUNK_IDX=$((CHUNK_IDX+1))
    # strip leading space
    chunk_paths="${chunk_paths#" "}"
    echo "reviewing chunk $CHUNK_IDX/${CHUNK_COUNT}: ${chunk_paths}"
    cdiff=$(chunk_diff_for $chunk_paths)
    [ -z "$cdiff" ] && continue
    # Is everything in this chunk a note file? (then 0-findings is plausible.)
    all_note=1
    for f in $chunk_paths; do
        [ "$(is_note_path "$f")" = "0" ] && { all_note=0; break; }
    done
    chunk_mode="code"; [ "$all_note" = "1" ] && chunk_mode="docs"
    chunk_find=""; chunk_sum=""; attempts=0
    while [ -z "$chunk_find" ] && [ "$attempts" -le "$MAX_EMPTY_RETRIES" ]; do
        attempts=$((attempts+1))
        js=$(review_one_diff "$cdiff" "$chunk_paths" "$chunk_mode")
        if [ -z "$js" ]; then
            echo "  chunk '$chunk_paths' claude/parse error — retry $attempts/$MAX_EMPTY_RETRIES"
            continue
        fi
        mapfile -t SF < <(echo "$js" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    s = d.get("summary", {})
    print(json.dumps(s, ensure_ascii=False))
    print(json.dumps(d.get("findings", []), ensure_ascii=False))
except Exception:
    print("{\"严重\":0,\"中\":0,\"轻\":0,\"建议\":0,\"total_findings\":0}")
    print("[]")
')
        ssum="${SF[0]:-}"; sfind="${SF[1]:-}"
        total=$(echo "$ssum" | python3 -c "import sys,json;print(json.load(sys.stdin).get('total_findings',0))" 2>/dev/null)
        if [ "$total" -eq 0 ] && [ "$all_note" -eq 0 ] && [ "$attempts" -le "$MAX_EMPTY_RETRIES" ]; then
            echo "  chunk '$chunk_paths' returned 0 findings — retry $attempts/$MAX_EMPTY_RETRIES (model may have glitched)"
            continue
        fi
        chunk_find="$sfind"; chunk_sum="$ssum"
        break
    done
    if [ -z "$chunk_find" ]; then
        # Model glitched on this chunk after retries. Do NOT fail the whole build
        # (that's what spams Feishu with "构建失败"). Skip this chunk, mark the
        # review incomplete, and let the other chunks still contribute. The final
        # result will be flagged low_confidence so it isn't presented as a clean
        # pass / a definitive all-files review.
        echo "WARNING: could not review '$chunk_paths' after retries — skipping (模型异常，此文件稍后未覆盖)" >&2
        INCOMPLETE=1
        continue
    fi
    AGG_SUM=$(python3 - "$AGG_SUM" "$chunk_sum" <<'PY'
import sys, json
a = json.loads(sys.argv[1]); b = json.loads(sys.argv[2])
for k in ("严重","中","轻","建议"):
    a[k] = a.get(k,0) + b.get(k,0)
a["total_findings"] = a.get("严重",0)+a.get("中",0)+a.get("轻",0)+a.get("建议",0)
print(json.dumps(a, ensure_ascii=False))
PY
)
    AGG_FIND=$(python3 - "$AGG_FIND" "$chunk_find" <<'PY'
import sys, json
a = json.loads(sys.argv[1]); b = json.loads(sys.argv[2])
a = a + b if isinstance(a, list) else b
print(json.dumps(a, ensure_ascii=False))
PY
)
done
set -e

# If some chunks glitched and were skipped (INCOMPLETE), the build must NOT go
# RED / spam "构建失败" — that's the exact pain. Instead force low_confidence and
# continue so the card says "部分文件审查未覆盖（模型异常）" with whatever WAS
# reviewed. Only a genuine full-pipeline failure (below, none) would hard-fail.
if [ "$INCOMPLETE" != "0" ]; then
    echo "WARNING: some chunks were skipped due to model output errors — review is partial, flagged low_confidence." >&2
fi

# ── Low-confidence marker (feature 4) ───────────────────────
# If the aggregated result is 0 findings on substantive (non-all-note) code, OR any
# chunk was skipped (INCOMPLETE), mark low_confidence so the card shows a wary note
# instead of a flat clean pass / a definitive all-files review.
_TOTAL=$(echo "$AGG_SUM" | python3 -c "import sys,json;print(json.load(sys.stdin).get('total_findings',0))" 2>/dev/null)
LOW_CONF=false
if [ "$INCOMPLETE" != "0" ]; then
    LOW_CONF=true
    echo "WARNING: review incomplete (one or more chunks skipped) — marking low_confidence"
fi
if [ "$LOW_CONF" = "false" ] && [ "$_TOTAL" -eq 0 ]; then
    # substantive code present? (any non-note file)
    any_code=0
    for f in "${ALL_FILES[@]:-}"; do
        [ "$(is_note_path "$f")" = "0" ] && { any_code=1; break; }
    done
    if [ "$any_code" = "1" ]; then
        LOW_CONF=true
        echo "WARNING: 0 findings on substantive code — marking low_confidence (model glitch possible)"
    fi
fi

_FROM_SHORT=$(echo "${FROM_COMMIT}" | cut -c1-7)
# docs_only: the reviewed range contains NO substantive code — only note/text docs.
# Used by the card to distinguish "纯文档变更" from a real code clean-pass.
DOCS_ONLY=false
any_code=0
for f in "${ALL_FILES[@]:-}"; do
    [ "$(is_note_path "$f")" = "0" ] && { any_code=1; break; }
done
[ "$any_code" = "0" ] && DOCS_ONLY=true
# Sort the aggregated findings by severity (严重>中>轻>建议) so every downstream
# consumer (report, card, GitLab comment) sees a deterministic, severity-ordered list.
AGG_FIND=$(python3 - "$AGG_FIND" <<'PY'
import sys, json
order = {"严重": 0, "中": 1, "轻": 2, "建议": 3}
fs = json.loads(sys.argv[1])
fs.sort(key=lambda f: order.get(f.get("severity", "建议"), 9))
# stable: keep model order within same severity
print(json.dumps(fs, ensure_ascii=False))
PY
)
CLAUDE_JSON=$(python3 - "$AGG_SUM" "$AGG_FIND" "$_FROM_SHORT" "$LOW_CONF" "$INCOMPLETE" "$DOCS_ONLY" <<'PY'
import sys, json
print(json.dumps({
    "summary": json.loads(sys.argv[1]),
    "findings": json.loads(sys.argv[2]),
    "commits": [{"sha": sys.argv[3], "message": "reviewed range"}],
    "low_confidence": sys.argv[4] == "true",
    "incomplete": sys.argv[5] == "1",
    "docs_only": sys.argv[6] == "true",
}, ensure_ascii=False))
PY
)
echo "$CLAUDE_JSON" > "$OUTPUT_FILE"

# Write cache ONLY for non-empty results (never poison with a false clean).
if [ "$_TOTAL" -gt 0 ]; then
    mkdir -p "$CACHE_DIR"
    printf '%s' "$CLAUDE_JSON" > "$CACHE_FILE"
    echo "cached result (${_TOTAL} findings) → ${CACHE_FILE}"
else
    echo "0 findings; not caching (keeps a possible model glitch from becoming a cached clean)"
fi

CRIT=$(echo "$CLAUDE_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin); s = d.get('summary', {})
    print(s.get('严重', 0), s.get('中', 0), s.get('轻', 0), s.get('建议', 0), s.get('total_findings', 0))
except Exception:
    print('0 0 0 0 0')
")
IFS=' ' read -r SEV_CRIT SEV_MED SEV_LIGHT SEV_ADV TOTAL_COUNT <<< "$CRIT"

echo "Reviewed ${FILTERED_COUNT} reviewable files, ${COMMIT_COUNT} commits (${FROM_COMMIT}..${TO_COMMIT}) in ${CHUNK_COUNT} chunk(s)"
_LC_FLAG=""
[ "$LOW_CONF" = "true" ] && _LC_FLAG=" · ⚠low-confidence"
echo "Findings: ${SEV_CRIT} 严重 · ${SEV_MED} 中 · ${SEV_LIGHT} 轻 · ${SEV_ADV} 建议${_LC_FLAG}"
echo "Output: ${OUTPUT_FILE}"
