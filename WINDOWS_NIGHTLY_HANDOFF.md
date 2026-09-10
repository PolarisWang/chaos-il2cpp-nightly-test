# Windows Nightly Build — 问题交接文档 (v2)

> 给接手修复的 agent。**截止 2026-09-10，build 258 已修复了 ATG 并发锁问题**，目前 Windows nightly 跑到了新的阻塞点——**native 链接器错误**。本文档包含完整架构、8 项已修复内容、当前根因、以及观测通道。

---

## 0. 一句话总结

Windows nightly（`chaos-il2cpp-nightly` 的 `windows-x64` 分支）**45/45 chunk 全红**，当前阻塞点是 **25 个 native-linker-error**（MSVC 链接 `entry.exe` 时找不到 Windows 特有符号），加上 **14 个 csharp-error**（ATG codegen 生成的主题 DLL 在 net8.0 下编译不过）和 **1 个 atg-combined-cs**（CombinedSubjects 合成问题）。

---

## 1. 系统架构

```
Linux master 10.10.1.173  (Jenkins, docker: chaos-master)
 ├─ linux-x64 agent  (docker: chaos-agent-x64)
 └─ windows-x64 agent (物理机/VM 10.10.9.197, JNLP 反连)
```

- **Jenkins job**: `chaos-il2cpp-nightly`
- **Jenkinsfile**: 仓库 `PolarisWang/chaos-il2cpp-nightly-test` 的 `Jenkinsfile`
- **引擎仓库**: `PolarisWang/booming-il2cpp`（Linux: `/home/debian/agent/booming-il2cpp`；Windows: `D:\agent\workspace\booming-il2cpp`）
- **nightly 入口**（Route-3 新 CLI）: `python -m verification.nightly.cli`，从 `<repo>/tests/e2e` 运行
- **引擎数据**: `tests/e2e/translation/`（29 个 System.* family，每个有 `_dll/namespace-partition.json`）

### nightly 关键路径
- Linux 分支：Jenkinsfile 用 `git archive origin/main | tar -x` 抽一份**纯净引擎树**到 workspace，再跑 nightly。
- Windows 分支：`bat` 脚本里 **git fetch+reset --hard origin/main 自动同步** → 建 workspace 产物目录 → 加载 MSVC 环境(vcvars) → 跑 nightly SDK 预检 → `python -m verification.nightly.cli`。

---

## 2. ✅ 已修复的（勿重复排查）

| # | 问题 | 修复 | 位置 |
|---|------|------|------|
| 1 | Windows agent 注册/上线 | init.groovy 加 windows-x64 节点 + NSSM 服务 | `jenkins/init.groovy`, `agent_export/*` |
| 2 | `'python' is not recognized` | bat 里 prepend `C:\Program Files\Python312` 等 | Jenkinsfile windows branch |
| 3 | `vcvars64.bat` 找不到（VS 装在 Professional 非 BuildTools） | vswhere 自发现 + fallback 硬编码路径 | Jenkinsfile windows branch |
| 4 | `DLL not found for <Assembly>` | **引擎修复**：DOTNET_ROOT 环境变量 fallback + 已知路径探测 | 引擎 `build.py`（commit `e54277476`） |
| 5 | engine 树陈旧（Windows agent 不 pull） | bat 里自动 `git fetch --depth=1 + reset --hard origin/main` | Jenkinsfile windows branch |
| 6 | cstdio 缺失（SDK 构建失败） | **引擎修复**：`pal_eh_posix.cpp` 加 `#include <cstdio>` | commit `0f661d621` |
| 7 | cmake 子进程无 MSVC 环境 | **引擎修复**：`build_presets.py` 用 vcvars64.cmd 包裹 cmake 调用 | commit `abc57c561` |
| 8 | AutoTestGenerator 多进程并发锁 | **引擎修复**：`ensure_tool_built` 加跨进程锁（contributor 已完成） | 引擎 `tool_helpers.py` |
| 9 | SSH 通道（master→Windows） | 配 ed25519 公钥到 `administrators_authorized_keys` | 私钥 `/root/.ssh/id_win_agent` |

---

## 3. 🔴 当前未解根因

Build 258 结果分布：

| Error class | 数量 | 含义 |
|---|---|---|
| **native-linker-error** | **25** | TPG 成功编译 `entry.exe` 的 .obj，但 MSVC linker 报错——**这是当前主要阻塞** |
| **csharp-error** | **14** | ATG 生成的 `CombinedSubjects.cs` 在 net8.0 编译时引用了 net10 才有的 API（如 `AggregateBy`/`CountBy`） |
| **atg-combined-cs** | **1** | CombinedSubjects 合成步骤异常 |
| 总计 | 45 | ✅ ATG 并发锁修复有效（之前完全卡在 ATG 构建） |

