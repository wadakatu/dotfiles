#!/usr/bin/python3
"""~/.claude/projects のセッションログから、直近 N 日のトークン消費を API 定価換算で集計する。

使い方: python3 agents/claude/usage-report.py [日数=7]

plan の上限がキャッシュ読みなどをどう重み付けしているかは公開されていないので、金額は目安。
上限そのものの残りは /usage か statusline の 5h / 7d を見る。
"""

from __future__ import annotations

import collections
import datetime
import glob
import json
import os
import sys

ROOT = os.path.expanduser("~/.claude/projects")
# USD / MTok: (input, output, 1h cache write, cache read)。5m write は input の 1.25 倍。
# https://platform.claude.com/docs/en/about-claude/pricing
PRICE = {
    "claude-fable-5-1": (10, 50, 20, 0.25),
    "claude-opus-5-5": (4, 20, 8, 0.20),
    "claude-sonnet-5-5": (2, 10, 4, 0.10),
    "claude-haiku-5-5": (0.1, 0.5, 0.2, 0.01),  # ponytail: 100k 超の割増は無視
}


def usd(model: str, u: dict) -> float:
    i, o, w1h, r = PRICE.get(model, (0, 0, 0, 0))
    cc = u.get("cache_creation") or {}
    w1 = cc.get("ephemeral_1h_input_tokens", 0)
    w5 = u.get("cache_creation_input_tokens", 0) - w1
    return (u.get("input_tokens", 0) * i + w5 * i * 1.25 + w1 * w1h
            + u.get("cache_read_input_tokens", 0) * r + u.get("output_tokens", 0) * o) / 1e6


def main() -> None:
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 7
    since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days)
    by_model, by_kind, by_sess = (collections.Counter() for _ in range(3))
    ctx_buckets = collections.Counter()
    seen = set()
    for path in glob.glob(f"{ROOT}/**/*.jsonl", recursive=True):
        if os.path.getmtime(path) < since.timestamp():
            continue
        rel = os.path.relpath(path, ROOT)
        sess = rel.split("/")[0].replace("-Users-", "~") + " " + rel.split("/")[1][:8]
        kind = "main"
        if "/subagents/" in rel:
            try:
                kind = "sub:" + json.load(open(path.replace(".jsonl", ".meta.json"))).get("agentType", "?")
            except (OSError, ValueError):
                kind = "sub:?"
        for line in open(path, errors="ignore"):
            if '"usage"' not in line:
                continue
            try:
                e = json.loads(line)
            except ValueError:
                continue
            m = e.get("message") or {}
            u = m.get("usage")
            ts = e.get("timestamp")
            if e.get("type") != "assistant" or not u or not ts:
                continue
            if datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")) < since:
                continue
            key = (m.get("id"), e.get("requestId"))
            if key in seen:
                continue
            seen.add(key)
            for it in u.get("iterations") or [u]:
                advisor = it.get("type") == "advisor_message"
                model = it.get("model", m.get("model")) if advisor else m.get("model", "?")
                cost = usd(model, it)
                by_model[model] += cost
                by_kind["advisor" if advisor else kind] += cost
                by_sess[sess] += cost
                if not advisor:
                    ctx = it.get("input_tokens", 0) + it.get("cache_read_input_tokens", 0) + it.get("cache_creation_input_tokens", 0)
                    ctx_buckets["<200k" if ctx < 200_000 else "200-400k" if ctx < 400_000 else ">=400k"] += 1

    total = sum(by_model.values()) or 1
    print(f"直近 {days} 日: API 定価換算 ${total:,.0f}")
    for title, d, n in (("モデル別", by_model, 6), ("用途別", by_kind, 8), ("セッション別", by_sess, 8)):
        print(f"\n== {title}")
        for k, v in d.most_common(n):
            print(f"  {k[:60]:60} ${v:8,.0f} {v / total:4.0%}")
    print("\n== リクエストあたりの文脈 (件数)")
    for k in ("<200k", "200-400k", ">=400k"):
        print(f"  {k:9} {ctx_buckets[k]}")


if __name__ == "__main__":
    main()
