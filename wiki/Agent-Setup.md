# Agent 设置与平台支持

## 容器化 Agent

以下 Agent 由 Docker Compose 自动管理，无需手动配置：

| Agent | 标签 | 构建预设 | 测试 | 基准测试 |
|-------|------|---------|------|---------|
| linux-x64 | `linux x64 native` | linux-x64-packaging | 全量 | 是 |
| linux-arm64 | `linux arm64 qemu` | linux-arm64-smoke | Fact 验证 | 否 |
| android-arm64 | `android arm64 ndk` | android-arm64-smoke | 编译验证 | 否 |

### 架构差异

```
linux-x64:  x86_64, 原生执行, 全速运行 benchmark
linux-arm64: aarch64, 通过 QEMU 模拟, 仅验证编译+Fact
android-arm64: aarch64, NDK 交叉编译, 仅验证编译通过
```

## 非容器化 Agent

### macOS ARM64

在 Mac 物理机上运行：

```bash
bash docker/macos-agent/setup.sh \
    --master-url http://<jenkins-ip>:8080 \
    --agent-name macos-arm64 \
    --secret <agent-secret>
```

前置条件:
- Homebrew installed
- `openjdk@17`, `git`, `cmake` installed
- 网络能访问 Jenkins Master (JNLP 端口 50000)

### Windows x64

在 Windows 物理机/VM 上运行 PowerShell：

```powershell
.\docker\windows-agent\setup.ps1 `
    -MasterUrl "http://<jenkins-ip>:8080" `
    -AgentName "windows-x64"
```

前置条件:
- Windows 10/11 或 Server 2019+
- Git for Windows
- Visual Studio 2022 Build Tools
- JDK 17

## Agent 环境依赖

所有 Agent 需要安装以下工具（由 `docker/install-ci-tools.sh` 自动处理）：

| 工具 | 用途 | 安装方式 |
|------|------|---------|
| OpenJDK 17 | Jenkins Agent 运行 | apt/brew/choco |
| CMake 3.28+ | 项目构建 | pip/brew |
| Allure CLI | 测试报告生成 | APT 仓库 / 手动 |
| SonarScanner | 代码扫描 | 手动下载 |
| Python 3.10+ | 脚本执行 | 系统自带 |
| git | 源码管理 | 系统自带 |

## 注册流程

容器化 Agent 自动注册流程：

```
1. docker-compose up → agent 容器启动
2. agent 运行 entrypoint.sh
3. entrypoint.sh 通过 JNLP 连接 Master
4. Master 根据 AGENT_NAME 匹配预配置的节点
5. Agent 进入空闲等待状态
```

非容器化 Agent 手动注册流程：

```
1. Jenkins Master → Manage Nodes → New Node
2. 配置 Remote Root Directory 和 Labels
3. 获取 Agent Secret
4. 运行 setup.sh 或 setup.ps1
```

---

*Last updated: 2026-06-14*
