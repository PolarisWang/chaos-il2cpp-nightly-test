# 系统架构

## 整体拓扑

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
   │ macOS Agent  │   │ Windows Agent │  ← SSH/JNLP（非容器化）
   └──────────────┘   └───────────────┘
```

## 容器服务列表

所有服务通过 Docker Compose 编排，共用 `chaos-il2cpp-nightly-test_jenkins` 网络：

| 容器 | 镜像源 | 端口映射 | 依赖 |
|------|--------|---------|------|
| chaos-master | jenkins/Dockerfile | 8080:8080, 50000:50000 | — |
| chaos-agent-x64 | docker/linux-x64-agent/ | — | master |
| chaos-agent-arm64 | docker/linux-arm64-agent/ | — | master |
| chaos-agent-android | docker/android-arm64-agent/ | — | master |
| chaos-sonarqube | sonarqube:lts-community | 9000:9000 | postgresql |
| chaos-sonar-db | postgres:15-alpine | — | — |
| chaos-report-server | report-server/Dockerfile | 8081:80 | report-api, sonarqube |
| chaos-report-api | report-server/api/Dockerfile | — | — |

## 数据流

```
Jenkins Agent (linux-x64)
  │
  ├─ nightly-orchestrator.sh
  │   ├─ git clone → cmake build → run-full-pipeline.sh
  │   ├─ collect-all-results.sh → nightly-data-<date>.json
  │   ├─ generate-nightly-report.py → nightly-report-<date>.html
  │   └─ cp → /var/lib/report-server/daily/
  │
  ├─ collect-all-results.sh (末尾)
  │   └─ POST /api/ingest → report-api → SQLite
  │
  └─ SonarQube scan → sonarqube:9000

浏览器 → Nginx (:8081)
  ├─ /              → index.html (ECharts 趋势图)
  ├─ /daily/*       → 静态 HTML/JSON 报告
  ├─ /api/*         → proxy_pass → FastAPI (:8000)
  │   ├─ /api/trends     → SQLite → JSON
  │   ├─ /api/reports    → SQLite → JSON
  │   ├─ /api/search     → SQLite → JSON
  │   ├─ /api/compare    → SQLite → JSON
  │   └─ /api/ingest     → collect 脚本调用
  └─ /latest        → redirect → nightly-latest.html
```

## 平台策略

| 平台 | 管线阶段 | 预计耗时 | 用途 |
|------|---------|---------|------|
| linux-x64 | 全量 (9 stages) | 4-8h | 主报告数据源 |
| linux-arm64 | build + fact | 1-2h | 跨平台正确性验证 |
| android-arm64 | build only | 30min | NDK 编译验证 |

---

*Last updated: 2026-06-14*
