#!/bin/bash
# review-with-claude.sh — Invoke Claude Code CLI to review git diff
#
# Calls `claude --print` with a structured skill prompt that asks Claude
# to analyze the diff between two commits for high-risk patterns.
#
# Usage:
#   review-with-claude.sh --repo-dir <path> --from-commit <sha> --to-commit <sha> \
#       --output <path> [--max-diff-lines 50000]
#
# Output:
#   - Writes findings JSON to --output path
#   - Prints summary line to stdout for pipeline consumption

set -euo pipefail

REPO_DIR=""
FROM_COMMIT=""
TO_COMMIT=""
OUTPUT_FILE=""
MAX_DIFF_LINES=50000

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
    echo '{"meta":{"from":"'"${FROM_COMMIT}"'","to":"'"${TO_COMMIT}"'"},"summary":{"critical":0,"high":0,"medium":0,"low":0,"total_findings":0},"findings":[],"commits":[]}' > "$OUTPUT_FILE"
    echo "Reviewed 0 commits"
    echo "Findings: 0"
    exit 0
fi

# Gather diff, truncate if too large
DIFF=$(git diff "${FROM_COMMIT}".."${TO_COMMIT}" 2>/dev/null || true)
DIFF_LINES=$(echo "$DIFF" | wc -l)
DIFF_TRUNCATED=false
if [[ "$DIFF_LINES" -gt "$MAX_DIFF_LINES" ]]; then
    DIFF=$(echo "$DIFF" | head -"$MAX_DIFF_LINES")
    DIFF_TRUNCATED=true
fi

# Write diff to temp file to avoid shell quoting issues
DIFF_FILE=$(mktemp)
trap "rm -f '$DIFF_FILE'" EXIT
printf '%s\n' "$DIFF" > "$DIFF_FILE"

# Build prompt and pipe to claude --print via heredoc + temp file
# Using quoted heredocs (<<'EOF') for fixed text to prevent any shell interpolation.
# The diff is read from a temp file, completely avoiding quoting issues.
CLAUDE_OUTPUT=$({
    cat << 'PROMPT_HEADER'
请 review 以下 git diff，输出 JSON 格式的审查结果。

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

错误做法（不劲爆，要报 HIGH）:
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

## 严重级别定义

- **CRITICAL**: 维度1/2/5 违规、内存安全漏洞、安全漏洞、四层边界越界
- **HIGH**: 维度3/4 风险、线程安全缺陷、平台适配遗漏、测试诚信问题
- **MEDIUM**: 维度6 问题、常规质量缺陷、错误处理不完善
- **LOW**: 格式问题、注释遗留、小优化建议

## 变更范围
PROMPT_HEADER
    echo ""
    echo "从 ${FROM_COMMIT} 到 ${TO_COMMIT}"
    echo "提交列表:"
    echo "${COMMIT_LOG}"
    echo ""
    echo '```diff'
    cat "$DIFF_FILE"
    echo '```'
    echo ""
    if [ "$DIFF_TRUNCATED" = true ]; then
        echo ""
        echo "**注意:** diff 超过 ${MAX_DIFF_LINES} 行，已截断。"
        echo ""
    fi
    cat << 'PROMPT_FOOTER'
## 输出格式要求

请严格输出以下 JSON 结构（不要包含其他说明文字，不要用 markdown 代码块包裹）:
{
  "summary": { "critical": 0, "high": 0, "medium": 0, "low": 0, "total_findings": 0 },
  "findings": [
    {
      "severity": "CRITICAL",
      "category": "layer_boundary",
      "dimension": 1,
      "file": "testing/foundation-dll/verification/some_script.py",
      "line": 85,
      "message": "Python层调用了 write_text 写入 .cpp 文件，违反四层边界"
    }
  ],
  "commits": [
    { "sha": "abc1234", "message": "feat: add GC optimization" }
  ]
}
PROMPT_FOOTER
} | claude --print) || {
    echo "ERROR: claude --print failed" >&2
    exit 1
}

# Write Claude output to findings file
echo "$CLAUDE_OUTPUT" > "$OUTPUT_FILE"

# Parse summary for stdout reporting
CRIT=$(echo "$CLAUDE_OUTPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    s = d.get('summary', {})
    print(s.get('critical', 0), s.get('high', 0), s.get('medium', 0), s.get('low', 0), s.get('total_findings', 0))
except Exception:
    print('0 0 0 0 0')
" 2>/dev/null || echo "0 0 0 0 0")

read -r CRIT_COUNT HIGH_COUNT MEDIUM_COUNT LOW_COUNT TOTAL_COUNT <<< "$CRIT"

echo "Reviewed ${COMMIT_COUNT} commits (${FROM_COMMIT}..${TO_COMMIT})"
echo "Findings: ${CRIT_COUNT} CRITICAL · ${HIGH_COUNT} HIGH · ${MEDIUM_COUNT} MEDIUM · ${LOW_COUNT} LOW"
echo "Output: ${OUTPUT_FILE}"
