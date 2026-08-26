#!/bin/bash
# review-with-claude.sh — Invoke Claude Code CLI to review git diff
#
# Reviews the diff between two commits for high-risk patterns, producing a rage
# standard JSON result (severity 严重/中/轻/建议 + `[Repo] file:line` findings).
#
# Reliability: the model (deepseek-v4-flash via the llm proxy) is unreliable on
# LARGE multi-file diffs — it flips between real findings, raw Python tracebacks,
# and valid-but-empty "0 findings".  To make results trustworthy:
#   * the diff is reviewed PER-CHANGED-FILE (one small, focused chunk each), which
#     the model handles reliably, then aggregated;
#   * a chunk that returns 0 findings for a substantive code file is RETRIED
#     (default REVIEW_MAX_EMPTY_RETRIES=2) because empty is likely a glitch;
#   * genuinely unparseable output FAILS LOUDLY (non-zero exit) rather than
#     fabricating a "未发现代码问题" card.
#
# Usage:
#   review-with-claude.sh --repo-dir <path> --from-commit <sha> --to-commit <sha> \
#       --output <path> [--max-diff-lines 50000]
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

EXTS_KEEP = (".cs", ".cpp", ".h", ".hpp", ".py", ".scriban", ".cmake", ".yaml", ".yml")

def is_excluded(path):
    """Return True if a file path should be excluded from code review."""
    # Directory-based exclusions
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

    # Filename-based exclusions
    if basename == "CombinedSubjects.cs":
        return True
    if basename.endswith(".deps.json"):
        return True
    if ".generated." in basename:
        return True
    if "/obj/" in path and basename.endswith(".g.cs"):
        return True

    # Extension-based exclusions
    for ext in (".md", ".html", ".txt", ".dll", ".pdb", ".exe", ".lib",
                ".svg", ".png", ".jpg", ".jpeg", ".jdata", ".jsonl"):
        if path.endswith(ext):
            return True

    # Only keep known source/build extensions
    if any(basename.endswith(e) for e in EXTS_KEEP):
        return False
    return True  # exclude everything else

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    parts = line.split("\t")
    # Rename/copy: status\told_path\tnew_path — take new_path
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

# Capture file names before potentially deleting the file
FILTERED_FILE_NAMES=""
if [[ "$FILTERED_COUNT" -gt 0 ]]; then
    FILTERED_FILE_NAMES=$(cat "$FILTERED_PATHS_FILE" 2>/dev/null || true)
fi

if [[ "$FILTERED_COUNT" -eq 0 ]]; then
    echo "WARNING: All files excluded by noise filters (no reviewable changes)" >&2
    rm -f "$FILTERED_PATHS_FILE"
    echo "Reviewed 0 reviewable files"
    echo "Findings: 0"
    echo '{"meta":{"from":"'"${FROM_COMMIT}"'","to":"'"${TO_COMMIT}"'"},"summary":{"严重":0,"中":0,"轻":0,"建议":0,"total_findings":0},"findings":[],"commits":[]}' > "$OUTPUT_FILE"
    exit 0
fi

echo "Filtered ${FILTERED_COUNT} reviewable files (out of $(echo "$CHANGED_FILES_LIST" | grep -c . || true) total changed)"

rm -f "$FILTERED_PATHS_FILE"

# ──────────────────────────────────────────────────────────────
# Chunked review — review EACH changed file as its own small diff, then aggregate.
#
# The model is unreliable on LARGE multi-file diffs.  A single file's diff is
# small and focused — the model handles those reliably.  We also retry a chunk
# whose review comes back empty when the file is substantive code (not docs),
# because an empty result is more likely a model glitch than a genuine all-clean.
# ──────────────────────────────────────────────────────────────
MAX_EMPTY_RETRIES="${REVIEW_MAX_EMPTY_RETRIES:-2}"   # retries per chunk on empty/error result
PROMPT_FILE=$(mktemp)
trap "rm -f '$PROMPT_FILE'" EXIT

# Per-file diff between the two commits.
chunk_diff_for() {
    local p="$1"
    git diff "${FROM_COMMIT}".."${TO_COMMIT}" -- "$p" 2>/dev/null
}

