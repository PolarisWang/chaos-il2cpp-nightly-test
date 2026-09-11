# Windows Nightly Build — 问题交接文档 (v4)

> 给接手修复的 agent。**截止 2026-09-11，build 262 错误分布：native-linker-error=5,
> csharp-error=8, atg-combined-cs=7, unknown=5（20/45 passed）**。SSH 通道可用。
>
> **v4 变更**：发布链路整体修复 —— Windows 数据现在能回流到 Jenkins controller。
> 根因不是「Windows 没回传」，而是**整条链路从来没有数据生产者**（详见 §3.0）。
> 详见 `NIGHTLY_BUILD_REPORT.md`。

---

## 0. 一句话总结

Windows nightly（`chaos-il2cpp-nightly` 的 `windows-x64` 分支）从 0/45 提升到
**20/45 passed**。剩余 25 个失败中 **15 个是 ATG 生成的 `CombinedSubjects.cs`
在 net8.0 下引用 net10 API**（引擎侧问题），5 个 native-linker-error（corecrt 已修，
剩新符号），5 个 unknown。

**流水线侧（本仓库）的问题已全部修复**：结果产出、归因维度、回传、回归对比。

---

## 1. 系统架构

```
Linux master 10.10.1.173  (Jenkins, docker: chaos-master, 总调度)
 ├─ linux-x64 agent  (docker: chaos-agent-x64)
 └─ windows-x64 agent (物理机/VM 10.10.9.197, JNLP 反连, SSH 已打通)
```

| 组件 | 路径/地址 |
|------|----------|
| Jenkins job | `chaos-il2cpp-nightly` |
| Jenkinsfile | `PolarisWang/chaos-il2cpp-nightly-test` 仓库 |
| 引擎仓库 | `PolarisWang/booming-il2cpp` |
| Engine (Linux) | `/home/debian/agent/booming-il2cpp`（注意：曾重度污染，已 reset + clean） |
| Engine (Windows) | `D:\agent\workspace\booming-il2cpp`（自动 git fetch origin/main 同步） |
| nightly 入口 | `python -m verification.nightly.cli`，从 `<repo>/tests/e2e` 运行 |
| 引擎数据 | `tests/e2e/translation/`（29 个 System.* family） |
| Windows agent 用户名 | `booming\admin140`（**注意不是** haochuan.wang） |

### nightly 关键路径
- Linux 分支：`git archive origin/main | tar -x` 抽纯净引擎树→跑 nightly→publish
- Windows 分支：bat 自动 `git fetch --depth=1 + reset --hard origin/main` → 加载
  vcvars64 → SDK 预检 → `verification.nightly.cli` → **下载 publish 脚本 → publish →
  `archiveArtifacts`**

### 数据产出链路（v4 修复后）

```
verification.nightly.cli
  └─ aggregate_reports() → <report_dir>/summary/nightly-result.json   ← 唯一事实源
       └─ publish-nightly-results.py ─→ nightly-data-*-win-runN.json + HTML
            └─ archiveArtifacts → Jenkins controller
```

---

## 2. ✅ 已修复的（共 13 项，勿重复排查）

| # | 问题 | 修复 | 位置 |
|---|------|------|------|
| 1 | Windows agent 注册/上线 | init.groovy + NSSM 服务 | `jenkins/init.groovy`, `agent_export/*` |
| 2 | `'python' is not recognized` | bat 里 prepend PATH | Jenkinsfile |
| 3 | `vcvars64.bat` 找不到（VS Professional 非 BuildTools） | vswhere 自发现 + fallback | Jenkinsfile |
| 4 | `DLL not found for <Assembly>` | **引擎修复**：DOTNET_ROOT fallback 路径探测 | `build.py` (commit `e54277476`) |
| 5 | engine 树陈旧（不 pull） | bat 里 `git fetch --depth=1 + reset --hard origin/main` | Jenkinsfile |
| 6 | cstdio 缺失（SDK build fail） | **引擎修复**：`#include <cstdio>` | `pal_eh_posix.cpp` (commit `0f661d621`) |
| 7 | cmake 无 MSVC 环境(SDK 预构建) | **引擎修复**：`build_presets.py` 用 vcvars64 包裹 cmake | `build_presets.py` (commit `abc57c561`) |
| 8 | ATG 多进程并发锁 | **引擎修复**：`ensure_tool_built` 加跨进程锁 | `tool_helpers.py` (build 258 起生效) |
| 9 | `Argument list too long` (code-review) | 超长文件列表改走 temp file 避免 ARG_MAX | `review-with-claude.sh` (commit `bd5e836`) |
| 10 | 原生 linker 39 个错误 | **引擎修复**：`FindMsvcCompiler()` 版本错配 | 引擎 `13cc2c55d` |
| 11 | **发布链路契约断裂**（数据全空） | 以 `summary/nightly-result.json` 为事实源 + 旧版 markdown 回退 | `publish-nightly-results.py` (v4) |
| 12 | **Windows 结果不回传** | 接入 publish + 本 node `archiveArtifacts` | `Jenkinsfile` (v4) |
| 13 | **`--baseline` 从不生效** | `%Y%mdd` → `%Y%m%d` | `Jenkinsfile` (v4) |

