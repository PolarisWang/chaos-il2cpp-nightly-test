# Code Review Report

- 范围: e73edbe..6a518bfa（49 commits，34 可审查文件）
- 时间: 2026-08-27
- 严重度: 严重 1 / 中 7 / 轻 8 / 建议 5（共 21）
- 说明: 此前多批 Jenkins 构建因模型输出异常未能完成 review，本次用修复后的审查脚本重新捡起审完。

## Findings

### 🟠 #1 [中] .ai/skills/hooks/check_repo_clean_hook.py:46-48

过滤条件 `not s.startswith("[repo-clean] repo")` 判定过宽：它会丢弃所有以 "repo" 开头、实际是违规记录的过滤结果（例如某条真实违规行 "[repo-clean] repo-root has junk file x"）。该过滤本意是排除干净的汇总头，却把一类正是本钩子要提示的脏目录违规系统性吞掉了，导致 nudge 漏报，与本钩子的核心目的（清理根目录顽固垃圾）相悖，属于静默功能缺陷。同时 s.strip() 后并未对空行做跳过处理。

- fix: 改为显式精确排除汇总头（如 `if s.startswith("[repo-clean] repo is clean") or not s.startswith("[repo-clean] ")` 后跳过，或让 check_repo_clean.py 输出结构化 JSON 并解析，避免字符串前缀猜测）。

### ⚪ #2 [轻] .ai/skills/hooks/check_repo_clean_hook.py:42-53

_violations() 通过对子脚本 check_repo_clean.py 的 stdout 前缀字符串（"[repo-clean] "）进行文本匹配来提取结果，与子脚本输出格式强耦合、无版本/契约约束。一旦 check_repo_clean.py 的日志前缀或措辞调整，本钩子会静默退化为永远返回空列表（返回 []），脏目录不再触发任何提示，且没有任何告警暴露该退化。

- fix: 让 check_repo_clean.py 支持 `--json` 输出结构化违规，钩子解析 JSON；或在钩子检测到 0 违规且子脚本执行成功时打一条 debug 日志以便排查。

### ⚪ #3 [轻] .github/workflows/hygiene-gate.yml:24-28

upload-artifact 无条件上传硬编码路径 artifacts/hygiene-report.json，但并未验证 chaos_hygiene.py --ci 一定生成该文件。若脚本不产出该文件（路径变化或未生成 report），artifact 步骤会报错导致整个 job 标记失败，制造虚假的 CI 红线（false negative），掩盖真正的 hygiene 结果。

- fix: 在执行步骤中先检查 `test -f artifacts/hygiene-report.json`，不存在则输出 ::warning 并跳过上传；或将 upload 步骤的条件设为 `if: always()` 且仅在文件存在时上传。

### 🟢 #4 [建议] .ai/skills/hooks/check_repo_clean_hook.py:20-27

_repo_root() 用写死的 `range(6)` 向上探测 .git，而真实路径 `.ai/skills/hooks/` 只需向上 4 层即命中，6 这个魔法数字没有文档说明其容差来源（如应对桌面级深层克隆路径）。一旦仓库目录深度或钩子位置变动，探测可能提前停止或冗余遍历，行为隐晦。

- fix: 用 `Path.cwd()`/`__file__` 直接基于仓库惯例定位，或将 6 提取为常量并注释其设计依据，且在找不到 .git 时记录一行可诊断日志（当前静默返回 None）。

### 🟢 #5 [建议] .ai/skills/hooks/check_repo_clean_hook.py:55-75

状态去重文件 .claude/.repo-clean-state.json 的读写没有加锁或原子写（write_text 非原子，先截断再写）。PostToolUse 钩子可能被并行进程同时触发，在两个进程都对同一次新的脏状态各自评估 signature 时可能产生竞态，导致重复提示或漏提示。当前仅影响提示体验，危害有限。

- fix: 改为 write via 临时文件 + os.replace() 原子替换，并对同签名重复提示做进程内校验；或直接依赖 signature 全量比对容忍极小竞态。

### 🟢 #6 [建议] docs/archive/dev-completed/scripts-orphaned-2026-08-27/check_wiki_links.py:3-9

docstring 中的 Usage 仍是原位置 'python scripts/codegen/check_wiki_links.py'，与脚本实际所处归档目录 docs/archive/dev-completed/scripts-orphaned-2026-08-27/ 不一致，会误导后续维护者。

- fix: 更新用法示例为归档路径，或新增一行说明该脚本已被归档仅作参考。

### 🟠 #7 [中] docs/archive/dev-completed/scripts-orphaned-2026-08-27/populate_all_families.py:3

LEDGER_PATH 硬编码了 Windows 绝对路径 D:/agent/booming-il2cpp/...，而在本 Linux 仓库中运行 open() 必然崩溃，完全不跨平台；同时归档脚本引用的是活动 ledger 的绝对路径，若在不同机器上执行会落到不存在的盘符。

