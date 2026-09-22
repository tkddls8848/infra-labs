# Local K3s AI lab

단일 노드 K3s 를 로컬에 올리고, 그 위에서 AI 추론 인프라를 실습하는 랩이다.

| 구성 | 내용 |
|---|---|
| [`scripts/addons/ai.sh`](scripts/addons/ai.sh) | K3s 단일 노드 설치 (선택적으로 K3AI) |
| [`scripts/inference/`](scripts/inference/) | 추론 라우팅 실습 — vLLM · llm-d · InferencePool (단계별 롤백 포함) |
| [`LAB-inference.md`](LAB-inference.md) | **실습 가이드**. 단계별로 무엇을 보고 무엇을 확인하는지 |
| [`config/inference.env`](config/inference.env) | 추론 실습의 단일 설정 원천 |
| [`bench/`](bench/) | 멀티턴 부하 · A/B 비교 · 실시간 관측 도구 |

---

# 1부 — K3s 베이스

## 고정 버전

- K3s: `v1.32.3+k3s1`
- K3s 설치 스크립트 URL: `https://get.k3s.io`
- 설치 스크립트 SHA-256:
  `ed01f89fd977bf20ac1516bbebf8370bf3ddbaa55dac8aba610956a4c78cc00b`
- 서버 옵션: `--write-kubeconfig-mode=0644`

설치 스크립트는 임시 파일로 내려받아 내용이 비어 있지 않은지, 셸 스크립트가 맞는지,
고정 체크섬과 일치하는지 확인한 뒤에야 실행한다. `get.k3s.io` 의 응답이 바뀌면
내용을 검토하고 체크섬을 의도적으로 갱신하기 전까지 실패한다. 네트워크 응답을
`sh` 로 파이프하는 경로는 어디에도 없다.

K3AI 가 선택 사항인 이유는 이 저장소가 고정된 K3AI 설치 스크립트 릴리스를 들고
있지 않기 때문이다. 쓰려면 운영자가 HTTPS URL 과 SHA-256 을 둘 다 제공해야 한다.

## 호스트 요구사항

- systemd 와 `sudo` 가 있는 리눅스 호스트 (Ubuntu 22.04/24.04 를 상정)
- `curl`, `sha256sum`, K3s 릴리스 엔드포인트로 나가는 HTTPS
- 이후 올릴 AI 워크로드가 쓸 CPU · 메모리 · 디스크
- 포트 `6443` 과 K3s 의 파드/서비스 네트워크 대역이 다른 로컬 클러스터와 겹치지 않을 것

스크립트는 현재 부팅 동안 스왑을 끄고 `/etc/fstab` 의 스왑 항목을 주석 처리한다.
이 랩의 쿠버네티스 구성이 요구하는 조건이다.

## 설치

```bash
bash scripts/addons/ai.sh
sudo systemctl status k3s
sudo kubectl get nodes
```

검토를 마친 K3AI 설치 스크립트를 쓰려면 무결성 입력 두 가지를 모두 준다:

```bash
K3AI_INSTALLER_URL="https://example.invalid/pinned/k3ai-install.sh" \
K3AI_INSTALLER_SHA256="<64-hex-sha256>" \
bash scripts/addons/ai.sh
```

K3AI 설치 스크립트는 검증된 로컬 파일에서 `--pipelines` 옵션을 명시해 실행된다.
URL 만 주지 말 것 — 검증되지 않은 설치 스크립트는 거부한다.

## 제거

K3s 는 설치 중에 자체 제거 도구를 만든다:

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

AI 워크로드의 데이터나 외부 볼륨은 따로 검토해서 지운다. K3s 제거 도구는 그
산출물들의 보존 정책을 알지 못한다.

---

# 2부 — 추론 라우팅 실습

DEVOCEAN 기술블로그 "쿠버네티스로 여는 AI 추론 인프라"(최용호, 2026-09-21) 가
설명하는 라우팅 계층을 로컬 GPU 한 장에서 재현한다. 실습 절차는
[`LAB-inference.md`](LAB-inference.md) 에 있다. 이 문서는 구성과 정책만 적는다.

## 추가 호스트 요구사항

- NVIDIA GPU 1장 (VRAM 6 GiB 이상 — 기본 설정이 이 크기 기준이다)
- NVIDIA 드라이버 + `nvidia-container-toolkit`
  (설치 후 `sudo systemctl restart k3s` — K3s 가 기동 시 탐지해 `nvidia`
  RuntimeClass 를 만든다)
- `helm` 3.8 이상 (OCI 레지스트리에서 차트를 받는다)
- `python3`, `git`
- 호스트 RAM 16 GiB 이상 (기본 설정의 파드 요청 합계는 약 8.4 GiB)
- 디스크 30 GiB 이상 (대부분은 vLLM 컨테이너 이미지다. 가중치는 1 GiB 남짓)

## 고정 버전 (세트)

