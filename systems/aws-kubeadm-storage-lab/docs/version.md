# 버전 정보

인프라 구성에 적용된 모든 구성요소의 버전 정보입니다.

---

## 1. IaC 및 클라우드 인프라

위치: `opentofu/main.tf`
- OpenTofu: >= 1.6.0
- AWS Provider: ~> 5.0 (hashicorp/aws)
- OS: Ubuntu 24.04 LTS (Noble Numbat)
  - AMI 필터: ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*
  - Owner: 099720109477 (Canonical)

---

## 2. EC2 인스턴스 타입

위치: `opentofu/modules/ec2/main.tf`

| 노드 | 타입 | vCPU | RAM | 역할 |
|------|------|------|-----|------|
| Bastion | t3.small | 2 | 2GB | Ansible 제어 노드, HAProxy |
| Master | t3.large | 2 | 8GB | K8s HA control plane (etcd ×3) + BeeGFS mgmtd/meta + Ceph CSI Provisioner |
| Worker | m5.large | 2 | 8GB | HCI (K8s + Ceph OSD + BeeGFS storaged) |

---

## 3. 스토리지 구성

- EBS 볼륨 타입: gp2
- Root 볼륨: 20GB (모든 인스턴스 공통)
- Ceph OSD: 워커당 1개, 5GB (`/dev/xvdb` → nvme1n1)
- BeeGFS 스토리지: 워커당 1개, 8GB (`/dev/xvdd` → nvme2n1, XFS 포맷)

---

## 4. Kubernetes 스택

위치: `ansible/inventory/group_vars/all.yml`
- Kubernetes: 1.31
- kubeadm API: kubeadm.k8s.io/v1beta4
- kube-proxy:
  - 모드: nftables
  - API: kubeproxy.config.k8s.io/v1alpha1
- CNI: Flannel v0.26.1 (버전 고정, K8s 1.28+ 지원)
  - 모드: VXLAN
  - 포트: UDP 8472
  - POD CIDR: 10.244.0.0/16
- kubectl / kubelet / kubeadm: 1.31
- Worker 커널: 6.8.0-aws 고정 (BeeGFS 7.4.6 최대 지원 커널 6.11, k8s.yml Play 0.5에서 자동 고정)

---

## 5. Ceph 스토리지 스택

위치: `scripts/system/ceph_install.sh`
- Rook-Ceph Operator: v1.16.6
  - Helm repository: https://charts.rook.io/release
  - Chart: rook-release/rook-ceph
- Ceph: v19.2.3
  - Image: quay.io/ceph/ceph:v19.2.3
- Ceph API: ceph.rook.io/v1
- 복제 설정:
  - osd_pool_default_size: 2
  - osd_pool_default_min_size: 1
  - Block Pool / CephFS replicated size: 2
- MON: 3개 (quorum)
- MGR: 1개 (pg_autoscaler 활성화)
- Dashboard: 활성화 (SSL 비활성화)
- MDS: activeCount=1, activeStandby=false
- OSD 배치: worker 노드만
- 디바이스 선택: `deviceFilter: ^nvme1n1$` (nvme2n1 BeeGFS 전용 제외)

---

## 6. BeeGFS 스토리지 스택

위치: `ansible/roles/beegfs_prep/`, `manifests/beegfs/`
- BeeGFS: 7.4.6 (Ubuntu 24.04 Noble 공식 지원 — 7.4.6부터)
  - APT 저장소: https://www.beegfs.io/release/beegfs_7.4.6/
  - 최대 지원 커널: 6.11 (worker 커널 6.8로 고정 필수)
- 구성요소:
  - mgmtd: Deployment 1개 (master-1, port 8008)
  - meta: Deployment 1개 (master-1, port 8005)
  - storaged: DaemonSet (all workers, port 8003)
  - helperd: systemd (all workers, CSI 의존, port 8004, `connDisableAuthentication=true`)
- 데몬 실행 방식: K8s 컨테이너 (`ubuntu:24.04` + `chroot /host`)
- 커널 모듈 빌드: 자체 빌드 시스템 (`/opt/beegfs/src/client/client_module_7/build/`, DKMS 미사용)
- 스토리지 디렉토리: `/mnt/beegfs/storage` (XFS, 8GB EBS)
- CSI Driver: beegfs.csi.netapp.com v1.8.0 (ThinkParQ/NetApp)
  - StorageClass mountOptions: 없음 (rsize/wsize는 BeeGFS 미지원)
