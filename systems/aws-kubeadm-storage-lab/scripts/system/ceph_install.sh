#!/bin/bash
set -e
CURRENT_STEP="init"
CURRENT_TARGET="local"
trap 'status=$?; command_name=${BASH_COMMAND%% *}; printf "[step=%s][target=%s][failed] reason=command exited %d: %s\\n" "$CURRENT_STEP" "$CURRENT_TARGET" "$status" "$command_name" >&2' ERR

# Lock 파일 확인 - 동시 실행 방지
LOCK_FILE="/tmp/ceph-setup.lock"
if [ -f "$LOCK_FILE" ]; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=다른 프로세스가 Ceph 설정 중입니다 (lock: $LOCK_FILE)" >&2
  exit 1
fi

source scripts/.env

export KUBECONFIG=~/.kube/config-k8s-storage-lab
SSH_OPTS="-o StrictHostKeyChecking=no -i $SSH_KEY"
CSSH="ssh $SSH_OPTS ubuntu@"

# K8s 클러스터 존재 확인
if ! kubectl cluster-info &>/dev/null; then
  echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET][failed] reason=K8s 클러스터에 접근할 수 없습니다." >&2
  echo "   먼저 start_k8s.sh 를 실행하세요."
  exit 1
fi

ROOK_VERSION="v1.16.6"
CEPH_IMAGE="quay.io/ceph/ceph:v19.2.3"

# Lock 파일 생성 및 trap 설정
touch "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

WORKER_COUNT=${#WORKER_PUBS[@]}

# 카운트다운 표시 함수
countdown() {
  local sec=$1
  local msg=$2
  for s in $(seq $sec -1 1); do
    printf "\r  [대기] %s - %2ds 남음..." "$msg" $s
    sleep 1
  done
  printf "\r  [완료] %s                    \n" "$msg"
}

CURRENT_STEP="1"; CURRENT_TARGET="master:${MASTER_IP:-${M1_PUB:-pending}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Helm 설치 (master-1)"
$CSSH$M1_PUB "
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  helm version
"

CURRENT_STEP="1-1"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] rook-ceph Helm repo 추가"
$CSSH$M1_PUB "
  helm repo add rook-release https://charts.rook.io/release
  helm repo update
  kubectl create namespace rook-ceph || true
"

CURRENT_STEP="1-2"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] rook-ceph Operator 배포"
$CSSH$M1_PUB "helm upgrade --install rook-ceph rook-release/rook-ceph --namespace rook-ceph --version $ROOK_VERSION"
echo "  [대기] rook-ceph-operator Deployment rollout 완료 대기 (최대 300s)..."
$CSSH$M1_PUB "kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=300s"

# operator의 CRD watch 연결(20+개)이 안정화될 시간 확보
# 바로 CephCluster를 배포하면 watch 폭풍 + reconcile 루프로 etcd 과부하 발생
countdown 60 "rook-ceph-operator CRD watch 안정화"
$CSSH$M1_PUB "kubectl -n rook-ceph get pods"

CURRENT_STEP="1-2-1"; CURRENT_TARGET="workers"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] 워커 노드 rbd 모듈 로드 확인"
for i in $(seq 0 $((WORKER_COUNT - 1))); do
  NODE_IP="${WORKER_PUBS[$i]}"
  NODE_NAME="worker-$((i + 1))"
  $CSSH$NODE_IP "
    if lsmod | grep -q '^rbd'; then
      echo '  rbd 모듈 로드됨: $NODE_NAME'
    else
      echo '  rbd 모듈 로드 시도: $NODE_NAME'
      sudo modprobe rbd
      lsmod | grep -q '^rbd' && echo '  rbd 로드 성공' || echo '  ❌ rbd 로드 실패 - linux-modules-extra-aws 확인 필요'
    fi
  "
done

CURRENT_STEP="1-3"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] CephCluster CR 배포"

