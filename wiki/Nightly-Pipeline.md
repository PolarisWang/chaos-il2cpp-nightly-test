# Nightly Build 管线

## 触发方式

- **定时触发**: Jenkins 内置 cron `H 3 * * *`（每日 03:00-04:00 之间）
- **手动触发**: Jenkins 页面点击"立即构建"，或 API:

```bash
curl -X POST http://localhost:8080/job/NightlyPipeline/build \
    --user admin:abcd@1234
```

## 执行流程

### 阶段 1: 多平台并行编译

```
03:00 ── 触发
         │
         ├── linux-x64  ── cmake --preset linux-x64-packaging
         ├── linux-arm64 ── cmake --preset linux-arm64-smoke
         └── android-arm64 ── cmake --preset android-arm64-smoke
```

### 阶段 2: linux-x64 全量测试 (4-8h)

```
build → fact → profile → benchmark → managed_benchmark
      → benchmark_report → hotupdate → coverage-audit → aggregate
```

24 个 DLL 以 4 个为一组并行执行，每批超时 7200s：

```
Batch 1: System.Private.CoreLib, System.Collections,
         System.Collections.Immutable, System.ComponentModel.TypeConverter

Batch 2: System.Data.Common, System.Diagnostics.DiagnosticSource,
         System.Formats.Asn1, System.IO.Compression.Brotli
...
```

### 阶段 3: 数据聚合

```
collect-all-results.sh
  ├── 扫描所有 DLL chunks/*/results/*.json
  ├── 生成 nightly-data-<date>.json
  └── POST /api/ingest → SQLite 趋势数据库
```

### 阶段 4: 报告生成

```
generate-nightly-report.py
  ├── 读取当前数据 + 自动发现前一日 baseline
  ├── 生成 nightly-report-<date>.html
  ├── 复制到 /var/lib/report-server/daily/
  └── 更新 nightly-latest.html 软链接
```

### 阶段 5: 质量扫描 + 通知

```
SonarQube 扫描 (3 平台并行)
Allure 报告发布
飞书卡片推送 + 邮件通知（仅失败时发邮件）
```

## 报告内容

生成的 HTML 报告包含：

1. **汇总卡片**: 构建状态、正确率、基准测试方法数、热更新通过率、内存分配
2. **Per-DLL 表格**: 每个 DLL 的 Fact/Benchmark/HotUpdate/Memory 指标
3. **Benchmark 回归对比**: 与前一日 baseline 的 Δ% 差异（绿色↑ / 红色↓）
4. **Chunk 详情**: 可展开查看每个 chunk 的具体数据
5. **回归告警**: 方法数下降的 DLL 列表 + 方法数上升的 DLL 列表

## 测试维度

| 阶段 | 产出 | 评估标准 |
|------|------|---------|
| build | 编译日志 | 编译通过/失败 |
| fact | chunks/*/results/fact.json | passed/total, valueSuspicious |
| profile | results/profile.json | GC pause, nursery alloc, fastPathRate |
| benchmark | results/benchmark.json | 方法耗时 |
| managed_benchmark | benchmark-history.jsonl | .NET 8/10 基线对比 |
| benchmark_report | comparison.json | 跨技术栈差异 |
| hotupdate | results/hotupdate.json | patch/revert 通过率 |
| coverage-audit | coverage-audit.json | 指令覆盖率 |

## 参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `BOOMING_REPO` | `/booming-il2cpp-nightly` | 源码仓库路径 |
| `BUILD_CONFIG` | `profile` | 编译配置 (profile/debug/ship) |

---

*Last updated: 2026-06-14*