버전들은 서로 물려 있다. llm-d v0.9.0 의 가이드가 GAIE 버전과 라우터 차트
버전을 가리키고, 차트 preset 이 Envoy 태그를 고정한다. 하나만 올리지 말고
아래 "버전 갱신" 절차대로 함께 올린다.

| 구성요소 | 핀 | 무결성 |
|---|---|---|
| Gateway API Inference Extension | `v1.5.0` | 릴리스 에셋 SHA-256 대조 |
| llm-d 라우터 차트 (standalone) | `v0.10.0` | `.tgz` SHA-256 대조 |
| EPP 이미지 | `ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.10.0` | 태그 고정 |
| Envoy 사이드카 | `envoyproxy/envoy:distroless-v1.33.2` | 차트 preset |
| vLLM | `docker.io/vllm/vllm-openai:v0.26.0` | 태그 고정 |
| NVIDIA device plugin | `nvcr.io/nvidia/k8s-device-plugin:v0.17.0` | 태그 고정 |
| llm-d 상류 (읽기 전용) | `v0.9.0` | git 태그 |
| 기본 모델 | `Qwen/Qwen2.5-0.5B-Instruct` | — |

실제 값은 모두 [`config/inference.env`](config/inference.env) 에 있다.
스크립트 안에 같은 값을 다시 적지 않는다.

### 매니페스트 정책

원격 매니페스트와 Helm 차트는 적용 전에 SHA-256 을 대조한다.
`kubectl apply -f <URL>` 로 미검증 원격 매니페스트를 직접 적용하는 경로는 없다.
차트도 `helm pull` 로 받아 검증한 **그 파일**로 설치한다 — `helm install` 이
레지스트리를 다시 찾아가게 두면 검증한 것과 설치한 것이 달라질 수 있다.

EPP 이미지 태그를 명시적으로 고정하는 이유는 차트 기본값이 움직이는 `main`
태그이기 때문이다. 그대로 두면 같은 스크립트가 날마다 다른 것을 설치한다.

## GPU 메모리 산정

time-slicing 은 SM 실행 시간만 나눈다. **VRAM 은 나누지 않는다.** 같은 GPU 위의
vLLM 레플리카들은 전체 메모리를 함께 보고 각자 `--gpu-memory-utilization` 만큼
예약하므로, 곱이 1을 넘으면 서로를 밟는다.

| VRAM | 권장 `REPLICAS` | 권장 `GPU_MEMORY_UTILIZATION` | 레플리카당 |
|---:|---:|---:|---:|
| 6 GiB | 2 | 0.40 | ≈ 2.4 GiB ← 기본값 |
| 8 GiB | 2 | 0.40 | ≈ 3.2 GiB |
| 12 GiB | 3 | 0.28 | ≈ 3.3 GiB |
| 16 GiB | 3 | 0.30 | ≈ 4.8 GiB |
| 24 GiB | 3 | 0.30 | ≈ 7.2 GiB |
| 24 GiB | 4 | 0.22 | ≈ 5.2 GiB |

`00_preflight.sh` 가 곱이 0.95 이상이거나 레플리카당 2 GiB 미만이면 막는다.
레플리카가 2개 미만이면 "여러 파드에 흩어진다"는 실습 전제 자체가 사라진다.
그래서 `REPLICAS=2` 가 이 랩의 하한이고, VRAM 이 약 4.4 GiB 미만이면 두 조건을
동시에 만족할 수 없다 — 그런 GPU 에서는 더 작은 모델을 써야 한다.

VRAM 만 맞으면 되는 것이 아니다. vLLM 은 호스트 RAM 도 쓰고, 그 몫은 노드
allocatable 에서 나온다. `00_preflight.sh` 6단계가 `REPLICAS × VLLM_MEMORY_REQUEST`
에 EPP·Envoy 를 더한 합계를 노드 용량과 대조한다. 여기서 막히면 두 번째
레플리카가 `Pending` 으로 남았을 상황을 미리 잡은 것이다.

또한 time-slicing 에는 **격리가 없다.** 한 파드의 CUDA OOM 이 같은 GPU 의 다른
파드를 같이 죽일 수 있다. 랩 전용이고, 운영에 쓸 구성이 아니다.

## 1부와의 관계 — 무엇을 빌려 쓰고 무엇을 남기는가

2부는 **1부가 설치한 K3s 클러스터를 그대로 빌려 쓴다.** 별도 클러스터를 만들지
않고, K3s 를 설치하지도 않는다. `00_preflight.sh` 가 접속을 확인하고, 없으면
`scripts/addons/ai.sh` 를 먼저 돌리라고 알려 준다.

그래서 2부는 자기 네임스페이스 밖도 건드린다. 어디를 건드리는지 명시한다.

| 범위 | 무엇 | 만드는 단계 |
|---|---|---|
| 네임스페이스 `llm-d-lab` | vLLM Deployment, Service, PVC, 라우터 | 02, 04 |
| `kube-system` | device plugin DaemonSet + time-slicing ConfigMap | 01 |
| 클러스터 스코프 | InferencePool CRD | 04 |
| 호스트 | 없음 | — |

