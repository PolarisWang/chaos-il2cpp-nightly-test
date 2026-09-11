# IL2CPP Nightly Build — 综合报告与优化方案

> 生成时间: 2026-09-11 · 数据源: build 263（最新）+ Windows 最新 run `20260911_041547-2250e18f7`
> 引擎 HEAD: `2250e18f7` · Jenkins job: `chaos-il2cpp-nightly`

---

## 一、整体流程现状

```
Jenkins (chaos-il2cpp-nightly, linux-x64 agent 调度)
│
├─ Init      下载 helper 脚本 → 记录 ARTIFACTS_DIR
├─ Dispatch  JOB_NAME 路由（code-review → runCodeReview；否则走 nightly）
│
└─ Stage: Full Pipeline (x64 + Windows)  ← 并行两分支
   │
   ├─ linux-x64 分支
   │   ├─ git archive origin/main | tar -x  → <workspace>/engine-src（纯净树，无 .git）
   │   ├─ cd engine-src/tests/e2e
   │   ├─ python3 -m verification.nightly.cli --max-workers 4
   │   └─ python3 publish-nightly-results.py --report-dir engine-src/.../summary
   │
   └─ windows-x64 分支
       ├─ git fetch --depth=1 + reset --hard origin/main  （同步 D:\agent\workspace\booming-il2cpp）
       ├─ 加载 vcvars64（vswhere 自发现）
       ├─ SDK 预检 build_presets.py --preset windows-x64-reference
       ├─ cd tests/e2e
       ├─ python -m verification.nightly.cli --max-workers 24
       └─ 回显 report tree + summary + 最新 chunk 日志到控制台
```

---

## 二、当前结果（build 263 + 最新 Windows run）

| 平台 | 结果 | 说明 |
|---|---|---|
| **linux-x64** | ❌ **完全失败**（FileNotFoundError） | foundation 目录解析错误，一个 chunk 都没跑 |
| **windows-x64** | ⚠️ **20/45 passed** | 引擎侧修复生效后大幅改善（曾 0/45） |

### Windows 错误分布（20/45 passed, 25 failed）

| Error class | 数量 | 趋势 |
|---|---|---|
| ✅ passed | **20** | ⬆️ 从 0 提升 |
| `csharp-error` | 8 | ATG 生成代码在 net8.0 编译失败 |
| `atg-combined-cs` | 7 | CombinedSubjects 合成异常 |
| `native-linker-error` | 5 | ⬇️ 从 39 降下来（corecrt 已修），剩新符号 |
| `unknown` | 5 | 待确认 |

### 失败 chunk 清单（Windows）
**translation-defect (15)**: System.ObjectModel, System.IO.Pipelines, System.IO.Compression.ZipFile, System.Linq, System.Formats.Asn1, System.Data.Common, System.Net.ServerSentEvents, System.Private.Xml, System.Diagnostics.DiagnosticSource×2, System.Runtime.Serialization.Formatters, System.Text.Json, System.Security.Cryptography, System.Reflection.Metadata, System.ComponentModel.TypeConverter
**code/native-crash (10)**: System.Private.Xml, System.Runtime.Intrinsics, System.Net.Sockets, System.Xml.ReaderWriter×3, System.Runtime.InteropServices, System.Text.Json, System.Security.Cryptography×2

---

## 三、🔴 当前问题（按严重度）

### 问题 1（P0）：Linux 分支完全跑不起来 —— foundation 路径解析

**现象**: `FileNotFoundError: Foundation dir not found: .../engine-src/tests/e2e/testing/foundation-dll`

**根因**（已定位到代码）:
```python
# engine: tests/e2e/verification/nightly/config.py:21-42
def _detect_repo_root():
    for _ in range(10):
        if (p / ".git").is_dir():   # ← 依赖 .git/ 作为 repo 根标记
            return p
        p = p.parent
    return Path.cwd()               # ← git archive 树没有 .git/ → 回退到这里

def _detect_foundation_dir():
    repo = _detect_repo_root()
    candidate = repo / "tests" / "e2e" / "translation"   # ← 从这里找
    ...
    return repo / "testing" / "foundation-dll"           # ← 或回退
```

Jenkinsfile 的 Linux 分支用 `git archive origin/main | tar -x` 抽出引擎树 —— **`git archive` 不包含 `.git/` 目录**。于是：
1. `_detect_repo_root()` 向上 10 层找不到 `.git/` → 返回 `Path.cwd()`
2. cwd = `engine-src/tests/e2e`（nightly.cli 的运行目录）
3. candidate = `engine-src/tests/e2e/tests/e2e/translation` ✗ 不存在
4. fallback = `engine-src/tests/e2e/testing/foundation-dll` ✗ 不存在
5. → `FileNotFoundError`

**这是 Jenkinsfile 的 `git archive` 方案与引擎的 `.git` 根探测不兼容** —— 我在方案 A（干净树）里引入的回归。

### 问题 2（P1）：Windows 产出 20/45，但 25 个失败未解决

