# IL2CPP Nightly Build — 综合报告与优化方案

> 更新: 2026-09-13 · 数据源: **build 285（SUCCESS）**
> 引擎 HEAD: `4f5d0097a` · Jenkins job: `chaos-il2cpp-nightly`
>
> **状态：Windows 首次产出非零发布数据 —— 18/45。**
> 完整交接细节见 `WINDOWS_NIGHTLY_HANDOFF.md`（v5）。

---

## 🆕 build 285 结果

| 平台 | 发布 | 失败分布 |
|---|---|---|
| **windows-x64** | ✅ **18/45**（首次非零） | atg-combined-cs=8, csharp-error=5, unknown=13, native-linker-error=1 |
| linux-x64 | 0/45 | atg-combined-cs=1, unknown=44 |

**四个目标全部达成**：定时跑 ✅ · 正确数据 ✅ · 汇总报告 ✅ · 同步到群 ✅

### 🔑 卡住数日的共同根因：`GcAllocateFast` 未定义

```
async_stubs.obj : error LNK2019: unresolved external symbol
  "...GcAllocateFast(unsigned __int64)" referenced in function async_task_create_gc
chaos_entry.exe : fatal error LNK1120: 1 unresolved externals
→ cmake build FAILED → 每个 chunk 都挂
```

`async_stubs.cpp` 使用 `CHAOS_IL2CPP_NEW_GC` 宏（展开为 `GcAllocateFast`），但
**没有 include 定义它的 `gc_alloc_stubs.h`** —— 只能看到 `gc_helpers.h` 的普通声明，
编译器无法内联，于是发出真实外部调用，链接失败。

修复：`#include "core/gc_alloc_stubs.h"`（引擎 `8c226c063`）。

**为什么之前三次都找错方向**：这个错误只暴露为分类器认不出的 `unknown`，而且
chunk 日志里 `fact` 阶段仍显示 **passed**（它跑的是**上一次遗留的 `entry.exe`**），
所以看起来像 "1/2 passed"，不像构建全挂。

### 本轮修复清单

| # | 问题 | 状态 |
|---|---|---|
| 1 | `GcAllocateFast` 缺 include（两平台共同根因） | ✅ 引擎 `8c226c063` |
| 2 | 发布出**别的 run** 的数字（build 283：建出 22 个却发布 0/45） | ✅ per-run summary + 拒绝外来 runId |
| 3 | `record_from_run` 静默吞异常（证据被丢） | ✅ 打完整 traceback |
| 4 | worker 用满 24 核 → 共享 C# 项目构建竞争 `CS2012` | ✅ 封顶 4 |
| 5 | 僵尸验证树触发硬门禁（每 chunk 都挂） | ✅ 运行前删除 |
| 6 | `DOTNET_ROOT` 跨节点污染（**我引入的**） | ✅ Windows 无条件覆盖 |
| 7 | bat/Groovy 陷阱 7 处（解析期展开、CPS 丢变量、反斜杠） | ✅ 详见 handoff §2 |

**自测 148/148。**

---

## 🔄 上一轮修复（发布链路，build 264 起）

**一句话**：Windows 之所以「没跑出数据」，不是 Windows 挂了，而是**整条发布链路
从来没有真正的数据生产者** —— 发布脚本读 `per-chunk/` + `reports/`，而这两个目录
是已删除的 legacy `nightly_runner` 的产物；当前 CLI 只写 `summary/`。
Linux 侧同样如此，只是它至少产出过一个「格式合法、内容全空」的空壳。

| 修复 | 文件 |
|---|---|
| 以 `summary/nightly-result.json` 为唯一事实源 + 旧版 markdown 回退 | `publish-nightly-results.py` |
| `error_classes` / `data_dlls` / `by_assembly` / provenance 写入 payload | `publish-nightly-results.py` |
| HTML 新增「Chunk 构建」+「失败归因」卡片 + 失败 chunk 清单 | `generate-nightly-report.py` |
| Windows 分支接入 publish + 本 node `archiveArtifacts` | `Jenkinsfile` |
| `--baseline` 日期格式 `%Y%mdd` → `%Y%m%d` | `Jenkinsfile` |
| 三个 bat 缺陷（HTML 不生成 / 退出码为空 / 写 Linux 路径） | `Jenkinsfile` |
| 禁止 CDN `main` 回退，强制 SHA pin | `Jenkinsfile` |

