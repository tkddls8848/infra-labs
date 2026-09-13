# 02. 셸 스크립트 구조

## 진입점 스크립트 (프로젝트 루트)

| 파일 | 역할 |
|------|------|
| `start_k8s.sh` | 인프라 생성 + K8s HA 클러스터 구성 (HAProxy 포함) |
| `start_ceph.sh` | rook-ceph 설치 |
| `start_beegfs.sh` | BeeGFS 설치 (패키지 + K8s 데몬 배포) |
| `worker_add.sh` | HCI Worker 노드 1대 추가 (스케일 아웃) |
| `worker_remove.sh` | HCI Worker 노드 1대 제거 (스케일 인) |
| `destroy_beegfs.sh` | BeeGFS 삭제 (beegfs-system 네임스페이스 + 패키지) |
| `destroy_ceph.sh` | rook-ceph만 삭제 + OSD 디스크 초기화 |
| `destroy_k8s.sh` | 전체 AWS 리소스 삭제 (tofu destroy) |
| `pause.sh` | EC2 중지 (비용 절감, OSD 스냅샷 포함) |
| `resume.sh` | EC2 재시작 + Ansible/Manifest 재전송 |

---

## start_k8s.sh 흐름

```
[0/5] 사전 요구사항 확인 (tofu, aws, ssh, scp, SSH 키)
[1/5] tofu apply (인프라 생성)
       → BASTION_IP, BASTION_PRIVATE_IP 수집
[2/5] Bastion SSH 대기
[3/5] SSH 키 + Ansible Playbook 전송
[4/5] 나머지 노드 부팅 대기 (master×3 + worker×N)
[5/5] Ansible k8s.yml 실행
       --extra-vars "control_plane_endpoint=BASTION_PRIVATE_IP"
```

`control_plane_endpoint`는 Bastion의 **private IP**:6443 (HAProxy).
K8s 노드들이 VPC 내부에서 HAProxy로 접근합니다.

---

## ansible/roles/hci_node

Worker 전용 추가 설정 (Ceph OSD + BeeGFS storaged 담당 노드).
`k8s.yml` 플레이 3번에서 `hosts: worker` 대상으로 실행.

| 항목 | 내용 |
|------|------|
| 패키지 | `lvm2`, `chrony`, `linux-modules-extra-aws` |
| Ceph 모듈 | `rbd`, `ceph` — `/etc/modules-load.d/k8s.conf` 등록 + `modprobe` |
| chrony | systemd 활성화 |

---

## scripts/system/ceph_install.sh

1. **Helm 설치** (master-1)
2. **rook-ceph Helm repo** + namespace 생성
3. **rook-ceph Operator 배포** → 60초 CRD watch 안정화 대기
4. **워커 rbd 모듈 로드 확인**
5. **CephCluster CR 배포**
   - `useAllDevices: true` (BeeGFS 디스크 `/dev/nvme3n1`은 XFS 포맷 완료 상태라 자동 제외)
   - `osd_pool_default_size: "2"`, `osd_pool_default_min_size: "1"`
   - placement: control-plane 제외 (OSD는 worker 전용)
6. **Ceph HEALTH_OK 대기**
7. **CSI Provisioner → master 노드 배치**
   - `rook-ceph-operator-config` ConfigMap 패치
     - `CSI_PROVISIONER_NODE_AFFINITY`: `node-role.kubernetes.io/control-plane=`
     - `CSI_PROVISIONER_TOLERATIONS`: control-plane NoSchedule 테인트 허용
   - csi-cephfsplugin-provisioner, csi-rbdplugin-provisioner rollout restart
   - worker CPU 여유 확보 (HCI 환경 — master CPU가 여유 있음)
8. **rook-ceph-tools toolbox 배포**
9. **CephBlockPool + StorageClass (ceph-rbd, RWO)**
10. **CephFilesystem + StorageClass (ceph-cephfs, RWX)**

---

## worker_add.sh 흐름

```
[0/4] 사전 요구사항 확인
[1/4] tofu apply -var="worker_count=N+1"  (EC2 + EBS 추가)
[2/4] 새 Worker 부팅 대기
[3/4] Ansible: common/worker/cluster_setup/k8s_common/worker 실행
[4/4] Ansible: beegfs.yml 실행 (BeeGFS storaged 추가)
```

Ceph OSD는 rook-ceph operator가 새 노드의 빈 디스크를 자동 감지합니다.

---

## worker_remove.sh 흐름

```
[0/5] 사전 요구사항 확인 (최소 1대 유지 검증)
[1/5] BeeGFS storaged 상태 확인
[2/5] kubectl drain (eviction + daemonset 무시)
[3/5] Ceph OSD 안전 제거 (out → down → purge, rebalancing 60초 대기)
[4/5] kubectl delete node
[5/5] tofu apply -var="worker_count=N-1"  (EC2 + EBS 제거)
```

---

## destroy_ceph.sh 흐름

```
[1/3] 인프라 정보 수집 (bastion IP, worker IPs)
[2/3] .env 생성 + kubectl 설치
[3/3] rook-ceph 삭제 (bastion 원격 실행)
  [1/5] API 서버 연결 확인 → 미응답 시 [2~4] 스킵
  [2/5] StorageClass 삭제
  [3/5] CephFilesystem / BlockPool 삭제
  [4/5] CephCluster 삭제 (finalizer 제거) + Helm uninstall + CRD 삭제
  [5/5] Worker OSD 디스크 초기화 (nvme1n1, nvme2n1만 — nvme3n1은 BeeGFS 유지)
```

---

## destroy_k8s.sh

```bash
source scripts/.env          # IP 미리 수집
tofu destroy -auto-approve
rm -f scripts/.env ~/.kube/config-k8s-storage-lab
ssh-keygen -R <각 노드 IP>   # known_hosts 정리
```

---

## destroy_beegfs.sh

```
[1/3] 인프라 정보 수집 (bastion IP)
[2/3] .env 로드 + kubectl 설정
[3/3] K8s 리소스 삭제 (bastion 원격 실행)
  [1/3] beegfs-system 네임스페이스 삭제 (StorageClass 포함)
  [2/3] BeeGFS CSI 드라이버 삭제
  [3/3] Worker 호스트 패키지 제거 (beegfs-storage, beegfs-client 등)
```
