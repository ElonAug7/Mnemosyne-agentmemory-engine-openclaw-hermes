# Changelog

All notable changes to Mnemosyne.

## [Unreleased] — 隐私修复：远端 embedding 改为默认关闭（2026-10-06）

**背景.** 一位 awesome-list 维护者（`dell-zhang`）在审查条目时读了 `engine.js` 并指出：条目声称
"no network"，但代码并不相符。经复核，**他的每一条都属实**，且问题自 v5.0.0 起就存在。

### Security

- **远端 embedding 默认关闭**（`remoteEmbedEnabled: false`）。原先 `remoteEmbed()` 会在
  `findDashScopeKey()` 返回 key 时把文本 POST 到 `https://dashscope.aliyuncs.com/compatible-mode/v1/embeddings`，
  且 `loadState()` 默认 `semanticEnabled: true` —— `cmdRecord()`（hook 路径）与 `cmdRecall()` 在索引为空时会
  自动构建，**用户无需做任何事就会联网**。现在只有显式 `embed --enable-remote` 之后才会发起网络请求。
- **修复跨厂商 API key 泄漏**：`findDashScopeKey()` 原先用 `apiKey.startsWith('sk-')` 兜底，
  会把配置里第一个 `sk-` 开头的 key（可能是 OpenAI / DeepSeek 等）**连同用户记忆文本一起发给 DashScope**。
  现在只接受 `baseUrl` 明确指向 dashscope 的条目。
- **修复必然失败的 Authorization 头**：原为 `'Authorization': '***' + key`（疑似被脱敏工具改坏源码），
  应为 `'Bearer ' + key`。该 bug 导致请求必然 401 —— 也正因如此，历史上没有造成更大的外发，
  但它同时意味着远端路径**从来没有真正工作过**。

### Added

- `tests/test-no-network-by-default.sh` —— 断言默认路径下**零外部网络请求**（回环放行），
  并含**反向对照**：`embed --enable-remote` 后必须确实尝试连接 dashscope，以证明闸门是"关着"而非"坏了"。
- `embed --enable-remote` / `embed --disable-remote` 显式开关；`status` 中新增 `remoteEmbedEnabled` 字段。

### Fixed

- README 中"网络依赖：零 — 默认不联网"、"无需 embedding 模型"、"零 API key"等表述与实现不符，
  已改为如实描述（默认零联网；远端路径默认关闭、需显式开启、且会读取 DashScope key）。

> **数据外发事实（如实记录）**：本机配置含真实 DashScope key，索引构建于 2026-09-25 07:40。
> 因 `remoteEmbed()` 是「先 fetch 再判 `!r.ok`」，且首批即 401 中断，**实际外发为前 10 条文本（约 1.5 KB）**，
> 不是全部 6670 条。检索词未外发（`semanticSearch` 的远端分支有 `vec.mode === 'remote'` 前置条件，本机为 `local`）。

## [Unreleased] — WebUI restyled to the KVAXIR design system (2026-10-06)

### Changed
- **`ui-page.html` rewritten to KVAXIR design system v2** (token source: `kvaxir/core/theme_palette.py`,
  contract: `kvaxir/docs/UI-DESIGN-CONTRACT.md`). Replaces the neon / glassmorphism look.
  - Banned primitives eliminated (counts are **occurrences** in the old file, not lines):
    `border-radius` 31→0, `box-shadow` 3→0, `backdrop-filter` 6→0, `gradient` 7→0, `animation` 8→0.
  - Single monospace family (`Noto Sans Mono CJK SC`); font sizes limited to the 3 contract levels
    11/13/18 plus the brand wordmark at 15.
  - Dark-graphite tokens (`#0E0F11` / `#17181B` / `#2A2C31` / `#C9CED6`), plus a `data-theme="light"`
    warm base (`#F7F4EF` / `#1F4E8C`) so components never assume a dark base.
  - Components mapped to KVAXIR primitives: `GButton`, `GTextField`, `GDataRow` (telemetry rows),
    `NavPill`, `GToast`. Emoji decoration and marketing/anthropomorphic copy removed.
