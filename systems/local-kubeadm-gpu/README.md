# Kubernetes GPU 클러스터 구성 (KVM Master + 베어메탈 GPU Worker)

> **Declared exception — direct VM creation and SSH are intentional.** This is
> the repository's one exception to the Ansible-inventory rule. The control
> plane is a libvirt VM, while the only NVIDIA GPU remains attached to the
> Ubuntu host and that host joins as a bare-metal worker. Converting this flow
> to the shared Ansible inventory would hide the libvirt/cloud-init boundary
> and its GPU-passthrough constraint: with no iGPU, the sole display/compute GPU
> cannot safely be detached for VFIO, so the driver/runtime must be prepared on
> the host instead of inside the VM. Keep the numbered scripts and direct SSH
> handoff here.

## Pinned compatibility set

This lab targets Ubuntu 24.04 on x86-64. It was cross-checked against
`devops/docs/os-compatibility-review.md`: the noble guest, `apt`, nftables
libvirt backend, and `ubuntu` guest user match that review. Versions are a set;
update and re-test them together rather than overriding one script locally.

| Component | Pin |
|---|---|
| Ubuntu cloud image | `release-20241004`, SHA-256 `fad101d50b06b26590cf30542349f9e9d3041ad7929e3bc3531c81ec27f2c788` |
| Kubernetes packages | `1.31.14-1.1` (`v1.31` package repository) |
| containerd.io | `1.7.22-1` |
| NVIDIA driver | `nvidia-driver-550-server=550.163.01-0ubuntu0.24.04.1` (runtime `550.163.01`) |
| NVIDIA Container Toolkit | `1.17.8-1` |
| Flannel | `v0.28.5`, vendored and SHA-256 verified |
| NVIDIA device plugin | `v0.17.0`, vendored and SHA-256 verified |
| CUDA smoke-test image | `nvidia/cuda:12.1.0-base-ubuntu22.04` |

`01_vm_create.sh` verifies the cloud image and both vendored manifests before
creating a VM. The manifests are embedded under `~/manifests` in the master VM;
`03_master_init.sh` and `05_gpu_plugin.sh` verify them again immediately before
`kubectl apply`. A pinned download URL plus the same expected checksum is the
fallback when a script is copied without the vendored directory.

## Why the NVIDIA runtime exceptions remain

The bare-metal worker is deliberately different from a generic containerd
node:

- `mode = "legacy"` keeps NVIDIA's classic runtime-hook injection path. The
  device-plugin pods in this lab request GPUs through environment variables and
  direct `/dev/nvidia*` access; they do not carry CDI annotations, so `auto`
  choosing CDI can omit the host driver libraries.
- `disable-require = true` prevents image `NVIDIA_REQUIRE_*` metadata from
  rejecting the pinned host driver before this lab's direct-device smoke test.
  This weakens a compatibility guard and is acceptable only for this local lab.
- `accept-nvidia-visible-devices-envvar-when-unprivileged = true` allows the
  Kubernetes device plugin's `NVIDIA_VISIBLE_DEVICES` allocation to reach the
  container runtime without making the workload itself privileged.
- containerd `imports = ["/etc/containerd/conf.d/*.toml"]` is required because
  `nvidia-ctk` writes the NVIDIA runtime drop-in there and containerd 1.7 does
  not load that directory unless the root config imports it.

## Destructive-operation policy

Normal phases never reset kubeadm state, destroy/undefine a VM, or broadly
remove cluster directories. They fail on conflicting pre-existing state and
direct the operator to `06_rollback.sh`. All `kubeadm reset`, VM destruction,
CNI removal, and package/config cleanup belongs to that interactive rollback
script. In particular, `04_worker_join.sh` refuses existing kubelet/bootstrap,
PKI, or `/var/lib/kubelet/config.yaml` state; use rollback option `04` before
rejoining.

## 아키텍처

```
┌─────────────────────────────────────────────────────┐
│  호스트 (psi)  -  Ubuntu 24.04                       │
│                                                     │
│  ┌─────────────────────┐                            │
│  │  k8s-master (KVM VM)│  ← control plane (GPU 없음) │
│  │  192.168.122.x      │                            │
│  │  2vCPU / 4GB / 30GB │                            │
│  └─────────────────────┘                            │
│                                                     │
│  호스트 자체  ← GPU worker (베어메탈)                  │
│  GTX 1660 SUPER → nvidia-smi / CUDA 직접 사용        │
└─────────────────────────────────────────────────────┘
```