---

## 3. 🔴 当前未解根因

### 3.0 ✅ 已修复：为什么 Windows「没跑出数据」

**根因不是 Windows 回传问题，而是整条发布链路没有生产者。**

`publish-nightly-results.py` 读 `<report_dir>/per-chunk/` 和 `<report_dir>/reports/`，
但这两个目录是**已删除的 legacy `nightly_runner.ReportCollector`** 的产物。
当前 Route-3 CLI 只写 `<report_dir>/summary/{nightly-result.json, nightly-summary.md}`
（`aggregate.py:102-156`）。三者对不上：

- `read_chunk_results()` / `read_aggregate_reports()` 恒返回空 → summary 全 0
- 但 `discover_assemblies()` 扫 `translation/`（真实存在）→ `total_dlls=45` 正确
- 于是产出**格式合法、内容全空**的报告，正常 ingest、正常发飞书卡

**Linux 侧也一直如此。** 修复见 §2 #11。

### 3.1 ✅ 已修复：native-linker-error 39 → 5

**原根因（已由引擎团队修复）：TPG 生成 `entry.exe` 时的 cmake 调用没有正确加载 MSVC/SDK 版本。**

引擎修复 `13cc2c55d`：
```
root_cause: FindMsvcCompiler() 与 FindVcAndSdkIncludePaths() 版本错配
fix_strategy: clPath 同源推导 include + NumericVersionKey + SDK 有效性过滤
```

原先报错（build 258-261）：`chaos_pch.h:24 C1083 corecrt_terminate.h` + `_Thrd_sleep_for` / `_Cnd_timedwait_for_unchecked` / `__std_find_*` 完全消失。

### 3.2 剩余 5 个 native-linker-error（新问题）

已不是 corecrt 问题。需读取这 5 个 chunk 的最新 run.log 确认新符号。
**现在可直接从 `nightly-data-*.json` 的 `summary.error_classes` 读取，无需 SSH grep。**

### 3.3 csharp-error（8 个）+ atg-combined-cs（7 个）—— 主要阻塞

ATG 生成的 `CombinedSubjects.cs` 在 net8.0 编译时报 `error CS0117: Enumerable 未包含 AggregateBy/CountBy`。
两边一致（Linux 同样），需决策：放弃 net8.0 兼容？还是让 ATG 不生成 net10 特有方法的 wrapper？

### 3.4 已知约束
- 引擎工作树卫生：已清理（`git reset --hard origin/main && git clean -fdx`）。改引擎代码请在干净 checkout 上做。
- code-review 可靠性已修复（锁泄漏、ARG_MAX、pipefail、monitor 增强，commit `93c209d` + `2eeec32`）
- Windows SSH 通道：`ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197'`（公钥免密）
- **~~内存指标恒 0~~** ✅ 已修：真实结构是 `profile.summary.*`，且
  `hotupdate.json` 用 `passed`/`failed`（无 `passCount`/`patchCount`）。
  实测后 hotupdate `0 → 12565`、mem_alloc `0 → 282032`。
- **~~`error_classes` 未入库~~** ✅ 已修：`report-server` 新增 `error_classes` 表
  + `GET /api/error-classes`、`/api/error-classes/trends`

---

## 4. 复现方法

```bash
curl -u admin:admin -X POST \
  'http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters' \
  --data-urlencode 'BOOMING_REPO=/home/debian/agent/booming-il2cpp' \
  --data-urlencode 'WINDOWS_BOOMING_DIR=D:/agent/workspace/booming-il2cpp' \
  --data-urlencode 'BUILD_CONFIG=profile'
```

或在 Linux 干净树上手动跑：
```bash
cd /home/debian/agent/booming-il2cpp/tests/e2e
CHAOS_FOUNDATION_DLL=$PWD/translation python3 -m verification.nightly.cli \
  --max-workers 4 --native-config profile
```

