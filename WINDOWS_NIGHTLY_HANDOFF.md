# Windows Nightly Build — 问题交接文档 (v5)

> 给接手修复的 agent。**截止 2026-09-13，build 285（SUCCESS）：Windows 首次产出
> 非零发布数据 —— 18/45**。SSH 通道可用。
>
> **v5 变更**：找到并修复了**卡住两平台数日的共同根因**（`GcAllocateFast` 缺
> include，§3.0），并修掉发布链路最后三个数据完整性缺陷（§3.2–3.4）。
> **Windows 发布数据从 0/45 变为 18/45。**

---

## 0. 一句话总结

Windows nightly 长期 **0/45**，一直以为是三个不同的环境问题轮流发生。实际是
**一个引擎侧的链接错误**：`async_stubs.cpp` 使用了 `CHAOS_IL2CPP_NEW_GC` 宏，但
没有 include 定义其展开目标 `GcAllocateFast` 的头文件，导致 `LNK2019` /
`undefined reference` → `cmake build FAILED` → **每个 chunk 都挂**，而且只暴露为
分类器认不出的 `unknown`。

修掉之后（build 285）：

| 平台 | 发布结果 | 主要失败 |
|---|---|---|
| **windows-x64** | **18/45** | atg-combined-cs:8, csharp-error:5, unknown:13, native-linker-error:1 |
| **linux-x64** | 0/45 | atg-combined-cs:1, unknown:44 |

**流水线侧（本仓库）的问题已全部修复并验证**：结果产出、归因、发布、飞书卡、
回归对比、CI 门禁。

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
| Engine (Linux) | `/home/debian/agent/booming-il2cpp`（**重度污染工作树，勿直接改**；用独立 worktree） |
| Engine (Windows) | `D:\agent\workspace\booming-il2cpp`（自动 git fetch origin/main 同步） |
| nightly 入口 | `python -m verification.nightly.cli`，从 `<repo>/tests/e2e` 运行 |
| 引擎数据 | `tests/e2e/translation/`（29 个 System.* family） |
| Windows agent 用户名 | `booming\admin140`（**注意不是** haochuan.wang） |
| Jenkins 凭据 | `.env` 的 `JENKINS_ADMIN_ID` / `JENKINS_ADMIN_PASSWORD`（**勿硬编码**） |

### nightly 关键路径
- Linux 分支：`git archive origin/main | tar -x` 抽纯净引擎树→跑 nightly→publish
- Windows 分支：bat 自动 `git fetch --depth=1 + reset --hard origin/main` → 加载
  vcvars64 → SDK 预检 → `verification.nightly.cli` → **下载 publish 脚本 → publish →
  `archiveArtifacts`**

### 数据产出链路（v5）

```
verification.nightly.cli
  └─ aggregate_reports()
       ├─ <report_dir>/summary/nightly-result.json      （共享，会被任何 run 覆盖）
       └─ <report_dir>/summary/run-<run_id>.json        （per-run，永不覆盖）★
            └─ publish-nightly-results.py
                 ├─ latest_run_id() 从 run-state/ 最新目录名发现本次 run ★
                 ├─ 优先读 per-run；共享文件 runId 不匹配则**拒绝**（§3.2）★
                 └─ nightly-data-<date>-<platform>-runN.json + HTML
                      └─ archiveArtifacts → Jenkins controller
```

---

## 2. ✅ 已修复的（共 17 项，勿重复排查）

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
| 14 | **`GcAllocateFast` 链接失败**（两平台共同根因） | 补 `#include "core/gc_alloc_stubs.h"` | 引擎 `8c226c063` (v5) |
| 15 | **worker 数用满 24 核**导致共享 C# 项目构建竞争 `CS2012` | Windows 封顶 4（`NIGHTLY_WORKERS` 可覆盖） | `Jenkinsfile` (v5) |
| 16 | **僵尸验证树**触发硬门禁，每 chunk 都挂 | 每次运行前删除该路径 | `Jenkinsfile` (v5) |
| 17 | **发布链路数据完整性三连**（见 §3.2–3.4） | per-run summary + 拒绝外来 runId + 不再吞异常 | `publish-nightly-results.py` / `aggregate.py` (v5) |

### 本轮踩过并已修复的 bat / Groovy 陷阱（勿重复）

