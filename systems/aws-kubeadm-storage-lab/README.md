# K8s Storage Lab

AWS 위에 Kubernetes + Ceph(rook-ceph) + BeeGFS 스토리지 통합 실습 환경을 자동 구성하는 프로젝트입니다.

## 아키텍처 개요

```
Internet
    │
    ▼
┌──────────────────────────────────────────┐
│  Bastion  t3.small  10.0.0.0/24 (public) │
│  - Ansible 제어 노드                      │
│  - HAProxy :6443 → 3× Master API         │
│  - HAProxy stats :9000                   │
└──────────┬───────────────────────────────┘
           │ VPC private  10.0.1.0/24
    ┌──────┴──────┐
    ▼             ▼
master-1/2/3   worker-1/2/3 ...
t3.large×3     m5.large×N
etcd HA        K8s 워크로드
K8s API        Ceph OSD×1 (5GB)
BeeGFS         BeeGFS storaged (8GB)
mgmtd/meta
Ceph CSI Provisioner
```

| 역할 | 수 | 인스턴스 | 서브넷 | 주요 구성 |
|------|----|----------|--------|-----------|
| Bastion | 1 | t3.small | 10.0.0.0/24 (public) | Ansible, HAProxy(6443/9000) |
| K8s Master (HA) | 3 | t3.large | 10.0.1.0/24 (private) | etcd, kubeadm, BeeGFS mgmtd/meta, Ceph CSI Provisioner |
| K8s Worker (HCI) | N | m5.large | 10.0.1.0/24 (private) | K8s 워크로드 + Ceph OSD×1 + BeeGFS storaged (커널 6.8 고정) |

**EBS 구성 (워커당):** Ceph OSD 5GB + BeeGFS 8GB

## 접근 구조

```
[운영자]
  │
  ├─ ssh :22      → Bastion (public IP)
  │                    └─ ssh → Master / Worker (private IP)
  │
  └─ kubectl :6443 → Bastion HAProxy → master-1/2/3:6443
                      (health check, 장애 master 자동 제외)
```

## 스토리지 구성

| StorageClass | 백엔드 | Access Mode | 용도 |
|-------------|--------|-------------|------|
| `ceph-rbd` | Ceph RBD (rook-ceph) | RWO | 블록 스토리지 (DB, 단일 Pod) |
| `ceph-cephfs` | CephFS (rook-ceph) | RWX | 파일 공유 (다중 Pod 동시 접근) |
| `beegfs-scratch` | BeeGFS 7.4.6 CSI | RWX | 고성능 병렬 파일시스템 |

> **BeeGFS 8 업그레이드 불가**: BeeGFS 8.x는 RHEL/CentOS RPM만 제공. Ubuntu deb 패키지 미제공(404 확인).
> Ubuntu 기반 이 랩은 BeeGFS 7.4.6이 최신 사용 가능 버전입니다.

## 디렉토리 구조

