#!/bin/bash
#
# 블록 스토어 앱 배포 (master에서 실행, privileged).
# cephadm-setup.sh 이후 단계 — 클러스터/cephadm SSH 키/worker 인증이 끝난 상태 전제.
#
#   - master: 중앙앱(central) systemd 서비스 (UI :3333)
#   - 각 worker: rbd 클라이언트 배포 → RBD 마운트 → 에이전트(agent) systemd 서비스 (:4000)
#
# 같은 앱의 Go 구현(apps/block-store-app-go)이 빌드돼 있으면 나란히 배포한다:
#   - master: Go 중앙앱 (UI :3334)
#   - 각 worker: Go 에이전트 (:4001) — Node 판과 같은 RBD 마운트를 공유한다
# 두 UI 에서 같은 파일이 보이므로 구현 차이를 그 자리에서 비교할 수 있다.
# Go 바이너리가 없으면 이 단계는 건너뛴다(기존 랩 동작에 영향 없음).
#
# 노드 간 작업은 ansible(인벤토리)로 수행한다. 앱 코드는 Vagrant synced_folder로
# master의 $APP_SRC / $GO_APP_SRC 에 올라와 있어야 한다.
#
# args: <network_prefix> <worker_length>
# env : AGENT_TOKEN(공유 시크릿), APP_SRC(앱 소스 경로), GO_APP_SRC(Go 앱 경로), RBD_POOL

set -euo pipefail

NETWORK_PREFIX="${1:?network prefix is required}"
WORKER_LENGTH="${2:?worker length is required}"
AGENT_TOKEN="${AGENT_TOKEN:-change-me-token}"
APP_SRC="${APP_SRC:-/opt/ceph-block-store-src}"
GO_APP_SRC="${GO_APP_SRC:-/opt/ceph-block-store-go-src}"
RBD_POOL="${RBD_POOL:-rbd-pool}"

APP_DST="/opt/ceph-block-store"
STORE_DIR="/srv/rbd-store"
AGENT_PORT=4000
CENTRAL_PORT=3333
# Go 구현은 별도 포트로 나란히 띄운다. 저장소(STORE_DIR)는 Node 판과 공유한다.
GO_AGENT_PORT=4001
GO_CENTRAL_PORT=3334
GO_BIN=/usr/local/bin/ceph-block-store
MASTER_IP="${NETWORK_PREFIX}.10"
ANSIBLE_DIR="/tmp/block-store-ansible"

echo "[block-store] 배포 시작 (workers=$WORKER_LENGTH, pool=$RBD_POOL)"

command -v ansible-playbook >/dev/null || { echo "ansible-playbook 필요 (common-setup 마스터 단계에서 설치됨)"; exit 1; }
[[ -f "$APP_SRC/app.js" ]] || { echo "앱 소스가 $APP_SRC 에 없습니다. Vagrantfile의 synced_folder를 확인하세요."; exit 1; }

run_ansible_playbook() {
  # npm/libuv가 Vagrant에서 상속한 stdio를 non-blocking으로 남길 수 있다.
  # Ansible에는 새 blocking pipe와 /dev/null을 연결하고 pipefail로 종료 코드를 보존한다.
  ansible-playbook "$@" </dev/null 2>&1 | cat
}

install -d "$ANSIBLE_DIR"

# --- 1. rbd 클라이언트 키링 + 최소 conf (워커 배포용) ---
echo "[block-store] rbd 클라이언트 키링 생성"
ceph auth get-or-create client.block-store \
  mon 'profile rbd' osd "profile rbd pool=${RBD_POOL}" mgr "profile rbd pool=${RBD_POOL}" \
  > "$ANSIBLE_DIR/ceph.client.block-store.keyring"
ceph config generate-minimal-conf > "$ANSIBLE_DIR/ceph.conf"

# --- 2. master: Node.js + 앱 + 중앙앱 서비스 ---
install_node() {
  command -v node >/dev/null && return 0
  echo "[block-store] Node.js 설치"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
}
install_node

echo "[block-store] master에 앱 배치"
rm -rf "$APP_DST"
mkdir -p "$APP_DST"
cp -r "$APP_SRC/app.js" "$APP_SRC/package.json" "$APP_SRC/public" "$APP_SRC/scripts" "$APP_DST/"
( cd "$APP_DST" && npm install --omit=dev )

