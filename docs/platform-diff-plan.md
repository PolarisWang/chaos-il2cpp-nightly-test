# 方案 A：双平台同-commit 对比 — 完整改动方案（v2，含 review 修正）

> 目标：让 Windows / Linux nightly 成为**可比的平台差异探针**，而不是两份互不相干的报告。
>
> v2 修正了 v1 的三处重大遗漏（executor 语义、Windows 路径隔离、TEMP 冲突）。

---

## 零、前置核查结果（v2 新增）

### 0.1 Executor 现状

`jenkins/init.groovy:14-18` + **live 容器实测**：

| node | label | executors | 类型 |
|---|---|---|---|
| `linux-x64` | linux x64 native | **2** | 容器 `chaos-agent-x64` |
| `linux-x64-cr` | linux-x64-cr code-review | 1 | 容器 |
| `windows-x64` | windows-x64 windows x64 msvc | **1** | **物理机 JNLP agent**（`setup.ps1` 手工注册） |

### 0.2 🔴 v1 的致命遗漏：加 executor 不是改配置

**`init.groovy` 只新建、不更新已存在的 node**：

```groovy
if (Jenkins.instance.getNode(a.name) == null) { ...写 config.xml... }
else { println "Agent ${a.name} already exists" }   // ← 改数无效
```

`windows-x64` 已存在于 live 容器（`/var/jenkins_home/nodes/windows-x64/config.xml`，实测 `numExecutors=1`）。
**改 `init.groovy` 的 `executors: 1 → 2` 对现网无效**，需要另外的更新机制（见 §三 Step 0）。

### 0.3 🔴 更致命：Windows 侧无 workspace 隔离，加 executor 会**制造随机故障**

| | Linux | Windows |
|---|---|---|
| 引擎源 | `BOOMING_DIR` | `WINDOWS_BOOMING_DIR` |
| **实际构建树** | `${WORKSPACE}/engine-src` ← **per-executor 隔离** ✅ | **直接用 `winBoomin`（固定路径）** ❌ |

```groovy
def winBoomin = env.WINDOWS_BOOMING_DIR ?: 'D:/agent/workspace/booming-il2cpp'   // :556
git -C "${winBoomin}" fetch --depth=1 origin main                                // :604
git -C "${winBoomin}" reset --hard origin/main                                   // :607
cd /d "${winBoomin}/tests/e2e"                                                   // :635
```

**两个 executor 会共用同一个 `D:\agent\workspace\booming-il2cpp`**，交叉执行 `reset --hard`、`rmdir` 产物 → **结果不可信**。

**结论：加 executor 之前，必须先给 Windows 侧做 per-executor 路径隔离。** 这与 Linux 侧早已完成的做法对齐。

### 0.4 次要冲突：`%TEMP%` 共享

`Jenkinsfile:903` 用 `"%TEMP%\win_rc.txt`（我上一轮加的 gate）。多 executor 下 `%TEMP%` 相同 → 文件互踩。应改用 `${env.WORKSPACE}` 下的路径。

---

## 一、方案 review：数据正确性

### 1.1 当前对比为何不可信（本会话实际踩坑）

用 Windows `honest-report-20260912` 对比 Linux `20260922`，得出"Linux real 执行率普遍 1/4"——**错误**。正确对齐后：

```
35 个可比 chunk：
  gap > 25%：仅 2 个
  gap > 10%：仅 4 个
  其余 31 个：±10% 内，多数 <3%
  （DiagnosticSource/global-ns: 51.2% vs 51.2% 完全相同）
```

**三层错误，方案每步堵一层**：

| 层 | 问题 | 对策 |
|---|---|---|
| L1 | 两报告**不同 commit**（09-12 vs 09-22，中间插入改 ATG 行为的 `ShapeRegistryIndex`） | Step 1 锚点 + Step 2 engineSha |
| L2 | 分母**未对齐**（W 的 `F_nom` vs L 的 `total`） | Step 3 统一取 `realPassed/realTotal` |
| L3 | 无判定逻辑，靠肉眼 | Step 3 自动分三类 |