```
k8s-storage-lab/
├── opentofu/                     # IaC (OpenTofu)
│   ├── main.tf
│   ├── variables.tf              # master_count(기본 3), worker_count
│   ├── outputs.tf
│   └── modules/
│       ├── vpc/                  # VPC, 서브넷(bastion/k8s), IGW, NAT GW
│       ├── security_group/       # Bastion SG / K8s HCI SG
│       ├── ec2/                  # EC2 인스턴스 + user_data
│       └── ebs/                  # EBS (Ceph OSD×1 5GB + BeeGFS 8GB, 워커당)
├── packer/                       # Packer AMI 빌드 (선택)
│   ├── worker.pkr.hcl            # Worker: containerd + kubeadm + BeeGFS 7.4.6 + 커널 6.8
│   ├── master.pkr.hcl            # Master: containerd + kubeadm
│   ├── bastion.pkr.hcl           # Bastion: ansible-core + boto3
│   ├── common.pkr.hcl            # 공통 변수 + plugin 선언
│   ├── variables.pkrvars.hcl     # AMI ID, Key Pair 등
│   └── scripts/
│       ├── base.sh               # 공통 패키지 + 커널 모듈 + sysctl
│       ├── worker_kernel.sh      # 커널 6.8 설치 + 5단계 고정 + GRUB 설정
│       ├── worker.sh             # containerd + kubeadm + BeeGFS 모듈 빌드 + lvm2/chrony/linux-modules-extra-aws + Ceph 모듈 등록
│       ├── master.sh             # containerd + kubeadm
│       └── bastion.sh            # ansible-core + boto3 + collections
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   ├── aws_ec2.yml           # AWS EC2 동적 인벤토리
│   │   └── group_vars/
│   │       ├── all.yml           # 공통 변수
│   │       └── worker.yml
│   ├── playbooks/
│   │   ├── k8s.yml               # K8s HA 클러스터 구성 (HAProxy 포함)
│   │   └── beegfs.yml            # BeeGFS 설치 + K8s 매니페스트 적용
│   └── roles/
│       ├── node_base/            # OS 공통 (swap, sysctl, containerd, 커널 모듈)
│       ├── hci_node/             # Worker 추가 패키지 (lvm2, chrony, linux-modules-extra-aws) + Ceph 모듈 로드 — Packer AMI 사용 시 ami_base 태그로 스킵
│       ├── cluster_setup/        # /etc/hosts, SSH key 배포
│       ├── k8s_common/           # kubelet, kubeadm, kubectl 설치
│       ├── control_plane/        # kubeadm init (master-1), --upload-certs
│       ├── control_plane_join/   # master-2/3 control-plane join
│       ├── worker/               # worker K8s join + label
│       ├── cni/                  # Flannel VXLAN
│       ├── addons/               # Metrics Server, Dashboard, Prometheus, Grafana, MetalLB
│       ├── haproxy/              # HAProxy 설치 (Bastion, k8s.yml에서 자동 실행)
│       └── beegfs_prep/          # BeeGFS 패키지 설치 + 커널 고정 + 디스크 포맷/마운트
├── manifests/
│   ├── beegfs/                   # BeeGFS 데몬 K8s 매니페스트
│   │   ├── 00-namespace.yaml
│   │   ├── 01-mgmtd.yaml         # mgmtd Deployment (master-1)
│   │   ├── 02-meta.yaml          # meta Deployment (master-1)
│   │   ├── 03-storage.yaml       # storaged DaemonSet (workers)
│   │   ├── 04-storageclass.yaml  # beegfs-scratch StorageClass
│   │   ├── 05-monitoring.yaml    # beegfs-exporter (python:3.12-slim, Prometheus)
│   │   └── 06-grafana-dashboard.yaml  # Grafana 대시보드 자동 import
│   ├── examples/                 # StorageClass별 PVC 테스트 YAML
│   └── networking/               # MetalLB + nginx LoadBalancer 예시
└── scripts/
    ├── lifecycle/                # 생성, 재설치, 중지/재시작, 삭제 진입점
    │   ├── start_k8s.sh
    │   ├── start_ceph.sh
    │   ├── start_beegfs.sh
    │   ├── destroy_k8s.sh
    │   ├── destroy_ceph.sh
    │   ├── destroy_beegfs.sh
    │   ├── worker_add.sh
    │   ├── worker_remove.sh
    │   ├── pause.sh
    │   └── resume.sh
    ├── provision/
    │   ├── 00_build_ami.sh       # Packer AMI 빌드 진입점
    │   └── check_resources.sh    # 노드 자원 현황 수집
    └── system/
        ├── ceph_install.sh       # rook-ceph operator + StorageClass
        └── fix_beegfs_storage_conf.sh # BeeGFS 스토리지 설정 수정
```

## 사전 요구사항

| 항목 | 조건 |
|------|------|
| AWS CLI | v2, 자격증명 설정 완료 |
| OpenTofu | v1.6+ |
| jq | 설치 필요 |
| SSH Key Pair | AWS에 등록, `~/.ssh/storage-lab.pem` 배치 |

