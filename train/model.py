# -*- coding: utf-8 -*-
"""
J AI Assistant — крошечная character-level нейросеть (Transformer).
Архитектура «в духе» GPT, но умещается в ~20 МБ RAM и обучается на CPU за минуты.

Обучение :  python train/model.py --mode train
Инференс :  python train/model.py --mode generate --prompt "привет"
Сервер   :  python train/model.py --mode serve --port 8090
            (POST {"text": "..."} -> {"response": "..."}; используется server.ps1)

Зависимости: только PyTorch (CPU). Файл модели: model/assistant.pt
"""
import argparse
import json
import math
import os
import sys
import time
from pathlib import Path

import torch
import torch.nn as nn
from torch.utils.data import DataLoader, TensorDataset

ROOT = Path(__file__).resolve().parent.parent          # корень проекта
MODEL_DIR = ROOT / "model"
DATA_FILE = MODEL_DIR / "corpus.jsonl"                 # обучающие пары {input, output}
CKPT = MODEL_DIR / "assistant.pt"                      # веса + словарь
TRAIN_LOG = ROOT / "logs" / "training.log"
INFER_LOG = ROOT / "logs" / "inference.log"

DEVICE = "cpu"                                          # по требованиям <=20 ГБ RAM, без GPU
torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))


