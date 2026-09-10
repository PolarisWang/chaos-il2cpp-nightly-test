# Windows Nightly Build — 问题交接文档 (v3)

> 给接手修复的 agent。**截止 2026-09-10，build 260/261 错误分布稳定：native-linker-error=39, unknown=5, atg-combined-cs=1**。SSH 通道可用。本机 batch review 正在跑 73 个未审提交的补审。本文档包含完整架构、已修复项、当前根因、复现方法和观测通道。

---

## 0. 一句话总结

Windows nightly（`chaos-il2cpp-nightly` 的 `windows-x64` 分支）**45/45 chunk 全红**，当前阻塞点是 **39 个 native-linker-error**（MSVC 链接 `entry.exe` 时找不到 Windows CRT 符号）+ 5 个 unknown + 1 个 atg-combined-cs。ATG 并发锁和 DOTNET_ROOT 均已修复，C# 编译问题（csharp-error）已在引擎侧修掉。剩下唯一的阻塞是 **TPG 内嵌的 cmake 调用没有加载 vcvars64**。

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
- Linux 分支：Jenkinsfile 用 `git archive origin/main | tar -x` 抽纯净引擎树→跑 nightly→publish
- Windows 分支：bat 脚本自动 `git fetch --depth=1 + reset --hard origin/main` → 加载 vcvars64 → SDK 预检 → `python -m verification.nightly.cli`

---

## 2. ✅ 已修复的（共 9 项，勿重复排查）

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

---

## 3. 🔴 当前未解根因

Build 260/261 结果分布（连续 3 次一致）：

| Error class | 数量 | 含义 |
|---|---|---|
| **native-linker-error** | **39** | TPG 成功编译 `entry.exe` 的 .obj，但 MSVC linker 报错——**唯一主要阻塞** |
| **unknown** | **5** | 其他原因（待确认） |
| **atg-combined-cs** | **1** | CombinedSubjects 合成异常 |

### 3.1 native-linker-error（39 个 — 唯一阻塞）

**根因：TPG（`chaos-il2cpp convert-to-cpp`，引擎的 C# 代码生成工具）在生成 `entry.exe` 时自己调用 cmake，但这条 cmake 调用路径没有加载 MSVC/vcvars 环境。**

四次构建（258~261）的日志完全一致：

```
chaos_pch.h(24): fatal error C1083: Cannot open include file: 'corecrt_terminate.h'

chaos_runtime_core.lib : error LNK2001: unresolved external symbol _Thrd_sleep_for
chaos_runtime_core.lib : error LNK2001: unresolved external symbol _Cnd_timedwait_for_unchecked
chaos_runtime_core.lib : error LNK2019: unresolved external symbol __std_find_last_trivial_1
chaos_runtime_core.lib : error LNK2019: unresolved external symbol __std_find_end_1
```

**根因链条：**
1. `chaos_pch.h` 在 `#ifdef _MSC_VER` 内 `#include <corecrt_terminate.h>`（绕开 MSVC `<exception>` C2039 的 workaround）
2. TPG 调用的 cmake 子进程没有继承 MSVC 的 `INCLUDE`/`LIB` 环境变量（因为没加载 vcvars64）
3. → UCRT include 目录(`C:\Program Files (x86)\Windows Kits\10\Include\*\ucrt\`) 不在 `INCLUDE` 中
4. → `corecrt_terminate.h` 找不到 → PCH 编译失败 → CRT 声明缺失 → 链接时 4 个符号无法解析
5. → `chaos_entry.exe` 链接失败 → 所有 39 个 chunk 卡在此处

⚠️ 注意：`build_presets.py` 已在 SDK 预构建时用 vcvars64 包裹（commit `abc57c561`，**已修复**），但 **TPG 内部的 entry.exe cmake 是另一条 call path，没有做同样处理**。

**该文件在 Windows 上确实存在**（已 SSH 确认）：
```
C:\Program Files (x86)\Windows Kits\10\Include\10.0.22621.0\ucrt\corecrt_terminate.h
```

**修复方向（需引擎 C++/C# 团队）**：
1. **让 TPG 生成 entry.exe 前加载 vcvars64**：TPG 用 `cmd /c "call vcvars64.bat && cmake --build ..."` 替代裸 cmake 调用。`vswhere` 路径已确认可用。
2. 或在 TPG 生成的 `chaos_entry.vcxproj` 中显式设置 `WindowsTargetPlatformVersion=10.0.22621.0`。

### 3.2 csharp-error（14→0，已修）
C# ATG 编译错误（`Enumerable.AggregateBy`/`CountBy` 在 net8.0 不存在）已在引擎侧修复。build 260 起 csharp-error = 0。

### 3.3 unknown（5 个）
待确认。可能与 `atg-combined-cs(1)` 同源或由那 1 个级联引起。

### 3.4 已知约束
- **引擎工作树卫生**：`/home/debian/agent/booming-il2cpp` 曾被 10000+ 脏文件污染，误推过 main。`git reset --hard origin/main && git clean -fdx` 已清理。改引擎代码请先在干净 checkout 上做。
- **bat 环境变量不传递到 python 子进程**：修引擎侧比修 bat 更可靠。
- **code-review 已恢复**：ARG_MAX 修复（`bd5e836`）已推送，锁已清。本机正逐个 review 73 个未审提交（`/tmp/batch_review.sh`），完成后汇总。

---

## 4. 复现方法

```bash
curl -u admin:admin -X POST \
  'http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters' \
  --data-urlencode 'BOOMING_REPO=/home/debian/agent/booming-il2cpp' \
  --data-urlencode 'WINDOWS_BOOMING_DIR=D:/agent/workspace/booming-il2cpp' \
  --data-urlencode 'BUILD_CONFIG=profile'
```

或在 Linux 干净树上手动跑（观察同样的 39 个 linker error）：
```bash
cd /home/debian/agent/booming-il2cpp/tests/e2e
CHAOS_FOUNDATION_DLL=$PWD/translation python3 -m verification.nightly.cli \
  --max-workers 4 --native-config profile
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

---

## 6. 状态快照（2026-09-10 21:20 CST）

| 项 | 值 |
|---|---|
| 最近 Windows build | **261**（FAILURE, 0/45 passed） |
| 错误分布 | native-linker-error=39, unknown=5, atg-combined-cs=1 |
| Linux 端 | 受 ATG/csharp-error 影响（6/45 passed，后续引擎修复待验证） |
| 引擎 main 最新 | `5beb64de3`（fix tests stub DLL path） |
| 补审 73 个 commit | 进行中（12/73 完成） |
| code-review 锁 | 已清，ARG_MAX 修复已推送 |
| SSH 通道 | ✅ 通（`booming\admin140@10.10.9.197`，公钥） |
| 交接文档 | v3 版，本文件 |