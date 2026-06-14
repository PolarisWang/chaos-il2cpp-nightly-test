# 质量看板

## Landing Page 说明

报告服务器主页 (`http://host:8081/`) 提供质量看板功能：

### 趋势图区域

4 张 ECharts 图表展示关键质量指标的长期趋势：

1. **正确率 (Fact)** — 折线图，显示每日 Fact 通过率百分比
   - 绿线: 通过率 100%
   - 黄线: 通过率 90-99%
   - 红线: 通过率 <90%

2. **基准测试方法数 (Benchmark)** — 柱状图，显示每日被测试的基准方法总数
   - 方法数突降 = 可能漏测或代码变更
   - 方法数突增 = 新增测试覆盖

3. **内存分配 (Nursery)** — 折线图，显示每日 Nursery 区域内存分配总量
   - 持续增长 = 可能内存泄漏

4. **热更新通过率 (HotUpdate)** — 折线图，显示每日热更新补丁通过率

### 最近报告表格

显示最近 14 天每份报告的核心指标：日期、正确率、基准测试数、热更新结果、内存分配、DLL 覆盖率。

## Nightly 报告说明

完整 HTML 日报 (`/daily/nightly-report-YYYYMMDD.html`) 包含：

### 汇总卡片

| 卡片 | 指标 | 颜色规则 |
|------|------|---------|
| 构建 | 有数据的 DLL 数 / 总 DLL 数 | 全绿 = 全部有数据 |
| 正确性 | Fact 通过率 | 绿 ≥100%, 黄 ≥90%, 红 <90% |
| 性能 | Benchmark 方法总数 | 中性（黄色） |
| 热更新 | HotUpdate 通过率 | 绿 = 全部通过 |
| 内存 | Nursery Alloc + GC Pause | 中性 |

### Per-DLL 表格

| 列 | 内容 |
|----|------|
| Assembly | DLL 名称 |
| Fact | 通过率（可展开查看各 chunk 详情） |
| Benchmark | 方法数 |
| BMK Δ | 与前一日对比的变化（有 baseline 时显示） |
| HotUpdate | pass/total |
| Memory | 分配总量 |
| GC Pause | GC 暂停时间 |
| Status | PASS / FAIL |

### Benchmark 回归对比

当存在前一日 baseline 时，报告会生成：

1. **Regression 告警** — 方法数下降的 DLL 列表（红色边框卡片）
2. **Improvement 提示** — 方法数上升的 DLL 列表（绿色边框卡片）

Delta 显示格式: `+5 (+2.5%)` 绿色 / `-3 (-1.5%)` 红色

---

*Last updated: 2026-06-14*
