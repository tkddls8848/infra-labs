# 실습 가이드 — 쿠버네티스 추론 인프라를 로컬에서 뜯어보기

이 실습은 "AI 라우터를 쓰면 좋아진다"를 믿는 대신 **직접 재보게** 하려고 만들었다.
모델 서버는 한 번 올려 두고 앞단만 갈아 끼우며 같은 부하를 반복해서 흘린다.
그래야 바뀐 숫자가 앞단 때문이라고 말할 수 있다.

## 무엇을 확인하게 되는가

| 단계 | 확인하는 것 | 재현되는가 |
|---|---|:---:|
| 1 | GPU 한 장을 여러 파드가 나눠 쓰는 방법 (time-slicing) | ✅ |
| 2 | 파드마다 KV 캐시를 **따로** 들고 있다는 것 | ✅ |
| 3 | 평범한 Service 로 분산하면 캐시가 깨진다는 것 | ✅ |
| 4 | Router(Envoy+EPP) / InferencePool / Model Server 의 실제 구조 | ✅ |
| 5 | 캐시 인지 라우팅이 히트율과 TTFT 를 바꾼다는 것 | ✅ |
| 6 | 캐시 친화도와 부하 분산이 서로 맞선다는 것 | ✅ |
| 7 | Prefill/Decode 분리의 구조 | 🔍 읽기만 |
| — | P/D 분리의 성능 이득, EKS·Karpenter·울트라스케일 | ❌ |

마지막 줄이 중요하다. 이 랩은 **라우팅 계층**을 재현한다. 클라우드 관리형
서비스와 다중 GPU 고속 전송은 재현 대상이 아니고, 재현한 척도 하지 않는다.

## 준비물

- NVIDIA GPU 1장 (VRAM 8 GiB 이상, 16 GiB 이상 권장)
- 호스트: NVIDIA 드라이버 + `nvidia-container-toolkit`
- K3s (이 랩의 `scripts/addons/ai.sh` 로 설치)
- `kubectl`, `helm` 3.8+, `python3`, `git`, `curl`
- 디스크 여유 30 GiB 이상 (모델 가중치 + 컨테이너 이미지)
- 인터넷 (HuggingFace, ghcr.io, docker.io)

파이썬 패키지 설치는 필요 없다. 부하 도구는 표준 라이브러리만 쓴다.

## 시작하기 전에

```bash
cd systems/local-k3s-ai

# 설정을 먼저 읽는다. 이 파일이 모든 스크립트의 단일 원천이다.
less config/inference.env
```

GPU VRAM 이 8~12 GiB 라면 `REPLICAS=2` 로 줄이는 편이 안전하다.
`REPLICAS × GPU_MEMORY_UTILIZATION` 이 0.95 를 넘으면 레플리카들이 서로
VRAM 을 빼앗아 CUDA OOM 으로 죽는다. 0단계가 이걸 먼저 잡아 준다.

---

## 0단계 — 사전 점검

```bash
scripts/inference/00_preflight.sh
```

아무것도 설치하지 않고 읽기만 한다. 여기서 막히면 대부분 둘 중 하나다.

- `RuntimeClass/nvidia 없음` → `nvidia-container-toolkit` 설치 후
  `sudo systemctl restart k3s`. K3s 는 기동할 때 런타임을 탐지해 RuntimeClass 를
  스스로 만든다.
- `레플리카당 2 GiB 미만` → `config/inference.env` 에서 `REPLICAS` 를 낮춘다.

---

## 1단계 — GPU 한 장을 여러 개로 광고하기

```bash
scripts/inference/01_gpu_timeslicing.sh
```

**보게 되는 것**: 노드의 `nvidia.com/gpu` capacity 가 `1` → `4` 로 바뀐다.

**직접 확인할 것**

```bash
# 물리 GPU 는 여전히 한 장이다
nvidia-smi --query-gpu=index,name --format=csv

# 그런데 쿠버네티스는 4장이라고 말한다
kubectl get node -o jsonpath='{.items[0].status.capacity.nvidia\.com/gpu}{"\n"}'
```

이 둘이 다른 이유를 설명할 수 있어야 다음 단계가 의미 있다.
time-slicing 은 **SM 실행 시간**을 나눈 것이지 메모리를 나눈 게 아니다.
그래서 메모리는 vLLM 쪽에서 `--gpu-memory-utilization` 으로 따로 갈라 준다.