- 모니터링: Prometheus exporter (`manifests/beegfs/05-monitoring.yaml`)
  - beegfs-ctl 기반 커스텀 exporter (port 9100)
  - ServiceMonitor → kube-prometheus-stack 자동 scrape
  - Grafana 대시보드 자동 import (`06-grafana-dashboard.yaml`)

---

## 7. 자동화 및 관리 도구

위치: `opentofu/modules/ec2/user_data/bastion.sh`
- Python: 3.12.x (Ubuntu 24.04 기본)
  - 패키지: python3, python3-pip, pipx
- Ansible: ansible-core 2.20.x (pipx 최신 stable)
  - 설치: pipx install ansible-core
  - Python 요구사항: >= 3.12
  - 추가 의존성: boto3, botocore (pipx inject)
- Ansible Collections:
  - amazon.aws
  - ansible.posix
  - community.general (>= 12.0.0)
  - community.crypto
- Ansible 설정 (ansible.cfg):
  - stdout_callback: ansible.builtin.default
  - result_format: yaml
- HAProxy: 최신 (apt, Bastion에 설치)
  - K8s API 포트: 6443
  - Stats 포트: 9000
- Helm: v3+ (최신)
  - 설치: https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
- jq: 최신

---

## 8. Addons (K8s 클러스터)

위치: `ansible/roles/addons/`
- Metrics Server: 최신 (Helm)
- Kubernetes Dashboard: 최신 (Helm)
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager + node-exporter)
  - Prometheus retention: 7d
  - Prometheus memory limit: 1Gi
  - Grafana NodePort: 30300
  - Prometheus NodePort: 30090
  - Alertmanager NodePort: 30093
- MetalLB: v0.14.9
  - 모드: L2
  - IP 대역: 10.0.1.200-10.0.1.220

---

## 9. StorageClass

| StorageClass | Provisioner | Access Mode | 비고 |
|---|---|---|---|
| ceph-rbd | rook-ceph.rbd.csi.ceph.com | RWO | imageFormat:2, layering |
| ceph-cephfs | rook-ceph.cephfs.csi.ceph.com | RWX | Filesystem: labfs |
| beegfs-scratch | beegfs.csi.netapp.com | RWX | volDirBasePath: /k8s/dynamic |

---

## 10. 시스템 패키지 (Ubuntu 24.04)

- Container Runtime: containerd.io 1.7.22-1 (버전 고정 + dpkg hold)
- 공통 패키지: curl, ca-certificates, gnupg, git, nfs-common, open-iscsi, conntrack, socat, nftables
- Worker 추가 패키지: lvm2, chrony, linux-modules-extra-aws, xfsprogs, nvme-cli
- BeeGFS 의존성: beegfs-client, beegfs-helperd, beegfs-utils, xfsprogs, dkms

---

## 11. 네트워크 구성

- VPC CIDR: 10.0.0.0/16
- Subnet:
  - Bastion: 10.0.0.0/24 (public)
  - K8s (master + worker): 10.0.1.0/24 (private)
- 보안 그룹:
  - Bastion SG: SSH(22), HAProxy(6443), Stats(9000)
  - K8s HCI SG: K8s + Ceph + Flannel + BeeGFS(8003-8008) + VPC 내부 전체 허용

---

## 12. 커널 모듈

자동 로드 설정 (modules-load.d):
- 공통: overlay, br_netfilter, nf_tables, nft_masq
- Worker 추가: rbd, ceph

---

## 호환성 참고

| 조합 | 버전 |
|------|------|
| Kubernetes ↔ Rook | K8s 1.31 ↔ Rook v1.16.6 ✓ |
| Rook ↔ Ceph | Rook v1.16.6 ↔ Ceph v19.2.3 ✓ |
| Ubuntu ↔ BeeGFS | Ubuntu 24.04 ↔ BeeGFS 7.4 ✓ (커널 6.8 고정 필수) |
| K8s ↔ kube-proxy | K8s 1.31 ↔ nftables 모드 stable ✓ |
