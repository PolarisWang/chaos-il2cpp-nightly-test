# chaos-il2cpp-nightly-test

**Jenkins + Allure + SonarQube + Report API** 全平台 CI/CD 质量流水线

多平台 IL2CPP 编译验证、Fact/Benchmark/HotUpdate/Memory 全量测试、
综合日报 + 趋势图表 + 飞书通知（含双按钮卡片）。

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
| Jenkins | http://10.10.1.173:8080 | `qa004 / abcd@1234` |
| SonarQube | http://10.10.1.173:9000 | `admin / admin` |
| Report Server | http://10.10.1.173:8081 | — |
| Report API | http://10.10.1.173:8081/api/ | — |

> **注意**: 首次启动 Jenkins 需要等待约 30 秒完成初始化（init.groovy 会注册 Agent 节点并重载配置）。

---

## 架构总览

```
                    ┌──────────────┐
                    │  Report      │  :8081  ← 日报 / HTML 报告 / ECharts 趋势
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
```

### 容器服务

| 容器 | 镜像 | 依赖 | 说明 |
|------|------|------|------|
| `chaos-master` | chaos-jenkins-master | — | Jenkins Master + JCasC 自动配置 |
| `chaos-agent-x64` | chaos-agent-linux-x64 | master | 主构建节点，运行完整 pipeline |
| `chaos-agent-arm64` | chaos-agent-linux-arm64 | master | ARM64 fact 冒烟验证 |
| `chaos-agent-android` | chaos-agent-android-arm64 | master | Android NDK 编译验证 |
| `chaos-sonarqube` | sonarqube:lts-community | postgresql | 代码质量分析 |
| `chaos-sonar-db` | postgres:15-alpine | — | SonarQube 数据库 |
| `chaos-report-server` | chaos-report-server | report-api | Nginx 报告托管（含 ECharts） |
| `chaos-report-api` | chaos-report-api | — | FastAPI 趋势/搜索/对比 API |
| `chaos-minio` | minio/minio | — | MinIO S3 对象存储 |

---

## 源码仓库挂载

booming-il2cpp 源码仓库**不是通过 git clone** 获取的，而是通过 Docker volume 直接挂载到容器中：

```yaml
volumes:
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:ro   # master (只读)
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:rw   # agent (读写)
```

Agent 容器内的 pipeline 脚本直接操作 `/booming-il2cpp/testing/foundation-dll/` 目录。

---

## 流水线：chaos-il2cpp-nightly

Jenkins 中唯一的流水线任务，包含 3 个平台 + 报告 + 通知：

### 执行流程

```
触发方式:
  - cron: 每日 03:00
  - 手动: Jenkins UI → "立即构建" / API

                   Init (设置 ARTIFACTS_DIR)
                         │
           ┌─────────────┼─────────────┐
           │             │             │
     linux-x64      linux-arm64   android-arm64
     Full Pipeline   Fact Smoke    Build Verify
     (26 DLLs x 8)   (3 DLLs)      (fix_all_failures.py)
           │
           ├── SonarQube Analysis (x64 + arm64 并行)
           ├── Allure Report
           ├── Nightly Report (HTML + API ingest)
           └── 飞书通知 (双按钮卡片)
```

### linux-x64 全量 pipeline (核心)

对 `testing/foundation-dll/` 下每个有 `chunks/` 目录的 DLL，依次执行：

```
┌─────────────────────────────────────────────────┐
│  ① build       ATG → subjects DLL → TPG →      │
│                 entry.exe (含 Hephaestus 缓存)   │
│  ② fact        entry.exe --fact-json            │
│  ③ benchmark   entry.exe --benchmark-all        │
│  ④ hotupdate   ATG --patch-mode → 热更新验证    │
│  ⑤ profile     entry.exe --profile              │
│  ⑥ coverage-audit  manifest vs 实际覆盖对比     │
│  ⑦ aggregate   聚合 chunk 级数据                │
│  ⑧ reporting   写入报告数据库                   │
└─────────────────────────────────────────────────┘
                         │
                     Collect Results
                    (collect-all-results.sh)
                         │
                 nightly-data-<date>.json
```

其 pipeline 阶段之间是**串行**的（按 DLL 依次处理），每个 DLL 内部 8 个阶段也是串行的。

### 报告与通知

```
nightly-data-<date>.json
    ├── generate-nightly-report.py → HTML → /var/lib/report-server/daily/
    ├── POST /api/ingest → Report API → SQLite 趋势库
    └── sendNightlyNotification() → notify-feishu.sh
        ├── 标题: ✅/❌ chaos-il2cpp Nightly #N — 20260615
        ├── 消息体: 构建配置 / 正确率 / benchmark / 内存 profile
        ├── 📊 查看报告 按钮 (→ report-server)
        └── 🔧 Jenkins Build 按钮 (→ Jenkins build 页)
```

---

## Report Server (报告服务器)

### 存储架构

```
/var/lib/report-server/
    ├── daily/                热存储: HTML + JSON 报告
    │   ├── nightly-report-20260615.html
    │   ├── nightly-data-20260615.json
    │   ├── nightly-latest.html (软链接)
    │   └── ...
    ├── db/
    │   └── report.db         SQLite 趋势索引
    └── archive/              冷存储: 压缩归档
```

### API 接口 (统一端口 8081)

```bash
# 健康检查
curl http://10.10.1.173:8081/api/health

# 报告列表
curl http://10.10.1.173:8081/api/reports?limit=90

# 单日报告
curl http://10.10.1.173:8081/api/reports/20260615

# 趋势数据
curl http://10.10.1.173:8081/api/trends?days=90

# 数据导入 (collect 脚本自动调用)
curl -X POST 'http://10.10.1.173:8081/api/ingest?date_tag=20260615'
```

