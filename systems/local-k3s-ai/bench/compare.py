#!/usr/bin/env python3
"""multiturn.py 가 남긴 두 결과를 나란히 놓고 본다.

이 랩의 결론은 숫자 하나가 아니라 '같은 모델 서버, 같은 부하, 앞단만 교체'
했을 때의 차이다. 그래서 비교는 두 실행이 정말 같은 조건이었는지 확인하는
것부터 한다 — 대화 수나 프롬프트 길이가 다르면 히트율을 견줄 수 없다.
"""

from __future__ import annotations

import argparse
import json
import sys
import unicodedata

# 두 실행이 같은 부하였는지 판단하는 기준. 이게 다르면 비교가 성립하지 않는다.
COMPARABLE_KEYS = ("conversations", "turns", "concurrency", "prefix_tokens", "model")


def width(text: str) -> int:
    """한글은 터미널에서 두 칸을 차지한다. 코드포인트 수로 자리를 맞추면
    표가 어긋나므로 East Asian Width 를 보고 센다."""
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def ljust(text: str, n: int) -> str:
    return text + " " * max(0, n - width(text))


def rjust(text: str, n: int) -> str:
    return " " * max(0, n - width(text)) + text


def load(path: str) -> dict:
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def fmt_ms(seconds: float) -> str:
    return f"{seconds * 1000:.0f} ms"


def delta_pct(base: float, new: float) -> str:
    """base 대비 new 의 변화율. 낮아지는 게 좋은 지표(TTFT)에 쓴다."""
    if base == 0 or base != base:  # 0 또는 NaN
        return "n/a"
    change = (new - base) / base * 100.0
    arrow = "▼" if change < 0 else "▲"
    return f"{arrow} {abs(change):.1f}%"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("baseline", help="result-baseline.json")
    ap.add_argument("router", help="result-router.json")
    args = ap.parse_args()

    try:
        a, b = load(args.baseline), load(args.router)
    except FileNotFoundError as exc:
        print(f"❌ 결과 파일이 없습니다: {exc.filename}", file=sys.stderr)
        print("   03_measure_baseline.sh 와 05_measure_router.sh 를 먼저 돌리세요.", file=sys.stderr)
        return 1

    mismatched = [k for k in COMPARABLE_KEYS if a.get(k) != b.get(k)]
    if mismatched:
        print("⚠️  두 실행의 조건이 다릅니다. 아래 비교는 신뢰할 수 없습니다:")
        for k in mismatched:
            print(f"     {k}: {a.get(k)!r}  vs  {b.get(k)!r}")
        print()

    print("=" * 68)
    print("  " + ljust("", 22) + rjust(a["label"], 20) + rjust(b["label"], 20))
    print("=" * 68)

    rows = [
        ("완료 요청", f"{a['requests_completed']}", f"{b['requests_completed']}", ""),
        ("TTFT p50", fmt_ms(a["ttft"]["p50"]), fmt_ms(b["ttft"]["p50"]),
         delta_pct(a["ttft"]["p50"], b["ttft"]["p50"])),
        ("TTFT p90", fmt_ms(a["ttft"]["p90"]), fmt_ms(b["ttft"]["p90"]),
         delta_pct(a["ttft"]["p90"], b["ttft"]["p90"])),
        ("캐시 질의(블록)", f"{a['prefix_cache']['queries']:.0f}",
         f"{b['prefix_cache']['queries']:.0f}", ""),
        ("캐시 히트(블록)", f"{a['prefix_cache']['hits']:.0f}",
         f"{b['prefix_cache']['hits']:.0f}", ""),
        ("접두사 캐시 히트율", f"{a['prefix_cache']['hit_rate_pct']:.1f}%",
         f"{b['prefix_cache']['hit_rate_pct']:.1f}%",
         f"{b['prefix_cache']['hit_rate_pct'] - a['prefix_cache']['hit_rate_pct']:+.1f}p"),
    ]
    for name, left, right, note in rows:
        print("  " + ljust(name, 22) + rjust(left, 20) + rjust(right, 20) + "   " + note)

    print("-" * 68)
    print("  파드별 요청 분포")
    pods = sorted(set(a["per_pod"]) | set(b["per_pod"]))
    for pod in pods:
        la = a["per_pod"].get(pod, {}).get("requests", 0.0)
        lb = b["per_pod"].get(pod, {}).get("requests", 0.0)
        print("    " + ljust(pod, 38) + rjust(f"{la:.0f}", 8) + rjust(f"{lb:.0f}", 12))
    print("=" * 68)

    gain = b["prefix_cache"]["hit_rate_pct"] - a["prefix_cache"]["hit_rate_pct"]
    print()
    if gain > 5:
        print(f"→ 캐시 히트율이 {gain:.1f}p 올랐다. 같은 대화의 후속 요청이 KV 캐시를")
        print("  가진 파드로 다시 갔다는 뜻이다. 글 5장의 EPP 가 하는 일이 이것이다.")
    elif gain < -5:
        print("→ 히트율이 오히려 떨어졌다. 부하가 한 파드에 몰려 포화 회피가 작동했거나,")
        print("  프롬프트가 짧아 캐시 친화도보다 부하 분산 점수가 이겼을 수 있다.")
        print("  --prefix-tokens 를 늘리거나 --concurrency 를 낮춰 다시 보라.")
    else:
        print("→ 차이가 거의 없다. 반복되는 앞부분이 너무 짧거나(--prefix-tokens),")
        print("  대화 수가 적어 어차피 같은 파드로 갔을 수 있다. 조건을 키워 다시 보라.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
