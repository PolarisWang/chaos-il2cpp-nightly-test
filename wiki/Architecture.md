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

## 代码审查（Code Review）流程

独立于 Nightly 的流水线，审查 `PolarisWang/booming-il2cpp` 的提交或 GitHub PR，输出 **rage 标准**的审查结果并推送飞书卡片。

```
宿主机 cron（每 1 分钟）
  ├─ trigger-code-review.sh  → main 分支新提交
  └─ trigger-pr-review.sh    → 打开的 GitHub PR（base..head）
        │  fetch refs/heads/pr-<N> / pr-<N>-base（真分支，供缓存本地拉取）
        │  crumb+cookie → 触发 Jenkins job `chaos-il2cpp-code-review`
        ▼
Jenkins Dispatch（label linux-x64-cr）
  └─ runCodeReview（内联，:630）  ← 权威路径（非 vars/codeReviewPipeline.groovy，后者已废弃）
      ├─ 下载 review-with-claude.sh 等脚本（raw.githubusercontent.com/main）
      │   ← 关键：脚本/改动 push 到 main 即生效，无需额外部署
      ├─ 增量 fetch → ~/booming-il2cpp-cache
      ├─ diff = base..head（PR）或 last_reviewed..HEAD（main）
      ├─ review-with-claude.sh --repo-dir --from-commit --to-commit --output findings.json
      │    ① 智能过滤：排除 third_party/、generated/、二进制、文档
      │    ② token 预算：预留 completion，按 ~3 chars/token 二分截断
      │    ③ claude --print 七维审查 + rage 输出 schema
      └─ 解析 findings.json → 渲染 rage 卡片 → 飞书 webhook
```

### Rage 标准输出格式

审查结果 JSON（`findings.json`）schema（**严重级别 4 级：严重 / 中 / 轻 / 建议**，对应 rage `_SEVERITY_ORDER`）

```json
{
  "summary": { "严重": 1, "中": 2, "轻": 0, "建议": 0, "total_findings": 3 },
  "findings": [
    {
      "severity": "严重",
      "repo": "il2cpp",
      "category": "layer_boundary",
      "dimension": 1,
      "file": "AutoTestGenerator/Verification/verification/some_script.py",
      "line": 85,
      "line_range": "85-90",
      "message": "Python层调用了 write_text 写入 .cpp 文件，违反四层边界",
      "fix": "将 write_text 移到 TPG 层对应的脚本中处理",
      "verify": "CPP 文件不再由 Python 脚本生成，四层边界检查通过"
    }
  ],
  "commits": [ { "sha": "abc1234", "message": "feat: add GC optimization" } ]
}
```

**严重级别映射**：严重（维度1/2/5 违规、内存/安全漏洞、边界越界）> 中（维度3/4 风险、线程安全、平台遗漏、测试诚信）> 轻（维度6、错误处理、性能隐患）> 建议（可选优化）。每条 finding 必须绑定真实代码行（`file` + `line`，可给 `line_range`）。

**飞书卡片渲染**（Jenkinsfile 内联 Python）：

```
📋 审查范围: 3 个提交  /  PR #12（3 个提交）

新提交:
  • [abc1234] feat: add GC optimization   (commit URL)
  • [[PR #12] title](https://github.com/.../pull/12)   (PR 模式)

风险概览:
  🔴 **1** 严重  🟠 **2** 中  ⚪ **0** 轻  🟢 **0** 建议

问题列表:
  🔴 **#1 [严重] [il2cpp]** [some_script.py:85](.../blob/<sha>/.../some_script.py#L85) — Python层调用了 write_text ...
  🟠 **#2 [中] [il2cpp]** [a.cpp:1303](...) — mask 不对称
  ...
🔗 [查看完整报告](Jenkins build URL)
```

- findings 按严重度排序（严重优先），每条 `#N [严重] [Repo] file:line_range`，文件名即飞书深链（指向 PR head / 提交处代码）。
- 状态文件 `findings_last_run` 用 rage 键：`{'严重','中','轻','建议'}`。

### 状态 / 锁文件（`/var/lib/report-server/daily/`）

| 文件 | 用途 |
|---|---|
| `last-reviewed-commit.json` | main 模式上次审查 commit |
| `pr-reviewed-head.json` | PR 模式各 PR 已审查 head（去重） |
| `cr-trigger.lock` / `cr-pr-trigger.lock` | 防重锁，30 分钟超时 |

### 测试

`scripts/test_rage_alignment.py` 固化 review-with-claude.sh 与 Jenkinsfile 之间的 schema 契约（严重度键、finding 字段、卡片渲染），防止两侧不同步。运行：
`python3 scripts/test_rage_alignment.py`（无 pytest 依赖）。

---

*Last updated: 2026-08-26*