### 1.2 主指标选择

| 字段 | 可比性 | 用途 |
|---|---|---|
| `realPassed` / `realTotal` | ✅ | **主指标**：真实执行的断言占比 |
| `gatePassed` / `gateTotal` | ✅ | 次指标（已排除 stubGap/factoryGap） |
| `stubGap` / `factoryGap` | ✅ | **解释差异成因** |
| `chunk_passed` / `chunk_total` | ⚠️ | 粒度太粗，仅飞书卡片概览 |

**必须用比率而非绝对值**：两侧 `total` 常不等（`xml`: W=411 / L=746），因 ATG 生成 subject 数受主机影响。

### 1.3 正确性边界（必须在报告中体现）

- 两侧 `total` 不等是**常态**，判定用**比率差**
- 某侧 `total < 30` → 标"样本不足"，不参与判定
- 两侧 `total` 差 > 50% → 标"解释需谨慎"

---

## 二、方案 review：报告能否指导开发

### 2.1 核心价值：自动分三类

| 类别 | 判定 | 开发动作 |
|---|---|---|
| 🔴 **平台差异** | \|Δ\| > 25% 且样本充足 | **靶心，进平台适配 backlog** |
| ⚪ **两侧共有低覆盖** | 两侧 real% 均 < 20 且 Δ < 10 | ATG/codegen 通用问题，**与平台无关**，不进适配排期 |
| ✅ **一致** | Δ ≤ 10% | 健康，仅回归监控 |

以本会话数据为例：

```
🔴 平台差异 (2)：  Xml.ReaderWriter/{xml, system-xml-schema}
⚪ 两侧共有 (10)：  Brotli/ZipFile/Linq/Text.Json/Net.Sockets ...
✅ 一致 (23)
```

**把"看起来到处都坏"收敛成一个短列表** —— 这正是我前几轮靠肉眼做、低效且出错的事。

### 2.2 补充维度（避免误导）

- **gap 排序**：按 \|Δ\| 降序
- **stubGap/factoryGap 对比**：W≈0 而 L 很大 → **ATG 判定两侧不一致**，比"断言失败"更根因
- **total 一致性标记**：差 > 50% 时提示

---

## 三、改动清单（v2，含新增的 Step 0）

| Step | 内容 | 风险 | 工作量 |
|---|---|---|---|
| **0** | **Windows per-executor 隔离**（加 executor 的前置条件） | **中** | ~2h |
| **1** | Jenkinsfile `ENGINE_REVISION` 锚点 | 中 | ~1h |
| **2** | `aggregate.py` + CI 注入 `engineSha` | 极低 | 30min |
| **3** | 新增 `build-platform-diff.py` | 无 | 2h |
| **4** | 飞书 payload 调整 | 低 | 1h |

**建议顺序：2 → 3 → 4 → 1 → 0**
先做"能验证、能看"的低风险项，再做锚点，最后动 executor（因为它牵连路径重构）。

### Step 0 — Windows per-executor 隔离 + executor=2

**0a. 路径隔离**（模仿 Linux 的 `engine-src` 模式）：

```groovy
// 替换固定 winBoomin 为 executor 私有树
def winEngSrc = env.WINDOWS_BOOMING_DIR ?: 'D:/agent/workspace/booming-il2cpp'  // 仅作 git 源
def winBoomin = "${env.WORKSPACE}/engine-src"                                    // 本 executor 私有
// 首次：git clone --local 或 xcopy 源树；后续：git fetch+checkout
```

**0b. TEMP 冲突**：`:903` 的 `%TEMP%\win_rc.txt` → `${env.WORKSPACE}\win_rc.txt`

**0c. executor 更新机制**（因为 `init.groovy` 不更新已有 node）：

```groovy
// init.groovy 的 else 分支改为幂等 upsert（读现有 config.xml，改 numExecutors 后回写）
} else {
    def cfg = new File(agentDir, "config.xml")
    if (cfg.exists()) {
        def txt = cfg.text.replaceAll(/<numExecutors>\d+<\/numExecutors>/,
                                      "<numExecutors>${a.executors}</numExecutors>")
        cfg.text = txt
        println "Updated ${a.name} -> ${a.executors} executors"
    }
}
```

