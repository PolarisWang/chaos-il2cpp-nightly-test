# 系统架构

## 整体拓扑

```
                    ┌──────────────┐
                    │  Report      │  :8081  ← 日报 / HTML 报告 / ECharts + drill-down
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

## 容器服务

所有服务通过 Docker Compose 编排，共享 `chaos-il2cpp-nightly-test_jenkins` 网络：

| 容器 | 镜像源 | 端口映射 | 依赖 | 说明 |
|------|--------|---------|------|------|
| chaos-master | jenkins/Dockerfile | 8080:8080, 50000:50000 | — | Self-contained Pipeline |
| chaos-agent-x64 | docker/linux-x64-agent/ | — | master | 主构建节点，全量 8-stage pipeline |
| chaos-agent-arm64 | docker/linux-arm64-agent/ | — | master | ARM64 fact 冒烟 |
| chaos-agent-android | docker/android-arm64-agent/ | — | master | NDK 编译验证 |
| chaos-sonarqube | sonarqube:lts-community | 9000:9000 | postgresql | 代码质量分析 |
| chaos-sonar-db | postgres:15-alpine | — | — | SonarQube 数据库 |
| chaos-report-server | report-server/Dockerfile | 8081:80 | report-api | Nginx + ECharts |
| chaos-report-api | report-server/api/Dockerfile | — | — | FastAPI + SQLite |
| chaos-minio | minio/minio | 9002, 9003 | — | S3 对象存储 |

## 数据流

```
Jenkins Agent (linux-x64)
  │
  ├─ Jenkinsfile (自包含 Pipeline)
  │   ├─ Init → ARTIFACTS_DIR
  │   ├─ linux-x64 Full Pipeline
  │   │   └─ 遍历 DLL → python3 -m verification --all-chunks --stages 8
  │   ├─ linux-arm64 Smoke
  │   │   └─ python3 -m verification.chunk_pipeline (3 DLLs fact)
  │   ├─ android-arm64 Verify
  │   │   └─ fix_all_failures.py --platform android
  │   ├─ SonarQube Scan (x64 + arm64)
  │   ├─ Nightly Report
  │   │   ├─ generate-nightly-report.py → HTML
  │   │   ├─ cp → /var/lib/report-server/daily/
  │   │   └─ POST /api/ingest → report-api → SQLite
  │   └─ 飞书通知
  │       └─ notify-feishu.sh → FEISHU_WEBHOOK_URL
  │
  └─ 外部 URL（通知卡片中）
      ├─ JENKINS_URL: http://10.10.1.173:8080
      └─ REPORT_URL:  http://10.10.1.173:8081

浏览器 → Nginx (:8081)
  ├─ /              → index.html (ECharts 趋势 + 3 级 drill-down)
  ├─ /daily/*       → 静态 HTML/JSON 报告
  ├─ /api/*         → proxy_pass → FastAPI (:8000)
  │   ├─ /api/trends     → SQLite → JSON
  │   ├─ /api/reports    → SQLite → JSON
  │   ├─ /api/search     → SQLite → JSON
  │   ├─ /api/compare    → SQLite → JSON
  │   └─ /api/ingest     → collect 脚本调用
  └─ /latest        → redirect → nightly-latest.html
```

## 配置管理

使用 `docker-compose.yml` 中的 YAML anchor 统一管理外部 URL：

```yaml
x-external-urls: &external-urls
  JENKINS_URL: http://10.10.1.173:8080        # 通知卡片中的 Jenkins 链接
  REPORT_URL: http://10.10.1.173:8081          # 通知卡片中的报告链接
  FEISHU_WEBHOOK_URL: https://open.feishu.cn/...  # 飞书 webhook
```

通过 `<<: *external-urls` 合并到 master 和 linux-x64-agent 的环境变量中。

## 多平台策略

| 平台 | 管线阶段 | 预计耗时 | 用途 |
|------|---------|---------|------|
| linux-x64 | 全量 (8 stages x 26 DLLs) | 2-6h | 主报告数据源，通知触发者 |
| linux-arm64 | fact (3 DLLs) | 15min | 跨平台正确性验证 |
| android-arm64 | build verify | 30min | NDK 编译验证 |

## Pipeline 自包含设计

Jenkinsfile 是**自包含**的，不依赖 Shared Library 或外部 groovy 脚本：

```
Jenkinsfile
  ├── pipeline { agent none ... }
  ├── stages (Init → 3 平台并行 → SonarQube → Report → Notify)
  ├── post (success/failure → sendNightlyNotification)
  └── Helper 函数
      ├── runSonarScan(platform, boomingDir, config, artifacts)
      └── sendNightlyNotification(Map params)
```

## 源码仓库挂载

```yaml
volumes:
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:ro   # master
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:rw   # agent
```

Agent 在 `/booming-il2cpp/testing/foundation-dll/` 中操作，无需 git clone。

---

*Last updated: 2026-06-16*