> **Windows 사용자:** 모든 스크립트는 Linux Bash 환경 전제. **WSL2에서 실행**하세요.
> ```bash
> cd /mnt/c/Users/<user>/orca/remote_coding/systems/aws-kubeadm-storage-lab
> cp /mnt/c/path/to/storage-lab.pem ~/.ssh/ && chmod 400 ~/.ssh/storage-lab.pem
> ```

## 빠른 시작

```bash
# 1. tfvars 확인 (master_count 기본값 3)
vi opentofu/terraform.tfvars
# key_name     = "storage-lab"
# worker_count = 3

# 2. 인프라 + K8s HA 클러스터 구성
bash scripts/lifecycle/start_k8s.sh
# → OpenTofu: VPC/EC2/EBS 생성
# → Ansible: HAProxy(Bastion) + master-1 init + master-2/3 join + worker join + addons

# 3. rook-ceph 구성
bash scripts/lifecycle/start_ceph.sh

# 4. BeeGFS 구성
bash scripts/lifecycle/start_beegfs.sh

# 5. PVC 테스트
kubectl apply -f manifests/examples/

# Worker 스케일 아웃 (1대 추가)
bash scripts/lifecycle/worker_add.sh

# Worker 스케일 인 (마지막 1대 제거)
bash scripts/lifecycle/worker_remove.sh

# rook-ceph 재설치
bash scripts/lifecycle/destroy_ceph.sh && bash scripts/lifecycle/start_ceph.sh

# BeeGFS 재설치
bash scripts/lifecycle/destroy_beegfs.sh && bash scripts/lifecycle/start_beegfs.sh

# 전체 삭제
bash scripts/lifecycle/destroy_k8s.sh
```

## Packer AMI 빌드 (선택)

사전 빌드된 AMI를 사용하면 Worker 커널 다운그레이드 + BeeGFS 모듈 빌드 시간을 단축할 수 있습니다.

```bash
cd packer

# Worker AMI만 빌드 (커널 6.8 고정 + BeeGFS 7.4.6 모듈 사전 빌드)
packer build -only="amazon-ebs.worker" -var-file=variables.pkrvars.hcl .

# 전체 빌드
packer build -var-file=variables.pkrvars.hcl .
```

빌드 완료 후 `opentofu/terraform.tfvars`에 AMI ID 반영:

```hcl
ami_worker  = "ami-0xxxxxxxxxxxxxxxxx"
ami_master  = "ami-0yyyyyyyyyyyyyyyyy"
ami_bastion = "ami-0zzzzzzzzzzzzzzzzz"
```

Packer AMI 사용 시 패키지 설치 단계를 건너뜁니다:

```bash
USE_PACKER_AMI=true bash scripts/lifecycle/start_k8s.sh
```

**Worker AMI 사전 포함 항목:**

| 항목 | 내용 |
|------|------|
| 커널 | 6.8.0-aws 고정 (5단계 보호) |
| containerd | 1.7.22-1 |
| K8s 바이너리 | kubeadm, kubelet, kubectl 1.31 |
| BeeGFS 패키지 | beegfs-storage, beegfs-client, beegfs-helperd, beegfs-utils 7.4.6 |
| BeeGFS 커널 모듈 | beegfs.ko 사전 빌드 + 자동 로드 등록 |
| HCI 패키지 | lvm2, chrony, linux-modules-extra-aws, linux-headers-aws |
| Ceph 커널 모듈 | rbd, ceph → `/etc/modules-load.d/k8s.conf` 등록 |

> Ansible `hci_node` 롤의 패키지 설치/chrony 활성화/modules-load.d 등록 태스크는
> `ami_base` 태그로 묶여 있어 `USE_PACKER_AMI=true` 시 자동 스킵됩니다.

## HAProxy 리버스 프록시

Bastion의 HAProxy가 K8s API 서버(6443)를 3개 Master로 load balance합니다.