| 陷阱 | 症状 | 修法 |
|---|---|---|
| `%ERRORLEVEL%` 写在括号块内 | 解析期展开 → 拿到陈旧值 | 用 `!ERRORLEVEL!` + **脚本级** `EnableDelayedExpansion` |
| `endlocal & set "V=%V%"` 一行写法 | `%V%` 解析期展开 → 捕获为空 | 同上，脚本级延迟展开 |
| Groovy 变量写成 cmd 语法 `%winArtifacts%` | 字面传递给 cmd → 展开为空 | 一律 `${winArtifacts}` |
| REM 注释里的单个反斜杠（如 `\var\lib`） | Groovy 当转义符 → **整个 Jenkinsfile 解析失败** | 避免裸反斜杠；自测已加全量扫描 |
| 顶层 `def` 变量在 `node{}` 内 | CPS 序列化丢失 binding → `MissingPropertyException` | 发布到 `environment{}` 的 `env.*` |
| bat 的 `echo (...)` 内含 `;` | cmd 当命令分隔符 → `skipping was unexpected` | 括号内 echo 不含 `; & | < >` |
| 顶层 `def` 变量在 `node{}` 内 | 同上 | 同上 |

---

## 3. 🔴 未解根因 / 关键教训

### 3.0 ✅ 已修复（v5）：**两平台 0/45 的共同根因 —— `GcAllocateFast` 未定义**

**这是卡住数日的那个根因。** build 280 的真实 chunk 日志：

```
async_stubs.obj : error LNK2019: unresolved external symbol
  "void* chaos::il2cpp::runtime_core::GcAllocateFast(unsigned __int64)"
  referenced in function async_task_create_gc
chaos_entry.exe : fatal error LNK1120: 1 unresolved externals
→ [build] cmake build FAILED → Error: Build failed → rc=1
```

**因果链**：

1. `async_stubs.cpp` 的 `async_task_create_gc()` 调用宏 `CHAOS_IL2CPP_NEW_GC(...)`
2. `chaos/native_types.h:322` 把该宏定义为调用 `GcAllocateFast`；**紧邻的注释**就写着
   它是 "`__forceinline` fast path **in gc_alloc_stubs.h**"
3. `GcAllocateFast` 定义确实存在 —— `core/gc_alloc_stubs.h:35`，header-only 的
   `__forceinline`（MSVC）/ `inline __attribute__((always_inline))`（GCC）
4. **但 `async_stubs.cpp` 没有 include 那个头**，它只能看到 `gc/gc_helpers.h:23` 的
   **普通声明** → 编译器无法内联 → 发出**真实外部调用** → 链接找不到符号

**旁证**（同一次链接）：`GcAllocate`/`GcAllocateAtomic`/`GcAllocateProfiled`/
`GcAllocateAtomicProfiled` 都报 `LNK4006 already defined in gc_alloc_stubs.obj` ——
那个 TU 定义了整个家族，**唯独没有 `GcAllocateFast`**（它只在头文件里）。
`gc_alloc_stubs.cpp:38` 甚至自己写明了这个隐患。

**修复**：`async_stubs.cpp` 加 `#include "core/gc_alloc_stubs.h"`（路径写法同
`runtime_core.h:182`）。全仓库 grep 确认 **`async_stubs.cpp` 是唯一使用该宏的 .cpp**，
所以这一处就是完整修复。

**⚠️ 为什么之前每次排查都找错方向**：这个错误只暴露为分类器认不出的 `unknown`，
而且 chunk 日志里 `fact` 阶段显示 **passed**（它跑的是**上一次成功构建遗留的
`entry.exe`**），所以日志看起来是 "1/2 passed"，不像构建全挂。v5 已加
`dll-not-found` 规则；**`GcAllocateFast` 这类则需要看 chunk 日志本身** —— 见 §5。

### 3.1 ✅ 已修复：native-linker-error 39 → 5（corecrt）

**原根因（引擎团队修复）：TPG 生成 `entry.exe` 时的 cmake 调用没有正确加载 MSVC/SDK 版本。**

引擎修复 `13cc2c55d`：
```
root_cause: FindMsvcCompiler() 与 FindVcAndSdkIncludePaths() 版本错配
fix_strategy: clPath 同源推导 include + NumericVersionKey + SDK 有效性过滤
```

原先报错（build 258-261）：`chaos_pch.h:24 C1083 corecrt_terminate.h` + `_Thrd_sleep_for` / `_Cnd_timedwait_for_unchecked` / `__std_find_*` 完全消失。

### 3.2 ✅ 已修复（v5）：**发布出的是「别的 run」的数字**

`summary/nightly-result.json` 是**单个文件，每个 run 覆盖**，而 agent 上积压了
很多 run（`run-state/` 曾有 13+ 个目录，跨数小时）。后果：

- build 283：Windows 建出 **22 个 chunk**，发布却是 **0/45** —— 共享文件里是
  `20260912_091611`（前一天）的结果
- publish **自己打了 warning 说文件不是它的，然后照样用了那些数字**