### 3.1 native-linker-error（25 个 — 主要阻塞）

原始错误（从 Windows chunk run.log 提取）：

```
chaos_runtime_core.lib : error LNK2001: unresolved external symbol _Thrd_sleep_for
chaos_runtime_core.lib : error LNK2001: unresolved external symbol _Cnd_timedwait_for_unchecked
chaos_runtime_core.lib : error LNK2019: unresolved external symbol __std_find_last_trivial_1
chaos_runtime_core.lib : error LNK2019: unresolved external symbol __std_find_end_1
```

这些是引擎 C++ 代码在 MSVC（Visual Studio 2022）上链接时找不到的 Windows CRT 符号：
- `_Thrd_sleep_for` / `_Cnd_timedwait_for_unchecked`——C11/C17 threads.h 符号，MSVC 实现为 `_Thrd_sleep` 等不同名，或需要特定 Windows SDK 版本
- `__std_find_last_trivial_1` / `__std_find_end_1`——VS 2022 标准库内部实现符号，链接时找不到，可能是新 CRT 版本不兼容

**修复方向**（需引擎 C++ 团队）：
1. 在 Windows/MSVC 条件编译中提供这些符号的替代实现
2. 或更换 CMake 配置以链接正确的 Windows CRT 库
3. 或升级/锁定 VS 2022 工具链版本到匹配标准库的版本

### 3.2 csharp-error（14 个）

```
error CS0117: “Enumerable”未包含“AggregateBy”的定义
error CS0117: “Enumerable”未包含“CountBy”的定义
```

ATG 为 net10 API 生成了主题代码，但 `CombinedSubjects.csproj` 的 net8.0 目标框架没有这些 API。两边一致（Linux 也同问题），需要决策：是放弃 net8.0 兼容只跑 net10？还是让 ATG 不生成 net10 特有方法的 wrapper？

### 3.3 已知的其它约束
- **cstdio 修复在 origin/main 上**（commit `0f661d621`）
- **Linux 端**同样受 csharp-error(14) 影响，但 Linux 没有 native-linker-error（走的 gcc）
- Windows 上 MSVC 的 `cl.exe` 路径：`C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\14.38.33130\bin\Hostx64\x64\cl.exe`

---

## 4. 复现方法

在 Jenkins 触发：
```bash
curl -u admin:admin -X POST \
  'http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters' \
  --data-urlencode 'BOOMING_REPO=/home/debian/agent/booming-il2cpp' \
  --data-urlencode 'WINDOWS_BOOMING_DIR=D:/agent/workspace/booming-il2cpp' \
  --data-urlencode 'BUILD_CONFIG=profile'
```

---

## 5. 观测通道（关键，不用求人贴日志）

**master → Windows SSH 已打通**（公钥免密）：
```bash
ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' "hostname"
```
- Windows 用户名：`booming\admin140`（**注意不是** haochuan.wang）
- 引擎树：`D:\agent\workspace\booming-il2cpp`
- 日志：`D:\agent\workspace\booming-il2cpp\tests\e2e\nightly-build-report\logs\<run_id>\<Assembly>\<chunk>\run.log`
- 汇总：`...\nightly-build-report\summary\nightly-summary.md` + `nightly-result.json`

读最新失败日志：
```bash
RID=$(ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' \
  "cmd /c dir /b /o-d D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs" | head -1)
ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' \
  "type \"D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs\\$RID\\System.Collections.Immutable\\global-ns\\run.log\""
```

---

## 6. 相关约束

- **引擎仓库工作树不能当开发目录用**：`/home/debian/agent/booming-il2cpp` 曾被 10000+ 脏文件污染，误推过 main。**改引擎代码请在干净 checkout 上做**（`git reset --hard origin/main && git clean -fdx` 后再改，或单独 clone）。Jenkinsfile 的 Linux 分支已改用 `git archive` 抽干净树。
- **Jenkins `bat` 不传递环境变量到 python 子进程**（DOTNET_ROOT 因此多次丢失）；修引擎侧比修 jenkinsfile 更可靠。
- **Windows ATG 锁已修**，如果在 Linux 上看到类似 ATG 并发挂起，那是 Linux 端沿用旧 `ensure_tool_built` 代码——commit `abc57c561`（已内含锁）需要 pull 过来。
- Windows 分支的 Jenkinsfile 依赖在 `chaos-il2cpp-nightly-test` 仓库。

---

## 7. 状态快照

- 最近 Windows run: **build 258**（`20260910_101552-e57607759`）— 0/45 passed
- 错误分布：native-linker-error=25, csharp-error=14, atg-combined-cs=1
- Linux 端：同样受 csharp-error 影响，但无 native-linker-error
- 引擎 main 最新：`e57607759`（hotupdate patch-host-arrays）、`1b6df696b`（atg: drop unstable XPath）