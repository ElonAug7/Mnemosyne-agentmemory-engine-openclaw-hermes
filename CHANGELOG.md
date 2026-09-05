# Changelog

All notable changes to Mnemosyne.

## [v6.4.0] — 画像抽取重构 + 工作区瘦身（2026-08-22）

### A. profile 画像抽取重构（cmdProfile）
- **根因**：旧版 profile.md 只是「从 MEMORY.md 二次复制」，memory-native 基准里画像推断命中率 0%（四类查询里唯一全灭），且 techCount=0、决策风格抽不到
- **升级为多源真实信号提炼**：
  - medium 摘要块（#decision/#tech/#planning 标签，逐文件跳过 [superseded] 旧文本）
  - current.json 的 recent_decisions/recent_facts/open_questions（经 isProfileSignal 噪音过滤）
  - MEMORY.md 结构化段（关键事实 → 拆成干净技术标签，而非整句塞入）
- **技术栈识别**：TECH_KEYS 词表（OpenClaw/Qwen/百炼/Ubuntu/VirtualBox/Mnemosyne 等），过泛词（node/python/js/react/vue/git）不放画像避免误判
- **决策风格/沟通风格**：conciseScore vs detailScore、fastScore vs slowScore 多源计数判定，修正旧版窄关键词漏配
- **画像完整度诚实化**：从「轮数虚高」（5171 轮→95%）改为「内容实质计分」（tech+focus+pref+style+personality），修复成熟度与内容脱节
- **Bug 修复**：`${maturity}` 插值失效（普通字符串而非模板字面量）、React/Vue 误判（扫到 [superseded] 历史）

### B. 工作区瘦身（删冗余）
- 删除 11 个 benchmark 临时工作区 `ws-r1~r5/ws-flaky/ws-probe/ws-trace4/5/ws-rel/ws-final2`（~900KB，纯残留）
- 删除 `__pycache__` + `elite/plugins/.../__pycache__`（Python 缓存）
- 回收区：`/tmp/.mnemosyne-recycle-20260822`（可恢复，未直接 rm）
- **保留**：`elite/`（Hermes 适配层，README 活跃交付章节）、`bge-daemon.py`（未接入主路径的本地语义层，待拍板）

### 版本
- VERSION → v6.4.0（同步 engine.js / hermes-bridge.js / install-elite.sh 回退常量）
- 测试套件 8/8 通过，搜索延迟 7.27ms < 50ms 硬指标

## [v6.3.0] — 检索本质重构（BM25 + 延迟回归修复）(2026-08-16)

### 背景
基于 `/media/sf_openclaw/mnemosyne-v62-bench-结果` 的 Memory-Native Evaluation 基准：v6.2 排名 9/11（nDCG@10=0.046），被裸 BM25（0.185）和多个嵌入系统碾压。根因：检索排序被 imp/recency 绑架（占 0.60 权重）、中文问句 bigram 词汇鸿沟、画像/事实问句全军覆没。

### Changed — 检索打分
- **真 BM25 打分**（`buildBM25Stats` + `bm25Score` + `normalizeBM25`）：把 keyword 分量从「伪 IDF 求和（Σidf×0.045）」升级为 Okapi BM25（IDF + term-frequency + 文档长度归一化，k1=1.5/b=0.75），经 sigmoid 归一化到 [0,0.5] 供复合线索公式使用
- **权重重平衡**：kwScore 0.25→0.45，imp 0.35→0.20，recency 0.25→0.15，检索与记忆价值解耦（imp 管「值不值得记」，不管「排不排前」）
- **kw=0 强制降级 ×0.3** + meaningfulHit 门馈（kwScore≥0.12）——防「elon/openclaw」全场命中词的假命中触发加成类信号
- **unigram 回退**：bigram 零命中时用有意义单字召回（UNIGRAM_FUNC_CHARS 过滤功能字），至少 2 字命中才召回
- **长期层无 ts 不再拿时间中性分**：长期知识不该靠时间衰减排挤关键词命中

### Changed — 性能（修复 P50 从 57ms 回归到 248ms）
- MMR/RIF 精排只作用于前 60 条（O(n²) 循环没必要跑满全候选池）
- MMR gram 集合只算一次（旧版每对候选都重跑 regex）
- `meaningfulUnigrams` / 查询分词按 query 缓存（queryTokenCache）
- `trackHit` 同步写盘 → `scheduleHitFreqSave` 批量延迟写（300ms debounce + flush），长层搜索 19ms 主因消除

### Added
- `bge-daemon.py`：本地中文语义 Embedding Daemon（bge-small-zh-v1.5 ONNX int8 量化，24MB，纯本地零网络，stdin/stdout JSONL 协议）——为 P0 语义层预留

