# chaos-il2cpp — Windows Nightly Agent 部署与运维文档

> **目标**: 把您的 Windows 机器变成一台"无头 build 节点"，只负责跑 nightly 核心流水线
>（build → fact → benchmark → hotupdate）。**所有控制、调试、修改都在 Linux 侧完成**，
> Windows 不需要 RDP / 日常操作。
>
> 架构 = **Linux 主控 + Windows 执行**：
> - **Linux (10.10.1.173)**: 编排 (Jenkins)、源码单一事实源、远程触发/调试/编排。
> - **Windows (您的机器)**: 只跑 `nightly_runner.main`，产物独立留存。
>
> ## 🚀 一键部署（Windows 上管理员 PowerShell）
>
> 从空机器开始，只需要**一行命令**：
>
> ```powershell
> Set-ExecutionPolicy Bypass -Scope Process; iex (iwr -UseBasicParsing https://raw.githubusercontent.com/PolarisWang/chaos-il2cpp-nightly-test/main/agent_export/bootstrap-windows.ps1)
> ```
>
> 本脚本会自动完成以下全部步骤（约 20-30 分钟）：
> 1. 安装 Python / CMake / Git / JDK 17 / .NET SDK 10+8
> 2. 安装 VS Build Tools 2022 (C++ 桌面包, 编译 entry.exe 必需)
> 3. 启用 OpenSSH Server + 创建 `agent` 用户（供 Linux 远程管理）
> 4. **自动在 Jenkins master 创建 `windows-x64` 节点**（不需要打开 Jenkins UI）
> 5. **自动获取 JNLP secret 并注入 agent 服务**
> 6. 下载 NSSM + 注册 Jenkins agent 为开机自启 Windows 服务
> 7. 启动 agent → 节点上线
>
> ---
>
> ## 验收标准（跑完后逐条确认）
>
> | # | 标准 | 确认方法 |
> |---|------|----------|
> | 1 | 脚本结束无红色 `[FAIL]` | 看最后一段「部署完成」摘要 |
> | 2 | Jenkins UI → Nodes → `windows-x64` 绿灯 | `http://10.10.1.173:8080/computer/windows-x64/` |
> | 3 | 从 Linux 能 SSH 连 Windows | `ssh agent@<本机IP>`（密码是你设的） |
> | 4 | 引擎源码已同步 | 确认 `C:\agent\booming-il2cpp\testing\foundation-dll\` 有内容 |
> | 5 | Windows nightly 分支可执行 | 以下表格「触发一次验证」 |

... (the rest of the original README follows) ...

---

## 0. 架构总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Linux 服务器  10.10.1.173  (主控)                                       │
│                                                                          │
│  Jenkins Master :8080 / JNLP:50000  ── cron 调度 nightly                  │
│    ├─ 容器 agent linux-x64 / arm64 / android (原有)                       │
│    └─ (可选) container agent 跑 Sonar / Report / 飞书                     │
│                                                                          │
│  /home/debian/agent/booming-il2cpp  ← 引擎源码"单一事实源"                │
│  /home/debian/agent/chaos-il2cpp-nightly-test/agent_export/ ← 本套件     │
│                                                                          │
│  从这里: ssh / rsync / jenkins-cli 远程控制 Windows agent                │
└──────────────────────────────────────────────────────────────────────────┘
                          │   JNLP (50000) + OpenSSH (22)
                          ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Windows 机  (执行节点, 无头)                                             │
│                                                                          │
│  OpenSSH Server  (Linux 远程进入: ssh agent@<win-ip>)                     │
│  agent.jar → Jenkins agent "windows-x64"  (label: windows-x64)           │
│  C:\agent\booming-il2cpp   ← 由 Linux rsync/同步, 引擎源码副本            │
│                                                                          │
│  跑 nightly_runner.main → 产物回传/归档                                    │
└──────────────────────────────────────────────────────────────────────────┘
```

**每天 2 次触发**（`Jenkinsfile triggers`）：`15 4` 与 `0 19`（UTC）。
> ⚠️ agent 容器未设 `TZ`，Jenkins cron 按 **UTC** 解释 → 北京约 **12:15** 与 **次日 03:00**。
> 以 Jenkins 实际触发记录为准。

---

## 1. 前置软件安装（在 Windows 上执行一次）

对应服务器 `docker/linux-x64-agent/Dockerfile` 的依赖，Windows 侧等价安装：

| 软件 | 版本 | 用途 |
|------|------|------|
| .NET SDK | **10.0** + **8.0 runtime** | 编译 CombinedSubjects.csproj + TPG net8.0 target |
| Python | 3.10+ (64-bit) | nightly_runner.main + 报告脚本 |
| CMake | 3.20+ | 构建 native entry.exe |
| Git for Windows | LTS | clone 引擎源码 |
| **OpenSSH Server** | Windows 可选组件 | 让 Linux 远程进入 (无头管理的关键) |
| VS Build Tools | 2022 (C++ 桌面包 / MSVC) | 编译 native codegen → exe |
| Java | JDK 17 | 运行 agent.jar |