- fix: 改为基于脚本所在位置或仓库根解析相对路径（如 os.path 结合 Path(__file__).resolve() 定位），或用 --ledger 命令行参数传入路径。

### ⚪ #8 [轻] docs/archive/dev-completed/scripts-orphaned-2026-08-27/populate_all_families.py:27-30

af = families.get(...) 在 family 不存在时返回 None，随后 af["methodSubjectIds"] 直接下标索引会产生难以定位的 TypeError('NoneType' object is not subscriptable)；且与末尾 print 循环中使用的 families[full_id] 下标访问方式不一致，同样会抛 KeyError，错误处理路径不明确。

- fix: 先校验 familyId 是否存在并给出清晰报错日志（raise KeyError 或打印缺失 family 后 continue），统一用带默认值的安全访问。

### ⚪ #9 [轻] docs/archive/dev-completed/scripts-orphaned-2026-08-27/populate_all_families.py:159-162

json.dump(data, ...) 在循环外无条件执行，即使 data 中不存在 System.Private.CoreLib（未命中任何 family、未实际填充任何方法）也会回写 ledger 并打印 "All families populated"，输出具有误导性，且有可能静默覆盖（清空）目标集合。

- fix: 记录实际命中并填充的 family 计数，若为 0 则跳过 json.dump 并打印明确的未命中告警。

### 🔴 #10 [严重] src/native/runtime-core/runtime_stubs/crypto_stubs.cpp:108-124

ChaosCngHash 修复了缓冲区过度读取，但 alloc_byte_array 返回的 result 在被 get_managed_array_mut 访问时，若分配失败返回 0 则在 result != 0 分支外未检查，逻辑基本正确；但更关键的是：该函数在 BCryptOk 失败时仍存在 return 0 的静默哨兵路径，虽非本次改动引入，但本次改动让成功路径返回真实哈希、失败路径返回 0，调用方（managed 端）无法区分『空哈希』与『失败』，语义模糊。此外 ChaossGetBytes 在 outData==nullptr 时 return 0 未分配释放 path，存在轻微资源无泄漏（无持有）。核心严重问题：ChaosCngHash 用 alloc_byte_array 分配后，在 copy 之前未验证 result 是否确实为有效 managed 数组（若 get_managed_array_mut 返回 nullptr 会解引用崩溃），缺少空指针防御。

- fix: 在 memcpy 前增加对 outArr/outData 的 nullptr 校验，失败路径显式区分并返回已分配数组（或释放 result 再返回 0 哨兵并 logging）

### 🟠 #11 [中] tests/contracts/native/runtime-core/crypto_hash_behavior_test.cpp:35-55

make_byte_array 通过 std::calloc 在堆上伪造一个 ManagedArrayAccessor 结构（32字节头 + 连续字节），但测试函数名是 ChaosSha1Hash/ChaosSha256Hash 而非经过修改的 ChaosCngHash/ChaosCngHmac。这些 SHA/MD5 走的是 OpenSSL 或兄弟路径，其契约（inArr->length 的语义）可能与 CNG 路径不同。若这些函数原先是正确实现（非 return 0），则该测试并未真正回归 CNG 的 return 0 修复点，测试未能覆盖到实际修改的混沌 CNG 哈希/HMAC/GetBytes 代码——是“假覆盖”，测试诚信存疑。被测试的 SHA 函数并未在 diff 中修改（只有 CNG 家族被改）。

- fix: 将测试改为直接调用 ChaosCngHash/ChaosCngHmac/ChaosCngGetBytes，或用同样的伪造数组驱动真实验证 CNG 返回不再是 0；若 SHA 用 OpenSSL 则明确标注测的是 OpenSSL 并行路径

### 🟠 #12 [中] scripts/wct_deadlock_spy.cpp:78-110

wct_deadlock_spy.cpp 新增诊断工具使用 Windows WCT（Advapi32.dll）且包含 <wct.h>，但仅有 Windows 实现，无任何 #ifdef _WIN32 守卫。若该文件进入 CMake 全局源列表（scripts/ 目录），跨平台（linux/arm64/android/ios）构建会因缺 <windows.h>/<wct.h> 直接编译失败，违反平台适配性要求。虽标注为 diagnostic 工具，但文件位于 scripts/ 且提交在仓库内，构建配置存在被打包编译的风险。

- fix: 将文件整体用 #if defined(_WIN32) || defined(_WIN64) 守卫，并在 CMakeLists 中将其仅加入 Windows 目标，或移到 Windows-only 目录

### 🟠 #13 [中] tests/contracts/native/runtime-core/gc_mark_stall_repro.cpp:60-105