### 설계 이유

| 항목 | 내용 |
|---|---|
| GPU | NVIDIA GeForce GTX 1660 SUPER (1개) |
| iGPU | 없음 |
| VFIO passthrough | 불가 (iGPU 없어 화면 소실) |
| 선택 방식 | 호스트 베어메탈을 k8s worker로 직접 join |

---

## 사전 요구사항

- Ubuntu 24.04 LTS
- NVIDIA 드라이버 설치 완료 (`nvidia-smi` 동작 확인)
- CPU 가상화 지원 (VT-x / AMD-V BIOS 활성화)
- 인터넷 연결

---

## 스크립트 구성

| 파일 | 실행 위치 | 역할 |
|---|---|---|
| `00_host_setup.sh` | 호스트 | KVM/libvirt 설치, IOMMU 설정, libvirt NAT 구성 |
| `01_vm_create.sh` | 호스트 | Master VM 생성, cloud-init으로 스크립트 배포 |
| `02_node_setup.sh` | **Master VM** + **호스트** | k8s 공통 패키지 설치 (GPU_MODE 자동 감지) |
| `03_master_init.sh` | Master VM | kubeadm init, Flannel CNI, join 명령 생성 |
| `04_worker_join.sh` | **호스트** | 호스트를 k8s worker로 join |
| `05_gpu_plugin.sh` | Master VM | NVIDIA Device Plugin 배포, CUDA 테스트 |
| `06_rollback.sh` | 호스트 | 단계별 롤백 |

---

## 실행 순서

### Phase 0 - 호스트 환경 준비

```bash
bash 00_host_setup.sh
```

- Intel/AMD CPU 자동 감지 → GRUB IOMMU 파라미터 추가
- KVM / libvirt 설치
- NVIDIA 드라이버 확인
- libvirt 네트워크 설정 (nftables NAT)

> GRUB 변경 시 재부팅 필요. 스크립트가 재부팅 여부를 묻습니다.

---

### Phase 1 - Master VM 생성

```bash
bash 01_vm_create.sh
```

- Ubuntu 24.04 cloud image 다운로드 (최초 1회)
- Master VM 생성 (2vCPU / 4GB / 30GB)
- cloud-init으로 스크립트 자동 배포:
  - `/home/ubuntu/02_node_setup.sh`
  - `/home/ubuntu/03_master_init.sh`
  - `/home/ubuntu/05_gpu_plugin.sh`
- `/etc/hosts`에 `k8s-master` 이름 등록

완료 후 SSH 접속 가능:
```bash
ssh ubuntu@k8s-master   # 비밀번호: ubuntu
```

---

### Phase 2 - 노드 공통 설정

#### Master VM에서

```bash
ssh ubuntu@k8s-master
bash ~/02_node_setup.sh
# 완료 후 재부팅
```

GPU_MODE 자동 감지 결과: `none` (hostname에 "master" 포함)

#### 호스트에서 (GPU worker)

```bash
bash 02_node_setup.sh
# 완료 후 재부팅
```

GPU_MODE 자동 감지 결과: `full` (베어메탈 + `/dev/nvidia*` 존재)

- NVIDIA 드라이버가 이미 동작 중이면 재설치 스킵
- nvidia-container-toolkit 설치
- containerd NVIDIA runtime 설정
- kubeadm / kubelet / kubectl 설치

**두 노드 모두 재부팅 후 진행.**

---

### Phase 3 - Master 클러스터 초기화

```bash
ssh ubuntu@k8s-master
bash ~/03_master_init.sh
```

- `kubeadm init` (pod CIDR: 10.244.0.0/16)
- kubectl 설정 (`~/.kube/config`)
- Flannel CNI 설치
- worker join 명령 저장: `~/k8s-setup/worker_join.sh`

완료 후 join 명령 확인:
```bash
cat ~/k8s-setup/worker_join.sh
```

---

### Phase 4 - 호스트를 Worker로 Join

```bash
# 호스트에서
bash 04_worker_join.sh "$(ssh ubuntu@k8s-master cat ~/k8s-setup/worker_join.sh)"
```