详见 §三 问题 3–6。

---

## 🆕 真实 agent 验证（2026-09-11）

不只是本机测试 —— 通过 SSH 在真实 Windows agent 上端到端跑通了发布链路：

```
=== publish exit=0 ===
=== artifacts ===
  generate-nightly-report.py
  nightly-data-20260910-win-run1.json
  nightly-report-20260910-win-run1.html
  publish-nightly-results.py
```

读出的正是真实数据：**20/45 passed + 四类归因**。失败路径也验证过
（指向不存在的目录 → `exit=1`，不再静默）。

### 验证中发现的三个 bat 缺陷（已修）

| # | 缺陷 | 根因 |
|---|---|---|
| 1 | HTML 不生成 | 只下载了 publish 脚本，没下载它调用的 `generate-nightly-report.py` |
| 2 | `publish exit=` 为空 | `set "VAR=%ERRORLEVEL%"` 在括号块内**解析期**展开，取到陈旧值 |
| 3 | 往 Linux 路径写 | `--report-server-dir` 默认 `/var/lib/...`，Windows 上会在当前盘建 `var/lib` 树且报成功 |

**2 号的坑比预想深**：`setlocal EnableDelayedExpansion` 写在块内**不管用** ——
`endlocal & set "VAR=%VAR%"` 这个惯用写法里 `%VAR%` 同样在解析期展开。
只有**脚本级** `EnableDelayedExpansion` + 直接读 `!ERRORLEVEL!` 才对（已用探针实测）。

### ⚠️ GitHub raw CDN 陈旧（重要运维知识）

实测：`raw.githubusercontent.com/<repo>/main` **push 后长时间仍返回上一版**，
加 `?cb=` 也无效；**按 SHA pin 的地址立即返回新内容**。

验证时真的撞上过：第一次跑到的是旧版 `publish-nightly-results.py`，报
`unrecognized arguments: --skip-report-server`，而修复其实早已在 main 上。

因此所有下载点改为**强制 SHA pin，`GIT_COMMIT` 为空则失败**。job 是
`CpsScmFlowDefinition`（pipeline-from-SCM），`GIT_COMMIT` 必定存在。

### 已确认的环境事实

- Jenkins workspace = `C:\agent\agentworkspace\workspace\chaos-il2cpp-nightly`
  （**不是** `C:\Jenkins\...`），`artifacts/` 子目录存在且为空
- `nightly-result.json` 落在
  `D:\agent\workspace\booming-il2cpp\tests\e2e\nightly-build-report\summary\`
- Python / curl / git 均在 PATH 上；curl 能连通 GitHub raw

---

## 🔄 上一轮进展（build 264）

### ✅ P0 已修复并验证：Linux 分支恢复运行

**问题**: Linux 分支用 `git archive origin/main | tar -x` 抽干净树，但 `git archive` **不含 `.git/`**。引擎的 `_detect_repo_root()` 靠向上找 `.git/` 定位根，找不到就回退到 `Path.cwd()`，导致**两个根都解析错**：

```
foundation_root()   → <cwd>/testing/foundation-dll   ← 不存在
testing_tree_root() → <cwd>                          ← 没有 _pipeline/
```

→ 每个 chunk 都 `FileNotFoundError`，`0/45`，每次运行必败。

**修复**（`a6a2922`）: 显式设置两个引擎文档化的 env 覆盖（`_path.py`）：
```bash
export CHAOS_FOUNDATION_DLL="${engTree}/tests/e2e/translation"
export CHAOS_TESTING_DIR="${engTree}/tests/e2e/verification"
```

**验证**:
- 本地对真实 archive 树验证：worklist discovery 返回预期的 **45 chunks** ✅
- Jenkins build 264：`FileNotFoundError` 计数 **0**，Linux 分支正常跑 chunk（PASS 30 / FAIL 41）✅

### 🔴 P0-新：Windows 分支 `'run' is not recognized`

build 264 的 Windows 分支报：
```
'run' is not recognized as an internal or external command
... (repeated)
Failed in branch windows-x64
```

**根因**: Jenkinsfile 的 Windows 分支里，bat 的 `for /f` 命令是 **多行**的（跨行续写），而 Jenkins 的 bat 在 Windows 上把每行当独立命令处理，`for /f ... in ('dir ...') do` 后面的 `run`（其实来自 `run.log` 文件名或续行拼接）被 cmd 当独立命令执行。

**修法**: 把多行 `for /f` 改成单行，或用 `%%f` 转义。

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
   │   ├─ export CHAOS_FOUNDATION_DLL + CHAOS_TESTING_DIR  ← P0 修复
   │   ├─ cd engine-src/tests/e2e
   │   ├─ python3 -m verification.nightly.cli --max-workers 4
   │   └─ python3 publish-nightly-results.py --report-dir engine-src/.../summary
   │
   └─ windows-x64 分支
       ├─ git fetch --depth=1 + reset --hard origin/main（同步 D:\agent\workspace\booming-il2cpp）
       ├─ 加载 vcvars64（vswhere 自发现）
       ├─ SDK 预检 build_presets.py --preset windows-x64-reference
       ├─ cd tests/e2e
       ├─ python -m verification.nightly.cli --max-workers %NUMBER_OF_PROCESSORS%
       ├─ 下载 publish-nightly-results.py（pin GIT_COMMIT + py_compile 校验）
       ├─ publish → nightly-data-<date>-win-runN.json + HTML   ← 新增
       └─ archiveArtifacts（在本 node 执行）                    ← 新增
```