### 基准结果（本地复现 harness，80 查询）
- 官方 v6.2：nDCG@10=0.046 / Hit=0.075
- 裸 BM25 基线：nDCG=0.185
- **v6.3（P1+P2+P3+BM25）**：nDCG@10=**0.238** / MRR=0.199 / Hit@10=0.388 / F1=0.112 / P50=62ms
- 相较 v6.2 提升 **5.2×**（nDCG），已反超裸 BM25 基线（+29%）和所有嵌入系统

## [v6.2.0] — 加固版 (2026-08-15)

### Fixed（种子用户反馈 + 自测发现，共 10 项）
- ui.js 环境变量：统一为 MNEMOSYNE_ROOT → HERMES_WORKSPACE → OPENCLAW_WORKSPACE → ~/.mnemosyne，且调引擎时注入 OPENCLAW_WORKSPACE（Hermes 环境 UI 空白 + 数据错位的根因）
- install-elite.sh：补 Windows 检测目录（LOCALAPPDATA/hermes/{skills,plugins}）
- install-elite.sh：set -u 安全（SKILL_DEST/PLUGIN_DEST 初始化 + LOCALAPPDATA/APPDATA ${VAR:-} 兑底）
- engine.js：distill-reject 假命令（HELP 有但 dispatch 无）→ 实现 cmdDistillReject
- engine.js：cmdCleanup 未定义 dirsToCheck 导致 cleanup --confirm 崩溃 → 定义 11 目录
- hermes-bridge.js：空记忆注入「（无相关记忆）」噪声 → 返回空串
- 版本号三处不一致（engine v6.1.0 / bridge v6.0.0 / install v6.0.0）→ VERSION 文件单一真相
- 插件适配层 prefetch 空记忆噪声
- MEMORY.md / CHANGELOG 版本记录滞后

### Added
- **Hermes 原生插件适配层**（elite/plugins/hermes-mnemosyne/）：MemoryProvider ABC 6 核心方法 + 4 hook，纯 Python 标准库，零依赖
- install-elite.sh `--hermes-plugin` / `--plugin-dir` 插件安装模式
- **测试套件**（tests/）：引擎 CLI / cleanup / distill / 安装流程 / UI 双环境 / Hermes 模拟集成 / 去重与噪音，run-all.sh 一键跑
- `medium-dedupe [--confirm]` 命令：2-gram 相似度压缩 medium 重复摘要块（相邻相似度≥0.7 时新块替换旧块）
- consolidate 写入时相邻块去重防护（根治 08-11 式同一窗口重复摘要）
- 待办噪音过滤升级：拦截 markdown 表格行/标题行，移除误伤合法待办的右括号规则
- **假命令大扫除**：HELP 文档化的 19 个命令中 backup/backup-log 实际未实现（health 还推荐用户跑它）→ 已实现（git init+commit）；其余 17 个纯虚构命令（version/version-diff/version-history/conflict/restore/save/export/timeline/time-travel/sessions/permission/config/devlog/ask/stale/imp-calibrate/reindex-all）已从 HELP 删除，文档与实现完全对齐

## [v6.1.0] — Cognitive Effects Pack (2026-08-11)

### 论文筛选报告先行（v6-plan.md）
- 筛掉与路线冲突的 5 篇：Memory Networks、Neural Turing Machine、PMMC、OpsMem、SuperLocalMemory 4.0
- 确认 14 篇已对齐理论（Ebbinghaus → Provenance Laundering）

### Added
- **首因效应 Primacy**：>30 天且 high-imp 的记忆搜索排序 +0.03
- **检索诱发遗忘 RIF**（Anderson & Bjork 1994）：同次搜索中同 topic 低分项 ×0.7
- **测验效应 Testing Boost**（Roediger & Karpicke 2006）：recall 命中临时强化
- **Zeigarnik 待办信号**：含待办线索的记忆加权
- **contextBonus / confidenceMultiplier**：上下文加成与低置信度降权
- UI「v6.1 复古终端控制盘」+ Windows MSYS/MinGW + Hermes 第三方适配验证数据

## [v5.0.0] — Compound-Cue Core (2026-08-09)

### v5 核心升级：复合线索评分模型

基于「复合线索理论」(Compound-Cue Theory) 对检索架构的全面重构。
不做加法做减法：把 imp + time decay + keyword + hit frequency 融为单次评分，替代旧版多路并行 merge。

### Added
- **复合线索评分模型** (`compoundScore()`): 统一公式 `α·imp + β·recency + γ·keyword + δ·hit_frequency`
- **time.js 正式接入搜索排序**: 半衰期衰减 (`2^(-age/halfLife)`) 生效于每条搜索结果
- **命中频率追踪** (hit-frequency.json): 忆阻器式动态权重，被多次命中的记忆自动加权
- **用户自定义标签**: `record --tags "tag1,tag2"` 支持，标签匹配权重 ×3
- **性能探查器**: `--profile` 开关，输出各阶段耗时分析 (P50/P99)
- **内存热区缓存**: LRU 缓存最近 7 天数据，消除重复文件 I/O
- **语义异步化**: keyword-first 策略 — 关键词结果先出 (15ms)，语义 200ms 内后补重排

