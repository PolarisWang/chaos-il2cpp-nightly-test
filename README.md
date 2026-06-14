# chaos-il2cpp-nightly-test

**Jenkins + Allure + SonarQube + Report API** 全平台 CI/CD 质量流水线

多平台 IL2CPP 编译验证、Fact/Benchmark/HotUpdate/Memory 全量测试、
综合日报 + 趋势图表 + 飞书通知。

---

## 快速启动

```bash
# 1. 一键启动所有服务（推荐）
bash scripts/startup.sh

# 2. 如需重新构建镜像
bash scripts/startup.sh --build

# 3. 查看运行状态
bash scripts/startup.sh --status

# 4. 停止所有服务
bash scripts/startup.sh --stop
```

首次启动后访问：

| 服务 | 地址 | 默认凭证 |
|------|------|---------|
| Jenkins | http://localhost:8080 | `admin / abcd@1234` |
| SonarQube | http://localhost:9000 | `admin / admin` |
| Report Server | http://localhost:8081 | — |
| Report API | http://localhost:8081/api/ | — |

> **注意**: 首次启动 SonarQube 需要等待 1-2 分钟初始化。`startup.sh` 会自动等待所有服务就绪。

---

## 启动脚本详解

`scripts/startup.sh` 提供多种模式：

```bash
# 完整启动（含健康检查和汇总信息）
bash scripts/startup.sh

# 仅初始化数据目录，不启动服务
bash scripts/startup.sh --init

# 仅启动部分栈
bash scripts/startup.sh --jenkins-only    # Jenkins + Agents
bash scripts/startup.sh --sonar-only      # SonarQube + PostgreSQL
bash scripts/startup.sh --report-only     # Report Server + API

# 运维操作
bash scripts/startup.sh --status    # 查看各服务状态
bash scripts/startup.sh --restart   # 重启所有服务
bash scripts/startup.sh --stop      # 停止所有服务
bash scripts/startup.sh --build     # 重新构建镜像并启动
```

---

## 架构总览

```
                    ┌──────────────┐
                    │  Report      │  :8081  ← Allure / 日报 / HTML 报告 / API
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

### 8 个容器服务

| 容器 | 镜像 | 依赖 | 说明 |
|------|------|------|------|
| `chaos-master` | chaos-jenkins-master | — | Jenkins Master + JCasC 自动配置 |
| `chaos-agent-x64` | chaos-agent-linux-x64 | master | 主构建节点，运行完整测试管线 |
| `chaos-agent-arm64` | chaos-agent-linux-arm64 | master | ARM64 交叉编译验证 |
| `chaos-agent-android` | chaos-agent-android-arm64 | master | Android NDK 编译验证 |
| `chaos-sonarqube` | sonarqube:lts-community | postgresql | 代码质量分析 |
| `chaos-sonar-db` | postgres:15-alpine | — | SonarQube 数据库 |
| `chaos-report-server` | chaos-report-server | report-api, sonarqube | Nginx 报告托管 |
| `chaos-report-api` | chaos-report-api | — | FastAPI 趋势/搜索/对比 API |

---

## 流水线类型

| 流水线 | 触发方式 | 流程 |
|--------|---------|------|
| **Nightly Build** | 每日 03:00 (cron) | 多平台编译 → 测试 → Sonar 扫描 → 综合日报 → 飞书推送 |
| **PR Review** | GitHub Webhook | 代码检查 → Sonar PR 分析 → 冒烟编译 → 飞书通知 |
| **Performance** | 手动触发 | 指定平台 → N 轮 Benchmark → Allure 报告 → 飞书通知 |

### Nightly Build 详细流程

```
03:00 cron 触发
    │
    ▼
