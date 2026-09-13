# 01. OpenTofu 인프라 코드

## 아키텍처

| 역할 | 수 | 인스턴스 | 서브넷 |
|------|----|----------|--------|
| Bastion | 1 | t3.small | 10.0.0.0/24 (public) |
| K8s Master (HA) | master_count (기본 3) | t3.medium | 10.0.1.0/24 (private) |
| K8s Worker (HCI) | worker_count | m5.large | 10.0.1.0/24 (private) |

> Worker는 K8s 컴퓨트 + Ceph OSD×2 + BeeGFS storaged를 동시에 담당하는 HCI 구조.
> Master는 3식 HA 구성으로 etcd quorum 유지, HAProxy(Bastion)가 K8s API를 로드밸런싱.

---

## modules/security_group

SG 2개: Bastion / K8s HCI.

- **Bastion SG**: 외부 SSH(22), HAProxy K8s API(6443), HAProxy stats(9000)
- **K8s SG**: VPC 내부 전체 허용 + K8s/Ceph/Flannel/BeeGFS 포트

BeeGFS 포트:
- mgmtd: 8008/tcp
- meta: 8005/tcp
- storage: 8003/tcp
- client/helperd: 8004/tcp

---

## modules/ec2

```hcl
# Bastion: 1대 (Ansible 제어 노드 + HAProxy)
resource "aws_instance" "bastion" {
  instance_type = "t3.small"
  subnet_id     = var.subnet_bastion_id
}

# Master: master_count대 (기본 3, HA)
resource "aws_instance" "master" {
  count         = var.master_count
  instance_type = "t3.medium"
  subnet_id     = var.subnet_k8s_id
}

# Worker (HCI): worker_count대
resource "aws_instance" "worker" {
  count         = var.worker_count
  instance_type = "m5.large"
  subnet_id     = var.subnet_k8s_id
}
```

### 인스턴스 타입 선정 근거

| 노드 | 타입 | 이유 |
|------|------|------|
| Bastion | t3.small | HAProxy + Ansible, 상시 부하 낮음 |
| Master | t3.medium (4GB) | etcd 3노드 quorum + Ceph CSI Provisioner 배치 — worker CPU 여유 확보 |
| Worker | m5.large (8GB) | Ceph OSD 지속 I/O → t3 버스트 크레딧 고갈 위험 |

---

## modules/ebs

```hcl
# Worker BeeGFS 스토리지: worker_count × 1개 (8GB gp2, /dev/xvdd → nvme3n1)
resource "aws_ebs_volume" "beegfs_storage" { count = var.worker_count; size = 8 }

# Worker Ceph OSD: worker_count × 1개 (5GB gp2)
resource "aws_ebs_volume" "ceph_osd" { count = var.worker_count; size = 5 }  # /dev/xvdb → nvme1n1
```

**Nitro 인스턴스 장치명 매핑:**
- `/dev/xvdb` → `/dev/nvme1n1` (Ceph OSD)
- `/dev/xvdd` → `/dev/nvme2n1` (BeeGFS storaged, XFS 포맷)

---

## user_data 스크립트

| 파일 | 대상 | 주요 내용 |
|------|------|-----------|
| `bastion.sh` | Bastion | Python, pipx, ansible-core, galaxy collections 설치 |
| `common.sh` | Master | swap off, sysctl, containerd, 커널 모듈 |
| `worker.sh` | Worker | common + lvm2, chrony, linux-modules-extra-aws, rbd/ceph 모듈 |

---

## variables.tf 주요 변수

| 변수 | 기본값 | 설명 |
|------|--------|------|
| `aws_region` | ap-northeast-2 | AWS 리전 |
| `master_count` | 3 | Master HA 노드 수 (etcd quorum) |
| `worker_count` | - | Worker HCI 노드 수 (tfvars 필수) |
| `key_name` | - | EC2 Key Pair 이름 (tfvars 필수) |