> 글에서 언급된 MIG 는 진짜 하드웨어 분할이라 A100/H100급에서만 된다.
> 소비자용 GPU 에서는 time-slicing 이 유일한 선택지고, **격리가 없다** —
> 한 파드가 OOM 을 내면 옆 파드도 같이 죽을 수 있다. 랩이니까 괜찮다.

---

## 2단계 — 모델 서버 올리기

```bash
scripts/inference/02_modelserver_up.sh
```

첫 실행은 가중치를 받느라 몇 분 걸린다. 스크립트는 레플리카 1개로 받아 둔 뒤
나머지를 늘린다 — 셋이 동시에 같은 캐시 디렉터리로 내려받으면 락을 기다리며
오히려 느려진다.

**보게 되는 것**: 파드 3개, GPU 1장, 그리고 Service 뒤의 엔드포인트 3개.

**직접 확인할 것 — 이게 이 랩 전체의 전제다**

```bash
# 파드마다 접두사 캐시 카운터가 따로 있다
for p in $(kubectl -n llm-d-lab get pods -l llm-d.ai/role=decode -o name | cut -d/ -f2); do
  echo "── $p"
  kubectl get --raw "/api/v1/namespaces/llm-d-lab/pods/$p:8000/proxy/metrics" \
    | grep -E 'prefix_cache_(queries|hits)_total'
done
```

세 파드가 각각 자기 숫자를 들고 있다. **KV 캐시는 파드 로컬이다.**
공유 캐시도, 복제도 없다. 글 4.2 의 "3번 파드에는 캐시가 없으니 처음부터
다시 연산" 이 성립하는 이유가 이것이다.

---

## 3단계 — 실습 A: 상태를 모르는 분산

```bash
scripts/inference/03_measure_baseline.sh
```

다른 터미널에 이걸 띄워 놓고 보면 과정이 보인다:

```bash
bench/watch.sh
```

**읽는 법**

- **접두사 캐시 히트율** — 파드 3개면 대체로 30%대. 대화의 앞부분이 매 턴
  똑같은데도 히트가 안 난다. 캐시를 가진 파드로 가지 않았다는 뜻이다.
- **파드별 요청 분포** — 거의 균등하다. Service 는 제 할 일을 잘했다.
  일반 웹 서비스였다면 이게 정답이다.
- 그 **공평함이** 재연산 비용으로 돌아온다는 게 글 4장의 요지다.

**직접 확인할 것**

```bash
# 이 경로에는 결정을 내리는 주체가 없다. iptables 규칙뿐이다.
sudo iptables -t nat -L KUBE-SERVICES -n | grep llm-d-lab
```

부하 크기를 바꿔 보고 싶으면 인자를 그대로 넘기면 된다:

```bash
scripts/inference/03_measure_baseline.sh --conversations 20 --turns 5 --prefix-tokens 3000
```

> 반복되는 앞부분(`--prefix-tokens`)이 짧으면 캐시가 아껴 주는 연산 자체가
> 적어서 차이가 안 보인다. 차이가 흐릿하면 이 값부터 키워 보라.

---

## 4단계 — 라우터 세우기

```bash
scripts/inference/04_router_up.sh
```

모델 서버는 **건드리지 않는다.** 앞단만 생긴다.

**보게 되는 것**: 글 5.1 의 세 구성요소가 실제 리소스로 나타난다.

| 글의 용어 | 실제로 생기는 것 |
|---|---|
| Router = Proxy + EPP | 파드 하나에 컨테이너 둘 (`envoy-proxy`, `epp`) |
| InferencePool | `InferencePool` 커스텀 리소스 (라벨 셀렉터) |
| Model Server | 2단계의 vLLM 파드들 — 그대로 |

**직접 확인할 것 1 — 설치 전에 읽기**

스크립트는 `helm install` 전에 렌더 결과를 파일로 남긴다. 블랙박스로 두지 않기
위해서다.

```bash
less .generated/router-rendered.yaml
```

**직접 확인할 것 2 — ext-proc 배선**

```bash
# 렌더해 둔 매니페스트에서 바로 읽는 게 가장 확실하다
grep -A 6 'ext_proc' .generated/router-rendered.yaml | head -30
grep -B 3 -A 3 'x-gateway-destination-endpoint' .generated/router-rendered.yaml

# 클러스터에 올라간 실제 ConfigMap 으로 보려면
ENVOY_CM=$(kubectl -n llm-d-lab get configmap -o name | grep -i envoy | head -1)
kubectl -n llm-d-lab get "$ENVOY_CM" -o yaml | grep -A 6 'ext_proc'
```

