# Ceph Block Store — Go 구현

`../block-store-app` (Node.js) 과 **같은 앱**이다. 같은 HTTP API, 같은 UI, 같은
환경변수 계약을 구현하며, 같은 랩·같은 RBD 마운트 위에서 나란히 뜬다.

목적은 새 기능이 아니라 **비교**다. 같은 요구사항을 Go 로 구현했을 때 배포와
런타임이 어떻게 달라지는지를 같은 자리에서 확인하기 위한 것이다.

```
                     ┌── Node.js 중앙앱  :3333 ──┐
브라우저 ────────────┤                            ├── 같은 RBD 마운트
                     └── Go 중앙앱      :3334 ──┘   /srv/rbd-store
                              │
                    ┌─────────┴─────────┐
              agent :4000 (Node)   agent :4001 (Go)   ← 같은 워커, 같은 볼륨
```

한쪽 UI 에서 올린 파일이 다른 쪽 UI 에도 그대로 보인다. 두 구현이 같은 볼륨을
읽고 쓰기 때문이다.

## 실측 비교

이 저장소에서 두 구현을 나란히 띄우고 잰 값이다. 랩에서 재현하려면
`bash scripts/ceph/block-store-compare.sh`.

### 배포 발자국

| | Node.js | Go |
| --- | --- | --- |
| 노드 런타임 | Node.js 20 설치 필요 | 없음 (정적 링크, libc 도 없음) |
| 의존 패키지 | 84개 | 0개 |
| 배포 파일 | `node_modules/` 782개 + `app.js` + `public/` | 바이너리 1개 |
| 크기 | node_modules 5.6 MB + 런타임 | 6.3 MB (UI 포함) |
| 노드별 외부 의존 | 인터넷, apt 미러, npm 레지스트리 | 없음 |

Go 빌드는 **호스트에서 한 번**(테스트 포함 약 18초, amd64+arm64 동시 산출),
npm install 은 **노드마다** 일어난다.

### 763MB 파일 업로드 중 피크 메모리

| | 업로드 전 RSS | 피크 RSS |
| --- | --- | --- |
| Node.js 중앙앱 | 92 MB | **4,658 MB** |
| Node.js 에이전트 | 68 MB | 1,599 MB |
| Go 중앙앱 | 7 MB | **8 MB** |
| Go 에이전트 | 6 MB | 6 MB |

Node 판은 `multer.memoryStorage()` 로 업로드 전체를 RAM 에 올린 뒤, 중앙앱에서
다시 `Blob` 을 만들어 `FormData` 에 담는다. 즉 파일이 메모리에 여러 벌 올라가고,
763MB 업로드 하나가 4.6GB 를 먹는다. `ceph-master` VM 메모리가 6144MB 이므로
**동시 업로드 두 건이면 OOM 이다.**

Go 판은 `multipart.Reader` 로 파트를 읽어 `io.Pipe` 로 에이전트에 직결하고,
에이전트는 그대로 디스크로 흘려보낸다. 파일 크기와 무관하게 메모리가 평평하다.

### `/api/nodes` 조회 지연 (무응답 노드 3대 + 정상 1대)

| | 응답 시간 |
| --- | --- |
| Node.js | **55초에도 미완료** (무한 대기) |
| Go | 5.01초 (정상 반환, 해당 노드는 offline 표시) |

Node 판은 `for...of` 안에서 `await fetch` 하므로 노드를 하나씩 순차 조회하고,
`fetch` 에 기본 타임아웃이 없어 무응답 노드 하나가 목록 전체를 무기한 붙잡는다.
워커 하나가 행(hang) 걸리면 UI 가 영영 안 뜬다. Go 판은 팬아웃 + 5초 상한이라
전체 지연이 가장 느린 노드 하나에 수렴한다.

## 빌드와 배포

```bash
# 호스트에서 한 번 (Go 1.24+ 필요, 워커에는 불필요)
bash scripts/build.sh          # dist/ceph-block-store-linux-{amd64,arm64}

# 랩에 반영
vagrant provision --provision-with blockstoreapp
```

`dist/` 에 바이너리가 없으면 랩 프로비저닝은 Go 배포를 **건너뛴다**. Go 툴체인이
없는 호스트에서도 기존 Node 랩이 그대로 동작해야 하기 때문이다.

수동 배포는 `scripts/run-agent.sh` 를 쓴다. Node 판의 같은 이름 스크립트와
나란히 놓고 보면 차이가 분명하다 — 그쪽은 NodeSource 등록 + `apt-get install` +
`npm install` 을 하고, 이쪽은 설치 단계가 없다.

## 환경변수

