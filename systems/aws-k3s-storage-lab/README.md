# k3s-storage-lab

k3s(프론트) + cephadm/BeeGFS 8(백엔드) 분리 구성 기능검증 환경.
EC2 2대, ~$20/월 (주 5일 × 5시간 기준).

## 아키텍처

```
EC2 #1 t3.large — Frontend          EC2 #2 t3.medium — Backend
┌────────────────────────┐          ┌────────────────────────┐
│ k3s server (master)    │          │ cephadm (Squid)        │
│ k3s agent-1 (worker-1) │◀────────▶│  MON/OSD/MGR/MDS       │
│ k3s agent-2 (worker-2) │          │                        │
│                        │          │ BeeGFS 8.3             │
│ Ceph CSI (RBD+CephFS)  │          │  mgmtd/meta/storaged   │
│ BeeGFS CSI v1.8.0+     │          │                        │
└────────────────────────┘          └────────────────────────┘
```

## 사전 요구사항

- AWS CLI 설정 완료 (`aws configure`)
- OpenTofu 설치
- Packer 설치 (AMI 빌드 시)
- EC2 Key Pair (`storage-lab`) 및 PEM 파일 (`~/.ssh/storage-lab.pem`)

## 빠른 시작

```bash
# 1. tfvars 수정 (key_name 확인)
vi opentofu/terraform.tfvars

# 2. 전체 자동 구성 (약 15~20분)
bash scripts/lifecycle/start.sh

# 3. 검증
ssh -i ~/.ssh/storage-lab.pem ec2-user@<FRONTEND_IP>
bash ~/05_verify.sh
```

## Packer AMI 빌드 (선택)

사전 빌드된 AMI를 사용하면 패키지 설치 및 BeeGFS 커널 모듈 빌드 시간을 단축할 수 있습니다.

```bash
# 사전 조건 점검 + 빌드 통합 실행
bash scripts/provision/00_build_ami.sh [REGION] [KEY_NAME] [PEM_FILE]
# 기본값: ap-northeast-2 / storage-lab / ~/.ssh/storage-lab.pem
```

직접 Packer로 빌드할 경우:

```bash
cd packer/k3s-storage-lab

# frontend AMI만 빌드
packer build -only="amazon-ebs.frontend" -var-file=variables.pkrvars.hcl .

# backend AMI만 빌드
packer build -only="amazon-ebs.backend" -var-file=variables.pkrvars.hcl .

# 둘 다 동시 빌드
packer build -var-file=variables.pkrvars.hcl .
```

빌드 완료 후 `opentofu/terraform.tfvars`에 AMI ID 반영:

```hcl
ami_frontend = "ami-0xxxxxxxxxxxxxxxxx"
ami_backend  = "ami-0yyyyyyyyyyyyyyyyy"
```

**Frontend AMI 사전 포함 항목:**

| 항목 | 내용 |
|------|------|
| k3s 바이너리 | v1.32.3+k3s1 (서비스 등록 제외) |
| BeeGFS 클라이언트 패키지 | beegfs-client, beegfs-utils, beegfs-tools |
| beegfs.ko | 커널 모듈 사전 빌드 + 설치 (RDMA 비활성) |
| helm | 바이너리 설치 + ceph-csi repo 캐시 |
| git + BeeGFS CSI driver | v1.8.0 사전 클론 (`/opt/beegfs-csi-driver`) |

## 단계별 실행

```bash
# Stage 1: 인프라 + k3s + manifests 전송
bash scripts/lifecycle/start_1_infra_k3s.sh

# Stage 2: Ceph 백엔드 + Ceph CSI (ceph-rbd, ceph-cephfs StorageClass)
bash scripts/lifecycle/start_2_ceph.sh

# Stage 3: BeeGFS 백엔드 + BeeGFS CSI (beegfs-scratch StorageClass)
bash scripts/lifecycle/start_3_beegfs.sh

# 검증
ssh -i ~/.ssh/storage-lab.pem ec2-user@<FRONTEND_IP> 'bash ~/05_verify.sh'
```

롤백:

```bash
bash scripts/lifecycle/rollback_3_beegfs.sh   # BeeGFS CSI + 백엔드 제거
bash scripts/lifecycle/rollback_2_ceph.sh     # Ceph CSI + 클러스터 제거
bash scripts/lifecycle/rollback_1_infra.sh    # AWS 인프라 삭제
```

## 삭제

```bash
bash scripts/lifecycle/destroy.sh
```

## 버전

| 항목 | 버전 |
|------|------|
| OS | RHEL 9.7 (ami-0a67d323f227ce006) |
| Kernel | 5.14.0-xxx (RHEL 9 기본, 고정 불필요) |
| k3s | v1.32.3+k3s1 |
| Ceph | Squid v19.2.x (cephadm) |
| BeeGFS | 8.3 (Community Edition) |
| BeeGFS CSI | v1.8.0+ |
| Ceph CSI | v3.12.x (Helm) |

## 주요 설계 결정

| 항목 | 선택 | 이유 |
|------|------|------|
| OS | RHEL 9 | BeeGFS 8.x 공식 RPM 지원, SELinux 기본 탑재 |
| BeeGFS | 8.3 Community Edition | RHEL 9 전용 (Ubuntu deb 패키지 미제공), mgmtd TOML 형식 |
| k3s SELinux | --selinux 플래그 + k3s-selinux RPM | RHEL 9 SELinux enforcing 환경 필수 |
| BeeGFS mgmtd | TOML 형식 (`tls-disable=true`, `auth-disable=true`) | BeeGFS 8 mgmtd는 TOML, TLS 기본 요구 |
| BeeGFS meta/storage | .conf 형식 (`connDisableAuthentication=true`) | 8버전에서도 .conf 유지 |
| DKMS 커널 빌드 | `kernel-devel-$(uname -r)` 명시 | 최신 kernel-devel과 실행 커널 버전 불일치 방지 |
| sudo PATH | `export PATH="/usr/local/bin:..."` 스크립트 최상단 | RHEL 9 sudo secure_path에 /usr/local/bin 미포함 |
| BeeGFS helperd | 제거 | BeeGFS 8에서 폐지 |
| Ceph 인증 | cephadm bootstrap `--allow-fqdn-hostname` | AWS EC2 hostname이 FQDN 형식 |