┌─ linux-x64 (主报告) ──────────────────────────────┐
│  1. git clone booming-il2cpp                       │
│  2. cmake configure + build (profile)              │
│  3. run-full-pipeline (24 DLLs, 4并行/批)          │
│     ├── build      → 编译验证                      │
│     ├── fact       → 正确性测试                    │
│     ├── profile    → 内存/GC/Alloc 分析            │
│     ├── benchmark  → 性能基准测试                   │
│     ├── managed_benchmark → .NET 8/10 对比          │
│     ├── benchmark_report → 跨技术栈差异             │
│     ├── hotupdate  → 热更新补丁验证                 │
│     ├── coverage-audit → 指令覆盖分析               │
│     └── aggregate  → 数据汇总                      │
│  4. collect-all-results   → 聚合 JSON              │
│  5. generate-nightly-report → HTML 日报             │
│  6. 上传 /var/lib/report-server/daily/             │
│  7. 调用 Report API ingest → 写入 SQLite 趋势      │
└────────────────────────────────────────────────────┘
    │
    ├─ linux-arm64 → build + fact (冒烟验证)         │
    └─ android-arm64 → build (编译验证)              │
    │
    ▼
┌─ 汇总阶段 ───────────────────────────────────────┐
│  SonarQube 扫描 (3 平台)                          │
│  Allure 报告生成                                  │
│  飞书卡片推送 + 邮件通知                          │
└──────────────────────────────────────────────────┘
```

---

## Report Server (报告服务器)

### 存储架构

```
/var/lib/report-server/
    ├── daily/                热存储: HTML + JSON 报告
    │   ├── nightly-report-20260614.html
    │   ├── nightly-data-20260614.json
    │   ├── nightly-latest.html → symlink
    │   └── ...
    ├── db/
    │   └── report.db         SQLite 趋势索引
    └── archive/              冷存储: 压缩归档
```

### 持久化策略

| 层级 | 存储介质 | 保留期 | 访问方式 |
|------|---------|--------|---------|
| 热存储 | 文件系统 (daily/) | 永久 | Nginx 直接 serve |
| 趋势索引 | SQLite (db/) | 永久 | FastAPI 查询 |
| 冷存储 | tar.gz 归档 | 可配置 | API 解压访问 |

### API 接口

所有 API 通过 Nginx 反向代理到 FastAPI，统一端口 8081：

```bash
# 健康检查
curl http://localhost:8081/api/health

# 报告列表（最近 90 天摘要）
curl http://localhost:8081/api/reports?limit=90

# 单日报告详情
curl http://localhost:8081/api/reports/20260614

# 趋势数据（供 ECharts 使用）
curl http://localhost:8081/api/trends?days=90

# 两日数据对比
curl http://localhost:8081/api/compare?a=20260613&b=20260614

# 按 DLL 名搜索历史
curl http://localhost:8081/api/search?q=System.Linq

# 单个 DLL 的历史趋势
curl http://localhost:8081/api/dll/System.Linq/trends?days=30