两个主要失败类：
- **csharp-error (8)** + **atg-combined-cs (7)**: `CombinedSubjects.cs` 引用 net10 才有的 API（`AggregateBy`/`CountBy`），但 `CombinedSubjects.csproj` 目标框架是 net8.0。
- **native-linker-error (5)**: corecrt 已修，剩 5 个新符号（尚未确认具体是什么）。
- **unknown (5)**: 未分类。

### 问题 3（P2）：Windows 最新 run 的 summary 未更新（陈旧）

Windows `nightly-summary.md` / `nightly-result.json` 的时间戳是 **03:20 AM**，但最新 run 是 **04:15**（`20260911_041547-2250e18f7`）。说明最新一轮跑完后 **summary 没被写出**。

引擎的 handoff 文档也提到了这条：「遗留问题：... nightly summary 未写出」。

### 问题 4（P2）：Windows 分支 exit code 9009

build 263 的 Windows 分支以 `exit code 9009` 结束（9009 = cmd 的 "command not found"）。需定位是哪条命令 —— 大概率是我在 `bat` 里加的某条诊断命令（`where` / `for /f`）在特定环境不可用。

### 问题 5（P3）：报告分发链路不完整

- Windows 的产物落在 `D:\agent\workspace\...\nightly-build-report\`，**没有回传到 Jenkins master** —— Linux 侧 publish 读不到 Windows 结果。
- 两平台的报告是**各自独立**的，最终飞书卡片只反映 Linux 侧（而 Linux 侧现在是 0/45 失败）。

---

## 四、优化方案列表

### P0 — 立刻修：Linux 分支 foundation 路径

| 方案 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **A（推荐）** | Jenkinsfile 里 export `CHAOS_FOUNDATION_DLL=${engTree}/tests/e2e/translation` | 1 行改动，零风险；引擎已有该 env 覆盖入口 | 需同时设 `CHAOS_TESTING_DIR`（若引擎用） |
| B | `git archive` 后 `mkdir -p ${engTree}/.git`（假标记） | 让 `_detect_repo_root` 正常工作 | hack，可能干扰其他 `.git` 检测逻辑 |
| C | 不用 `git archive`，改用 `git worktree add` | 保留 `.git`，引擎自然工作 | worktree 有锁/状态，且之前已弃用此路 |
| D | 引擎侧改 `_detect_repo_root` 支持 `CLAUDE.md`/`CMakeLists.txt` 标记 | 更健壮 | 需引擎 PR，周期长 |

**推荐 A**：立即可做、无副作用。同时验证是否需要 `CHAOS_TESTING_DIR`。

### P1 — csharp-error / atg-combined-cs（15 个 chunk）

| 方案 | 做法 |
|---|---|
| A | 让 ATG 检测目标框架，net8.0 时**跳过** net10 特有 API 的 wrapper 生成 |
| B | `CombinedSubjects.csproj` 升到 net10.0（若环境有 SDK） |
| C | 确认 `AggregateBy`/`CountBy` 是否真的是测试目标 —— 若是，保留并升级 TFM |

**需引擎团队决策**（涉及测试覆盖面）。

### P1 — 剩余 5 个 native-linker-error

先确认新符号是什么（我上次读取时被 shell 引号问题挡住）。定位后按 corecrt 同思路修（MSVC/SDK 版本或条件编译）。

### P2 — summary 未写出

修 `verification.nightly.aggregate` 的 `aggregate_reports()` —— 确认异常路径为「静默返回」还是「抛异常被吞」。建议：无论 chunk 结果如何，**总是**写出 summary（哪怕全失败）。

### P2 — exit code 9009

定位 Windows 分支哪条命令返回 9009 并修（或加容错）。

### P3 — 报告分发

| 方案 | 做法 |
|---|---|
| A | Windows 分支跑完后 `archiveArtifacts` / `stash` 产物，master 侧 unstage 后合并 |
| B | Windows 直接把 summary.json scp/推到 master 的 report-server 目录 |
| C | 若两平台结果本就应独立，明确在飞书卡中分平台展示 |

---

## 五、优先级总表

| # | 问题 | 优先级 | 工作量 | 归属 |
|---|---|---|---|---|
| 1 | Linux foundation 路径（git archive 无 .git） | **P0** | 1 行 Jenkinsfile | 我 |
| 2 | csharp-error + atg-combined-cs | P1 | 引擎改动 | 引擎团队 |
| 3 | 剩余 5 个 native-linker-error | P1 | 需先定位 | 引擎团队 |
| 4 | summary 未写出 | P2 | 引擎改动 | 引擎团队 |
| 5 | Windows exit 9009 | P2 | 定位+修 | 我 |
| 6 | 报告分发（Windows→master） | P3 | Jenkinsfile 改动 | 我 |

---

## 六、观测通道（复用）

```bash
# Windows SSH（公钥免密）
ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197'

# 最新 run 的 chunk 日志
R=$(ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' \
  "cmd /c dir /b /o-d D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs" | head -1)

# Jenkins 触发
curl -u admin:admin -X POST \
  'http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters' \
  --data-urlencode 'BOOMING_REPO=/home/debian/agent/booming-il2cpp' \
  --data-urlencode 'WINDOWS_BOOMING_DIR=D:/agent/workspace/booming-il2cpp' \
  --data-urlencode 'BUILD_CONFIG=profile'
```