**注意**：改 `init.groovy` 只在 Jenkins **重启**（重跑容器初始化）时生效，需与运维确认窗口。

**0d. 校验**：加完后确认 `windows-x64` 有 2 个 executor，且两次并发跑**产物不互踩**。

### Step 1 — Jenkinsfile commit 锚点

```groovy
// parameters
string(name: 'ENGINE_REVISION', defaultValue: '',
       description: 'Engine commit for BOTH platforms. Empty = pin origin/main at Dispatch.')

// Dispatch stage（linux-x64-cr，已有）一次性解析
def pinned = params.ENGINE_REVISION?.trim() ?: sh(
    script: "git --git-dir='${BOOMING_DIR}/.git' rev-parse origin/main",
    returnStdout: true).trim()
env.PINNED_ENGINE_REVISION = pinned

// Linux（替换 :468 附近）
git --git-dir='${engSrc}/.git' archive ${PINNED_ENGINE_REVISION} | tar -x -C ...

// Windows（替换 :604-607）
git -C "${winEngSrc}" fetch --depth=1 origin ${PINNED_ENGINE_REVISION}
git -C "${winBoomin}" checkout --detach ${PINNED_ENGINE_REVISION}
```

**保留** `:626` 的 untracked 清理（`checkout` 同样不清理 untracked）。

### Step 2 — 报告落 engineSha

`tests/e2e/verification/nightly/aggregate.py`（引擎仓库）：

```python
payload = { ..., "engineSha": os.environ.get("CHAOS_ENGINE_SHA", "") }
```

Jenkinsfile 两侧：`export CHAOS_ENGINE_SHA='${PINNED_ENGINE_REVISION}'`

### Step 3 — `scripts/build-platform-diff.py`（新增）

```
用法：
  build-platform-diff.py --linux <linux.json> --windows <win.json> --output <out>

校验：
  1. 两侧 engineSha 存在且相等，否则 abort
  2. 任一为空 → 标 "unverifiable"，出报告但顶部警告
  3. total < 30 → "insufficient sample"，不参与判定

输出：platform-diff-<date>.json + .md（三类分组）
```

### Step 4 — 飞书 payload 调整

**4a. 卡片头部**加 engineSha 短 hash（一眼确认同源）
**4b. 新增「🔴 平台差异 (N)」区块** —— **按你的决定，只显示计数**
**4c. `verdict()` 加规则**：两侧 engineSha 不等 → `yellow`，reason="两平台非同源，差异不可比"
**4d. 保留**现有"绝对判定"哲学（不用百分比阈值触发告警，避免狼来了）

---

## 四、v2 review 发现的其他风险

| # | 风险 | 说明 | 对策 |
|---|---|---|---|
| R1 | **Jenkins 重启窗口** | `init.groovy` 改动只在容器重启生效 | 与运维排窗口 |
| R2 | **Windows 磁盘空间** | 每 executor 一份完整引擎树（~2GB+），现有 228GB 可用 | 够用，但需监控 |
| R3 | **首次隔离的拷贝成本** | 第一跑需 clone/xcopy 整树 | 用 `git clone --local` 加速 |
| R4 | **锚点改变语义** | 从"跑最新 main"→"跑 Dispatch 时刻的 main" | 定时 nightly 行为一致；手动触发更可预测 |
| R5 | **两侧 total 差异** | 非 bug，但会让绝对数对比误导 | 报告强制用比率 + 显示基数 |
| R6 | **Step 3 脚本无归属** | 放 `chaos-il2cpp-nightly-test/scripts/`（CI 仓库），不放引擎 | 明确 |

---

## 五、待确认

1. **Step 0c 需要 Jenkins 重启** —— 能否安排窗口？或接受"手工在 UI 改 executor 数"（临时方案，重启后被 init.groovy 覆盖回 1）
2. **Step 0a 的隔离方式**：`git clone --local`（快，但需维护）vs 每跑 `git worktree`（更轻）
