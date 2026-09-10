# Windows Nightly Build — 问题交接文档

> 给接手修复的 agent：本文档包含完整背景、已修复项、**确切未解根因**、复现方法、以及可用的观测通道。

---

## 0. 一句话总结

Windows nightly build（`chaos-il2cpp-nightly` 的 `windows-x64` 分支）**45/45 chunk 全红**，根因已经定位到**引擎侧一个真实的并发文件锁 bug**：

> **`ensure_tool_built()` 没有跨进程锁** —— 多个 chunk 子进程同时调用 `dotnet build` 编译同一个 `Chaos.IL2CPP.Tools.AutoTestGenerator.csproj`，CSC 输出 DLL 被互相锁定 → 全部失败。

---

## 1. 系统架构（背景）

```
Linux master 10.10.1.173  (Jenkins, docker: chaos-master)
 ├─ linux-x64 agent  (docker: chaos-agent-x64)
 └─ windows-x64 agent (物理机/VM 10.10.9.197, JNLP 反连)
```

- **Jenkins job**: `chaos-il2cpp-nightly`
- **Jenkinsfile**: `/home/debian/agent/chaos-il2cpp-nightly-test/Jenkinsfile`（仓库 `PolarisWang/chaos-il2cpp-nightly-test`）
- **引擎仓库**: `PolarisWang/booming-il2cpp`（Linux: `/home/debian/agent/booming-il2cpp`；Windows: `D:\agent\workspace\booming-il2cpp`）
- **nightly 入口**（Route-3 新 CLI）: `python -m verification.nightly.cli`，从 `<repo>/tests/e2e` 运行
- **引擎数据**: `tests/e2e/translation/`（29 个 System.* family，每个有 `_dll/namespace-partition.json`）

### nightly 关键路径
- Linux 分支：Jenkinsfile 用 `git archive origin/main | tar -x` 抽一份**纯净引擎树**到 workspace（不碰脏工作区），再跑 nightly。
- Windows 分支：`bat` 脚本里 **git fetch+reset --hard origin/main 自动同步** → 跑 nightly。

---

## 2. 已经修好的（勿重复排查）

| # | 问题 | 修复 | 位置 |
|---|------|------|------|
| 1 | Windows agent 注册/上线 | init.groovy 加 windows-x64 节点 + NSSM 服务 | `jenkins/init.groovy`, `agent_export/*` |
| 2 | `'python' is not recognized`（服务账户无 PATH） | bat 里 prepend `C:\Program Files\Python312` 等 | Jenkinsfile windows branch |
| 3 | `vcvars64.bat` 找不到（VS 装在 Professional 而非 BuildTools） | vswhere 自发现 MSVC + fallback | Jenkinsfile windows branch |
| 4 | `DLL not found for <Assembly>` | **引擎修复**：`DOTNET_ROOT` 环境变量 + fallback 路径探测 | 引擎 `tests/e2e/verification/stages/build.py`（commit `e54277476`） |
| 5 | 引擎树陈旧（Windows agent 不 pull） | bat 里自动 `git fetch --depth=1 + reset --hard origin/main` + `safe.directory` | Jenkinsfile windows branch |
| 6 | cstdio 头缺失（SDK 构建失败） | **引擎修复**：`pal_eh_posix.cpp` 加 `#include <cstdio>` | commit `0f661d621` |
| 7 | cmake 子进程无 MSVC 环境 | **引擎修复**：`build_presets.py` 用 vcvars64 包裹 cmake 调用 | commit `abc57c561` |
| 8 | SSH 通道（master→Windows） | 配 ed25519 公钥到 `administrators_authorized_keys` | 私钥 `/root/.ssh/id_win_agent` |

---

## 3. 🔴 未解决根因（这就是要修的）

### 症状
Windows nightly：45/45 chunk 失败，error_class = `csharp-error`(20) + `unknown`(25)。

### 确切错误（从 Windows chunk run.log 读到的原始行）
```
[build] Target DLL: C:\Program Files\dotnet\shared\Microsoft.NETCore.App\10.0.6\System.Collections.Immutable.dll
[build] AutoTestGenerator FAILED (rc=2147516545)
    The application to execute does not exist:
    '...\Chaos.IL2CPP.Tools.AutoTestGenerator\bin\Debug\net8.0\Chaos.IL2CPP.Tools.AutoTestGenerator.dll'
```
以及并发锁的直接证据（另一个 chunk）：
```
CSC : error CS2012: Cannot open '...\AutoTestGenerator\obj\x64\Debug\net8.0\Chaos.IL2CPP.Tools.AutoTestGenerator.dll'
      for writing -- The process cannot access the file because it is being used by another process.;
      file may be locked by 'VBCSCompiler' (39828)
```
以及 MSBuild 内部错误：
```
Microsoft.NET.Sdk.targets(850,5): error MSB4018: at Microsoft.Build.BackEnd.TaskBuilder.ExecuteInstantiatedTask(...)
      [...\Chaos.IL2CPP.Tools.AutoTestGenerator.csproj]
```