- **Repository layout**: the 15 per-version directories are gone; each past release is now a git tag
  whose tree root is that release. See the tag table in `README.md`.

### Fixed
- Cleanup / trash modals used `var(--card)` / `var(--line)`, which were never defined, so both dialogs
  rendered with a transparent background. Now tokenised (`--panel` / `--hairlineBright`).
- Switching language wiped the file currently on screen (`applyLanguage()` overwrote `#content`
  unconditionally). It now only redraws the empty state, and telemetry labels re-translate.

### Verified
- Playwright over 1075 rendered nodes: 1 font family, sizes only 11/13/15/18, radius 0 everywhere,
  no shadows, no blur, no background images, no animations.
- Flows re-tested: file list (237 items), layer filters, file open (raw + markdown), search,
  report telemetry, ZH/EN toggle, dark/light base toggle. `node --check` clean.

### Performance — 单次搜索 I/O 从 90 MB 降到 10 MB（2026-10-06）

三项独立修复，每项都单独实测归因；**全部修复均验证搜索结果逐条不变**。

- **`loadVectors()` 加进程内缓存**：原先没有任何缓存，每次调用都
  `JSON.parse(embeddings.json 2.7MB)` + `readFileSync(embeddings.bin 27MB)`；一次
  `search --mode hybrid` 会调用 3 次 → 80 MB。
  **为什么不复用既有的 `memCache` / `cachedReadFile`（有意为之，非遗漏）**：
  `cachedReadFile()` 返回的是 `.toString('utf8')` 的**字符串**，而向量需要二进制 buffer 才能建立
  零拷贝的 `Int16Array` / `Float64Array` 视图；且 `memCache` 是面向小文本的 LRU（TTL 7 天 / 500 条），
  把 27 MB buffer 塞进去会把有用的缓存全挤掉。故为向量单设一个二进制缓存。
  （核实：`loadVectors()` 函数体内不含 `memCache` / `cachedReadFile` 任何引用，只有 `readFileSync`。）
- **向量改 int16 量化列存**（8 字节头 `MNVEC2\n\0`；无头 = 旧 f64 裸数据，自动兼容并迁移）。
  **头长度必须为偶数**——否则 `Int16Array` 视图对不齐，会退化成每次加载整块复制 6.8 MB
  （初版写成 7 字节的 `MNVEC2\n`，正好踩中这个坑，已改）。
  记号：`Q = VECTOR_QUANT = 10000`；`k` 为整数，满足「落盘值 === k / Q」。
  - **为何无损**：`normalize()` 写出的就是 `Math.round(x*Q)/Q`，即精确的 `k/Q`。
    所以 `Math.round(v*Q)` 是**把 k 还原出来**，不是对已有精度再做一次有损取整。
    实测全部 3,415,040 个值：`np.array_equal(还原, 原值) = True`，`|k|max = 10000 ≤ 32767` 不溢出。
  - **为何用查表**：`LUT[k+Q]` 预先算好 `k/Q`；JS 里 `k/Q` 产生的 double 与原始
    `Math.round(x*Q)/Q` **逐位相同**，故点积结果与旧 f64 存储完全一致。查表免掉逐元素除法，
    零额外开销；相比之下整体解量化成 Float64Array 需 10.7 ms，反而比现状 5.3 ms 更慢。
    （整体除以标度、把 `Q` 提到求和号外**不等价**——会改变末位精度，故不采用。）
- **`stale.json` 批写**：原先每命中一行就「整读 38 KB + 解析 + 全量排序 + 整写」，
  一次搜索触发 60+ 次读写；改为进程内累加、退出时一次落盘。
  **这一项才是 `searchLayer:long` 31.3 ms → 2.0 ms 的真正原因**——归因依据见下表逐项数据
  （同一固定状态快照、`--profile` 逐层计时、每变体 best-of-3）。
- （附带）`match()` 的查询侧小写化预计算。**实测仅省约 1.7 ms**，远小于原先估计——
  long 层的开销原本几乎全在 `trackMemoryHit` 的 I/O 上。保留，但收益可忽略。

逐项归因（`searchLayer:long`，ms，同一固定状态快照 / best-of-3）：