- **frontend k8s_api `:6443`** → **backend k8s_masters** (roundrobin, health check)
- Master 장애 시 자동 제외, 복구 시 자동 재포함
- **stats 페이지:** `http://BASTION_IP:9000/stats` (admin/admin)

설정은 `ansible/roles/haproxy/templates/haproxy.cfg.j2`에서 동적으로 생성됩니다.

## Worker 스케일 아웃/인

```bash
# Worker 추가 (K8s + Ceph OSD + BeeGFS 자동 구성)
bash scripts/lifecycle/worker_add.sh

# Worker 제거 (drain → Ceph OSD 안전 제거 → K8s delete → tofu)
bash scripts/lifecycle/worker_remove.sh
```

Ceph는 `deviceFilter: ^nvme1n1$`로 OSD 디스크를 감지합니다 (nvme2n1 BeeGFS 제외).

## 주요 설계 결정

| 항목 | 선택 | 이유 |
|------|------|------|
| OS | Ubuntu 24.04 (Noble) | BeeGFS 7.4.6 공식 deb 지원 (BeeGFS 8은 Ubuntu 패키지 미제공) |
| K8s 버전 | 1.31 | stable, nftables 모드 지원 |
| Master HA | 3식 (etcd quorum) | 1대 장애 허용, HAProxy 자동 failover |
| Master 타입 | t3.large (8GB) | etcd 3노드 quorum + BeeGFS mgmtd/meta + Ceph CSI Provisioner — 실측 메모리 96%+ (4GB 부족) |
| Worker 타입 | m5.large (8GB) | Ceph OSD 지속 I/O → t3 버스트 크레딧 고갈 위험 |
| kube-proxy 모드 | nftables | Ubuntu 24.04 환경, Flannel iptables lock 경합 방지 |
| Worker 커널 | 6.8.0-aws 고정 (5단계) | BeeGFS 7.4.6 최대 지원 커널 6.11 — 6.12+ 감지 시 자동 다운그레이드 후 K8s 설치 진행 |
| 커널 고정 메커니즘 | APT preferences + apt-mark hold + 구커널 제거 + GRUB savedefault 비활성화 + unattended-upgrades 차단 | 5단계 조합으로 자동 업그레이드 완전 차단 |
| containerd | 1.7.22-1 고정 + hold | K8s 1.31 호환 검증, 자동 업그레이드 방지 |
| CNI | Flannel v0.26.1 VXLAN | 버전 고정, K8s 1.28+ 지원 확인 |
| Ceph 배포 | rook-ceph operator | HCI 환경 K8s 단일 제어면, CSI 자동 설치 |
| Ceph 디바이스 | `deviceFilter: ^nvme[12]n1$` | BeeGFS 전용 nvme3n1 경합 방지 (실행 순서 무관) |
| BeeGFS 커널 모듈 | 자체 빌드 시스템 | BeeGFS 7.x는 DKMS 미사용 — `/opt/beegfs/src/client/client_module_7/build/` |
| BeeGFS 배포 | K8s 컨테이너 (DaemonSet/Deployment) | chroot 방식으로 호스트 바이너리 실행 (`/opt/beegfs/sbin/`) |
| Ceph CSI Provisioner | master 노드 배치 | worker CPU 여유 확보 (HCI 환경) |
| BeeGFS 디스크 | 8GB gp2 EBS (`/dev/xvdd` → nvme2n1) | Ceph OSD와 디바이스 분리, XFS 포맷 |
| HAProxy | Bastion Ansible 자동 구성 | master_count 변경 시 자동 반영 |

## 버전

| 항목 | 버전 |
|------|------|
| OS | Ubuntu 24.04 LTS (Noble) |
| Kernel (Worker) | 6.8.0-aws (고정) |
| Kubernetes | 1.31 |
| Containerd | 1.7.22-1 |
| BeeGFS | 7.4.6 |
| Ceph | Squid (rook-ceph, 최신) |
| Flannel CNI | v0.26.1 |
