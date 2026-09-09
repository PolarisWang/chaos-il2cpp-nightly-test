# chaos-il2cpp Windows Nightly Agent — Jenkinsfile 手工修改说明
# 本文档说明如何在现有 Jenkinsfile 中新增 windows-x64 全量流水线阶段。
# 如果你希望一键应用, 这是 `Jenkinsfile.patch` 的内容说明与逐段手工替换。

## 背景

现有 Jenkinsfile 的 `linux-x64 Full Pipeline` 阶段（约 L141-177）负责跑全量
nightly_runner, 并带 `--skip-ingest --skip-minio`, 产物进 `${WORKSPACE}/artifacts`。
我们在此基础上**并行**加一个 windows-x64 阶段, 让 Linux 与 Windows 同时跑同一套
build → fact → benchmark → hotupdate, 各自独立产出。

关键差异（Windows 侧）:
1. 用 `bat()` 而不是 `sh()` —— Windows agent 没有 bash (除非装了 Git Bash)。
2. 路径分隔符全用正斜杠 `/`（Python / CMake 都接受）。
3. 产出目录用独立 `nightly-run-windows`, 避免与 Linux 结果互相覆盖。

## 手动替换片段

### A. 在 `linux-x64 Full Pipeline` 阶段结束（`}` 闭合后）插入以下代码:

位置: 原文件 `stage('linux-x64 Full Pipeline') { ... }` 的右大括号之后,
`// linux-arm64 — Smoke Test` 注释之前。

```groovy
        // ─────────────────────────────────────────────────────
        // windows-x64 — Full Pipeline (并行)
        // ─────────────────────────────────────────────────────
        stage('windows-x64 Full Pipeline') {
            when { expression { env.DISPATCHED != 'true' } }
            agent { label 'windows-x64' }
            steps {
                script {
                    bat """
                        if not exist "${ARTIFACTS_DIR}" mkdir "${ARTIFACTS_DIR}"
                        cd /d "${BOOMING_DIR}/testing/foundation-dll"
                        echo === [win-x64] Full Pipeline ===

                        python -m verification.nightly_runner.main ^
                            --report-dir "${ARTIFACTS_DIR}/nightly-run-windows" ^
                            --max-workers 4 ^
                            --bench-workers 2 ^
                            --native-config "${BUILD_CONFIG}" ^
                            --stage-timeout 600
                    """ 
                }
            }
        }
```

### B. （可选）把 Linux 阶段也包进 parallel, 让两侧真正同时跑

若不改, Linux 与 Windows 是**串行**的（先 Linux 完成再 Windows）。
要对角并行, 把 `linux-x64 Full Pipeline` 与 `windows-x64 Full Pipeline` 两个 stage
合并进一个 `parallel { }`。完整做法:

```groovy
        stage('Full Pipeline (linux + windows)') {
            when { expression { env.DISPATCHED != 'true' } }
            parallel {
                stage('linux-x64') {
                    agent { label 'linux-x64' }
                    steps { script { /* 把原 linux-x64 阶段的 sh"" ... "" 逻辑搬进来 */ } }
                }
                stage('windows-x64') {
                    agent { label 'windows-x64' }
                    steps { script { /* 上方 bat"" ... "" 逻辑 */ } }
                }
            }
        }
```

## 产物收尾

- windows 阶段不额外调用 publish-nightly-results / report —— 汇总仍由 Linux 侧完成。
- Windows 的 artifact JSON 会落在这台的 `${WORKSPACE}\artifacts\nightly-run-windows\`,
  由 `post { archiveArtifacts }` 归档, 可从 Jenkins 构建页 Artifacts 下载查看。
- 由于基准不同, Windows 结果刻意不并入 Linux 的 `nightly-data` 汇总,
  避免污染服务器基线。

## 失败弹性

- 若 Windows agent 掉线或工具缺失导致该 stage 失败, 只要该 stage 单独失败,
  其余 Linux/arm64/android 阶段不受影响（每个 agent 独立 node）。
- 如需"Windows 失败不红整个构建", 可在 bat 后加 `|| exit 0` 或用
  `catchError(buildResult: 'UNSTABLE') { ... }` 包裹。

## 验证方法

1. 先手动触发一次: Jenkins → chaos-il2cpp-nightly → Build with Parameters。
2. 在 Stage View / Blue Ocean 看是否出现 `windows-x64 Full Pipeline` 且落在你的机器。
3. 确认产物在构建页 Artifacts 里能下载。