def log(path: Path, msg: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n"
    with open(path, "a", encoding="utf-8") as f:
        f.write(line)
    print(line.rstrip())


# ---------------- модель ----------------
class TinyGPT(nn.Module):
    """Character-level Transformer: d_model=192, 4 слоя, 6 голов (~7 млн параметров)."""

    def __init__(self, vocab_size: int, d_model: int = 192, n_head: int = 6,
                 n_layer: int = 4, d_ff: int = 512, max_len: int = 256, dropout: float = 0.1):
        super().__init__()
        self.max_len = max_len
        self.tok = nn.Embedding(vocab_size, d_model)
        self.pos = nn.Embedding(max_len, d_model)
        layer = nn.TransformerEncoderLayer(
            d_model=d_model, nhead=n_head, dim_feedforward=d_ff,
            dropout=dropout, batch_first=True, activation="gelu")
        self.enc = nn.TransformerEncoder(layer, num_layers=n_layer)
        self.norm = nn.LayerNorm(d_model)
        self.head = nn.Linear(d_model, vocab_size, bias=False)
        self.register_buffer("pe", torch.triu(torch.ones(max_len, max_len), diagonal=1).bool())

    def forward(self, x):
        b, t = x.shape
        h = self.tok(x) + self.pos(torch.arange(t, device=x.device))
        h = self.enc(h, mask=self.pe[:t, :t].to(x.device), is_causal=True)
        return self.head(self.norm(h))


# ---------------- словарь ----------------
def build_vocab(texts):
    chars = sorted(set("".join(texts)) | set("\n "))
    itos = {c: i for i, c in enumerate(chars)}
    stoi = {i: c for c, i in itos.items()}
    return itos, stoi


def encode(s, itos):
    return [itos.get(c, 0) for c in s]


def decode(ids, stoi):
    return "".join(stoi.get(int(i), "") for i in ids)


# ---------------- данные ----------------
def load_corpus():
    pairs = []
    if DATA_FILE.exists():
        with open(DATA_FILE, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                    if "input" in rec and "output" in rec:
                        pairs.append((rec["input"], rec["output"]))
                except json.JSONDecodeError:
                    pass
    return pairs


def make_dataset(pairs, itos, block=128):
    """Скользящие окна фиксированной длины block; x/y всегда ровно block-1 токенов."""
    xs, ys = [], []
    for inp, out in pairs:
        seq = encode(inp + "\n" + out + "\n", itos)
        if len(seq) < 8:
            continue
        step = max(block // 2, 1)
        starts = list(range(0, len(seq), step)) or [0]
        for i in starts:
            chunk = seq[i:i + block]
            if len(chunk) < 2:
                continue
            chunk += [0] * (block - len(chunk))       # padding до фиксированной длины
            xs.append(chunk[:-1])
            ys.append(chunk[1:])
    return TensorDataset(torch.tensor(xs), torch.tensor(ys))


# ---------------- обучение ----------------
def train(steps: int, epochs: int, batch: int, lr: float):
    pairs = load_corpus()
    if len(pairs) < 20:
        print(f"⚠️ Корпус мал ({len(pairs)} примеров). Добавьте данные в model/corpus.jsonl.")
        if not pairs:
            sys.exit("Нет данных для обучения.")

    # дообучение поверх существующей модели (сохраняем словарь — иначе эмбеддинги рассогласуются)
    itos = stoi = None
    model = None
    if CKPT.exists():
        try:
            ck = torch.load(CKPT, map_location=DEVICE, weights_only=False)
            model = TinyGPT(len(ck["itos"])).to(DEVICE)
            model.load_state_dict(ck["state"])
            itos, stoi = ck["itos"], ck["stoi"]
            log(TRAIN_LOG, "CONTINUE from existing checkpoint")
        except Exception as e:
            log(TRAIN_LOG, f"WARN checkpoint load failed: {e}")
            model = None
    if itos is None:
        texts = [p[0] + "\n" + p[1] for p in pairs]
        itos, stoi = build_vocab(texts)
        model = TinyGPT(len(itos)).to(DEVICE)
    else:
        # новые символы корпуса добавляем в конец словаря
        base = list(itos.keys())
        extra = sorted(set("".join(p[0] + "\n" + p[1] for p in pairs)) - set(base))
        for c in extra:
            itos[c] = len(itos); stoi[len(itos) - 1] = c
        if extra:
            old_head = model.head.weight.data.clone()
            old_tok = model.tok.weight.data.clone()
            model = TinyGPT(len(itos)).to(DEVICE)
            model.tok.weight.data[:old_tok.shape[0]] = old_tok
            model.head.weight.data[:old_head.shape[0]] = old_head
            log(TRAIN_LOG, f"VOCAB expanded by {len(extra)} chars")

    ds = make_dataset(pairs, itos)
    dl = DataLoader(ds, batch_size=batch, shuffle=True)

    opt = torch.optim.AdamW(model.parameters(), lr=lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=max(epochs, 1))
    crit = nn.CrossEntropyLoss()

    n_params = sum(p.numel() for p in model.parameters())
    ram_mb = n_params * 4 * 4 / 1e6   # веса+градиенты+2 момента Adam, fp32
    log(TRAIN_LOG, f"START params={n_params:,} est_ram={ram_mb:.0f}MB examples={len(pairs)} "
                   f"train_seqs={len(ds)} epochs={epochs}")

    model.train()
    done = 0
    V = len(itos)
    for ep in range(1, epochs + 1):
        tot, nb = 0.0, 0
        t0 = time.time()
        for xb, yb in dl:
            logits = model(xb)
            # явный reshape: (B,T,V)->(B*T,V), target (B,T)->(B*T) — совместимо со всеми версиями torch
            loss = crit(logits.reshape(-1, V), yb.reshape(-1))
            opt.zero_grad(); loss.backward(); opt.step()
            tot += loss.item(); nb += 1
            done += 1
            if steps and done >= steps:
                break
        sched.step()
        avg = tot / max(nb, 1)
        ppl = math.exp(min(avg, 20))
        log(TRAIN_LOG, f"EPOCH {ep}/{epochs} loss={avg:.4f} perplexity={ppl:.1f} "
                       f"time={time.time()-t0:.1f}s")
        if steps and done >= steps:
            break

    torch.save({"state": model.state_dict(), "itos": itos, "stoi": stoi,
                "cfg": {"params": n_params, "epochs": epochs,
                        "trained_at": time.strftime("%F %T"), "examples": len(pairs)}}, CKPT)
    size_kb = CKPT.stat().st_size / 1024
    log(TRAIN_LOG, f"SAVED {CKPT.name} ({size_kb:.0f} KB)")
    print(f"✅ Модель сохранена: {CKPT} ({size_kb:.0f} КБ, параметров: {n_params:,})")


# ---------------- инференс ----------------
def sample(model, itos, stoi, prompt: str, temp=0.7, top_k=25, maxlen=160):
    model.eval()
    enc = encode(prompt, itos)
    out = list(enc[-model.max_len + 1:])
    eos = itos.get("\n", 1)
    with torch.no_grad():
        for _ in range(maxlen):
            x = torch.tensor([out])
            logits = model(x)[0, -1] / max(temp, 0.05)
            if top_k:
                v, idx = torch.topk(logits, min(top_k, len(logits)))
                keep = torch.full_like(logits, -float("inf"))
                keep[idx] = v
                logits = keep
            p = torch.softmax(logits, -1)
            nxt = int(torch.multinomial(p, 1))
            if nxt == eos and len(out) > len(enc) + 3:
                break
            out.append(nxt)
    full = decode(out, stoi)
    gen = full[len(prompt):].strip() if full.startswith(prompt) else full
    return gen or full.strip()


def generate(prompt: str, max_len: int):
    ck = torch.load(CKPT, map_location=DEVICE, weights_only=False)
    itos, stoi = ck["itos"], ck["stoi"]
    model = TinyGPT(len(itos)).to(DEVICE)
    model.load_state_dict(ck["state"])
    res = sample(model, itos, stoi, prompt, maxlen=max_len)
    log(INFER_LOG, f"GENERATE prompt={prompt!r} -> {res[:80]!r}")
    print(res)


# ---------------- HTTP-сервер для PowerShell ----------------
def serve(port: int):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    ck = torch.load(CKPT, map_location=DEVICE, weights_only=False)
    itos, stoi = ck["itos"], ck["stoi"]
    model = TinyGPT(len(itos)).to(DEVICE)
    model.load_state_dict(ck["state"])
    model.eval()
    log(INFER_LOG, f"SERVE start port={port}")
    print(f"🧠 Model server J AI Assistant на http://127.0.0.1:{port} (Ctrl+C — стоп)")

    class H(BaseHTTPRequestHandler):
        def _send(self, code, obj):
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            self._send(200, {"status": "ok", "service": "j-ai-model"})

        def do_POST(self):
            try:
                n = int(self.headers.get("Content-Length", 0))
                data = json.loads(self.rfile.read(n).decode("utf-8"))
                text = (data.get("text") or "").strip()
                if not text:
                    return self._send(400, {"error": "empty text"})
                t0 = time.time()
                resp = sample(model, itos, stoi, text,
                              temp=float(data.get("temp", 0.7)),
                              maxlen=int(data.get("max_len", 160)))
                log(INFER_LOG, f"REQ {text[:60]!r} -> {resp[:80]!r} ({time.time()-t0:.2f}s)")
                self._send(200, {"response": resp, "time_ms": int((time.time() - t0) * 1000)})
            except Exception as e:
                log(INFER_LOG, f"ERROR {e}")
                self._send(500, {"error": str(e)})

        def log_message(self, *a):
            pass

    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["train", "generate", "serve"], required=True)
    ap.add_argument("--prompt", default="привет")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--max-len", dest="max_len", type=int, default=160)
    ap.add_argument("--steps", type=int, default=0, help="быстрый тест: N батчей вместо эпох")
    ap.add_argument("--port", type=int, default=8090)
    a = ap.parse_args()
    MODEL_DIR.mkdir(exist_ok=True)

    if a.mode == "train":
        train(a.steps, a.epochs, a.batch, a.lr)
    elif a.mode == "generate":
        generate(a.prompt, a.max_len)
    else:
        serve(a.port)
