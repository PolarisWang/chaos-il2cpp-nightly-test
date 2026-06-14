# chaos-il2cpp-nightly-test

**Jenkins + Allure + SonarQube** 全平台 CI/CD 质量流水线

## 架构总览

```
                    ┌──────────────┐
                    │  Report      │  :8081  ← Allure / 日报 / Sonar 代理
                    │  Server      │
                    └──────┬───────┘
                           │
┌──────────┐  :8080  ┌────┴───────┐    ┌──────────────┐
│  Browser │────────▶│   Jenkins  │───▶│  SonarQube   │  :9000
│  (用户)   │        │   Master   │    │  + PostgreSQL │
└──────────┘        └────┬┬┬─────┘    └──────────────┘
                         │││
          ┌──────────────┼┼┼──────────────┐
          │              │││              │
   ┌──────┴──────┐ ┌────┴─────┐ ┌───────┴──────┐
   │ linux-x64   │ │ linux-   │ │ android-     │
   │  Agent      │ │ arm64    │ │ arm64 Agent  │
   │  (Container)│ │ Agent    │ │ (Container)  │
   └─────────────┘ └──────────┘ └──────────────┘
                                         
   ┌──────────────┐   ┌───────────────┐
   │ macOS Agent  │   │ Windows Agent │  ← SSH / JNLP 注册（非容器化）
   │ (物理机/VM)   │   │ (物理机/VM)    │
   └──────────────┘   └───────────────┘
```

## 流水线类型

| 流水线 | 触发方式 | 流程 |
|--------|---------|------|
| **Nightly Build** | 每日 03:00 (cron) | 多平台编译 → 测试(Allure) → Sonar 扫描 → 三合一日报 → 飞书推送 |
| **PR Review** | GitHub Webhook | 代码检查 → Sonar PR 分析 → 冒烟编译 → 飞书通知 |
| **Performance** | 手动触发 | 指定平台 → N 轮 Benchmark → Allure 报告 → 飞书通知 |

## 快速开始

```bash
# 1. 复制环境变量
cp .env.example .env
# 编辑 .env, 填入 SONAR_TOKEN, FEISHU_WEBHOOK_URL

# 2. 启动 SonarQube
docker compose -f sonarqube/docker-compose.yml up -d

# 3. 启动 Jenkins + Agents
docker compose up -d

# 4. 访问
# Jenkins:    http://localhost:8080   (admin/abcd@1234)
# SonarQube:  http://localhost:9000   (admin/admin)
# Reports:    http://localhost:8081
```

## 新注册非容器 Agent (macOS / Windows)

```bash
# macOS (在 Mac 机器上运行)
bash docker/macos-agent/setup.sh \
    --master-url http://<jenkins-ip>:8080 \
    --agent-name macos-arm64 \
    --secret <agent-secret>

# Windows (在 Windows 机器上运行 PowerShell)
.\docker\windows-agent\setup.ps1 \
    -MasterUrl "http://<jenkins-ip>:8080" \
    -AgentName "windows-x64"
```

## 日报

Nightly Build 结束后自动生成三合一 HTML 日报：

1. **构建状态** — 各平台编译结果
2. **测试报告** — Allure 统计（通过/失败/跳过）
3. **代码质量** — SonarQube 质量门禁结果

日报早上 8:00 通过飞书卡片推送链接。

## 目录结构

```
pipelines/vars/          ← Jenkins Shared Library (Groovy)
sonarqube/               ← SonarQube 服务栈 + 扫描配置
report-server/           ← Nginx 报告托管
scripts/                 ← 工具脚本 (Allure/Sonar/日报/通知)
docker/                  ← Agent 镜像 + 安装脚本
jenkins/                 ← Jenkins 配置 (JCasC/插件/Job XML)
feishu-bot/              ← 飞书机器人配置
```

## 环境变量

| 变量 | 说明 |
|------|------|
| `SONAR_TOKEN` | SonarQube 认证 Token |
| `FEISHU_WEBHOOK_URL` | 飞书机器人 Webhook 地址 |
| `JENKINS_ADMIN_ID` | Jenkins 管理员账号 |
| `JENKINS_ADMIN_PASSWORD` | Jenkins 管理员密码 |