### 根因分析
`tests/e2e/verification/_pipeline/tool_helpers.py::ensure_tool_built()` **没有跨进程互斥锁**：

```python
def ensure_tool_built(tool_name: str) -> bool:
    proj = _tool_dir(tool_name) / f"{tool_name}.csproj"
    dll = tool_dll(tool_name)
    if dll.exists() and proj.exists():
        # ... mtime 检查，若新鲜则 return True
    # 否则无锁地直接 dotnet build
    result = subprocess.run(["dotnet", "build", str(proj), "-nologo"], ...)
```

- nightly 用 **subprocess-per-chunk** 并发执行（Windows 上 `%NUMBER_OF_PROCESSORS%` = 24）。
- 开跑瞬间，24 个子进程**同时**发现 ATG DLL 不存在/陈旧 → **同时** `dotnet build` 同一个 csproj。
- MSBuild/CSC 的输出文件互相锁定 → 大多数失败，且 VBCSCompiler 残留进程持续持锁后续运行。

Linux 上为什么没这么明显：Linux 分支 `--max-workers 4`，竞争窗口小；Windows 用 24，必然相撞。

### 建议修复方向（供接手 agent 判断）
1. **在 `ensure_tool_built` 加跨进程文件锁**（Windows 用 `msvcrt.locking` / 一个 lock 文件，POSIX 用 `fcntl.flock`），锁内再检查一次 DLL 是否已就绪（double-checked）。**这是根因修复。**
2. 或在 `nightly.run.run_phases` 启动前**预构建一次 ATG + 所有 tool**（单进程），再并发跑 chunk。
3. 或降低 Windows `--max-workers`（治标）。
4. 清掉残留 `VBCSCompiler` 进程（`taskkill /IM VBCSCompiler.exe /F`）以释放锁。

---

## 4. 复现方法

在 Jenkins 触发（或 CLI）：
```bash
curl -s -u admin:admin -X POST \
  'http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters' \
  --data-urlencode 'BOOMING_REPO=/home/debian/agent/booming-il2cpp' \
  --data-urlencode 'WINDOWS_BOOMING_DIR=D:/agent/workspace/booming-il2cpp' \
  --data-urlencode 'BUILD_CONFIG=profile'
```

或直接在 Linux 干净树上手动跑（观察同样的并发锁）：
```bash
cd /home/debian/agent/booming-il2cpp/tests/e2e
CHAOS_FOUNDATION_DLL=$PWD/translation python3 -m verification.nightly.cli \
  --max-workers 24 --native-config profile
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

读最新失败日志的例子：
```bash
RID=$(ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' \
  "dir /b /o-d D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs" | head -1)
ssh -i /root/.ssh/id_win_agent 'booming\admin140@10.10.9.197' \
  "type \"D:\\agent\\workspace\\booming-il2cpp\\tests\\e2e\\nightly-build-report\\logs\\$RID\\System.Collections.Immutable\\global-ns\\run.log\""
```

---

## 6. 相关约束 / 注意事项

- **引擎仓库工作树不能当开发目录用**：`/home/debian/agent/booming-il2cpp` 曾被 10000+ 脏文件污染，误推过 main。**改引擎代码请在干净 checkout 上做**（`git reset --hard origin/main && git clean -fdx` 后再改，或单独 clone）。Jenkinsfile 的 Linux 分支已改用 `git archive` 抽干净树，不受此影响。
- **Jenkins `bat` 环境变量不传递到 python 子进程**：这是 Windows 分支反复踩的坑（DOTNET_ROOT 就是因此丢失）。修引擎侧比修 bat 更可靠。
- **Windows 分支的 Jenkinsfile 依赖**：`agent_export/` 套件 + `jenkins/init.groovy` 都在 `chaos-il2cpp-nightly-test` 仓库里。
- **验收标准**：`windows-x64` 分支 `nightly-summary.md` 显示 `N/45 passed` 且 N 接近 45（或与 Linux 结果一致），且 Jenkins Stage View 中 `Full Pipeline (x64 + Windows)` 两个分支都绿。

---

## 7. 当前状态快照

- 最近 Windows run: `20260910_083741-3a27db13d`（0/45 passed）
- Linux 端：同样受 ATG/并发问题影响，最近一次 `6/45 passed`，另有 34 个 provenance HEAD 抖动（因在活动工作树跑；改用 `git archive` 干净树后应缓解）
- 引擎 main 最新相关 commit: `abc57c561`（build_presets vcvars 修复）、`e54277476`（DOTNET_ROOT）
