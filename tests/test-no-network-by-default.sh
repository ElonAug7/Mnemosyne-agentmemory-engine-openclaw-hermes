#!/usr/bin/env bash
# ============================================================
# test-no-network-by-default.sh
# 断言：Mnemosyne 在默认配置下**不发起任何外部网络请求**。
#
# 背景：v6.6 之前引擎会静默地把记忆文本 POST 给 dashscope.aliyuncs.com
# （remoteEmbed 默认走远端、且 findDashScopeKey 会用 sk- 前缀误抓别家 key）。
# 本测试防止该行为回归。
#
# 判据：
#   ① 默认配置下：fetch / http / https 均**无外部目标**（127.0.0.1 回环放行）
#   ② 显式 embed --enable-remote 后：确实会尝试连 dashscope（证明闸门是"关着"而非"坏了"）
# ============================================================
set -uo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ENGINE_DIR/engine.js"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT

# ---- 造一个最小工作区 ----
mkdir -p "$WS/memory"/{short/raw,short/working,short/inject,medium,index,engine,long,dreaming}
cat > "$WS/memory/short/raw/$(date +%F).jsonl" <<'JSONL'
{"role":"user","text":"test message one about memory engine","ts":"2026-10-06T00:00:00Z","imp":0.8}
{"role":"assistant","text":"reply about the memory engine internals","ts":"2026-10-06T00:00:01Z","imp":0.5}
JSONL
cat > "$WS/memory/medium/$(date +%F).md" <<'MD'
# 2026-10-06

## #decision
- Use local hashed vectors, never send text off the machine.
MD

# ---- 网络探针：拦截 fetch / http.request / https.request ----
cat > "$WS/probe.js" <<'PROBE'
const fs = require('fs');
const http = require('http');
const https = require('https');
const out = process.env.NET_PROBE_OUT;
const rec = (kind, target) => { try { fs.appendFileSync(out, kind + '\t' + target + '\n'); } catch {} };

global.fetch = function (url) {
  let t = ''; try { t = new URL(String(url)).hostname; } catch { t = String(url); }
  rec('fetch', t);
  return Promise.reject(new Error('network blocked by test probe'));
};

function wrap(mod, name) {
  const orig = mod.request;
  mod.request = function (...args) {
    let host = '';
    try {
      const a0 = args[0];
      if (typeof a0 === 'string') host = new URL(a0).hostname;
      else if (a0 instanceof URL) host = a0.hostname;
      else if (a0 && typeof a0 === 'object') host = a0.hostname || a0.host || '';
    } catch {}
    rec(name, String(host));
    return orig.apply(this, args);
  };
}
wrap(http, 'http.request');
wrap(https, 'https.request');
PROBE

export OPENCLAW_WORKSPACE="$WS"
export MEMORY_UI_PORT=1   # 避免碰到真实端口
export NET_PROBE_OUT="$WS/net.log"

run() { : > "$NET_PROBE_OUT"; node -r "$WS/probe.js" "$ENGINE" "$@" >/dev/null 2>&1; }
external() {  # 输出所有非回环目标
  [ -s "$NET_PROBE_OUT" ] || return 0
  awk -F'\t' '{h=$2; gsub(/^\[|\]$/,"",h);
    if (h!="127.0.0.1" && h!="localhost" && h!="::1" && h!="" && h!="null") print $1" -> "h}' "$NET_PROBE_OUT"
}

echo "── ① 默认配置：不得有任何外部网络请求 ──"
for c in "status" "todos" "profile" "search --query memory --mode hybrid" "recall --query memory" "sync --quick"; do
  run $c
  EXT="$(external)"
  if [ -z "$EXT" ]; then ok "$c — 无外部请求"
  else bad "$c — 出现外部请求: $EXT"; fi
done

# embed 会走 remoteEmbed（旧版就是这里外发的）
run embed --force
EXT="$(external)"
if [ -z "$EXT" ]; then ok "embed --force — 无外部请求"
else bad "embed --force — 出现外部请求: $EXT"; fi

echo "── ② 反向对照：显式开启后必须真的尝试联网（证明闸门有效）──"
export DASHSCOPE_API_KEY="sk-test-not-a-real-key"
run embed --enable-remote     # 只翻转开关，本身不构建索引
run embed --force             # 这次才真正构建，应尝试外发
EXT="$(external)"
if [ -n "$EXT" ]; then ok "embed --enable-remote + embed --force — 确已尝试外发 ($EXT)"
else bad "embed --enable-remote — 未尝试外发，闸门可能形同虚设"; fi
unset DASHSCOPE_API_KEY

echo "── ③ 关闭后必须恢复零外部请求 ──"
run embed --disable-remote
run search --query memory --mode hybrid
EXT="$(external)"
if [ -z "$EXT" ]; then ok "embed --disable-remote — 已恢复零外部请求"
else bad "embed --disable-remote — 仍有外部请求: $EXT"; fi

echo
if [ "$FAIL" -eq 0 ]; then echo "test-no-network-by-default: $PASS 通过 / 0 失败"; exit 0
else echo "test-no-network-by-default: $PASS 通过 / $FAIL 失败"; exit 1; fi