| 变体 | base | B(缓存) | **C(stale批写)** | D(小写) | CD | ACD(全部) |
|---|---|---|---|---|---|---|
| long 层 | 31.28 | 27.28 | **2.05** | 29.61 | 2.00 | 2.15 |

> `ACD`(2.15) 与 `CD`(2.00) 的 0.15 ms 差异在测量噪声内（计时为 ms 级、best-of-3）；
> 且 long 层根本不接触向量，A 不可能影响它。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 单次搜索读 | 75 次 / 90.1 MB | **38 次 / 10.3 MB** |
| 单次搜索写 | 36 次 / 1.34 MB | **3 次 / 0.11 MB** |
| 端到端耗时 | 253 ms | **169 ms** |
| `searchLayer:long` | 31.3 ms | **2.0 ms** |
| `embeddings.bin` | 27.32 MB | **6.83 MB** |
| 记忆库总计 | 44 MB | **23.4 MB** |

> **搜索结果不可跨次复现。** `trackHit()` 在检索过程中改写 `hit-frequency.json`，而该文件又反过来
> 参与打分 —— **未打补丁的引擎自己就会漂移**（已验证：同一查询、同一引擎，连跑第 3 次结果指纹即改变）。
> 这是既有行为，**不是本次改动引入的**；也正因如此，比对结果必须从固定状态快照出发。

> 打 tag 但本文件无对应小节的版本：`v6.0.0`（Elite 层首次并入）、`v5.0.0-hermes`（Hermes 桥接）。
> Tags without a section here: `v6.0.0`, `v5.0.0-hermes`.

## [v6.5.0] — Local Dictionary Semantics + Recall Pipeline Fixes (2026-09-05)

### Fixed
- `cmdRecall`/hook recall argument bug: `multiPathSearch(query, 'hybrid')` passed a string as opts → silently ran keyword mode; now `{mode:'hybrid'}`
- Recall layer truncation: top-20 pool was dominated by high-imp raw hits, medium/long layers never surfaced → new `layerTopK` guaranteed recall
- `semanticSearch` performance bug: dimension-mismatch branch recomputed `localEmbed` per item (3127 items → 600ms+); now uses stored vectors directly (~6× faster)
- Semantic merge timeout 200ms → 80ms (keyword path stays <50ms; semantics merge when fast, never block)
- Version constants drifted (v6.4.0 leftovers in engine.js / elite bridge / install script)

### Added
- Local semantic dictionary `data/semantic-dict.json` — 800+ synonym entries, 20 concept groups (performance/bugfix/debug/timers...), CN↔EN mappings; merged into query expansion at startup. Pure dictionary: no LLM, no embedding API, editable like config
- Automatic local semantic index bootstrap on recall/hook when empty (512-dim character n-gram vectors, fully offline)
- Binary vector column store `embeddings.bin` — zero-parse loading; index JSON 13MB → 938KB (metadata only)

### Notes
- Full test suite 8/8 passing · latency keyword ~10-40ms < 50ms target

## [v6.4.0] — User Profile Reconstruction (2026-08-22)

### Changed
- **Profile extraction rewrite** (`cmdProfile`): upgraded from "copy MEMORY.md" to multi-source distillation
  - Medium summary blocks (`#decision`/`#tech`/`#planning` tags, skips `[superseded]` stale text)
  - Working-memory decisions/facts with benchmark-debug noise filtering
  - MEMORY.md structured sections → clean tech-stack tags (no raw sentence dumps)
- **Tech-stack detection**: curated keyword table (OpenClaw/Qwen/Bailian/Ubuntu/VirtualBox/Mnemosyne...); over-generic terms (node/python/js/react/vue) excluded to avoid false positives
- **Style/pace inference**: multi-source score-based (concise vs detail, fast vs deliberate) instead of narrow keyword matching
- **Honest maturity**: content-based scoring (tech+focus+pref+style+personality) replaces inflated turn-count percentage

### Fixed
- `${maturity}` interpolation bug (plain string instead of template literal)
- React/Vue false positives from scanning `[superseded]` history

### Removed
- 11 leftover benchmark workspaces (`ws-*`) + Python cache dirs (~900KB reclaimed)