# review_one_diff <diff-text> <path>  →  echoes finding JSON on stdout, or "" on failure.
review_one_diff() {
    local cdiff="$1" cpath="$2"
    [ -z "$cdiff" ] && { echo ""; return; }

    # Token-aware truncation (safety net). deepseek-v4-flash budget ~1048500
    # tokens; reserve the 131072 completion (effort=max) + overhead, ~3 chars/token.
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

    # Build the prompt for THIS chunk only (same rubric header/footer).
    {
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
        echo ""
        echo "变更文件: $cpath"
        echo "提交范围: ${FROM_COMMIT}..${TO_COMMIT}"
        echo "${COMMIT_LOG}"
        echo ""
        echo '```diff'
        printf '%s\n' "$cdiff"
        echo '```'
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

请严格输出以下 JSON 结构（不要包含其他说明文字，不要用 markdown 代码块包裹）:
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
    } > "$PROMPT_FILE"

    # Call claude --print for this chunk.
    OUT_CAP=$(mktemp); ERR_CAP=$(mktemp)
    set +e
    claude --print < "$PROMPT_FILE" > "$OUT_CAP" 2> "$ERR_CAP"
    RC=$?
    set -e
    CLAUDE_OUT=$(cat "$OUT_CAP")
    [ -z "$CLAUDE_OUT" ] && CLAUDE_OUT=$(cat "$ERR_CAP")
    rm -f "$OUT_CAP" "$ERR_CAP"
    if [ "$RC" != "0" ]; then
        echo ""   # claude itself errored → caller retries
        return
    fi

    # Robust JSON extraction — see notes: finding messages may contain braces, so
    # a naive first-{/last-} grab returns a malformed slice.  Locate the OUTERMOST
    # balanced '{...}' object and validate with json.loads (require a `summary`).
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

# ── Review each changed file as its own chunk, aggregate ──
AGG_SUM=$'{"严重":0,"中":0,"轻":0,"建议":0,"total_findings":0}'
AGG_FIND="[]"
CHUNK_FAILED=0
# Iterate FILTERED_FILE_NAMES one path per line (no IFS override — repo paths
# contain no spaces, so default splitting is safe and avoids leaking IFS abroad).
for cpath in $FILTERED_FILE_NAMES; do
    [ -z "$cpath" ] && continue
    cpath="${cpath//$'\r'/}"
    cdiff=$(chunk_diff_for "$cpath")
    [ -z "$cdiff" ] && continue
    echo "reviewing chunk: $cpath"
    chunk_find=""
    chunk_sum=""
    attempts=0
    # docs/notes file — a 0-findings result there is plausibly genuine.
    is_note=0
    case "$cpath" in
        *.md) is_note=1 ;;
        *.txt) is_note=1 ;;
    esac
    while [ -z "$chunk_find" ] && [ "$attempts" -le "$MAX_EMPTY_RETRIES" ]; do
        attempts=$((attempts+1))
        js=$(review_one_diff "$cdiff" "$cpath")
        if [ -z "$js" ]; then
            echo "  chunk '$cpath' claude/parse error — retry $attempts/$MAX_EMPTY_RETRIES"
            continue
        fi
        # extract summary + findings (two lines: summary, then findings array)
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
        # retry empty result on substantive code (likely a model glitch)
        if [ "$total" -eq 0 ] && [ "$is_note" -eq 0 ] && [ "$attempts" -le "$MAX_EMPTY_RETRIES" ]; then
            echo "  chunk '$cpath' returned 0 findings — retry $attempts/$MAX_EMPTY_RETRIES (model may have glitched)"
            continue
        fi
        chunk_find="$sfind"; chunk_sum="$ssum"
        break
    done
    if [ -z "$chunk_find" ]; then
        echo "ERROR: could not get a reviewed result for '$cpath' after retries" >&2
        CHUNK_FAILED=1
        continue
    fi
    # Aggregate summary
    AGG_SUM=$(python3 - "$AGG_SUM" "$chunk_sum" <<'PY'
import sys, json
a = json.loads(sys.argv[1]); b = json.loads(sys.argv[2])
for k in ("严重","中","轻","建议"):
    a[k] = a.get(k,0) + b.get(k,0)
a["total_findings"] = a.get("严重",0)+a.get("中",0)+a.get("轻",0)+a.get("建议",0)
print(json.dumps(a, ensure_ascii=False))
PY
)
    # Aggregate findings
    AGG_FIND=$(python3 - "$AGG_FIND" "$chunk_find" <<'PY'
import sys, json
a = json.loads(sys.argv[1]); b = json.loads(sys.argv[2])
a = a + b if isinstance(a, list) else b
print(json.dumps(a, ensure_ascii=False))
PY
)
done

if [ "$CHUNK_FAILED" != "0" ]; then
    echo "ERROR: one or more chunks failed to produce a review — refusing to emit a partial/false result." >&2
    exit 1
fi

# ── Write aggregated findings ──
_FROM_SHORT=$(echo "${FROM_COMMIT}" | cut -c1-7)
CLAUDE_JSON=$(python3 - "$AGG_SUM" "$AGG_FIND" "$_FROM_SHORT" <<'PY'
import sys, json
print(json.dumps({
    "summary": json.loads(sys.argv[1]),
    "findings": json.loads(sys.argv[2]),
    "commits": [{"sha": sys.argv[3], "message": "reviewed range"}],
}, ensure_ascii=False))
PY
)
echo "$CLAUDE_JSON" > "$OUTPUT_FILE"

# Parse summary for stdout reporting (rage 4-tier: 严重 中 轻 建议)
CRIT=$(echo "$CLAUDE_JSON" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    s = d.get('summary', {})
    print(s.get('严重', 0), s.get('中', 0), s.get('轻', 0), s.get('建议', 0), s.get('total_findings', 0))
except Exception:
    print('0 0 0 0 0')
" 2>/dev/null || echo "0 0 0 0 0")

IFS=' ' read -r SEV_CRIT SEV_MED SEV_LIGHT SEV_ADV TOTAL_COUNT <<< "$CRIT"

echo "Reviewed ${FILTERED_COUNT} reviewable files, ${COMMIT_COUNT} commits (${FROM_COMMIT}..${TO_COMMIT})"
echo "Findings: ${SEV_CRIT} 严重 · ${SEV_MED} 中 · ${SEV_LIGHT} 轻 · ${SEV_ADV} 建议"
echo "Output: ${OUTPUT_FILE}"