# OSD 수가 더 이상 늘지 않고 연속 5회 동일할 때 안정으로 판단 (최대 8분)
# useAllDevices: true 이므로 목표 수를 하드코딩하지 않음
wait_osd_running() {
  $CSSH$M1_PUB "
    PREV=0
    STABLE=0
    for i in \$(seq 1 48); do
      UP=\$(kubectl -n rook-ceph get pods -l app=rook-ceph-osd --no-headers 2>/dev/null | grep -c Running || true)
      echo \"  [대기] OSD 기동 확인 [\$i/48] Running: \$UP\"
      if [ \"\$UP\" -gt 0 ] && [ \"\$UP\" -eq \"\$PREV\" ]; then
        STABLE=\$((STABLE + 1))
        [ \"\$STABLE\" -ge 5 ] && echo \"  OSD 안정 확인 (5회 연속 \$UP 개)\" && break
      else
        STABLE=0
      fi
      PREV=\$UP
      sleep 10
    done
  "
  countdown 45 "OSD I/O 초기화 및 API server 안정화"
}

# CephCluster CR 배포 (useAllNodes: true — K8s 노드명에 무관하게 control-plane 제외 전체 적용)
$CSSH$M1_PUB "
cat <<'CREOF' | kubectl apply -f -
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: rook-ceph
  namespace: rook-ceph
spec:
  cephVersion:
    image: $CEPH_IMAGE
    allowUnsupported: false
  dataDirHostPath: /var/lib/rook
  skipUpgradeChecks: false
  mon:
    count: 3
    allowMultiplePerNode: false
  mgr:
    count: 1
    modules:
      - name: pg_autoscaler
        enabled: true
  dashboard:
    enabled: true
    ssl: false
  placement:
    all:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
  cephConfig:
    global:
      osd_pool_default_size: \"2\"
      osd_pool_default_min_size: \"1\"
  storage:
    useAllNodes: true
    useAllDevices: false
    deviceFilter: "^nvme1n1$"
CREOF
"

echo "  deviceFilter: ^nvme1n1$ — Ceph OSD 전용 디스크만 사용 (/dev/xvdb, nvme2n1=BeeGFS 제외)"
wait_osd_running

CURRENT_STEP="1-4"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph 클러스터 HEALTH_OK 대기"
$CSSH$M1_PUB "
  for i in \$(seq 1 90); do
    STATUS=\$(kubectl -n rook-ceph get cephcluster rook-ceph \
      -o jsonpath='{.status.ceph.health}' 2>/dev/null || echo 'PENDING')
    echo \"  [대기] Ceph 클러스터 상태 확인 [\$i/90]: \$STATUS\"
    [ \"\$STATUS\" = 'HEALTH_OK' ] && echo '  HEALTH_OK 달성' && break
    sleep 10
  done
  kubectl -n rook-ceph get cephcluster rook-ceph
  kubectl -n rook-ceph get pods -o wide
"

CURRENT_STEP="1-4-1"; CURRENT_TARGET="master:${MASTER_IP:-${M1_PUB:-pending}}"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] CSI Provisioner master 노드 배치"
$CSSH$M1_PUB "
cat > /tmp/csi-patch.yaml << 'PATCHEOF'
data:
  CSI_PROVISIONER_NODE_AFFINITY: node-role.kubernetes.io/control-plane=
  CSI_PROVISIONER_TOLERATIONS: '[{\"key\":\"node-role.kubernetes.io/control-plane\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}]'
PATCHEOF
  kubectl -n rook-ceph patch configmap rook-ceph-operator-config \
    --type merge --patch-file /tmp/csi-patch.yaml
  kubectl rollout restart deployment/csi-cephfsplugin-provisioner \
    deployment/csi-rbdplugin-provisioner -n rook-ceph
  kubectl -n rook-ceph rollout status deployment/csi-cephfsplugin-provisioner --timeout=180s
  kubectl -n rook-ceph rollout status deployment/csi-rbdplugin-provisioner --timeout=180s
  echo '  CSI Provisioner → master 노드 재배치 완료'
"

CURRENT_STEP="1-4-2"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] rook-ceph-tools 배포"
$CSSH$M1_PUB "kubectl apply -f https://raw.githubusercontent.com/rook/rook/$ROOK_VERSION/deploy/examples/toolbox.yaml"
echo "  [대기] rook-ceph-tools 기동 대기..."
$CSSH$M1_PUB "kubectl -n rook-ceph rollout status deploy/rook-ceph-tools --timeout=120s"


CURRENT_STEP="1-5"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] CephBlockPool + StorageClass (RBD)"
$CSSH$M1_PUB "
cat <<'EOF' | kubectl apply -f -
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: replicapool
  namespace: rook-ceph
spec:
  replicated:
    size: 2
    requireSafeReplicaSize: false
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-rbd
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  clusterID: rook-ceph
  pool: replicapool
  imageFormat: \"2\"
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-rbd-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-rbd-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
"

CURRENT_STEP="1-6"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] CephFilesystem + StorageClass (CephFS)"
$CSSH$M1_PUB "
cat <<'EOF' | kubectl apply -f -
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: labfs
  namespace: rook-ceph
spec:
  metadataPool:
    replicated:
      size: 2
  dataPools:
    - name: replicated
      replicated:
        size: 2
  preserveFilesystemOnDelete: false
  metadataServer:
    activeCount: 1
    activeStandby: false
    placement:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane
                  operator: DoesNotExist
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-cephfs
provisioner: rook-ceph.cephfs.csi.ceph.com
parameters:
  clusterID: rook-ceph
  fsName: labfs
  pool: labfs-replicated
  csi.storage.k8s.io/provisioner-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/provisioner-secret-namespace: rook-ceph
  csi.storage.k8s.io/controller-expand-secret-name: rook-csi-cephfs-provisioner
  csi.storage.k8s.io/controller-expand-secret-namespace: rook-ceph
  csi.storage.k8s.io/node-stage-secret-name: rook-csi-cephfs-node
  csi.storage.k8s.io/node-stage-secret-namespace: rook-ceph
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
"

CURRENT_STEP="1-7"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] StorageClass 확인"
kubectl get storageclass
kubectl -n rook-ceph get pods -o wide

CURRENT_STEP="1-8"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] rook-ceph 상태 확인"
kubectl -n rook-ceph get cephcluster rook-ceph \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,HEALTH:.status.ceph.health

kubectl get csidrivers

CURRENT_STEP="1-9"; CURRENT_TARGET="k8s-storage-cluster"; echo "[step=$CURRENT_STEP][target=$CURRENT_TARGET] Ceph Dashboard 접속 정보"
$CSSH$M1_PUB "
  NODE_PORT=\$(kubectl -n rook-ceph get svc rook-ceph-mgr-dashboard \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo 'NodePort 없음')
  ADMIN_PASS=\$(kubectl -n rook-ceph get secret rook-ceph-dashboard-password \
    -o jsonpath='{.data.password}' | base64 --decode)
  echo \"Dashboard NodePort : \$NODE_PORT\"
  echo \"접속 URL           : http://<worker-IP>:\$NODE_PORT\"
  echo \"Dashboard 비밀번호 : \$ADMIN_PASS\"
"

echo "Ceph 설치 완료 - StorageClass: ceph-rbd, ceph-cephfs"
echo "   다음 (BeeGFS): bash scripts/lifecycle/start_beegfs.sh"