## [v6.3.0] — Retrieval Core Reconstruction (2026-08-16)

### Changed
- **True BM25 scoring** (Okapi BM25: IDF + term-frequency + length normalization, k1=1.5/b=0.75), sigmoid-normalized into the compound-cue formula
- **Weight rebalance**: keyword 0.25→0.45, imp 0.35→0.20, recency 0.25→0.15 — retrieval decoupled from memory value
- **kw=0 forced demotion** (×0.3) + meaningful-hit gating; unigram fallback when bigram hits are zero
- **Performance fixes**: MMR/RIF rerank limited to top-60, gram sets cached, query tokenization cache, hit-frequency batched writes (300ms debounce) — P50 back from 248ms to 62ms

### Benchmark (Memory-Native Evaluation, 80 queries)
| System | nDCG@10 |
|---|---|
| v6.2 | 0.046 |
| raw BM25 baseline | 0.185 |
| **v6.3** | **0.238** (+5.2× vs v6.2, beats raw BM25 and all embedding systems) |

## [v6.2.0] — Hardening (2026-08-15)
- Test suite (8 scripts), single-source-of-truth VERSION file
- Hermes native plugin adapter layer; `install-elite.sh --hermes-plugin`
- Medium-block dedupe (106 duplicate blocks → 0)
- Fixed 10+ bugs incl. ui.js env handling, install `set -u`, cleanup crashes

## [v6.1.0] — Cognitive Effects Pack (2026-08-11)
- Scoring additions: primacy effect, RIF penalty (Anderson & Bjork 1994), testing boost (Roediger & Karpicke 2006), Zeigarnik todo signal, context bonus, confidence multiplier
- Retro-terminal Web UI; Windows MSYS/MinGW + Hermes third-party adapter verification

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

## [v4.5.0-pro] — Modular Architecture (2026-08-08)

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


## [v4.5.0-en] — English Edition (2026-08-08)

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

## [v4.5.0] — The Lean Engine (2026-08-08)

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

## [v4.0.0-pro] — Evaluation-Ready (2026-08-07)

### Added
- 251 manual imp calibration samples with TF-IDF KNN + 5-fold CV (MAE 0.168)
- Standalone evaluation panel at :8766 (bench.js + imp-evaluate.js + locomo-adapter.js)
- System message auto-detection (heartbeat/error/continuation → imp 0.02)
- LoCoMo Composite score: 67/100

---

## [v4.0.0] — Memory Echo (2026-08-07)

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

## [v3.0.0] — Security Hardening (2026-08-06)

### Added
- POST+CSRF protection on all write endpoints
- Truncation protection: imp≥0.7 messages backed up to medium before truncation
- IMP_TECH scoring dimension (optimize/refactor/architecture/bug/performance/security)
- Hook failure detection with compensation scanning

### Changed
- Todo extraction limited to medium summaries and manual adds (reduced noise)

---

## [v3.0.0-lite] — Stripped (2026-08-06)

### Removed
- Version management, Git backup, permission control, distill review, manual calibration, record-raw toggle, content index, dev log, signal. 14 commands, core pipeline intact.

---

## [v2.0.0] — User Experience (2026-08-06)

### Added
- Runtime config via `config.json` (retention/thresholds/weights)
- Recycle bin (15-day retention, restore/purge)
- Suggested cleanup for expired files
- **Consolidate**: auto-writes medium-term summary blocks (triggered by message count, imp threshold, or imp sum)
- **Nightly distill**: 22:30 cron auto-extracts long-term memory proposals

---

## [v1.0.0] — Initial Release (2026-08-05→06)

### Added
- **4-layer memory architecture**: index → short(raw/working/inject) → medium → long
- **Semantic index**: local bigram+trigram vectors (512-dim), no external embedding API
- **7-way parallel search**: 5 modes × 7 channel weights (keyword/semantic/hybrid/recent/history)
- **Web Console** at :8765: file browser, Markdown render, JSONL chat bubbles, search
- **Gateway Hook**: auto-records all messages with imp scoring
- **Portable install**: Linux systemd + macOS launchd, zero hardcoded paths
- Named **Mnemosyne** — after the Greek goddess of memory, mother of the Muses