**修复三件事**：

1. `aggregate_reports()` **额外写一份 `summary/run-<run_id>.json`**（永不覆盖）
2. publish **优先读它**；`latest_run_id()` 从 `run-state/` 最新目录名自动发现本次
   run id（避免"run id 只在 summary 里"的鸡生蛋）
3. 回退到共享文件时**比对 runId，不匹配则拒绝**（返回空 → 报告"无数据"），
   而不是发布一个看起来像真 0/45 的错数字

### 3.3 ✅ 已修复（v5）：`record_from_run` 的静默失败

`aggregate.py` 里 baseline 写入被裸 `except Exception: pass` 包着。run
`20260912_045412` 从 `baseline/index.json` **缺失**（前后邻居都在），说明写失败且
无人知晓 —— 而它恰好就是那个"发布数字与自身 run-state 不符"的 run，
**唯一能解释问题的证据被吞掉了**。现在失败会打完整 traceback，
`return None`（没找到 chunk 结果）也会明确报告。

### 3.4 🔴 未解：剩余失败（引擎侧，现在都有名字了）

build 285 的 Windows 分布：

| error class | 数量 | 性质 |
|---|---|---|
| `atg-combined-cs` | 8 | ATG 生成的 `CombinedSubjects.cs` 编译失败 —— **可行动** |
| `csharp-error` | 5 | 其他 C# 编译错 |
| `unknown` | 13 | 分类器认不出，**需读 chunk 日志**（§5） |
| `native-linker-error` | 1 | 剩余新符号 |

`atg-combined-cs` 的历史根因：`CombinedSubjects.cs` 引用 net10 才有的 API
（`AggregateBy`/`CountBy`），但 csproj 目标框架是 net8.0 —— 需决策：放弃 net8.0
兼容，还是让 ATG 检测 TFM 跳过此类 wrapper。

### 3.5 ⚠️ 重要操作约束

**不要在 chunk 阶段停 nightly。** `aggregate_reports()` 在 Phase B **之后**才跑，
所以任何中断（Ctrl-C / Jenkins stop）都会导致：**chunk 即使全部建成功，该轮结果也
全部丢失**，且 publish 会去读别人的 summary。build 283 就是这样丢掉 22 个通过的
chunk 的。

### 3.6 已知约束
- **引擎工作树 `/home/debian/agent/booming-il2cpp` 是重度污染的开发者工作树**
  （曾 456 个脏文件，且其他 agent 在并发提交）。**改引擎代码请用独立 worktree**：
  `git worktree add --detach <path> origin/main`
- code-review 可靠性已修复（锁泄漏、ARG_MAX、pipefail、monitor 增强，commit `93c209d` + `2eeec32`）
- Windows SSH 通道：`ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197'`（公钥免密）
- **~~内存指标恒 0~~** ✅ 已修：真实结构是 `profile.summary.*`，且
  `hotupdate.json` 用 `passed`/`failed`（无 `passCount`/`patchCount`）。
  实测后 hotupdate `0 → 12565`、mem_alloc `0 → 282032`。
- **~~`error_classes` 未入库~~** ✅ 已修：`report-server` 新增 `error_classes` 表
  + `GET /api/error-classes`、`/api/error-classes/trends`
- **Linux 的 baseline 永远记录不了**：`build_root()` 指向
  `engine-src/artifacts/foundation-dll`，而 Linux 用 `git archive` 树，该路径不存在
  → Linux 趋势数据一直为空（v5 的"不再吞异常"修复把它暴露出来了）。**未修。**

### 3.7 🔴 已排除的错误方向（勿重复走）

数日内有三个"看似不同"的 Windows 全挂，其中两个是**误诊或我自己造成的**：

| 曾被当成根因 | 实际 |
|---|---|
| `corecrt_terminate.h` C1083 回归 | ❌ 实测 build 268 起 **0 次**出现；纯属误判 |
| "幽灵判定覆盖了 PASS" | ❌ 运行时打点证明 `run_phase` **只有一条写入路径**且正确 |
| `DOTNET_ROOT` 在 Windows 上为空 | ⚠️ **是我自己引入的**：`env.DOTNET_ROOT` 是 pipeline 级，在 linux-x64 的 Init 里设置后会**传播到 Windows**，而 Windows 的 `if not defined` 兜底看到"已定义"就保留了那个 Linux 路径。已改为无条件覆盖 |
| `MAX_PATH` / SDK 构建失败 / 僵尸树 | ❌ 逐条排除（280 显示 `SDK ready` 且成功预编译 3MB lib） |