### Changed
- `searchLayer()`: 全面改用缓存读文件 (`cachedReadFile`/`cachedReadDir`)
- `multiPathSearch()`: 从「并行搜索 + merge」重构为「keyword-first + compound scoring + semantic async fire-and-forget」
- `cmdStatus()`: 新增 cache 统计、hitFreq 统计、_v5 特性标记
- 版本号统一为 `VERSION = 'v5.0.0'`

### Fixed
- searchLayer 文件 I/O 瓶颈：13+ 次 sync readFileSync → ~3 次（首次缓存 miss 后全部命中）

### Design
- 零依赖、零新增行数（重构简化代码）
- 向后兼容：所有旧 API 不变，tags 字段可选

---

## [v4.5-Pro] — Modular Architecture (2026-08-08)

### Added
- **5 independent modules** (time.js, refusal.js, rewrite.js, multihop.js, crosslang.js)
- Time-aware: dynamic half-life by information type (7-90 days), relative time anchors, conflict resolution
- Refusal front-loading: score distribution detection, 3-tier confidence, keyword coincidence detection
- Query rewrite: session-level dynamic context (stateless), post-retrieval expansion, rewrite safety valve
- Multi-hop reasoning: atomic sub-question decomposition, per-hop verification, evidence chain completeness
- Cross-language: 100+ bilingual entity mapping, automatic query expansion, output language constraints

### Design
- Modular: each feature is an independent `modules/*.js` file, hot-swappable
- Zero new dependencies
- Engine +41 lines (3,291 total), 18.6KB of module code

---


## [v4.5-bilingual] — English Edition (2026-08-08)

### Changed
- **UI fully translated to English** — all labels, buttons, stats, layer names
- **Bilingual tokenizer** — `tokenize()` handles Chinese 2-gram + English word extraction + bilingual stopwords
- **Layer names** — API and UI both use English (Workbench, Daily, Chat Logs, Index, Medium, Long-term, Todos, Other)
- Engine core unchanged (same imp scoring, same 5-mode search, same consolidate pipeline)

### Benchmarks vs v4.5 (Chinese)
- Search quality: English queries return comparable results to Chinese queries on same concepts
- Latency: No measurable difference (tokenizer change is O(n) with same complexity)
- Engine size: 3,255 lines (same as v4.5)

---


---

## [v4.5] — The Lean Engine (2026-08-08)

> Cut 56% of commands. Same performance. Not just trimming — rethinking what matters.

### Added
- **P0: 9-dimensional imp scoring** — up from 7 dimensions
  - Fix 4: Dual-keyword combo detection (+0.20). 5 cross-domain pairs (e.g., "deploy" + "model").
  - Fix 5: Negation/correction detection (+0.25). "No, that's wrong" / "try another approach".
  - Fix 6: Comparative decision detection (+0.18). "A is better than B" patterns.
  - Fix 7: Commitment/promise detection (+0.35, strong promises → 0.90). "I guarantee", "I swear", "never again forget".
- **P0: Memory QA command** — `qa --query "..."` with 4-way recall (context + profile + search + MEMORY.md)
- **P1: Search result dedup** — `dedupeResults()` removes near-duplicate results from same file
- **P2: Topic continuation v2** — semantic overlap detection between current and previous topics, plus 4-mode dialogue classification (instruction/question/confirmation/discussion)
- **P2: Chinese tokenizer** — `tokenizeChinese()` 2-gram segmentation + stopword filtering, zero extra deps
- **P1: Write batching** — record batches 10 messages or 30s before triggering sync/reindex/consolidate
- **Memory-Native Evaluation Protocol v1.0** — 80 queries across 4 types (cross-session / temporal / conflict / profile) with 5-dim scoring (EM/F1/TA/RB/PC)

### Changed
- **44 → 20 commands** (-55%). Engine 3,768 → 3,250 lines (-14%).
- **Web UI streamlined**: removed workbench widget, floating buttons, heatmap, time machine, growth log, tool group, eval panel (:8766)
- **install.sh fixed** (all versions): auto-rename now targets `WORKSPACE/tools/memory-engine` instead of script parent dir
- **Reference manual rewritten**: 455-line MNEMOSYNE-REFERENCE.md covering capabilities, architecture, limitations, and honest comparison vs 6 systems

### Removed
`time-travel` `stale` `conflict` `ask` `timeline` `sessions` `content-index` `permission` `config` `devlog` `signal` `save` `export` `backup` `backup-log` `version` `version-history` `version-diff` `record-raw` `reindex-all` `imp-calibrate` `distill-reject` `save-distill`