---

## 外部 URL 配置

使用 `docker-compose.yml` 中的 YAML anchor 统一管理三个外部访问地址：

```yaml
x-external-urls: &external-urls
  JENKINS_URL: http://10.10.1.173:8080
  REPORT_URL: http://10.10.1.173:8081
  FEISHU_WEBHOOK_URL: https://open.feishu.cn/open-apis/bot/v2/hook/...
```

通过 `<<: *external-urls` 应用到 master 和 linux-x64-agent 容器。

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `JENKINS_URL` | `http://10.10.1.173:8080` | Jenkins 外部访问地址（通知链接用） |
| `REPORT_URL` | `http://10.10.1.173:8081` | 报告服务器外部地址（通知链接用） |
| `FEISHU_WEBHOOK_URL` | — | 飞书机器人 Webhook 地址 |
| `SONAR_TOKEN` | — | SonarQube 认证 Token |
| `JENKINS_ADMIN_ID` | `qa004` | Jenkins 管理员账号 |
| `JENKINS_ADMIN_PASSWORD` | `abcd@1234` | Jenkins 管理员密码 |
| `MINIO_ACCESS_KEY` | `minioadmin` | MinIO S3 访问密钥 |
| `MINIO_SECRET_KEY` | `minioadmin` | MinIO S3 密钥 |

---

## 脚本参考

| 脚本 | 说明 |
|------|------|
| `scripts/startup.sh` | 一键启动/停止/重启所有服务 |
| `scripts/collect-all-results.sh` | 跨 DLL 数据聚合 + 写入报告 |
| `scripts/generate-nightly-report.py` | 综合 HTML 报告生成 |
| `scripts/notify-feishu.sh` | 飞书双按钮卡片推送 |
| `scripts/setup-agents.sh` | Agent 容器初始化脚本 |
| `scripts/debug-csrf.sh` | CSRF 调试脚本 |

---

## 目录结构

```
chaos-il2cpp-nightly-test/
├── docker/                   Agent 镜像
│   ├── linux-x64-agent/       Linux x64 构建 Agent
│   ├── linux-arm64-agent/     Linux ARM64 Agent
│   └── android-arm64-agent/   Android NDK Agent
├── docker-compose.yml         主编排（Jenkins + Agents + Report + MinIO）
├── sonarqube/                 SonarQube 服务栈
│   └── docker-compose.yml
├── report-server/             报告服务器
│   ├── Dockerfile             Nginx 镜像
│   ├── src/index.html         前端页面（ECharts drill-down）
│   └── api/                   FastAPI 服务
│       ├── main.py            API 端点
│       ├── database.py        SQLite 数据库层
│       └── Dockerfile
├── jenkins/                   Jenkins 配置
│   ├── Dockerfile
│   ├── plugins.txt
│   ├── jenkins.yaml           JCasC 自动配置
│   └── init.groovy            初始化脚本（Agent 注册 + 凭证创建）
├── scripts/                   工具脚本
│   ├── startup.sh
│   ├── collect-all-results.sh
│   ├── generate-nightly-report.py
│   └── notify-feishu.sh
├── Jenkinsfile                Pipeline 入口（自包含，无 shared library）
└── README.md
```

---

## 飞书通知卡片

Nightly Build 完成后，飞书群会收到一张交互式卡片：

```
┌─────────────────────────────────────┐
│ ✅ chaos-il2cpp Nightly #29 — 20260615 │
├─────────────────────────────────────┤
│ 构建配置: profile                   │
│ 状态: SUCCESS                       │
│                                     │
│ 覆盖范围: 24/26 DLLs 有数据         │
│ 正确率 (Fact): 737/737 (100.0%)     │
│ 基准测试: 593 方法                  │
│ 热更新: 737/737 (100.0%)            │
│ 内存 Profile: 18 方法               │
│                                     │
│ 失败详情:                            │
│ • System.Linq: 1 failed chunk(s)    │
│                                     │
│ ┌──────────┐ ┌──────────────┐       │
│ │📊 查看报告│ │🔧 Jenkins    │       │
│ └──────────┘ └──────────────┘       │
│ chaos-il2cpp CI · 2026-06-15 12:34  │
└─────────────────────────────────────┘
```

---

## 常见问题

**Q: 启动后报告页面显示"暂无数据"？**
A: 首次启动还没有 Nightly 运行记录。等待下一次定时触发，或手动触发 Jenkins 的 chaos-il2cpp-nightly 任务。

**Q: 如何手动触发 Nightly Build？**
A: 访问 Jenkins → `chaos-il2cpp-nightly` → "立即构建"，或运行：
```bash
curl -X POST http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters \
    --user qa004:abcd@1234
```

**Q: 飞书通知没有收到？**
A: 确认以下两点：
1. `FEISHU_WEBHOOK_URL` 已配置在 `docker-compose.yml` 的 `x-external-urls` 中
2. **同时配置在 linux-x64-agent 容器**（通知脚本在该容器上运行），而非仅在 master 上
3. 也可以通过 YAML anchor `<<: *external-urls` 确保两个容器都有该变量

**Q: Report API 连不上？**
A: 确保 report-api 容器在运行：`docker ps | grep report-api`。检查日志：`docker compose logs report-api`。

**Q: 如何修改外部访问地址（IP 或端口）？**
A: 编辑 `docker-compose.yml` 中的 `x-external-urls` 段，修改 `JENKINS_URL` 和 `REPORT_URL`，然后重启 master 和 x64-agent：
```bash
docker compose up -d --no-deps master linux-x64-agent
```