单独验证发布链路（不跑 nightly）：
```bash
python3 scripts/publish-nightly-results.py \
  --report-dir /home/debian/agent/booming-il2cpp/tests/e2e/nightly-build-report/summary \
  --foundation-dir /home/debian/agent/booming-il2cpp/tests/e2e/translation \
  --output-dir /tmp/pub --date-tag 20260911 --run-tag run1 \
  --build-number 265 --skip-ingest --skip-minio
```

---

## 5. 观测通道

**master → Windows SSH 已打通**（公钥免密）：
```bash
ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' "hostname"
```
- Windows 用户名：`booming\admin140`
- 引擎树：`D:\agent\workspace\booming-il2cpp`
- 日志：`D:\agent\workspace\booming-il2cpp\tests\e2e\nightly-build-report\logs\<run_id>\<Assembly>\<chunk>\run.log`
- 汇总：`...nightly-build-report\summary\nightly-summary.md` + `nightly-result.json`

读最新失败日志：
```bash
RID=$(ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' \
  "cmd /c dir /b /o-d D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs" | head -1)
ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' \
  "type \"D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs\\$RID\\System.Collections.Immutable\\global-ns\\run.log\"" 2>/dev/null | grep -aE "unresolved external|fatal error|LNK|error CS" | sort -u
```

**v4 起不再需要手工 grep**：失败归因已写入
`nightly-data-<date>-win-runN.json` 的 `summary.error_classes`，并在 HTML 报告的
「失败归因」卡片中按类展示，同时入库 `report-server`（`GET /api/error-classes`）。

---

## 6. 发布链路自测与 CI 门禁

```bash
# 全量（需引擎树，跑 e2e）
python3 scripts/test-publish-nightly.py --require-e2e

# 纯单元（无引擎树也能跑，会显式标注 SKIP）
CHAOS_ENGINE_DIR=/nonexistent python3 scripts/test-publish-nightly.py
```

Jenkinsfile 的 `Publish-Chain Self-Test` stage 在昂贵构建**之前**跑这个套件。
**改发布链路（`publish-nightly-results.py` / `generate-nightly-report.py` /
`report-server`）时必须同步更新它** —— 它是唯一能挡住
「报告静默变空」这类回归的东西（那个 bug 曾让每晚都发布空报告而构建全绿）。

### ⚠️ GitHub raw CDN 会返回陈旧内容

**实测（2026-09-11）**：`raw.githubusercontent.com/<repo>/main` 在 push 之后
**长时间仍返回上一个版本**，加 `?cb=` 缓存破坏参数也无效；而**按 commit SHA
pin 的地址立即返回新内容**。

后果：如果只 pin 到 `main`，会拿到旧脚本 —— 验证时就撞到过一次
（拉到了旧版 `publish-nightly-results.py`，报
`unrecognized arguments: --skip-report-server`，而修复其实早已在 main 上）。

因此**所有下载点都强制 SHA pin，且 `GIT_COMMIT` 为空时直接失败**，不回退 `main`。
job 是 `CpsScmFlowDefinition`（pipeline-from-SCM），`GIT_COMMIT` 必定存在，
为空说明 SCM 配置真坏了 —— 此时猜测比失败更危险。

## 7. 状态快照（2026-09-11）

| 项 | 值 |
|---|---|
| 最近 Windows build | 262（20/45 passed） |
| 错误分布 | csharp-error=8, atg-combined-cs=7, native-linker-error=5, unknown=5 |
| **流水线侧（本仓库）** | ✅ 全部修复（14 项） |
| 自测套件 | ✅ 83/83 |
| **真实 agent 验证** | ✅ 端到端跑通（20/45 + 四类归因 + HTML，exit=0） |
| 剩余阻塞 | ⬜ 引擎侧：TFM 兼容(15) + 新 linker 符号(5) |
| SSH 通道 | ✅ 通（`booming\admin140@10.10.9.197`，公钥） |

### 真实 agent 上验证过的关键事实

- Jenkins workspace = `C:\agent\agentworkspace\workspace\chaos-il2cpp-nightly`
  （**不是** `C:\Jenkins\...`），`artifacts/` 子目录存在
- `nightly-result.json` 确实落在
  `D:\agent\workspace\booming-il2cpp\tests\e2e\nightly-build-report\summary\`
- Python/curl/git 均在 PATH 上，curl 能连通 GitHub raw
- **bat 陷阱**：`endlocal & set "VAR=%VAR%"` 这种一行写法在本机**不工作**
  —— `%VAR%` 在解析期就展开（早于 `endlocal`），捕获为空。只有**脚本级**
  `setlocal EnableDelayedExpansion` + 直接读 `!ERRORLEVEL!` 才正确

---

