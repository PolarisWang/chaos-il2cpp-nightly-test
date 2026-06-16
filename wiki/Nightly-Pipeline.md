# Nightly Build 管线

## 触发方式

- **定时触发**: Jenkinsfile 内 cron `H 3 * * *`（每日 03:00-04:00 之间）
- **手动触发**: Jenkins → `chaos-il2cpp-nightly` → "立即构建"，或 API:

```bash
curl -X POST http://10.10.1.173:8080/job/chaos-il2cpp-nightly/buildWithParameters \
    --user qa004:abcd@1234
```

## 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `BOOMING_REPO` | `/booming-il2cpp` | 源码仓库路径（Docker volume 挂载） |
| `BUILD_CONFIG` | `profile` | 编译配置 (profile/debug/ship) |

## 执行流程

### 阶段 1: Init

在 linux-x64 节点上设置 `ARTIFACTS_DIR` 环境变量。

### 阶段 2: 多平台并行

```
linux-x64 (全量)
  ├── 遍历所有有 chunks/ 的 DLL
  ├── 每个 DLL 执行 8 个阶段
  └── collect-all-results.sh 汇总

linux-arm64 (冒烟)
  └── 对 System.Linq / System.Collections / System.Text.Json
      执行 fact 阶段

android-arm64 (编译验证)
  └── fix_all_failures.py --platform android
```

### 阶段 3: SonarQube 分析

x64 + arm64 并行执行 sonar-scanner。

### 阶段 4: Allure 报告

如果 `_allure-results` 存在，生成 Allure HTML 报告。

### 阶段 5: Nightly 报告

```
generate-nightly-report.py
  ├── 读取 nightly-data-<date>.json
  ├── 自动发现前一日 baseline（如有）
  ├── 生成 nightly-report-<date>.html
  ├── 复制到 /var/lib/report-server/daily/
  ├── POST /api/ingest → Report API → SQLite
  └── publishHTML (Jenkins 归档)
```

### 阶段 6: 飞书通知

```
sendNightlyNotification() → notify-feishu.sh
  ├── 读取 nightly-data 中的汇总指标
  ├── 构建双按钮交互卡片
  ├── 📊 查看报告 → REPORT_URL
  └── 🔧 Jenkins Build → JENKINS_URL
```

## 每个 DLL 的 8 个阶段详解

```
① build
   │
   ├── AutoTestGenerator (ATG)
   │   --all-types → --emit-metadata → subjects.metadata.json
   │
   ├── dotnet build CombinedSubjects.csproj → CombinedSubjects.dll
   │
   ├── TestProjectGenerator (TPG)
   │   generate-dll → C++ codegen → CMake → entry.exe
   │
   ├── Hephaestus 缓存
   │   ├── CACHE HIT: 直接恢复缓存的 entry.exe
   │   └── CACHE MISS: 完整 ATG + TPG 构建
   │
   └── --profile 注入
       └── runtime-entry.cpp 补丁 → entry.exe 支持 --profile

② fact
   entry.exe --fact-json
   ├── AOT: entry.exe
   ├── JIT: entry-jit.exe (如果存在)
   └── 交叉对比: AOT vs JIT 结果一致性

③ benchmark
   entry.exe --benchmark-all
   ├── 自适应迭代校准 (adaptive)
   └── AOT + JIT 独立跑

④ hotupdate
   ├── ATG --patch-mode (如果目标 DLL 存在)
   ├── 无 patch DLL → 只跑 assert + semantic check
   └── revert 验证

⑤ profile
   entry.exe --profile
   ├── 逐方法记录: GC/heap_before/heap_after
   ├── Nursery 分配量 / GC 暂停时间
   └── 本批次多数 DLL 无 profile 数据

⑥ coverage-audit
   └── manifest 声明的方法数 vs meteorology 实际覆盖数

⑦ aggregate
   └── 汇总所有 chunk 数据，写入 _dll/reports/latest/

⑧ reporting
   └── 写入 per-assembly 报告数据库
```

## Docker volume 挂载

booming-il2cpp 源码仓库**不通过 git clone** 获取，而是由 `docker-compose.yml` 直接挂载：

```yaml
volumes:
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:ro   # master
  - /home/debian/agent/booming-il2cpp:/booming-il2cpp:rw   # agent
```

Agent 上的测试框架入口: `/booming-il2cpp/testing/foundation-dll/verification/`

## 数据聚合

所有 DLL 跑完后：

```
collect-all-results.sh
  ├── 扫描所有 DLL chunks/*/results/*.json
  ├── 生成 nightly-data-<date>.json
  └── POST /api/ingest → Report API → SQLite
```

## 失败处理

- 每个 DLL 的 pipeline 失败不会终止整体构建（`|| echo "WARNING"`）
- 失败 DLL 会在飞书通知中列出
- `FAILED_PLATFORMS` 记录 arm64 失败

## 超时设置

- Pipeline 总超时: 6 小时
- TPG build: 2 小时
- ATG: 20 分钟
- Fact: 10 分钟
- Benchmark: 自适应

---

*Last updated: 2026-06-16*