Node 판과 **동일한 계약**이다. systemd 유닛에서 `ExecStart` 만 바꿔 끼울 수 있다.

| 변수 | 역할 | 기본값 |
|---|---|---|
| `ROLE` | `central` 또는 `agent` | `central` |
| `PORT` | 리슨 포트 | central 3333 / agent 4000 |
| `AGENT_TOKEN` | central↔agent 공유 시크릿 | **필수** (미설정 시 기동 거부) |
| `STORE_DIR` | (agent) RBD 마운트 경로 | `/srv/rbd-store` |
| `NODES` | (central) `이름=URL,...` 레지스트리 | 워커 2대(60.11/60.12:4000) |

랩에서는 Node 판과 겹치지 않게 `PORT=3334`(central) / `PORT=4001`(agent) 로 뜬다.

## API

Node 판과 동일하다. 같은 `index.html` 이 두 구현 모두에서 동작한다.

**중앙앱**

| | |
|---|---|
| `GET /` | UI (바이너리에 embed) |
| `GET /api/nodes` | `{nodes:[{name,url,online,store}]}` |
| `GET /api/nodes/{node}/files` | 파일 목록 |
| `GET /api/nodes/{node}/files/{name}/download` | 다운로드 |
| `POST /api/nodes/{node}/files` | 업로드 (multipart, 필드명 `file`) |
| `DELETE /api/nodes/{node}/files/{name}` | 삭제 |

**에이전트** (모든 경로가 `x-agent-token` 요구)

| | |
|---|---|
| `GET /health` | `{ok, store}` |
| `GET /files` | `{files:[{key,size,lastModified}]}` |
| `GET /files/{name}/download` | 파일 본문 |
| `POST /files` | multipart `file` + `x-filename` 헤더 |
| `DELETE /files/{name}` | `{success:true}` |

## 동작이 다른 지점

API 는 같지만 다음은 의도적으로 다르게 했다.

- **경로 탈출을 거부한다.** Node 판은 `path.basename` 으로 `a/../../etc/passwd`
  를 조용히 `passwd` 로 바꿔 처리한다. 사용자가 요청한 것과 다른 파일을
  성공적으로 다루게 되므로, 여기서는 이름을 변형하지 않고 400 으로 거부한다.
- **업로드가 원자적이다.** 임시 파일에 쓰고 `rename` 으로 교체한다. Node 판은
  대상 파일에 직접 쓰므로 업로드가 끊기면 기존 파일이 반쯤 덮인 채 남는다.
- **토큰 비교가 상수 시간이다** (`crypto/subtle`).
- **기본 토큰으로 뜨지 않는다.** Node 판은 `change-me-token` 으로 뜨고 경고만
  찍는다. 기본 시크릿으로 뜬 서비스는 사실상 인증이 없으므로 기동을 거부한다.
- **마운트가 빠지면 `/health` 가 실패한다.** 디렉터리만 있고 RBD 가 안 붙은
  노드를 정상으로 보고하면 중앙앱이 그 노드로 트래픽을 보내 루트 디스크에 쓰게 된다.

## 의존성 정책

`go.mod` 에 외부 모듈이 없다. 취향이 아니라 전제다 — 노드에 배포되는 산출물이
파일 하나여야 "런타임도 패키지 매니저도 없는 노드에 복사 한 번"이 성립한다.
HTTP 서버·라우팅·multipart·JSON·embed·동시성이 전부 stdlib 로 해결된다.
Go 1.22 부터 `net/http` 라우터가 `GET /files/{name}/download` 형태의 메서드+경로
패턴을 지원해서 서드파티 라우터도 필요 없다.

## 테스트

```bash
go test ./...
go test -race ./...
```

경로 탈출 거부, 업로드 중단 시 원자성, 토큰 인증, 미등록 노드 차단,
비ASCII 파일명 왕복, 팬아웃이 실제로 동시인지, 그리고 UI 가 읽는 JSON 형태를
덮는다. `scripts/build.sh` 가 빌드 전에 `go vet` 과 테스트를 돌린다.

## 주의

Node 판과 같은 제약이 그대로 적용된다.

- RBD 볼륨은 **노드 1개만 마운트**한다. 같은 이미지를 두 노드가 동시에 RW
  마운트하면 파일시스템이 깨진다.
- 노드별로 **독립된 저장 공간**이다. worker-1 에 올린 파일은 worker-2 에 없다.
- 두 구현이 같은 마운트를 공유하는 것은 **같은 노드 안에서**의 이야기다.
  프로세스 두 개가 같은 디렉터리를 읽고 쓰는 것이며, RBD 를 이중 마운트하는 것이 아니다.