# 数据导入（collect 脚本自动调用）
curl -X POST 'http://localhost:8081/api/ingest?date_tag=20260614'
```

### 前端页面

| 页面 | 地址 | 内容 |
|------|------|------|
| Landing Page | `/` | 趋势图 + 最近报告列表 + 快速入口 |
| 最新报告 | `/latest` | 重定向到最新日期的报告 |
| 历史浏览 | `/daily/` | Nginx autoindex，按日期排列 |
| API 列表 | `/api/reports` | JSON 格式报告列表 |

---

## 数据目录

| 用途 | 路径 |
|------|------|
| 报告文件 | `/var/lib/report-server/daily/` |
| 趋势数据库 | `/var/lib/report-server/db/` |
| 报告归档 | `/var/lib/report-server/archive/` |
| Jenkins 数据 | Docker volume `jenkins-home` |
| SonarQube 数据 | Docker volume `sonarqube-data` |

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `SONAR_TOKEN` | — | SonarQube 认证 Token |
| `FEISHU_WEBHOOK_URL` | — | 飞书机器人 Webhook 地址 |
| `JENKINS_ADMIN_ID` | `qa004` | Jenkins 管理员账号 |
| `JENKINS_ADMIN_PASSWORD` | `abcd@1234` | Jenkins 管理员密码 |

---

## 脚本参考

| 脚本 | 说明 |
|------|------|
| `scripts/startup.sh` | 一键启动/停止/重启所有服务 |
| `scripts/nightly-orchestrator.sh` | Nightly 主编排（clone → build → test → report） |
| `scripts/run-full-pipeline.sh` | 24 DLL 并行管线执行器 |
| `scripts/collect-all-results.sh` | 跨 DLL 数据聚合 + SQLite 写入 |
| `scripts/generate-nightly-report.py` | 综合 HTML 报告生成（含 benchmark 回归对比） |
| `scripts/sonar-scan.sh` | SonarQube 扫描 |
| `scripts/notify-feishu.sh` | 飞书卡片推送 |
| `scripts/notify-email.sh` | 邮件通知 |
| `scripts/build-html-daily.sh` | (遗留) 简易日报生成 |
| `scripts/generate-allure.sh` | Allure 报告生成 |

---

## 目录结构

```
chaos-il2cpp-nightly-test/
├── docker/                   Agent 镜像 + 安装脚本
│   ├── linux-x64-agent/       Linux x64 构建 Agent
│   ├── linux-arm64-agent/     Linux ARM64 交叉编译 Agent
│   ├── android-arm64-agent/   Android NDK 编译 Agent
│   ├── macos-agent/           macOS 物理机 Agent 安装脚本
│   └── install-ci-tools.sh    共享 CI 工具安装脚本
├── docker-compose.yml         主 Docker Compose（Jenkins + Agents + Report）
├── sonarqube/                 SonarQube 服务栈
│   ├── docker-compose.yml     SonarQube + PostgreSQL
│   └── sonar-project.properties
├── report-server/             报告服务器
│   ├── Dockerfile             Nginx 镜像
│   ├── nginx.conf             Nginx 配置（含 /api/ 反向代理）
│   ├── src/index.html         Landing page（含 ECharts 趋势图）
│   └── api/                   FastAPI 服务
│       ├── Dockerfile
│       ├── main.py            7 个 API 端点
│       ├── database.py        SQLite 数据库层
│       └── requirements.txt
├── jenkins/                   Jenkins 配置
│   ├── Dockerfile             Jenkins Master 镜像
│   ├── plugins.txt            插件列表
│   ├── jenkins.yaml           JCasC 自动配置
│   ├── init.groovy            初始化脚本
│   └── jobs/                  Job XML 定义
├── pipelines/                 Jenkins Shared Library
│   └── vars/
│       ├── nightlyPipeline.groovy
│       ├── prReviewPipeline.groovy
│       ├── performancePipeline.groovy
│       └── notification.groovy
├── scripts/                   工具脚本
│   ├── startup.sh             一键启动脚本
│   ├── nightly-orchestrator.sh
│   ├── run-full-pipeline.sh
│   ├── collect-all-results.sh
│   ├── generate-nightly-report.py
│   └── ...
├── Jenkinsfile                Pipeline 入口
├── .env.example               环境变量模板
└── README.md                  本文档
```

---

## 非容器 Agent 注册

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

---

## 常见问题

**Q: 启动后报告页面显示"暂无数据"？**
A: 首次启动还没有 Nightly 运行记录。等待下一次定时触发，或手动触发 Jenkins 的 Nightly Pipeline。

**Q: 如何手动触发 Nightly Build？**
A: 访问 Jenkins → Nightly Pipeline → "立即构建"，或运行：
```bash
curl -X POST http://localhost:8080/job/NightlyPipeline/build \
    --user admin:abcd@1234
```

**Q: Report API 连不上？**
A: 确保 report-api 容器在运行：`docker ps | grep report-api`。检查日志：`docker compose logs report-api`。