K3s 자체, `nvidia` RuntimeClass, 1부가 만든 것은 **어느 단계에서도 건드리지
않는다.**

## 파괴적 작업 정책

**앞으로 가는 단계는 남의 것을 덮어쓰지 않는다.** 01 과 04 는 `kube-system` 의
device plugin 과 클러스터 스코프 CRD 를 만들기 전에 이미 있는지 확인한다. 있는데
이 랩이 만든 것이 아니면 — GPU Operator, 다른 랩, 수동 설치 — 덮어쓰지 않고
멈추거나(device plugin) 기존 것을 그대로 쓴다(CRD). 이 랩이 만든 리소스에는
`local-k3s-ai.lab/owner: inference` 어노테이션이 붙는다.

**되돌리는 것은 표시된 것만 지운다.** [`90_rollback.sh`](scripts/inference/90_rollback.sh)
는 단계를 골라 그 이전 상태로 되돌린다. 저장소의
[`local-kubeadm-gpu/06_rollback.sh`](../local-kubeadm-gpu/06_rollback.sh) 와 같은
방식이다.

| 명령 | 되돌리는 범위 | 남는 것 |
|---|---|---|
| `90_rollback.sh 07` | 받아 둔 llm-d 체크아웃 | 클러스터 전부 |
| `90_rollback.sh results` | 실습 결과 JSON | 클러스터 전부 |
| `90_rollback.sh 06` | 라우터 설정을 기본값으로 복원 | 라우터·모델 서버 |
| `90_rollback.sh 04` | 라우터, (이 랩이 만든) CRD | 모델 서버 — 실습 A 는 계속 가능 |
| `90_rollback.sh 02` | + 네임스페이스, 모델 가중치 | GPU 공유 설정 |
| `90_rollback.sh 01` | + device plugin (이 랩 것일 때만) | K3s, RuntimeClass |

인자 없이 실행하면 메뉴가 나오고, 실행 전에 확인을 받는다. `--yes` 로 생략한다.
`all` 은 `01` 과 같다. K3s 까지 지우려면 1부의 `k3s-uninstall.sh` 를 쓴다.

`06_saturation.sh` 는 라우터 설정을 일부러 망가뜨리는 실습이라, 어떻게 끝나든
(정상·실패·Ctrl-C) 스스로 원래 값으로 되돌린다. 그래도 꼬였다면
`90_rollback.sh 06` 이 확실히 복원한다.

## 생성물

스크립트는 `.generated/` 아래에만 쓴다. `.gitignore` 의 `systems/**/.generated/`
규칙으로 커밋되지 않는다. 여기에는 렌더된 매니페스트, 받아 둔 차트, 실습 결과
JSON, llm-d 상류 체크아웃이 들어간다. `90_rollback.sh` 가 되돌리는 범위에 맞춰 지운다.

## 버전 갱신

1. [llm-d 릴리스](https://github.com/llm-d/llm-d/releases)에서 새 태그를 고르고
   `LLMD_VERSION` 을 올린다.
2. 그 태그의 `guides/env.sh` 를 읽어 `GAIE_VERSION`, `ROUTER_CHART_VERSION`,
   `ROUTER_EPP_VERSION` 을 맞춘다.
3. 새 GAIE 릴리스 에셋(`v1-manifests.yaml`)을 받아 `sha256sum` 으로
   `GAIE_MANIFEST_SHA256` 을 갱신한다.
4. `helm pull` 로 새 차트를 받아 `.tgz` 의 `sha256sum` 으로
   `ROUTER_CHART_SHA256` 을 갱신한다.
5. 그 태그의 `guides/recipes/modelserver/components/images/gpu-vllm/release/`
   에서 vLLM 이미지 태그를 확인해 `VLLM_IMAGE` 를 맞춘다.
6. 위 표와 `config/inference.env` 를 함께 고치고, 0~5단계를 처음부터 다시 돌려
   실제로 뜨는지 확인한다.

## 검증 상태

이 랩의 스크립트와 매니페스트는 위 표의 상류 소스(llm-d `v0.9.0`, GAIE `v1.5.0`,
라우터 차트 `v0.10.0`)를 직접 읽고 그 인터페이스에 맞춰 작성했다. 템플릿은 렌더
후 YAML 파싱으로, 셸 스크립트는 구문 검사로, 부하·비교 도구의 계산 로직은
단위 테스트로 확인했다.

**다만 GPU 가 달린 실제 클러스터에서 끝까지 실행해 본 적은 없다.** 첫 실행에서는
이미지 태그, 차트 값 스키마, 로그 문구 같은 부분이 어긋날 수 있다. 각 스크립트가
실패 지점을 짚어 주도록 써 두었으니, 막히는 곳이 있으면 그 메시지와 함께 알려
주면 고친다.
