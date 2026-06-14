# 报告服务器

## 架构

报告服务器由两个容器组成：

```
Nginx (chaos-report-server)          FastAPI (chaos-report-api)
  :8081 ─── /api/* ──proxy_pass──▶    :8000
  │                                   │
  ├── /daily/* (静态文件)               └── SQLite /var/lib/report-server/db/report.db
  ├── /latest (重定向)
  ├── / (Landing Page + ECharts)
  └── /sonar/* (SonarQube 代理)
```

## 存储结构

```
/var/lib/report-server/
    ├── daily/                      热存储: HTML + JSON 报告
    │   ├── nightly-report-YYYYMMDD.html
    │   ├── nightly-data-YYYYMMDD.json
    │   ├── nightly-latest.html → nightly-report-YYYYMMDD.html
    │   └── ...
    ├── db/
    │   └── report.db               SQLite 趋势索引
    └── archive/                    冷存储: 压缩归档
```

## API 文档

所有 API 端点通过 `http://host:8081/api/` 访问。

### `GET /api/health`

健康检查。

**响应:**
```json
{"status": "ok", "time": "2026-06-14T08:40:38"}
```

### `GET /api/reports?limit=90`

返回最近 N 天的报告摘要列表。

| 参数 | 类型 | 默认 | 范围 |
|------|------|------|------|
| limit | int | 90 | 1-365 |

**响应:**
```json
{
  "reports": [
    {
      "date_tag": "20260614",
      "build_number": "42",
      "total_dlls": 24,
      "data_dlls": 22,
      "fact_passed": 1456,
      "fact_total": 1500,
      "benchmark_methods": 520,
      "hotupdate_passed": 48,
      "hotupdate_total": 48,
      "memory_alloc_bytes": 85983232,
      "memory_gc_pause_ns": 230000000,
      "memory_fast_path_rate": 0.95,
      "created_at": "2026-06-14 08:40:38"
    }
  ],
  "total": 1
}
```

### `GET /api/trends?days=90`

聚合趋势数据，供 ECharts 前端使用。

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| days | int | 90 | 返回最近 N 天的趋势 |

**响应:**
```json
{
  "trends": [
    {
      "date_tag": "20260614",
      "fact_passed": 1456,
      "fact_total": 1500,
      "fact_pct": 97.1,
      "benchmark_methods": 520,
      "hotupdate_passed": 48,
      "hotupdate_total": 48,
      "hotupdate_pct": 100.0,
      "memory_alloc_bytes": 85983232,
      "memory_gc_pause_ns": 230000000
    }
  ]
}
```

### `GET /api/reports/{date_tag}`

获取单日报告详情及原始数据。

**响应:**
```json
{
  "summary": { "...": "同上" },
  "data": { "完整 nightly-data JSON" }
}
```

### `GET /api/compare?a=20260613&b=20260614`

对比两日数据。

**响应:**
```json
{
  "report_a": { "date_tag": "20260613", "fact_pct": 95.0 },
  "report_b": { "date_tag": "20260614", "fact_pct": 97.1 },
  "dlls_a": { "System.Private.CoreLib": { "fact_passed": 70, "fact_total": 70 } },
  "dlls_b": { "System.Private.CoreLib": { "fact_passed": 68, "fact_total": 70 } }
}
```

### `GET /api/search?q=System.Linq`

按 DLL 名称搜索历史数据。

| 参数 | 类型 | 说明 |
|------|------|------|
| q | string | 搜索关键词（模糊匹配） |

### `GET /api/dll/{name}/trends?days=30`

单个 DLL 的历史趋势。

### `POST /api/ingest?date_tag=20260614`

将 nightly-data JSON 文件解析并写入 SQLite。由 `collect-all-results.sh` 自动调用。

## 前端页面

Landing Page (`/`) 包含 4 张 ECharts 趋势图：

1. **正确率趋势** (折线图) — Fact 通过率随时间变化
2. **基准测试方法数** (柱状图) — Benchmark 方法数变化
3. **内存分配** (折线图) — Nursery Alloc 变化
4. **热更新通过率** (折线图) — HotUpdate 通过率变化

## 保留策略

| 层级 | 存储 | 保留期 | 清理方式 |
|------|------|--------|---------|
| 热存储 | 文件系统 | 永久 | 手工清理 |
| SQLite | 数据库 | 永久 | 手工清理 |
| 冷存储 | tar.gz | 可配置 | `scripts/archive.sh` |

---

*Last updated: 2026-06-14*