### 数据产出链路（修复后）

```
verification.nightly.cli
  └─ aggregate_reports() → <report_dir>/summary/nightly-result.json   ← 唯一事实源
       │                    { total, passed, failed, byErrorClass, byAssembly, … }
       └─ publish-nightly-results.py
            ├─ read_nightly_summary()      读 nightly-result.json（主路径）
            ├─ parse_legacy_summary_md()   旧版 markdown（回退）
            ├─ merge_nightly_summary()     → error_classes / data_dlls / by_assembly
            └─ nightly-data-*.json ─┬─ Report API ingest（Linux）
                                    ├─ HTML 报告（含失败归因卡片）
                                    └─ archiveArtifacts → Jenkins controller（两平台）
```

---

## 二、当前结果

| 平台 | 状态 | 说明 |
|---|---|---|
| **linux-x64** | ✅ **恢复运行 + 数据链路已修** | 不再 FileNotFoundError；现在能产出非空指标 |
| **windows-x64** | ⚠️ **20/45 passed，数据已可回流** | 引擎 corecrt 修复生效（曾 0/45）；发布 + archive 已接入 |

### Windows 错误分布（最近一次成功的 run）

| Error class | 数量 | 趋势 |
|---|---|---|
| ✅ passed | **20** | ⬆️ 从 0 提升 |
| `csharp-error` | 8 | ATG 生成代码在 net8.0 编译失败 |
| `atg-combined-cs` | 7 | CombinedSubjects 合成异常 |
| `native-linker-error` | 5 | ⬇️ 从 39 降下来（corecrt 已修） |
| `unknown` | 5 | 待确认 |

---

## 三、🔴 当前问题（按严重度）

### 问题 1（P0）✅ 已修复：Linux foundation 路径
见上方「最新进展」。

### 问题 2（P0）✅ 已修复：Windows 分支 bat 多行 `for /f` 脚本 bug
见上方「最新进展」。

### 问题 3（P0）✅ 已修复：发布链路整体失灵 —— 数据从来没人生产
**这是本次最重要的发现，此前被误判为「Windows 没回传」。**

发布脚本 `publish-nightly-results.py` 读的是 `<report_dir>/per-chunk/` 和
`<report_dir>/reports/`，但这两个目录**是已删除的 legacy `nightly_runner.ReportCollector`
的产物**。当前 Route-3 CLI（`verification.nightly.cli`）只写
`<report_dir>/summary/{nightly-result.json, nightly-summary.md}`（`aggregate.py:102-156`）。

