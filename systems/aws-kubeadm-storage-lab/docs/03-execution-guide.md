# 03. 단계별 실행 가이드

## 사전 요구사항

| 항목 | 조건 |
|------|------|
| AWS CLI | v2, 자격증명 설정 완료 |
| OpenTofu | v1.6+ |
| jq | 설치 필요 |
| SSH Key Pair | AWS에 등록, `~/.ssh/storage-lab.pem` 배치 |

> Windows 사용자: **WSL2**에서 실행. PEM 키를 WSL 홈으로 복사 후 `chmod 400`.

---

## 실행 흐름 요약

```
terraform.tfvars 수정 (key_name, worker_count)
       ↓
bash scripts/lifecycle/start_k8s.sh          ← 인프라 + K8s HA 3식 + HAProxy (약 25~30분)
       ↓
bash scripts/lifecycle/start_ceph.sh         ← rook-ceph (약 15~20분)
       ↓
bash scripts/lifecycle/start_beegfs.sh       ← BeeGFS 7.4.6 (약 10~15분)
       ↓
kubectl apply -f manifests/examples/
```

---

## Step 0: 사전 준비

```bash
ls ~/.ssh/storage-lab.pem
chmod 400 ~/.ssh/storage-lab.pem

vi opentofu/terraform.tfvars
# key_name     = "storage-lab"
# worker_count = 3
# master_count = 3   # 기본값, 생략 가능
```

---

## Step 1: 인프라 + K8s HA 구성

```bash
bash scripts/lifecycle/start_k8s.sh
```

내부 실행 순서:
1. `[0/5]` 사전 요구사항 확인
2. `[1/5]` `tofu apply` → Bastion + Master×3 + Worker×N + EBS 생성
   - BASTION_PRIVATE_IP 수집 (HAProxy endpoint)
3. `[2/5]` Bastion SSH 대기
4. `[3/5]` SSH 키 + ansible/ + manifests/ 전송
5. `[4/5]` 모든 노드 부팅 대기 (ProxyJump 확인)
6. `[5/5]` `ansible-playbook k8s.yml --extra-vars "control_plane_endpoint=BASTION_PRIVATE_IP"`:
   - **[Play 0.5] Worker 커널 6.8 고정** — 6.12+ 감지 시 6.8 설치 → GRUB 변경 → reboot
   - **[Play 0.6] 커널 검증 게이트** — 6.8 아니면 전체 중단
   - **HAProxy 설정** (Bastion, master×3 backend 자동 생성)
   - node_base → hci_node → cluster_setup → k8s_common
   - **master-1 kubeadm init** (`--control-plane-endpoint BASTION_PRIVATE_IP:6443 --upload-certs`)
   - CNI (Flannel VXLAN)
   - **master-2/3 control-plane join** (serial: 1)
   - worker join
   - addons (Metrics Server, Dashboard, Prometheus, Grafana, MetalLB)
   - Bastion /etc/hosts + SSH config 등록

완료 후 확인 (Bastion에서):
```bash
export KUBECONFIG=~/.kube/config-k8s-storage-lab
kubectl get nodes -o wide
# master-1/2/3, worker-1~N  모두 Ready

# HAProxy stats
curl http://localhost:9000/stats | grep -i backend
```

---

## Step 2: rook-ceph 구성

```bash
bash scripts/lifecycle/start_ceph.sh
```

1. Helm 설치 (master-1)
2. rook-ceph operator 배포 + 안정화 대기(60s)
3. rbd 커널 모듈 확인
4. CephCluster CR 배포 (`deviceFilter: ^nvme[12]n1$` — nvme3n1 BeeGFS 전용 명시적 제외)
5. OSD 안정화 대기 (5회 연속 동일 수)
6. HEALTH_OK 대기
7. CSI Provisioner → master 노드 재배치 (worker CPU 여유 확보)
8. StorageClass 생성 (ceph-rbd, ceph-cephfs)

완료 후 확인:
```bash
kubectl -n rook-ceph get pods -o wide
kubectl get storageclass
# ceph-rbd, ceph-cephfs 확인
```

---

## Step 3: BeeGFS 구성

```bash
bash scripts/lifecycle/start_beegfs.sh
```

1. ansible/manifests 재전송
2. `ansible-playbook beegfs.yml`:
   - BeeGFS 7.4.6 APT 저장소 + 패키지 설치 (noble 공식 지원)
   - Worker: 커널 모듈 빌드 (`/opt/beegfs/src/client/client_module_7/build/`) + modprobe
   - Master: `/mnt/beegfs/mgmtd`, `/mnt/beegfs/meta` 디렉토리 생성
   - Worker: `/dev/nvme3n1` XFS 포맷 → `/mnt/beegfs/storage` 마운트
   - 설정 파일 생성 (`sysMgmtdHost`, `connDisableAuthentication=true`)
   - K8s 매니페스트 적용 (namespace, mgmtd/meta Deployment, storaged DaemonSet, StorageClass)
   - CSI Driver: git clone + kustomize 배포 (`kubectl apply -k`)

완료 후 확인:
```bash
kubectl -n beegfs-system get pods -o wide
kubectl get storageclass
# beegfs-scratch 확인
```

---

## Step 4: PVC 테스트

```bash
kubectl apply -f manifests/examples/test-pvc-rbd.yaml
kubectl apply -f manifests/examples/test-pvc-cephfs.yaml
kubectl apply -f manifests/examples/test-pvc-beegfs.yaml
kubectl get pvc
```

---

## Worker 스케일 아웃/인

```bash
# Worker 1대 추가 (K8s + Ceph + BeeGFS 자동 구성)
bash scripts/lifecycle/worker_add.sh

# Worker 1대 제거 (안전 drain → Ceph OSD purge → delete → tofu 축소)
bash scripts/lifecycle/worker_remove.sh
```

---

## 재설치

```bash
# rook-ceph 재설치
bash scripts/lifecycle/destroy_ceph.sh && bash scripts/lifecycle/start_ceph.sh

# BeeGFS 재설치
bash scripts/lifecycle/destroy_beegfs.sh && bash scripts/lifecycle/start_beegfs.sh

# 전체 삭제
bash scripts/lifecycle/destroy_k8s.sh
```

---

## EC2 중지/재시작 (비용 절감)

```bash
bash scripts/lifecycle/pause.sh    # OSD 스냅샷 후 EC2 중지
bash scripts/lifecycle/resume.sh   # EC2 재시작 + 최신 playbook 재전송
```

---

## 예상 비용 (ap-northeast-2, 실행 중 기준)

| 리소스 | 수량 | 시간당 |
|--------|------|--------|
| t3.small (bastion × 1) | 1 | ~$0.026 |
| t3.large (master × 3) | 3 | ~$0.250 |
| m5.large (worker × 3) | 3 | ~$0.288 |
| EBS gp2 20GB (루트 × 7) | 7 | 미미 |
| EBS gp2 5GB (Ceph OSD × 6) | 6 | 미미 |
| EBS gp2 8GB (BeeGFS × 3) | 3 | 미미 |
| **합계** | | **~$0.56/h** |

> 미사용 시 `bash scripts/lifecycle/pause.sh` 또는 `bash scripts/lifecycle/destroy_k8s.sh`.