gc_mark_stall_repro 用 2400×16KB 对象（约37MB）构建 806 页 old-gen 图，但仅跑一次 Collect 且 GC 只 raw 扫描第一字为 TypeInfo 的地址。Setup 一旦 OOM（return 1）即退出，测试对『mark 停滞』的断言依赖超时 20s，在多页大堆 37MB 分配在 CI 低内存环境中可能因 OOM 假失败而非真正暴露停滞。且 exit 124 被当作停滞复现，但用超时信号化正常慢 GC 于慢机器上易误报回归（假阳性）。

- fix: 将 kSeedObjectBytes/个数按环境内存自适应，或对分配失败做 retry/提示而非直接 return 1；停滞判定改用并行 mark watchdog 日志而非粗粒度 20s 超时

### ⚪ #14 [轻] scripts/gc/gc-baseline.py:15-25

gc-baseline.py 中 DEFAULT_BENCHMARK_EXE = "testing/build/runtime-core/gc/RelWithDebInfo/test_gc_regression_benchmark.exe"，路径硬编码指定 .exe 扩展名与 RelWithDebInfo 构建子目录，跨平台（Linux 实为 test_gc_regression_benchmark 无 .exe）下无法解析，且硬编码了具体构建子目录名，违反平台适配性。

- fix: 在 _resolve_exe 中不做 .exe 后缀强绑，优先通过 PATH/CMake cache 或探测现有构建目录获取可执行文件名，去掉 RelWithDebInfo 硬编码

### ⚪ #15 [轻] scripts/cleanliness/chaos_hygiene.py:109-113

chaos_hygiene.py 在 _dispatch 中对每个 check 用 timeout=check.get("timeout",180) 默认为 180 秒：若磁盘健康检查（disk-health）走 _dir_size_mb 的可信有界遍历，实际应较慢；但 hygiene 中 subprocess 超时 180s 与 check_generated_up_to_date 每次 spawn 120s 叠加，在 CI 上若 generator 偶发慢会因超时把 PASS 误判为 FAIL（spawn 失败），产生假负。且非 --report 模式仍可能重写 STATUS.md 无门控。

- fix: 超时失败（spawn/timeout）应显式标记为 WARN 而非 FAIL，或让生成器漂移检查容忍首轮慢编译；并在非 report/ci 模式禁止写 STATUS.md

### ⚪ #16 [轻] src/native/runtime-core/gc/gc_old_gen.cpp:1455-1515

gc_old_gen.cpp 新增的 S2 mark watchdog 线程（std::thread watchdog）在每轮做 300ms sleep 后采样，但缺少对 ctx 生命期的一次性保护：若并行 mark 因异常中途返回，watchdog 在 loop 已通过 while(!watchdog_stop) 的判断后仍可能在 join 前读到已释放的内存。虽该路径下 RunWorkers 正常完成才置 stop，但整个 watchdog 属于日志类探针，其本身使用 std::fprintf 直接写 unbuffered stderr 在并发多 worker 写时无互斥，可能交错输出混淆日志，但非功能性错误。

- fix: 给 watchdog 的 stderr 输出加互斥（复用 g_print 或独立 mutex），并确保先 join watchdog 再释放 ctx 相关引用

### 🟢 #17 [建议] docs/archive/dev-completed/scripts-orphaned-2026-08-27/populate_synthetic_subject_ids.py:149-156

populate_synthetic_subject_ids.py 为 9 个“type-forwarded to System.Runtime”且表面清单无数据的 DLL 生成 SYNTHETIC_METHOD_PATTERNS（固定 .ctor/get_Property/Method1..Validate 等）的假方法 ID，使 methodCount>0。这是用臆造的合成数据美化审计数据：测试/审计诚信存疑，审计 ledger 被填充了并非真实存在的 API 方法 ID，且位于 archive 目录但函数注释仍指向 production 路径（scripts/codegen/ 路径已二次改变），脚本父目录 REPO_ROOT 与其声明不一致。

- fix: 对无表面数据的家族显式标记为 UNKNOWN/methodCount=0 或 pending,勿用合成 ID 填充;并同步脚本实际所在路径使 REPO_ROOT 正确解析

### 🟢 #18 [建议] src/native/runtime-core/gc/gc_bgc.cpp:1456-1535

PauseForYoungGc 变成有界等待（2s 超时每 500us 轮询）在快速无竞争的 young GC 路径上每次都会 sleep_for(500us) 至少一次，即便 ack 通过 bgc_cv_.notify_all 应已被唤醒：这在每个 young GC 引入该 fast-path 之前没有的固定 500us～1ms 延迟，属于可避免的年轻代 STW 命中热点性能回退。尤其在有活跃 BGC mark 的常见路径下，young GC 每秒可能数十次 × 500us sleep 会实质拉长暂停。

- fix: 改用条件变量带超时 cv.wait_for 或双阶段忙等（先自旋避免 sleep 初始化），仅在超时边界才 sleep，压低 fast-path 延迟到亚微秒
