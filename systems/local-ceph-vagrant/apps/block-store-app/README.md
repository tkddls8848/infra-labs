# Ceph Block Store (노드별 RBD 파일 앱)

Ceph **RBD(블록)** 스토리지에 파일을 올리고 받는 웹앱입니다.

블록 스토리지는 **단일 writer**라 노드 간 공유가 안 됩니다. 그래서 **노드마다 자기 RBD 볼륨을 따로 마운트**하고, 사용자가 웹 UI에서 **저장 노드를 선택**해 그 노드의 볼륨에 파일을 CRUD 합니다.

> Object(RGW) / File(CephFS) 공유는 이 앱이 아니라 **Filestash**로 처리합니다. 이 앱은 **블록 전용**입니다.

> **같은 앱의 Go 구현이 [`../block-store-app-go`](../block-store-app-go) 에 있습니다.**
> 같은 API·같은 UI 이며, 같은 RBD 마운트를 공유하고 포트만 다릅니다(central 3334 / agent 4001).
> 랩을 올리면 두 UI 에서 같은 파일이 보이므로 두 구현을 그 자리에서 비교할 수 있습니다.
> 배포 발자국·메모리·지연 실측값은 그쪽 README 를 참고하세요.

## 구성

```
브라우저 ──HTTP──> [중앙앱 central, master:3333]
                       │ 선택한 노드로 프록시 (x-agent-token)
        ┌──────────────┼──────────────┐
        ▼                              ▼
[에이전트 agent           ]    [에이전트 agent           ]
 ceph-worker-1:4000            ceph-worker-2:4000
 /srv/rbd-store (RBD 마운트)    /srv/rbd-store (RBD 마운트)
```

- `app.js` 하나로 `ROLE=central` / `ROLE=agent` 분기.
- 에이전트는 자기 로컬 RBD 마운트(`STORE_DIR`)에만 파일 CRUD.
- 중앙앱은 UI 제공 + 선택 노드 에이전트로 프록시. `AGENT_TOKEN` 공유 시크릿으로 인증.

## 사전 준비 (master에서)

RBD 풀은 `cephadm-rbd.sh`가 만든 `rbd-pool`을 사용합니다. 워커에서 `rbd`를 쓰려면 클라이언트 설정을 배포해야 합니다:

```bash
# master에서 rbd 권한 클라이언트 키링 생성
sudo ceph auth get-or-create client.block-store \
  mon 'profile rbd' osd 'profile rbd pool=rbd-pool' mgr 'profile rbd pool=rbd-pool' \
  | sudo tee /etc/ceph/ceph.client.block-store.keyring
sudo ceph config generate-minimal-conf | sudo tee /tmp/ceph.conf
```
위 `/tmp/ceph.conf`와 `/etc/ceph/ceph.client.block-store.keyring`을 **각 워커의 `/etc/ceph/`**(파일명은 `ceph.conf`, `ceph.client.block-store.keyring`)로 복사하세요.

## 배포

### 1) 각 워커: RBD 마운트 + 에이전트
```bash
# 앱 코드(app.js, package.json, scripts/)를 워커로 복사한 뒤, 워커에서:
sudo POOL=rbd-pool SIZE=5G CEPH_USER=block-store bash scripts/setup-rbd-node.sh
AGENT_TOKEN='my-shared-secret' bash scripts/run-agent.sh
```
- `setup-rbd-node.sh`: `rbd-pool`에 이미지 생성 → map → mkfs → `/srv/rbd-store` 마운트.
- `run-agent.sh`: Node.js(없으면 설치) + 의존성 설치 + 에이전트 기동(4000).

### 2) master: 중앙앱
```bash
npm install
AGENT_TOKEN='my-shared-secret' \
NODES='ceph-worker-1=http://192.168.60.11:4000,ceph-worker-2=http://192.168.60.12:4000' \
node app.js
```
브라우저에서 `http://<master>:3333` → 왼쪽 "저장 노드" 목록에서 온라인 노드 선택 → 업로드/다운로드/삭제.

## 환경변수

| 변수 | 역할 | 기본값 |
|---|---|---|
| `ROLE` | `central` 또는 `agent` | `central` |
| `PORT` | 리슨 포트 | central 3333 / agent 4000 |
| `AGENT_TOKEN` | central↔agent 공유 시크릿 (**반드시 동일**) | `change-me-token`(경고) |
| `STORE_DIR` | (agent) RBD 마운트 경로 | `/srv/rbd-store` |
| `NODES` | (central) `이름=URL,...` 노드 레지스트리 | 워커 2대(60.11/60.12:4000) |

## 에이전트를 systemd로 상주시키기 (선택)

```ini
# /etc/systemd/system/ceph-block-agent.service
[Unit]
Description=Ceph Block Store agent
After=network-online.target srv-rbd\x2dstore.mount

[Service]
WorkingDirectory=/opt/ceph-block-store
Environment=ROLE=agent
Environment=STORE_DIR=/srv/rbd-store
Environment=PORT=4000
Environment=AGENT_TOKEN=my-shared-secret
ExecStart=/usr/bin/node app.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl enable --now ceph-block-agent
```
(RBD 마운트도 재부팅 후 유지하려면 `/etc/fstab`에 `rbd` 매핑/마운트를 등록하거나 `rbdmap` 서비스를 사용하세요.)

## 보안 메모 (실습용 기본값)
- `AGENT_TOKEN`은 단순 공유 시크릿입니다. 에이전트 포트(4000)는 **클러스터 내부망에서만** 접근 가능하게 두세요.
- 마운트에 `chmod 0777`을 줍니다(실습 편의). 운영에선 전용 사용자/권한으로 조정하세요.

## 주의
- RBD 볼륨은 **노드 1개만 마운트**합니다. 같은 이미지를 두 노드가 동시에 RW 마운트하면 파일시스템이 깨집니다.
- 노드별로 **독립된 저장 공간**입니다. worker-1에 올린 파일은 worker-2에 없습니다(블록의 본질).
