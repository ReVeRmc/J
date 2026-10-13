# -*- coding: utf-8 -*-
"""Собирает обучающий корпус model/corpus.jsonl из логов диалогов (logs/dialog.jsonl).

Формат dialog.jsonl (пишет server.ps1): {"ts":..., "turn":..., "role":"user"|"assistant", "intent":..., "text":...}
Правило: реплика user + ближайшая следующая реплика assistant = пара {input, output}.
Дубликаты убираются. Использование:  python train/build_corpus.py
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIALOG = ROOT / "logs" / "dialog.jsonl"
OUT = ROOT / "model" / "corpus.jsonl"


def main():
    if not DIALOG.exists():
        raise SystemExit(f"❌ Нет файла {DIALOG}. Сначала поработайте с ассистентом — диалог залоггируется автоматически.")
    pairs, seen = [], set()
    pending_user = None
    with open(DIALOG, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            role, text = rec.get("role"), (rec.get("text") or "").strip()
            if not text or len(text) > 2000:
                pending_user = None
                continue
            if role == "user":
                pending_user = text
            elif role == "assistant" and pending_user:
                key = (pending_user, text)
                if key not in seen:
                    seen.add(key)
                    pairs.append({"input": pending_user, "output": text})
                pending_user = None

    OUT.parent.mkdir(exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        for p in pairs:
            f.write(json.dumps(p, ensure_ascii=False) + "\n")
    print(f"✅ Корпус собран: {len(pairs)} пар -> {OUT}")
    print("   Далее: python train/model.py --mode train")


if __name__ == "__main__":
    main()