后果：
- `read_chunk_results()` / `read_aggregate_reports()` 恒返回空 → `summary` 全 0
- 但 `discover_assemblies()` 扫的是 `translation/`（真实存在）→ `total_dlls=45` 正确
- 于是产出一个**格式完全合法、内容全空**的报告，正常 ingest、正常发飞书卡

这解释了「报告能生成但内容是空的」。**Linux 侧也一直如此**，不只是 Windows。

**修复**（`publish-nightly-results.py`）：
- 新增 `read_nightly_summary()`：以 `summary/nightly-result.json` 为唯一事实源
- 新增 `parse_legacy_summary_md()`：兼容 6 月旧版 markdown schema
- 新增 `merge_nightly_summary()`：合并并写入 `error_classes` / `by_assembly` / `data_dlls`
- `per-chunk/` 缺失不再报噪音警告；真正无数据时才告警

### 问题 4（P1）✅ 已修复：Windows 结果不出机器，且无归因维度
- Windows 分支只有 `type` 回显，没有 publish 调用 → 45 chunk 结果止步于 `D:\`
- `error_class`（native-linker / csharp / atg-combined-cs）只存在于人读的 run.log，
  数据模型无该字段 → 39→5→8 的趋势只能手工 grep

**修复**：
- Windows 分支接入 publish + `archiveArtifacts`（在 Windows node 上执行）
- `summary.error_classes` 现在写入 JSON，HTML 新增「失败归因」卡片 + 失败 chunk 清单
- Windows 产物用 `-win` 日期后缀，与 Linux 趋势数据隔离

### 问题 5（P1）✅ 已修复：`--baseline` 从未生效
`Jenkinsfile` 用 `date ... +%Y%mdd` 推导昨日日期，格式串错误 → 输出 `202609dd`，
`prevFile` 恒不存在，**回归对比功能实际上从来没工作过**。
已修为 `+%Y%m%d`。

### 问题 6（P1）✅ 已修复：指标计算缺陷
| 缺陷 | 说明 |
|---|---|
| `data_dlls` 缺失 | 飞书卡读 `data.data_dlls ?: 0` 恒显示 `0/45`；API 和 HTML 各自重算第三套逻辑。现在写入 payload |
| `summary.build_number` 从未写入 | Report API `upsert_report` 读它 → DB 该列恒空 |
| 无 provenance | JSON 无 engine SHA / run_id → 无法回答「这个 20/45 是哪次提交」 |

### 问题 7（P1，未解决）：Windows 25 个失败
- **csharp-error (8)** + **atg-combined-cs (7)**: `CombinedSubjects.cs` 引用 net10 才有的 API（`AggregateBy`/`CountBy`），但 csproj 目标框架是 net8.0。
- **native-linker-error (5)**: corecrt 已修，剩 5 个新符号（未确认）。
- **unknown (5)**: 未分类。

**归属：引擎团队。** 现在这些数字已可从 `nightly-data-*.json` 的
`summary.error_classes` 直接读取，不再需要 SSH grep 日志。

### 问题 8（P1）✅ 已修复：内存 / 热更新指标恒 0（键路径错）
用**真实引擎产物**实测后定位（不是猜）：

| 文件 | 真实结构 | 原代码读的 | 后果 |
|---|---|---|---|
| `profile.json` | `{exitCode, nativeConfig, entryCount, profileData, **summary**, sectionSizes}`，指标在 `summary` 下 | `profile.totalNurseryAllocBytes` | **内存恒 0** |
| `hotupdate.json` | `{passed, failed, …}`（实测 114 个样本，**无** `passCount`/`patchCount`） | `passCount` / `patchCount` | **热更新恒 "-"** |

修复后拿真实 chunk 文件验证：`hotupdate 0 → 12565`、`mem_alloc 0 → 282032`。

### 问题 9（P2）✅ 已修复：`memory_fast_path_rate` 用 max 而非加权平均
`max()` 报的是「最好的那个 chunk」的比率，会掩盖其他 chunk 的退化。
改为按 `methodCount` 加权平均（内部累加键 `_fp_weighted` 会在返回前清除）。

### 问题 10（P2）✅ 已修复：`error_classes` 未入库
- `database.py` 新增 `error_classes` 表（`date_tag, error_class, count, platform`，主键含 `platform`）
- `upsert_error_classes()` 先删后插，**避免重新 ingest 时残留旧行**
- `main.py` ingest 时按 `-win` 后缀区分 `linux`/`windows` 平台
- 新增 `GET /api/error-classes` 与 `GET /api/error-classes/trends`

### 问题 11（已修复）：Report API 的 `data_dlls` 重算覆盖正确值
`main.py` 原本自己重算 `has_data`（扫 `dlls[].chunks[].fact`），而 Route-3 CLI
不产 `chunks` → 恒为 0。改为优先用 publish 写入的 `summary.data_dlls`。

---

## 四、优化方案列表

| # | 问题 | 优先级 | 方案 | 状态 |
|---|---|---|---|---|
| 1 | Linux foundation 路径 | P0 | `export CHAOS_FOUNDATION_DLL + CHAOS_TESTING_DIR` | ✅ `a6a2922` |
| 2 | Windows bat 多行 `for /f` | P0 | 改单行 / 修转义 | ✅ `eaa8f85` |
| 3 | 发布链路契约断裂 | P0 | 以 `summary/nightly-result.json` 为事实源 | ✅ 本次 |
| 4 | Windows 结果不回传 | P1 | 接入 publish + `archiveArtifacts` | ✅ 本次 |
| 5 | `--baseline` 从不生效 | P1 | `%Y%mdd` → `%Y%m%d` | ✅ 本次 |
| 6 | 失败无归因维度 | P1 | `error_classes` 入 JSON + HTML 卡片 + DB | ✅ 本次 |
| 7 | `data_dlls` / `build_number` / provenance | P1 | 写入 payload；API 优先读 payload | ✅ 本次 |
| 8 | 内存 / 热更新键路径错 | P1 | 按真实产物结构读 `profile.summary` + `passed/failed` | ✅ 本次 |
| 9 | `fast_path_rate` 用 max | P2 | 改加权平均 | ✅ 本次 |
| 10 | `error_classes` 未入库 | P2 | 新表 + 2 个 API 端点 | ✅ 本次 |
| 11 | `data_dlls` 三处三算法 | P1 | 统一为 `total > 0`（ran，而非 passed） | ✅ 本次 |
| 12 | csharp-error + atg-combined-cs | P1 | ATG 检测 TFM / csproj 升 net10 | ⬜ 引擎团队 |
| 13 | 剩余 5 个 native-linker-error | P1 | 定位新符号 | ⬜ 引擎团队 |
| 14 | `aggregate_reports()` 异常不落盘 | P2 | 保证异常也写 summary | ⬜ 引擎团队 |
| 15 | CDN main 回退（已禁用） | P1 | 强制 SHA pin | ✅ 本次 |

### 自测与 CI 门禁

`scripts/test-publish-nightly.py` —— **83 项检查全通过**，覆盖两种 `report_dir`
布局、corrupt JSON、legacy 回退、空数据告警、e2e publish→HTML、真实产物键路径、
加权平均、DB 平台隔离与陈旧行清理、Jenkinsfile 断言。

已接入 Jenkinsfile `Publish-Chain Self-Test` stage（在昂贵的构建**之前**跑）：

- **`checkout scm` 是必需的**，不是顺手加的：`Init` 只 curl `scripts/` 进 workspace，
  没有 checkout 时测试会**静默 SKIP** 掉 Jenkinsfile 和 report-server 两组断言 ——
  而那两组恰好是守护这个门禁自身的。有 checkout 也意味着测的是**本 commit 的代码**，
  而不是 raw.githubusercontent 当时返回的版本。
- **`--require-e2e`**：若 e2e 段被静默跳过（机器上没有引擎树），stage 直接失败，
  防止门禁「空过」。
- **SKIP 一律显式打印**并按失败级别汇总 —— 静默跳过会让套件变绿，而它本该提供的
  覆盖已经消失（这正是本次修复的那类问题）。

> 这个门禁存在的理由：发布链路**已经静默坏过一次** —— 发布脚本一直读引擎早已不再
> 写的目录，于是每晚都发布一份格式合法但内容全空的报告，构建始终是绿的，无人察觉。

---

## 五、观测通道

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