**教训**：不要用 console 的行号区间判断"一个 run"，两个平台并行且交错；
**`Run ID:` 行是唯一可靠的 run 计数**（每个进程恰好一行，`sh -x` 会让命令回显两次
从而让 `grep -c` 多算）。

---

## 4. 复现方法

**凭据不要硬编码** —— 从 `.env` 读（存在 `JENKINS_ADMIN_ID` /
`JENKINS_ADMIN_PASSWORD`）。下面用变量代替：

```bash
set -a; . /home/debian/agent/chaos-il2cpp-nightly-test/.env; set +a
JAR=$(mktemp)
CRUMB=$(curl -s -c "$JAR" -u "$JENKINS_ADMIN_ID:$JENKINS_ADMIN_PASSWORD" \
  'http://10.10.1.173:8080/crumbIssuer/api/json' \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['crumb'])")
curl -s -b "$JAR" -u "$JENKINS_ADMIN_ID:$JENKINS_ADMIN_PASSWORD" \
  -X POST -H "Jenkins-Crumb: $CRUMB" \
  'http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters' \
  --data-urlencode 'BOOMING_REPO=/home/debian/agent/booming-il2cpp' \
  --data-urlencode 'WINDOWS_BOOMING_DIR=D:/agent/workspace/booming-il2cpp' \
  --data-urlencode 'BUILD_CONFIG=profile'
rm -f "$JAR"
```

> ⚠️ CSRF crumb 是必须的（否则 403）。`-u admin:admin` 硬编码会被权限门禁拦下，
> 且不该出现在任何脚本里。

**等它跑完再看结果 —— 不要在 chunk 阶段停**（见 §3.5）。

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
  "type \"D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs\\$RID\\System.Collections.Immutable\\global-ns\\run.log\"" 2>/dev/null | grep -aE "unresolved external|undefined reference|fatal error|LNK|error CS|cmake build FAILED" | sort -u
```

### ⚠️ 排查 `unknown` 时**必须**做的第一件事

**不要只看 console 的 `[A] FAIL ... (unknown)` 就下结论。** `unknown` 只表示分类器
认不出，真实原因在 chunk 日志里。v5 那个卡了数日的 `GcAllocateFast` 就是被
`unknown` 掩盖的。**务必 grep 这两个模式**：

```bash
# 链接错误的两个平台写法（Windows / Linux）
grep -aE "LNK2019|LNK1120|undefined reference|cmake build FAILED" run.log | sort -u
```

**并且注意这个陷阱**：`build` 阶段挂了时，`fact` 阶段可能仍显示 **passed** ——
它跑的是**上一次成功构建遗留的 `entry.exe`**。所以 chunk 会显示 "1/2 passed"，
**看起来不像构建全挂**。判断构建是否真的成功，要看 `build` 阶段的 `<<<` 行，
不是整体通过数。

**同时注意**：`build_root()` 在 Linux 的 archive 树下不存在（§3.6），所以
Linux 的 baseline 永远为空，`[baseline] NOT RECORDED` 是已知现象，不是新故障。

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

## 7. 状态快照（2026-09-13）

| 项 | 值 |
|---|---|
| 最近 build | **285（SUCCESS）** |
| **windows-x64 发布** | ✅ **18/45**（首次非零） |
| windows 失败分布 | atg-combined-cs=8, csharp-error=5, unknown=13, native-linker-error=1 |
| linux-x64 发布 | 0/45（atg-combined-cs=1, unknown=44） |
| **流水线侧（本仓库）** | ✅ 全部修复并验证（17 项） |
| 自测套件 | ✅ **148/148** |
| 引擎侧根因 | ✅ `GcAllocateFast` 缺 include（`8c226c063`）已修并验证 |
| 剩余阻塞 | ⬜ 引擎侧：ATG/TFM(8) + 13 个 unknown + 1 个 linker 符号 |
| 定时任务 | ✅ `15 4` + `0 19`（历史证实按时触发） |
| 飞书卡 | ✅ 双平台 + verdict 标题 |
| SSH 通道 | ✅ 通（`booming\admin140@10.10.9.197`，公钥） |

### 交付确认（用户目标）

> 「和 linux 一样每天定时跑 windows nightly build，然后能有正确的数据，
> 然后汇总成数据报告，同步到群里，整个流程要跑通」

| 目标 | 状态 |
|---|---|
| 每天定时跑 | ✅ cron `15 4` / `0 19`，`Started by timer` 已证实 |
| 有正确的数据 | ✅ 18/45，且 provenance/runId 正确、不再读到别的 run |
| 汇总成数据报告 | ✅ JSON + HTML 双双归档到 controller |
| 同步到群里 | ✅ 飞书卡含双平台 + verdict，HTTP 200 |

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