또는 join 명령을 직접 복사해서:
```bash
bash 04_worker_join.sh "kubeadm join 192.168.122.x:6443 --token xxx --discovery-token-ca-cert-hash sha256:xxx"
```

Master에서 노드 확인:
```bash
ssh ubuntu@k8s-master kubectl get nodes
```

---

### Phase 5 - GPU Device Plugin 배포

```bash
ssh ubuntu@k8s-master
bash ~/05_gpu_plugin.sh
```

- NVIDIA Device Plugin DaemonSet 배포
- CUDA 테스트 Pod (`nvidia/cuda:12.1.0-base-ubuntu22.04`) 실행
- `nvidia-smi` 출력 확인

---

## GPU_MODE 자동 감지 로직 (`02_node_setup.sh`)

```
hostname에 "master" 포함
    → GPU_MODE=none  (NVIDIA 설치 전체 스킵)

worker + systemd-detect-virt=none (베어메탈) + /dev/nvidia* 존재
    → GPU_MODE=full  (드라이버 + toolkit 설치)

worker + VM 환경 (kvm/qemu 등)
    → GPU_MODE=toolkit-vm  (userspace toolkit만, 커널 모듈 제외)

GPU_MODE 환경변수로 강제 지정 가능:
    GPU_MODE=none bash 02_node_setup.sh
    GPU_MODE=full bash 02_node_setup.sh
```

---

## 롤백 (`06_rollback.sh`)

```bash
bash 06_rollback.sh
```

| 선택 | 롤백 범위 |
|---|---|
| `01` | Master VM 삭제 (cloud image / host_info.env 보존) |
| `02` | VM 내부 패키지 제거 불가 → VM 삭제 후 재생성 |
| `03` | Master 클러스터 해체 (kubeadm reset, CNI 초기화) |
| `04` | 호스트 worker 제거 (kubeadm reset, 노드 drain/delete) |
| `05` | GPU Device Plugin / CUDA 테스트 Pod 제거 |

---

## 유용한 명령어

```bash
# 노드 상태
ssh ubuntu@k8s-master kubectl get nodes -o wide

# GPU 할당량 확인
ssh ubuntu@k8s-master kubectl get nodes \
  -o custom-columns='NAME:.metadata.name,GPU:.status.capacity.nvidia\.com/gpu'

# Device Plugin 로그
ssh ubuntu@k8s-master kubectl logs -n kube-system \
  -l app=nvidia-device-plugin-ds --tail=30

# CUDA 테스트 결과
ssh ubuntu@k8s-master kubectl logs cuda-test

# Master VM 관리
sudo virsh list --all
sudo virsh console k8s-master   # 콘솔 접속 (Ctrl+] 로 탈출)
sudo virsh start k8s-master
sudo virsh shutdown k8s-master
```

---

## 네트워크 구성

| 구성 요소 | 네트워크 |
|---|---|
| libvirt NAT | 192.168.122.0/24 |
| Master VM | 192.168.122.x (DHCP, /etc/hosts에 k8s-master로 등록) |
| Pod CIDR | 10.244.0.0/16 (Flannel) |
| k8s API | 192.168.122.x:6443 |

### VM 인터넷 연결 (nftables NAT)

`00_host_setup.sh`에서 자동 설정:
- libvirt firewall 백엔드: nftables
- masquerade 규칙: `/etc/nftables.d/99-libvirt-nat.nft`
- ip_forward: `/etc/sysctl.d/99-libvirt-nat.conf`

---

## 트러블슈팅

### VM에서 apt-get 실패 (네트워크 없음)

```bash
# 호스트에서 NAT 규칙 확인
sudo nft list ruleset | grep masquerade

# 없으면 00_host_setup.sh 재실행
bash 00_host_setup.sh
```

### SSH 접속 거부 (REMOTE HOST IDENTIFICATION)

VM 재생성 후 호스트 키 변경 시:
```bash
ssh-keygen -R k8s-master
ssh-keygen -R <master-ip>
```

`01_vm_create.sh`에서 자동 처리됩니다.

### GPU Device Plugin - No devices found

호스트(worker)에서 nvidia-container-toolkit이 containerd에 설정됐는지 확인:
```bash
cat /etc/containerd/config.toml | grep nvidia
# 없으면:
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

### kubeadm join 토큰 만료 (24시간)

```bash
ssh ubuntu@k8s-master
kubeadm token create --print-join-command
```