여기가 글 5.2 의 1~4번 흐름이다. Envoy 는 **어디로 보낼지 스스로 정하지 않는다.**
`ORIGINAL_DST` 클러스터로 설정돼 있고, 목적지는 EPP 가 헤더로 찍어 준다.

**직접 확인할 것 3 — InferencePool 의 셀렉터**

```bash
kubectl -n llm-d-lab get inferencepool -o yaml | grep -A 8 selector
kubectl -n llm-d-lab get service vllm-baseline -o yaml | grep -A 5 selector
```

**둘이 같은 파드를 가리킨다.** 차이는 선택 대상이 아니라 선택 방법이다.

---

## 5단계 — 실습 B: 캐시를 아는 분산

```bash
scripts/inference/05_measure_router.sh
```

3단계와 **완전히 같은 부하**다. 대화 프롬프트도 시드가 고정돼 있어 글자 하나까지
같다. 끝나면 A/B 비교표가 나온다.

**읽는 법**

- **캐시 히트율이 올랐는가** — 올랐다면 같은 대화의 후속 요청이 캐시를 가진
  파드로 돌아갔다는 뜻이다. 이게 EPP 가 하는 일이다.
- **파드별 분포가 기울었는가** — 기울었다면 정상이다. EPP 는 공평함보다
  캐시 적중을 택했다. 다만 완전히 한 파드로 쏠리지는 않는다 —
  `token-load-scorer` 가 균형추 역할을 한다.
- **TTFT p50/p90** — 재연산이 줄면 첫 토큰이 빨라진다. 0.5B 모델에서는
  차이가 작을 수 있다. `--prefix-tokens` 를 키우면 커진다.

**직접 확인할 것 — EPP 가 왜 그 파드를 골랐나**

```bash
ROUTER_POD=$(kubectl -n llm-d-lab get pods -l app.kubernetes.io/instance=llmd-lab -o name | head -1)
kubectl -n llm-d-lab logs "$ROUTER_POD" -c epp --tail=200 | grep -iE 'score|prefix|endpoint'
```

로그가 비어 있으면 `config/inference.env` 의 `EPP_LOG_VERBOSITY` 를 올리고
4단계를 다시 돌린다.

**직접 확인할 것 — 라우터를 죽여 보기**

```bash
ROUTER_DEPLOY=$(kubectl -n llm-d-lab get deployment \
  -l app.kubernetes.io/instance=llmd-lab -o name | head -1)

# 라우터를 내린다. failureMode: FailOpen 이라 서비스는 살아 있어야 한다.
kubectl -n llm-d-lab scale "$ROUTER_DEPLOY" --replicas=0
# ... 요청을 다시 흘려 보고, 히트율이 어떻게 되는지 본다
kubectl -n llm-d-lab scale "$ROUTER_DEPLOY" --replicas=1
```

> 이 랩은 Envoy 를 EPP 파드의 **사이드카**로 돌린다. 그래서 라우터를 0으로
> 내리면 프록시까지 같이 사라져 진입점 자체가 없어진다. FailOpen 이 무엇을
> 지켜 주는지 제대로 보려면 `router.proxy.mode: service` 로 프록시를 별도
> Deployment 로 떼어 낸 뒤 EPP 만 내려야 한다.

"라우팅 품질은 잃되 서비스는 죽지 않는다" 가 설계상 의도라는 걸 눈으로 본다.

---

## 6단계 — 실습 C: 두 힘을 맞붙이기

```bash
scripts/inference/06_saturation.sh 50
```

라우터는 그대로 두고 **숫자 하나만** 바꾼다. `peakPrefillThroughput` 을 낮추면
EPP 는 엔드포인트가 늘 포화됐다고 보고 캐시 친화도를 포기한다.

**읽는 법**: 히트율이 baseline 수준으로 되돌아갈 것이다.

그래서 결론은 "AI 라우터를 깔았다" 가 아니다. **어떤 신호를 얼마나 믿을지**가
결론이다. 글이 말한 보정(calibration)이 실제 운영에서 왜 별도 절차인지가
여기서 드러난다 — 상류 기본값 15928 은 Qwen3-32B / H100 80GB / TP=2 에서
측정된 값이고, 당신의 하드웨어 값이 아니다.

스크립트는 끝나면서 원래 값으로 되돌린다.

**직접 해볼 것**: 값을 5, 500, 5000 으로 바꿔 가며 히트율이 어디서 꺾이는지
찾아보라. 그 지점이 당신 하드웨어에서 두 힘이 뒤집히는 경계다.

---

## 7단계 — Prefill/Decode 분리 해부 (적용하지 않음)