# --- 3. 워커 인벤토리 (cephadm vagrant 키 사용) + NODES 레지스트리 ---
cat > "$ANSIBLE_DIR/inventory.ini" <<EOF
[workers]
EOF
NODES_CSV=""
for i in $(seq 1 "$WORKER_LENGTH"); do
  host="ceph-worker-$i"
  ip="${NETWORK_PREFIX}.$((i + 10))"
  key_path="$(find "/vagrant/.vagrant/machines/$host" -path '*/private_key' -type f | head -n 1 || true)"
  if [[ -z "$key_path" ]]; then
    echo "워커 $host 의 Vagrant private key를 찾지 못했습니다." >&2
    exit 1
  fi
  echo "$host ansible_host=$ip ansible_user=vagrant ansible_ssh_private_key_file=$key_path" >> "$ANSIBLE_DIR/inventory.ini"
  NODES_CSV="${NODES_CSV:+$NODES_CSV,}${host}=http://${ip}:${AGENT_PORT}"
done
export ANSIBLE_HOST_KEY_CHECKING=False

# --- 4. 워커 배포 플레이북: ceph client → node → 앱 → RBD 마운트 → 에이전트 서비스 ---
cat > "$ANSIBLE_DIR/deploy-agent.yml" <<'PLAY'
- hosts: workers
  become: true
  vars:
    app_dst: /opt/ceph-block-store
    store_dir: /srv/rbd-store
  tasks:
    - name: /etc/ceph 디렉터리
      file: { path: /etc/ceph, state: directory, mode: '0755' }
    - name: ceph.conf 배포
      copy: { src: "{{ ceph_conf }}", dest: /etc/ceph/ceph.conf, mode: '0644' }
    - name: rbd 키링 배포
      copy: { src: "{{ ceph_keyring }}", dest: /etc/ceph/ceph.client.block-store.keyring, mode: '0600' }
    - name: Node.js 설치 (없으면)
      shell: command -v node || (curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && apt-get install -y nodejs)
      args: { executable: /bin/bash }
    - name: 앱 디렉터리
      file: { path: "{{ app_dst }}", state: directory, mode: '0755' }
    - name: 앱 파일 복사 (app.js, package.json)
      copy: { src: "{{ app_src }}/{{ item }}", dest: "{{ app_dst }}/{{ item }}" }
      loop: [app.js, package.json]
    - name: 앱 scripts 복사
      copy: { src: "{{ app_src }}/scripts/", dest: "{{ app_dst }}/scripts/" }
    - name: 의존성 설치
      command: npm install --omit=dev
      args: { chdir: "{{ app_dst }}" }
    - name: RBD 생성/마운트 (setup-rbd-node.sh)
      shell: "POOL={{ rbd_pool }} CEPH_USER=block-store bash {{ app_dst }}/scripts/setup-rbd-node.sh"
      args: { executable: /bin/bash }
    - name: 에이전트 systemd 유닛
      copy:
        dest: /etc/systemd/system/ceph-block-agent.service
        content: |
          [Unit]
          Description=Ceph Block Store agent
          After=network-online.target
          [Service]
          WorkingDirectory={{ app_dst }}
          Environment=ROLE=agent
          Environment=STORE_DIR={{ store_dir }}
          Environment=PORT=4000
          Environment=AGENT_TOKEN={{ agent_token }}
          ExecStart=/usr/bin/node app.js
          Restart=on-failure
          [Install]
          WantedBy=multi-user.target
    - name: 에이전트 시작
      systemd: { name: ceph-block-agent, enabled: true, state: restarted, daemon_reload: true }
PLAY

echo "[block-store] 워커 에이전트 배포 (ansible)"
run_ansible_playbook -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/deploy-agent.yml" \
  -e ceph_conf="$ANSIBLE_DIR/ceph.conf" \
  -e ceph_keyring="$ANSIBLE_DIR/ceph.client.block-store.keyring" \
  -e app_src="$APP_SRC" \
  -e rbd_pool="$RBD_POOL" \
  -e agent_token="$AGENT_TOKEN"

# --- 5. master 중앙앱 systemd 서비스 ---
echo "[block-store] master 중앙앱 서비스 등록"
cat > /etc/systemd/system/ceph-block-central.service <<EOF
[Unit]
Description=Ceph Block Store central
After=network-online.target

[Service]
WorkingDirectory=$APP_DST
Environment=ROLE=central
Environment=PORT=$CENTRAL_PORT
Environment=AGENT_TOKEN=$AGENT_TOKEN
Environment=NODES=$NODES_CSV
ExecStart=/usr/bin/node app.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ceph-block-central