### 1.1 一键安装脚本（第 1 阶段：基础工具 + OpenSSH）

在 Windows 上用**管理员 PowerShell** 执行一次：

```powershell
powershell -ExecutionPolicy Bypass -File install-agent-tools.ps1        # 装 Python/CMake/Git/.NET/OpenSSH
powershell -ExecutionPolicy Bypass -File enable-remoting.ps1             # 启用 OpenSSH + 建 agent 用户 + 目录结构
```

> `install-agent-tools.ps1` 已包含 OpenSSH Server 安装（Windows 可选功能 Win 10/11/Server）。
> `enable-remoting.ps1` 创建 `agent` 用户、建 `C:\agent` 目录结构、配置 SSH。

### 1.2 VS Build Tools（C++ 工具链）手动安装

> TPG codegen 在本机 CMake 编译 native `entry.exe`，必须有 MSVC 编译器。

1. 下载 [VS Build Tools 2022](https://aka.ms/vs/17/release/vs_BuildTools.exe)
2. 勾选工作负载：**"使用 C++ 的桌面开发"**（Desktop development with C++）
3. 验证 `cl` 可用：
   ```powershell
   & "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
   cl
   ```

### 1.3 JDK 17

```powershell
winget install EclipseAdoptium.Temurin.17.JRE
java -version
```

### 1.4 验证工具链

```powershell
powershell -ExecutionPolicy Bypass -File verify-tools.ps1    # 全绿再继续
```

---

## 2. 源码获取（在 Linux 上做一次，然后 Windows 用 rsync 拉）

引擎源码的**单一事实源 = Linux**。Windows 不再 git clone，而是从 Linux **拉同步副本**：

### 2.1 Windows 侧只需准备空目录

`enable-remoting.ps1` 已建好 `C:\agent\booming-il2cpp`。确保 Windows 的 git 有 `core.autocrlf false`：
（此设置由 enable-remoting.ps1 写入 agent 用户的 git 全局配置）

### 2.2 从 Linux 同步源码到 Windows

之后**每次改源码 / 首次初始化**，都在 Linux 上跑：

```bash
bash agent_export/sync-to-windows.sh <windows-ip>
```

它会 rsync `/home/debian/agent/booming-il2cpp/` → `C:\agent\booming-il2cpp`，
排除 `.git`、`_dll/`、`artifacts/`、CMake 缓存。Windows 上若无 rsync 则退化为 scp。

> **工作流**：在 Linux 改引擎代码 → git commit/push → `sync-to-windows.sh` 推副本 → 触发构建。
> 完全不需要 RDP 到 Windows。

---

## 3. Jenkins JNLP agent 配置（在 Linux / Jenkins UI 上做）

### 3.1 创建节点

1. 登录 `http://10.10.1.173:8080`（qa004）。
2. **Manage Jenkins → Nodes → New Node**：
   - Name: `windows-x64`
   - Type: `Permanent Agent`
   - Remote root: `C:\agent\workspace`
   - Labels: `windows-x64`
   - Usage: `Only build jobs with label expressions matching this node`
   - Launch: `Launch agent by connecting it to the controller`（JNLP）
   - Availability: `Keep this agent online as much as possible`
   - Save
3. 记下节点 secret。

### 3.2 在 Windows 上启动 agent

`start-agent.ps1`（PowerShell）或 `install-agent-service.ps1`（NSSM 服务, 推荐）：

```powershell
.\install-agent-service.ps1 -Secret <SECRET> -JenkinsUrl http://10.10.1.173:8080
```

> 服务 `JenkinsAgent-windows-x64` 开机自启 + 自动重启（Restart=always）。
> 之后这条 Windows 命令只需要执行这一次; 日常维护全部在 Linux 侧。

---

## 4. 从 Linux 远程管理 Windows（核心，无头）

### 4.1 SSH 进 Windows

```bash
ssh agent@<windows-ip>
# 例: ssh agent@192.168.1.50
# 进入的是一个 PowerShell/cmd 会话, 可执行任意命令查日志、看进程、重启服务。
```

### 4.2 远程触发一次构建（在 Linux 上）

```bash
bash agent_export/trigger-windows-build.sh <windows-ip>   # 触发 Jenkins nightly job
```

### 4.3 查看构建开始前的实时日志（Linux 上 tail Windows 上的执行日志）

```bash
ssh agent@<windows-ip> "Get-Content C:\agent\workspace\logs\run.log -Wait"
```

### 4.4 拉取构建产物（Linux 上从 Windows 拉回）

```bash
rsync -av -e ssh agent@<windows-ip>:'C:/agent/workspace/artifacts/' /home/debian/agent/win-artifacts/
```

---

## 5. 流程调试与修改（都在 Linux 侧）

因为 Windows 只是执行器，调试闭环如下：

### 并行 / 串行控制
- 原方案 `windows-x64` 与 `linux-x64` 是**并行** stage。
- 若要"Linux 先跑完 → Windows 再跑"（结果供 Linux 汇总），改用**串行**：把 `windows-x64
  Full Pipeline` 阶段放在 `linux-x64 Full Pipeline` **之后**、且不用 `parallel` 包装。
  这样 Linux stage 完成后才进入 Windows stage。

### 调试一个 Windows 上的失败
1. Linux 侧 `ssh agent@<win-ip>` 进入 Windows。
2. 到失败目录手, 手动跑同一条命令复现：
   ```powershell
   cd C:\agent\booming-il2cpp\testing\foundation-dll
   python -m verification.nightly_runner.main --report-dir C:\agent\dbg --native-config profile
   ```
3. 修源码（在 Linux）→ `sync-to-windows.sh` → 重跑。

### 修改 Jenkinsfile（在 Linux 仓库里）
- `Jenkinsfile.patch` 是给 `git apply` 用的（在 Linux 仓库根跑）。
- 改完 `git commit` + 触发重建，即可。

### 结果对比与报告
- Windows 结果用独立目录 `nightly-run-windows`, 不并入 Linux 的 `nightly-data` 基线。
- Windows 是否"回传/纳入报告"由你决定——默认独立, 便于拉回本机分析, 不污染服务器基线。

---

## 6. 从 Linux 侧入手：工作流速查表

| 操作 | 从哪儿执行 | 命令 |
|------|-----------|------|
| 首次在 Windows 装工具 | Windows (RDP一次) | `install-agent-tools.ps1` + `enable-remoting.ps1` |
| 首次建 Jenkins 节点 | Jenkins UI / Linux | 见 §3.1 |
| 在 Windows 启动 agent 服务 | Windows (一次) | `install-agent-service.ps1` |
| 同步源码到 Windows | **Linux** | `bash sync-to-windows.sh <win-ip>` |
| 远程进 Windows 查日志 | **Linux** | `ssh agent@<win-ip>` |
| 远程触发构建 | **Linux** | `bash trigger-windows-build.sh <win-ip>` |
| 远程 tail 实时日志 | **Linux** | `ssh agent@<win-ip> "Get-Content C:\\agent\\workspace\\logs\\run.log -Wait"` |
| 拉回产物 | **Linux** | `rsync -av ... agent@<win-ip>:... artifacts/` |
| 远程重启 agent 服务 | **Linux** | `ssh agent@<win-ip> "Restart-Service JenkinsAgent-windows-x64"` |

---

## 7. 常见故障排查

| 现象 | 成因 | 处理 (在 Linux 侧完成) |
|------|------|------|
| SSH 连不上 Windows | OpenSSH 未装/未启/防火墙 | `enable-remoting.ps1`; 检查 Windows 防火墙放行 22 端口 |
| agent 掉线/服务死 | JNLP 断连 | `ssh ... "Restart-Service JenkinsAgent-windows-x64"` |
| `sh()` 报 command not found | Windows 无 bash | stage 已用 `bat()` |
| `cl` 找不到 / C++ 失败 | 缺 MSVC | 重装 VS Build Tools C++ 工作负载 |
| python import 失败 | 缺依赖 | `ssh ... "cd C:\agent\booming-il2cpp\testing\foundation-dll; pip install -r requirements.txt"` |
| 源码不同步 | 改在 Linux 但未推 | 记得 `sync-to-windows.sh` |
| CRLF 报错 | autocrlf | `enable-remoting.ps1` 已写 `core.autocrlf false` |
| Windows 基准与 Linux 差异 | 硬件不同 | 设计如此; 用 nightly-run-windows 独立看趋势 |

---

## 8. 文件清单（本套件）

| 文件 | 说明 |
|------|------|
| `install-agent-tools.ps1` | Windows 一次性安装基础工具 + OpenSSH |
| `enable-remoting.ps1` | Windows 一次性启用远程: SSH 用户/目录结构/防火墙 (在 Windows 上跑一次) |
| `verify-tools.ps1` | Windows 工具链验证 |
| `start-agent.ps1` | Windows 启动 JNLP agent |
| `install-agent-service.ps1` | Windows 注册 agent 为服务 (一次) |
| `sync-to-windows.sh` | **Linux 侧**同步源码到 Windows |
| `trigger-windows-build.sh` | **Linux 侧**远程触发构建 |
| `Jenkinsfile.patch` | Jenkinsfile 增加 windows-x64 阶段 |
| `jenkinsfile-windows-stage.md` | 手工改 Jenkinsfile 说明 |

---

*生成时间: 2026-09-01 · 模型: Linux 主控 + Windows 执行 (无头 build 节点)*
