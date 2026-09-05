#!/usr/bin/env python3
"""
Mnemosyne v6.3 本地语义 Embedding Daemon (bge-small-zh-v1.5 ONNX)
纯本地、零网络、stdin/stdout JSONL 协议。

协议（每行一个 JSON）：
  输入: {"texts": ["句子1", "句子2", ...]}
  输出: {"vectors": [[f32,...], ...]}

加载: onnxruntime + 内置 tokenizer（复用 transformers 的 tokenizer.json，手写 BPE）
模型: /tmp/bge-model/model_quantized.onnx (24MB, int8 量化)
"""
import sys, os, json, re
import numpy as np

MODEL_DIR = os.environ.get('MNEMOSYNE_BGE_DIR', '/tmp/bge-model')
MODEL_PATH = os.path.join(MODEL_DIR, 'model_quantized.onnx')
TOKENIZER_PATH = os.path.join(MODEL_DIR, 'tokenizer.json')

def load_ort():
    import onnxruntime as ort
    return ort.InferenceSession(MODEL_PATH, providers=['CPUExecutionProvider'])

class Tokenizer:
    """手写 BPE tokenizer（从 tokenizer.json 读 vocab，避免 transformers 依赖）"""
    def __init__(self, path):
        d = json.load(open(path, 'r', encoding='utf8'))
        model = d.get('model', {})
        self.vocab = model.get('vocab', {})
        self.id2tok = {v: k for k, v in self.vocab.items()}
        self.unk_id = self.vocab.get('[UNK]', 100)
        self.cls_id = self.vocab.get('[CLS]', 101)
        self.sep_id = self.vocab.get('[SEP]', 102)
        self.pad_id = self.vocab.get('[PAD]', 0)
        # merges: list of pairs
        self.merges = model.get('merges', [])
        # pre-tokenizer 简单按字符（中文逐字 + 英文按空格）
    def tokenize(self, text):
        # 中文逐字，英文/数字按连续段
        text = str(text or '').lower()
        tokens = []
        for seg in re.findall(r'[\u4e00-\u9fff]|[a-z0-9]+|[^\s\w]', text, re.IGNORECASE):
            if re.match(r'[\u4e00-\u9fff]', seg):
                tokens.append(self.vocab.get(seg, self.unk_id))
            else:
                # 简单子词：找最长的 vocab 前缀
                i = 0
                while i < len(seg):
                    matched = False
                    for j in range(len(seg), i, -1):
                        sub = seg[i:j]
                        if sub in self.vocab:
                            tokens.append(self.vocab[sub])
                            i = j
                            matched = True
                            break
                    if not matched:
                        tokens.append(self.unk_id)
                        i += 1
        return [self.cls_id] + tokens[:510] + [self.sep_id]

def embed(sess, texts, tok):
    maxlen = 512
    input_ids, attn, ttype = [], [], []
    for t in texts:
        ids = tok.tokenize(t)
        L = len(ids)
        input_ids.append(ids + [tok.pad_id] * (maxlen - L))
        attn.append([1] * L + [0] * (maxlen - L))
        ttype.append([0] * maxlen)
    feed = {
        'input_ids': np.array(input_ids, dtype=np.int64),
        'attention_mask': np.array(attn, dtype=np.int64),
        'token_type_ids': np.array(ttype, dtype=np.int64),
    }
    out = sess.run(None, feed)[0]  # [batch, seq, hidden]
    # mean pooling 只对 attention 有效位置
    mask = np.array(attn, dtype=np.float32)[:, :, None]
    summed = (out * mask).sum(axis=1)
    counts = mask.sum(axis=1)
    counts = np.maximum(counts, 1e-9)
    vecs = summed / counts
    # L2 归一化
    norms = np.linalg.norm(vecs, axis=1, keepdims=True)
    norms = np.maximum(norms, 1e-12)
    vecs = vecs / norms
    return vecs.astype(np.float32).tolist()

def main():
    sess = load_ort()
    tok = Tokenizer(TOKENIZER_PATH)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            texts = req.get('texts', [])
            if not texts:
                print(json.dumps({'vectors': []}), flush=True)
                continue
            vecs = embed(sess, texts, tok)
            print(json.dumps({'vectors': vecs}), flush=True)
        except Exception as e:
            print(json.dumps({'error': str(e)}), flush=True)

if __name__ == '__main__':
    main()