# --- 6. Go 구현 배포 (바이너리가 있을 때만) ---
#
# Node 판과 같은 RBD 마운트를 공유하고 포트만 다르게 띄운다. 한쪽 UI 에서 올린
# 파일이 다른 쪽에서 그대로 보이므로, 같은 데이터·같은 스토리지 위에서 두 구현을
# 직접 비교할 수 있다.
#
# 여기에는 런타임 설치도 의존성 설치도 없다 — 정적 바이너리를 복사하는 것이 전부다.
# 대조군인 4단계 플레이북의 "Node.js 설치" + "의존성 설치" 태스크와 비교할 것.
GO_DEPLOYED=0
GO_ARCH="$(dpkg --print-architecture)"
GO_SRC_BIN="$GO_APP_SRC/dist/ceph-block-store-linux-${GO_ARCH}"

if [[ ! -f "$GO_SRC_BIN" ]]; then
  echo "[block-store] Go 바이너리 없음 — Go 구현 배포를 건너뜁니다"
  echo "               (호스트에서 'bash apps/block-store-app-go/scripts/build.sh' 후 재실행)"
else
  echo "[block-store] Go 구현 배포 ($(stat -c%s "$GO_SRC_BIN") bytes, 설치 패키지 0개)"
  install -m 0755 "$GO_SRC_BIN" "$GO_BIN"

  GO_NODES_CSV=""
  for i in $(seq 1 "$WORKER_LENGTH"); do
    ip="${NETWORK_PREFIX}.$((i + 10))"
    GO_NODES_CSV="${GO_NODES_CSV:+$GO_NODES_CSV,}ceph-worker-$i=http://${ip}:${GO_AGENT_PORT}"
  done

  cat > "$ANSIBLE_DIR/deploy-go-agent.yml" <<'PLAY'
- hosts: workers
  become: true
  vars:
    store_dir: /srv/rbd-store
  tasks:
    # 배포 단계가 이것 하나다. RBD 마운트는 Node 판 플레이북이 이미 끝내 놓았고,
    # 이 에이전트는 같은 마운트를 그대로 쓴다.
    - name: Go 바이너리 복사
      copy: { src: "{{ go_bin_src }}", dest: /usr/local/bin/ceph-block-store, mode: '0755' }
    - name: Go 에이전트 systemd 유닛
      copy:
        dest: /etc/systemd/system/ceph-block-agent-go.service
        content: |
          [Unit]
          Description=Ceph Block Store agent (Go)
          After=network-online.target
          # 저장소가 마운트된 뒤에 뜬다. 마운트 전에 뜨면 루트 디스크에 쓰게 된다.
          RequiresMountsFor={{ store_dir }}
          [Service]
          Environment=ROLE=agent
          Environment=STORE_DIR={{ store_dir }}
          Environment=PORT={{ go_agent_port }}
          Environment=AGENT_TOKEN={{ agent_token }}
          ExecStart=/usr/local/bin/ceph-block-store
          Restart=on-failure
          [Install]
          WantedBy=multi-user.target
    - name: Go 에이전트 시작
      systemd: { name: ceph-block-agent-go, enabled: true, state: restarted, daemon_reload: true }
PLAY

  echo "[block-store] 워커 Go 에이전트 배포 (ansible)"
  run_ansible_playbook -i "$ANSIBLE_DIR/inventory.ini" "$ANSIBLE_DIR/deploy-go-agent.yml" \
    -e go_bin_src="$GO_SRC_BIN" \
    -e go_agent_port="$GO_AGENT_PORT" \
    -e agent_token="$AGENT_TOKEN"

  echo "[block-store] master Go 중앙앱 서비스 등록"
  cat > /etc/systemd/system/ceph-block-central-go.service <<EOF
[Unit]
Description=Ceph Block Store central (Go)
After=network-online.target

[Service]
Environment=ROLE=central
Environment=PORT=$GO_CENTRAL_PORT
Environment=AGENT_TOKEN=$AGENT_TOKEN
Environment=NODES=$GO_NODES_CSV
ExecStart=$GO_BIN
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now ceph-block-central-go
  GO_DEPLOYED=1
fi

echo "[block-store] 배포 완료"
echo "  Central UI (Node) : http://${MASTER_IP}:${CENTRAL_PORT}"
echo "  Nodes      (Node) : ${NODES_CSV}"
if [[ "$GO_DEPLOYED" -eq 1 ]]; then
  echo "  Central UI (Go)   : http://${MASTER_IP}:${GO_CENTRAL_PORT}"
  echo "  Nodes      (Go)   : ${GO_NODES_CSV}"
  echo
  echo "  두 UI 는 같은 RBD 마운트를 보므로 한쪽에서 올린 파일이 다른 쪽에도 나타납니다."
  echo "  구현 비교:  bash /vagrant/scripts/ceph/block-store-compare.sh"
fi