### Benchmarks
- **6-system comparison**: SQLite FTS5 <1ms · v4.5 42ms · ChromaDB 158ms · AgentMemory 160ms · Mem0 ❌
- **vs AgentMemory 0.4.8**: keyword 42ms (3.9× faster), RAM 0MB vs +105MB, zero model download vs 79MB
- **LoCoMo T0** (30 docs, 20 QA): 8 systems tested, honest R@K results documented with methodological caveats

### Roadmap
- **Line 1**: Zero-NN + Spreading Activation (pure math, zero deps)
- **Line 2**: imp → TF-IDF → activation → local embedding → local LLM (mainstream pipeline with imp noise filter)

---

## [v4-pro] — Evaluation-Ready (2026-08-07)

### Added
- 251 manual imp calibration samples with TF-IDF KNN + 5-fold CV (MAE 0.168)
- Standalone evaluation panel at :8766 (bench.js + imp-evaluate.js + locomo-adapter.js)
- System message auto-detection (heartbeat/error/continuation → imp 0.02)
- LoCoMo Composite score: 67/100

---

## [v4] — Memory Echo (2026-08-07)

### Added
- **Context**: topic continuation — detects >12h gaps, greets with "Last time we discussed X, welcome back"
- **Recall**: auto-trigger on high-imp user messages (imp≥0.4, len>20) → writes `last-recall.json`
- **Topic tags**: #decision #planning #tech auto-labeled on summary blocks
- **Quality self-assessment**: each block gets `<!-- quality: ✅ -->` or missing-category notes
- **Dialogue mode detection**: instruction/question/confirmation/discussion
- **Knowledge gap tracking**: "I don't know / let me check" patterns
- **Heartbeat heatmap**: 30-day activity visualization
- **Time Machine**: MEMORY.md version browsing and restore

---

## [v3] — Security Hardening (2026-08-06)

### Added
- POST+CSRF protection on all write endpoints
- Truncation protection: imp≥0.7 messages backed up to medium before truncation
- IMP_TECH scoring dimension (optimize/refactor/architecture/bug/performance/security)
- Hook failure detection with compensation scanning

### Changed
- Todo extraction limited to medium summaries and manual adds (reduced noise)

---

## [v3-lite] — Stripped (2026-08-06)

### Removed
- Version management, Git backup, permission control, distill review, manual calibration, record-raw toggle, content index, dev log, signal. 14 commands, core pipeline intact.

---

## [v2] — User Experience (2026-08-06)

### Added
- Runtime config via `config.json` (retention/thresholds/weights)
- Recycle bin (15-day retention, restore/purge)
- Suggested cleanup for expired files
- **Consolidate**: auto-writes medium-term summary blocks (triggered by message count, imp threshold, or imp sum)
- **Nightly distill**: 22:30 cron auto-extracts long-term memory proposals

---

## [v1] — Initial Release (2026-08-05→06)

### Added
- **4-layer memory architecture**: index → short(raw/working/inject) → medium → long
- **Semantic index**: local bigram+trigram vectors (512-dim), no external embedding API
- **7-way parallel search**: 5 modes × 7 channel weights (keyword/semantic/hybrid/recent/history)
- **Web Console** at :8765: file browser, Markdown render, JSONL chat bubbles, search
- **Gateway Hook**: auto-records all messages with imp scoring
- **Portable install**: Linux systemd + macOS launchd, zero hardcoded paths
- Named **Mnemosyne** — after the Greek goddess of memory, mother of the Muses

## [v6.5.0] — 本地语义词典 + 检索修复 (2026-09-05)

### Fixed
- cmdRecall/hook recall 传参 bug：`multiPathSearch(query, 'hybrid')` 字符串当 opts → 实际跑 keyword；改 `{mode:'hybrid'}`
- recall 层截断 bug：结果只取前 20（raw 高 imp 刷榜）→ medium/long 永远被挤出 → 新增 layerTopK 保底召回
- semanticSearch 性能 bug：维度不匹配分支对每个 item 重算 `localEmbed(item.text)`（3127 次 → 600ms+）；改直接用 item.vec
- 语义等待上限 200ms → 80ms（keyword 首出 ~20ms 达标，语义快则合并慢不阻塞）

### Added
- 本地语义词典 `data/semantic-dict.json`（纯本地零 LLM 零 embedding API）：800+ 同义词条 + 概念组（性能优化/bug修复/真机调试/定时任务等 20 组）+ 中英映射；engine.js 启动合并进 SYNONYM_DICT + 概念组扩展（expandSynonyms）
- 语义索引自动构建：recall/hook 路径空索引时自动 embed（纯本地 512 维字向量）
- 向量二进制列存：embeddings.bin（float64 顺序写，加载零解析）；embeddings.json 13MB → 938KB（仅元数据）