```bash
scripts/inference/07_pd_anatomy.sh
```

상류 매니페스트를 받아 렌더해서 **읽기만** 한다.

**왜 적용하지 않는가**: P/D 분리는 prefill 풀에서 decode 풀로 KV 캐시를 옮기고,
그 전송을 NIXL 이 RDMA 로 GPU 메모리 간에 직접 한다. GPU 한 장짜리 랩에는
옮길 건너편이 없다. 억지로 올리면 파드는 뜨지만 요청은 KV 전송에서 막힌다.
그 실패에서 배울 건 없다.

**보게 되는 것**

- `Deployment/decode` 하나가 `prefill` + `decode` 둘로 갈라진다
- 두 풀을 가르는 것은 `llm-d.ai/role` 라벨 **하나**다
- decode 파드에 `routing-proxy` 사이드카가 붙는다 (`--kv-connector=nixlv2`)
- vLLM 에 `--kv-transfer-config '{"kv_connector":"NixlConnector", ...}'` 가 들어간다
- NIXL 전용 포트 5600 이 열린다

GPU 가 2장 이상 생기면 `.generated/llm-d-v0.9.0/guides/pd-disaggregation/README.md`
가 다음 출발점이다.

---

## 정리

```bash
scripts/inference/90_teardown.sh          # 이 랩의 네임스페이스만
scripts/inference/90_teardown.sh --all    # + CRD, device plugin, 생성물
```

K3s 자체는 남는다. 클러스터까지 지우려면 `sudo /usr/local/bin/k3s-uninstall.sh`.

---

## 스스로 점검하는 질문

실습이 끝나고 아래에 답할 수 있으면 글의 4~7장을 구조 수준에서 이해한 것이다.

1. Service 와 InferencePool 은 같은 파드를 가리킨다. 그런데 결과가 다른 이유는?
2. Envoy 는 목적지를 어떻게 아는가? 그 정보는 어디서 오는가?
3. KV 캐시는 왜 파드 사이에 공유되지 않는가? 공유하려면 무엇이 필요한가?
4. 캐시 히트율이 높은데 TTFT p90 이 나쁘다면 무엇을 의심해야 하는가?
5. `peakPrefillThroughput` 를 낮췄을 때 히트율이 떨어진 이유를 한 문장으로.
6. GPU 1장에서 P/D 를 분리하면 왜 느려지는가?

## 재현되지 않는 것 — 솔직하게

| 글의 내용 | 이유 |
|---|---|
| P/D 분리의 "처리량 2배, 비용 30~40% 절감" | GPU 2장 이상 + RDMA 인터커넥트 필요 |
| Amazon EKS, Auto Mode, EKS Capabilities | 관리형 컨트롤 플레인 자체가 상품 |
| Karpenter 의 Spot·Graviton 비용 효과 | AWS 실계정 필요 (단, KWOK 프로바이더로 스케줄링 동작만은 로컬 재현 가능) |
| 울트라스케일(10,000 노드), Project Rainier | 규모 자체가 재현 대상이 아님 |
| MIG 를 통한 GPU 분할 | A100/H100급 하드웨어 전용 |

## 문제 해결

| 증상 | 원인과 조치 |
|---|---|
| 파드가 `Pending`, `Insufficient nvidia.com/gpu` | 1단계를 돌리지 않았거나 `GPU_TIME_SLICING_REPLICAS` < `REPLICAS` |
| vLLM 파드가 CUDA OOM 으로 재시작 반복 | `REPLICAS × GPU_MEMORY_UTILIZATION` 이 너무 크다. 둘 중 하나를 낮춘다 |
| `RuntimeClass "nvidia" not found` | `nvidia-container-toolkit` 설치 후 `sudo systemctl restart k3s` |
| 첫 기동이 10분 넘게 안 끝남 | 가중치 다운로드 중. `kubectl -n llm-d-lab logs -f deploy/decode` 로 확인 |
| helm pull 이 ghcr.io 에서 실패 | helm 3.8 이상인지 확인. 사내 프록시면 ghcr.io 허용 필요 |
| 비교표에서 두 실행의 조건이 다르다고 경고 | 한쪽만 인자를 바꿔 돌렸다. 같은 인자로 3단계와 5단계를 다시 |
| A/B 차이가 거의 없음 | `--prefix-tokens` 를 3000 이상으로. 반복 구간이 짧으면 캐시가 아낄 게 없다 |
| 포트가 이미 사용 중 | 남은 `kubectl port-forward` 프로세스를 정리하거나 `config/inference.env` 의 포트를 바꾼다 |
