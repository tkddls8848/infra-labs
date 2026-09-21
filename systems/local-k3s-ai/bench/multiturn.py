#!/usr/bin/env python3
"""멀티턴 부하를 흘리고, 그 결과를 모델 서버 파드의 지표로 되짚는다.

이 랩이 확인하려는 것은 처리량이 아니라 '같은 대화의 후속 요청이 KV 캐시를
가진 파드로 갔는가' 다. 그래서 측정은 두 갈래로 한다.

  클라이언트 쪽   TTFT — 캐시를 놓치면 프롬프트 전체를 다시 prefill 하므로
                  첫 토큰까지의 시간이 늘어난다.
  서버 쪽         vLLM 의 접두사 캐시 카운터 — 부하 전후 값을 빼서 이번 실행이
                  만든 질의/히트 블록 수만 본다.

부하 형태는 글 4.2 를 그대로 흉내낸다. 대화마다 긴 고유 프롬프트(문서)를 주고,
턴이 늘어날수록 그 앞부분이 계속 반복되게 한다. 라우팅이 대화를 같은 파드로
붙여 주면 이 반복 구간이 전부 캐시 히트가 되고, 확률로 흩어지면 매번 다시
계산된다.

표준 라이브러리만 쓴다. 파드 지표는 kubectl 의 API 서버 프록시로 읽으므로
port-forward 도, 파드 안의 curl 도 필요 없다.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

# vLLM 은 버전에 따라 접두사 캐시 카운터 이름이 다르다. 둘 다 받아 둔다.
QUERY_METRICS = ("vllm:prefix_cache_queries_total", "vllm:gpu_prefix_cache_queries_total")
HIT_METRICS = ("vllm:prefix_cache_hits_total", "vllm:gpu_prefix_cache_hits_total")
SUCCESS_METRICS = ("vllm:request_success_total",)

_SAMPLE = re.compile(r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?P<labels>\{[^}]*\})?\s+(?P<value>\S+)$")


def parse_prom(text: str) -> dict[str, float]:
    """프로메테우스 텍스트를 읽어 메트릭 이름별 합계를 낸다.

    라벨(model_name 등)은 구분하지 않고 더한다. 이 랩은 파드마다 모델이
    하나뿐이라 라벨별로 쪼갤 이유가 없다.
    """
    totals: dict[str, float] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = _SAMPLE.match(line)
        if not m:
            continue
        try:
            value = float(m.group("value"))
        except ValueError:
            continue
        name = m.group("name")
        totals[name] = totals.get(name, 0.0) + value
    return totals


def pick(totals: dict[str, float], names: tuple[str, ...]) -> float:
    for n in names:
        if n in totals:
            return totals[n]
    return 0.0


def kubectl(*args: str) -> str:
    proc = subprocess.run(
        ["kubectl", *args], capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)} 실패: {proc.stderr.strip()}")
    return proc.stdout


def list_pods(namespace: str, selector: str) -> list[str]:
    # 공백 구분 목록으로 받는다. jsonpath 안에서 개행을 이스케이프하면 셸과
    # kubectl 의 따옴표 규칙이 겹쳐 조용히 어긋나기 쉽다.
    out = kubectl(
        "-n", namespace, "get", "pods", "-l", selector,
        "--field-selector=status.phase=Running",
        "-o", "jsonpath={.items[*].metadata.name}",
    )
    return out.split()


def snapshot(namespace: str, pods: list[str]) -> dict[str, dict[str, float]]:
    """파드별 지표 스냅샷. 읽지 못한 파드는 조용히 건너뛰지 않고 표시한다."""
    snap: dict[str, dict[str, float]] = {}
    for pod in pods:
        try:
            raw = kubectl(
                "get", "--raw",
                f"/api/v1/namespaces/{namespace}/pods/{pod}:8000/proxy/metrics",
            )
        except RuntimeError as exc:
            print(f"  ⚠️  {pod} 지표를 읽지 못했습니다: {exc}", file=sys.stderr)
            continue
        totals = parse_prom(raw)
        snap[pod] = {
            "queries": pick(totals, QUERY_METRICS),
            "hits": pick(totals, HIT_METRICS),
            "requests": pick(totals, SUCCESS_METRICS),
        }
    return snap


def delta(before: dict[str, dict[str, float]], after: dict[str, dict[str, float]]):
    out = {}
    for pod, a in after.items():
        b = before.get(pod, {"queries": 0.0, "hits": 0.0, "requests": 0.0})
        out[pod] = {k: a[k] - b.get(k, 0.0) for k in a}
    return out


def make_document(conv_id: int, approx_tokens: int) -> str:
    """대화마다 고유하고, 같은 대화 안에서는 매 턴 똑같이 반복되는 긴 앞부분.

    무작위 문자열이 아니라 재현 가능한 문장을 쓴다. 같은 시드로 두 번 돌리면
    baseline 과 router 가 완전히 같은 프롬프트를 보게 된다 — 그래야 비교가 된다.
    """
    rng = random.Random(conv_id * 7919)
    subjects = ["클러스터", "파드", "스케줄러", "캐시", "노드", "라우터", "엔드포인트", "볼륨"]
    verbs = ["관찰한다", "기록한다", "재계산한다", "분산한다", "유지한다", "폐기한다"]
    # 한 문장이 대략 10 토큰 언저리다. 정확할 필요는 없고, 프롬프트가 충분히
    # 길어서 재계산 비용이 TTFT 에 드러나기만 하면 된다.
    sentences = []
    for i in range(max(1, approx_tokens // 10)):
        sentences.append(
            f"{i:03d}번 항목에서 {rng.choice(subjects)}는 {rng.choice(subjects)}를 {rng.choice(verbs)}."
        )
    return (
        f"[문서 {conv_id}] 아래는 대화 {conv_id} 에만 해당하는 참고 자료다.\n"
        + " ".join(sentences)
    )


def stream_chat(base_url: str, model: str, messages: list[dict], max_tokens: int,
                timeout: float) -> tuple[float, float, str]:
    """요청을 보내고 (TTFT, 전체 소요, 응답 텍스트) 를 돌려준다.

    TTFT 는 실제 내용 토큰이 담긴 첫 SSE 청크가 도착한 시각으로 잰다. 빈
    델타(역할만 담긴 첫 청크)를 세면 캐시 차이가 묻혀 버린다.
    """
    payload = json.dumps({
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    started = time.perf_counter()
    ttft = None
    chunks: list[str] = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            body = line[len("data:"):].strip()
            if body == "[DONE]":
                break
            try:
                event = json.loads(body)
            except json.JSONDecodeError:
                continue
            for choice in event.get("choices", []):
                piece = (choice.get("delta") or {}).get("content") or ""
                if piece:
                    if ttft is None:
                        ttft = time.perf_counter() - started
                    chunks.append(piece)
    total = time.perf_counter() - started
    if ttft is None:
        # 내용 토큰이 하나도 없으면 TTFT 를 정의할 수 없다. 전체 시간으로 대신한다.
        ttft = total
    return ttft, total, "".join(chunks)


def run_conversation(conv_id: int, args, model: str, results: list, lock: threading.Lock,
                     errors: list):
    document = make_document(conv_id, args.prefix_tokens)
    messages = [
        {"role": "system", "content": "너는 인프라 로그를 읽는 조수다. 한 문장으로만 답한다."},
        {"role": "user", "content": f"{document}\n\n첫 번째 질문: 이 문서의 000번 항목은 무엇을 말하나?"},
    ]
    for turn in range(args.turns):
        try:
            ttft, total, answer = stream_chat(
                args.base_url, model, messages, args.max_tokens, args.timeout
            )
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            with lock:
                errors.append(f"대화 {conv_id} 턴 {turn}: {exc}")
            return
        with lock:
            results.append({"conv": conv_id, "turn": turn, "ttft": ttft, "total": total})
        # 다음 턴은 지금까지의 대화를 통째로 다시 보낸다. 앞부분(문서 + 이전 턴)이
        # 그대로 반복되므로, 같은 파드로 가면 그 구간이 전부 캐시 히트가 된다.
        messages = messages + [
            {"role": "assistant", "content": answer or "(빈 응답)"},
            {"role": "user", "content": f"{turn + 1}번째 후속 질문: 방금 답을 한 문장으로 바꿔 말해 줘."},
        ]
        if args.think_time > 0:
            # 사용자가 답을 읽는 시간. 이 틈에 다른 대화가 끼어들어야 랜덤 분산이
            # 대화를 흩뜨릴 기회를 얻는다.
            time.sleep(args.think_time)


def discover_model(base_url: str, timeout: float) -> str:
    with urllib.request.urlopen(f"{base_url}/v1/models", timeout=timeout) as resp:
        data = json.loads(resp.read())
    models = [m["id"] for m in data.get("data", [])]
    if not models:
        raise RuntimeError(f"{base_url}/v1/models 가 모델을 보고하지 않습니다.")
    return models[0]


def percentile(values: list[float], p: float) -> float:
    if not values:
        return float("nan")
    ordered = sorted(values)
    k = max(0, min(len(ordered) - 1, int(round((p / 100.0) * (len(ordered) - 1)))))
    return ordered[k]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base-url", required=True,
                    help="OpenAI 호환 진입점. 예: http://127.0.0.1:8000")
    ap.add_argument("--label", required=True,
                    help="결과 파일 이름에 쓸 이름. 예: baseline, router")
    ap.add_argument("--namespace", default=os.environ.get("NAMESPACE", "llm-d-lab"))
    ap.add_argument("--selector", default=None,
                    help="모델 서버 파드 셀렉터. 기본값은 MODEL_LABEL 환경변수로 만든다.")
    ap.add_argument("--conversations", type=int, default=12)
    ap.add_argument("--turns", type=int, default=4)
    ap.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--prefix-tokens", type=int, default=1500,
                    help="대화마다 반복되는 앞부분의 대략적 길이. 짧으면 캐시 효과가 안 보인다.")
    ap.add_argument("--max-tokens", type=int, default=32)
    ap.add_argument("--think-time", type=float, default=0.3)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--out-dir", default=None)
    args = ap.parse_args()

    if args.selector is None:
        model_label = os.environ.get("MODEL_LABEL")
        if not model_label:
            print("❌ --selector 를 주거나 MODEL_LABEL 환경변수를 설정하세요.", file=sys.stderr)
            return 2
        args.selector = f"llm-d.ai/model={model_label}"

    pods = list_pods(args.namespace, args.selector)
    if not pods:
        print(f"❌ '{args.selector}' 에 맞는 Running 파드가 없습니다.", file=sys.stderr)
        return 1

    try:
        model = discover_model(args.base_url, args.timeout)
    except Exception as exc:  # noqa: BLE001 — 진입점이 안 열린 경우를 그대로 보여 준다
        print(f"❌ {args.base_url} 에 접속하지 못했습니다: {exc}", file=sys.stderr)
        print("   port-forward 가 살아 있는지 확인하세요.", file=sys.stderr)
        return 1

    print(f"경로       : {args.label}  ({args.base_url})")
    print(f"모델       : {model}")
    print(f"모델 서버  : {len(pods)}개 — {', '.join(pods)}")
    print(f"부하       : 대화 {args.conversations} x 턴 {args.turns}, 동시 {args.concurrency}, "
          f"반복 프롬프트 ≈{args.prefix_tokens} 토큰")
    print()

    print("부하 전 지표 스냅샷…")
    before = snapshot(args.namespace, pods)

    results: list[dict] = []
    errors: list[str] = []
    lock = threading.Lock()
    gate = threading.Semaphore(args.concurrency)

    def worker(conv_id: int):
        with gate:
            run_conversation(conv_id, args, model, results, lock, errors)

    started = time.perf_counter()
    threads = [threading.Thread(target=worker, args=(c,), daemon=True)
               for c in range(args.conversations)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - started

    print("부하 후 지표 스냅샷…")
    after = snapshot(args.namespace, pods)
    d = delta(before, after)

    ttfts = [r["ttft"] for r in results]
    q = sum(v["queries"] for v in d.values())
    h = sum(v["hits"] for v in d.values())
    hit_rate = (h / q * 100.0) if q > 0 else float("nan")

    summary = {
        "label": args.label,
        "base_url": args.base_url,
        "model": model,
        "pods": pods,
        "conversations": args.conversations,
        "turns": args.turns,
        "concurrency": args.concurrency,
        "prefix_tokens": args.prefix_tokens,
        "requests_completed": len(results),
        "errors": errors,
        "wall_seconds": wall,
        "ttft": {
            "p50": percentile(ttfts, 50),
            "p90": percentile(ttfts, 90),
            "max": max(ttfts) if ttfts else float("nan"),
            "mean": statistics.fmean(ttfts) if ttfts else float("nan"),
        },
        "prefix_cache": {"queries": q, "hits": h, "hit_rate_pct": hit_rate},
        "per_pod": d,
    }

    print()
    print("─" * 62)
    print(f"  결과: {args.label}")
    print("─" * 62)
    print(f"  완료 요청      : {len(results)} / {args.conversations * args.turns}"
          + (f"   (실패 {len(errors)})" if errors else ""))
    print(f"  소요           : {wall:.1f}s")
    print(f"  TTFT  p50/p90  : {summary['ttft']['p50']*1000:.0f} ms / "
          f"{summary['ttft']['p90']*1000:.0f} ms")
    print(f"  접두사 캐시    : 질의 {q:.0f} 블록, 히트 {h:.0f} 블록  →  히트율 {hit_rate:.1f}%")
    print("  파드별 처리    :")
    for pod, v in sorted(d.items()):
        own = (v["hits"] / v["queries"] * 100.0) if v["queries"] > 0 else float("nan")
        print(f"    {pod:<42} 요청 {v['requests']:>4.0f}   히트율 {own:>5.1f}%")
    if errors:
        print("  오류:")
        for e in errors[:5]:
            print(f"    - {e}")
    print("─" * 62)

    out_dir = args.out_dir or os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".generated"
    )
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"result-{args.label}.json")
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)
    print(f"\n결과 저장: {out_path}")

    if errors and not results:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
