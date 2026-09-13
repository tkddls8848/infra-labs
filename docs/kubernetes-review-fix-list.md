# k8s 클러스터 정의 코드 수정 필요 목록

검토 범위: `systems/` 하위 전체 클러스터 정의 코드.

> **경로 안내**: 이 문서는 원래 `D:\forfun\devops\k8s`(이후 `devops/local/kubernetes`) 기준으로
> 작성되었다. 저장소가 `systems/<시스템명>/` 구조로 재편되면서 기존 항목의 경로가 모두
> 바뀌었으므로, 아래 매핑표 기준으로 다시 정리했다.

| 이전 경로 | 현재 시스템 폴더 |
| --- | --- |
| `ubuntu/kubeadm`, `vagrant/ubuntu/kubeadm/basic` | `local-kubeadm-vagrant` |
| `ubuntu/kubespray`, `vagrant/ubuntu/kubespray/rook-ceph` | `local-kubespray-rook-ceph` |
| `ubuntu/cephadm`, `../storage/vagrant/ubuntu/cephadm/basic` | `local-ceph-vagrant` |
| `kvm/cephadm`, `../storage/kvm/ubuntu/cephadm/basic` | `local-ceph-kvm` |
| `centos8/cephfs`, `../storage/vagrant/centos8/cephfs/kubespray` | `local-kubespray-cephfs-rocky9` |
| `kvm/kubeadm_GPU`, `kvm/ubuntu/kubeadm/gpu` | `local-kubeadm-gpu` |
| `centos8/minikube`, `vagrant/centos8/minikube/kubevirt` | `local-minikube-kubevirt-rocky` |
| `rocky/minikube`, `vagrant/rocky/minikube/kubevirt` | `local-minikube-kubevirt-rocky` |
| `host/ubuntu/microk8s/kubeflow-gpu` | `local-microk8s-kubeflow-gpu` |
| `host/ubuntu/k3s/ai`, `ubuntu/k3s/ai.sh` | `local-k3s-ai` |
| `../data/vagrant/ubuntu/hadoop/basic`, `ubuntu/hadoop` | `local-hadoop-vagrant` |

원칙:

- 기존 방식과 신규 방식을 동시에 살리는 완충 구현은 넣지 않는다.
- 클러스터 유형별로 표준적인 한 가지 구현 방식을 선택하고, 충돌하거나 위험한 기존 경로는 제거한다.
- 노드 간 작업은 직접 SSH 명령으로 처리하지 않는다. 단, `local-kubeadm-gpu`는 예외로 둔다.
- 노드 간 작업은 Ansible inventory에 master/worker/storage 역할을 정의하고, Ansible playbook이 각 대상 노드에서 실행하는 방식으로 통일한다. 단, `local-kubeadm-gpu`는 예외로 둔다.
- CNI는 클러스터 유형별로 명시한다. MicroK8s를 제외한 Kubernetes 클러스터는 Flannel로 전환한다. MicroK8s는 기본 CNI를 유지한다.
- 버전은 latest가 아니라 os 버전 및 k8s 버전 및 관련 설치요소간 호환성이 가장 안정적인 버전을 선택한다.
- `local-kubeadm-gpu`는 예외로 둔다. 기존 VM 생성/SSH 기반 흐름은 유지하되, 위험한 cleanup과 latest 사용은 제거하고 필요한 이유를 문서화한다.

## 검증 범위에 대한 사전 공지

아래 항목의 "처리 결과"는 모두 **정적 검증** 기준이다. 실제로 수행한 검증은 `bash -n`,
`vagrant validate`, `ansible-inventory --list`, PyYAML 파싱, 업스트림 SHA-256 대조,
금지 패턴 스캔이다. **`vagrant up`으로 실제 클러스터를 기동한 검증은 수행하지 않았다.**
작업 환경에 `shellcheck`가 설치되어 있지 않아 shellcheck는 실행하지 못했다.

## 치명적 수정 항목

- [x] `local-kubeadm-vagrant`의 kubeadm 공통 프로비저닝 스크립트 경로를 수정한다.
  - 이전 문제: 호출 경로 `./kubeadm-common.sh`, 실제 파일 `./kubeadm-setup.sh`.
  - 처리 결과: 디렉터리 재편 과정에서 이미 해소되었다. 현재 Vagrantfile은
    `./scripts/cluster/kubeadm-setup.sh`를 호출하며, 인자 순서가 스크립트 기대값과
    일치하는지 재검증했다.

- [x] `local-kubeadm-vagrant`의 kubeadm 인자 계약을 수정한다.
  - 처리 결과: Vagrantfile이 `KUBE_VERSION`, `FLANNEL_VERSION`, `POD_CIDR`, `JOIN_FILE`을
    모두 전달한다. Calico 관련 인자는 제거되고 Flannel로 전환되었다.
    `inventory/group_vars.yml`을 버전·Pod CIDR의 기준 소스로 삼았고, addon Vagrantfile에
    남아 있던 옛 setup/master 인자와 누락된 worker join을 수정했다.

- [x] 클러스터 설정 방식에서 password/root SSH를 제거한다.
  - 처리 결과: `PermitRootLogin`, `PasswordAuthentication`, `sshpass`, `expect`,
    하드코딩된 `vagrant` 비밀번호는 `systems/local-*` 전체에서 제거되었다.
    노드 간 작업은 Ansible inventory 기준으로 전환했다.
  - 남은 `StrictHostKeyChecking=no`는 예외 클러스터인 `local-kubeadm-gpu`
    (`01_vm_create.sh`, `04_worker_join.sh`, `06_rollback.sh`)에만 존재하며,
    이는 SSH 기반 흐름을 유지하기로 한 예외 원칙에 따른 것이다.
  - `local-kubespray-rook-ceph`의 inventory에 있던 `StrictHostKeyChecking=no`와
    `UserKnownHostsFile=/dev/null` 우회는 제거하고, `ssh-keyscan`으로 known_hosts를
    채우되 실패 시 명확히 중단하도록 바꾸었다.

- [x] Ceph OSD 디스크 초기화를 명시 디스크 대상으로 제한한다.
  - 처리 결과: `local-ceph-vagrant`, `local-ceph-kvm` 모두 inventory의
    `osd_devices` 선언만을 대상으로 동작한다. `sgdisk --zap-all` 전체 순회와
    `--all-available-devices`는 제거되었고, 선언되지 않은 디스크가 발견되면
    경고하거나 실패한다. `fix-osd-heartbeat.sh`의 `vd[b-z]`/`sd[b-z]` 전체 순회도
    inventory 선언 기준으로 교체했다.

- [x] 로컬 런타임 상태 파일을 정리하고 ignore 상태를 확인한다.
  - 처리 결과: 루트 `.gitignore`의 패턴이 사라진 `devops/k8s/**` 경로를 가리키고 있어
    실제로는 아무것도 차단하지 못하는 상태였다. 이를 `systems/**` 기준으로
    전부 재지정하고 `.generated/`, `.lab/`을 추가했다. 죽은 `!devops/local/data/`
    부정 패턴은 제거했다. `git check-ignore -v`로 19개 샘플 경로가 실제로 차단되는지
    확인했고, 추적 중인 생성물은 없었다.

- [x] 클러스터별 Ansible inventory를 추가한다.
  - 처리 결과: `local-kubeadm-vagrant`, `local-kubespray-rook-ceph`,
    `local-ceph-vagrant`, `local-ceph-kvm`, `local-kubespray-cephfs-rocky9`에
    inventory가 존재하며 `control_plane`/`workers`/`storage` 그룹을 정의한다.
    노드 수·IP·역할·버전·네트워크 대역이 inventory 단일 기준으로 관리되고,
    Vagrantfile이 이를 읽어 토폴로지를 구성한다. `local-kubeadm-gpu`는 예외로 두고
    기존 스크립트 흐름을 README에 문서화했다.

## 높은 우선순위의 정확성 수정

- [x] `local-ceph-vagrant`와 `local-ceph-kvm`의 차이를 명확히 문서화한다.
  - 처리 결과: 두 구현은 별도 클러스터 정의로 유지했다. 각 README에 provider
    (VirtualBox vs libvirt/KVM), VM 디스크 생성 방식과 장치명(`sd*` vs `vd*`),
    네트워크, inventory 위치, host 사전 요구사항, 실행 전제 차이를 기록했다.

- [x] Kubespray worker 수와 인벤토리 생성을 일치시킨다.
  - 처리 결과: 노드 목록과 worker 수를 inventory 단일 소스로 통합했다.
    Vagrantfile이 inventory에서 노드와 역할을 파생하므로 하드코딩된 worker 3개와의
    불일치가 사라졌다.

- [x] Kubespray 프로비저닝을 재실행 가능하게 정리한다.
  - 처리 결과: SSH 키, Kubespray checkout, inventory, Python venv, 패키지 설치를
    존재 여부와 버전 확인 후 필요한 경우에만 수행하도록 바꾸었다.
    `local-kubespray-cephfs-rocky9`의 Python 소스 빌드도 체크섬 검증과
    멱등 처리를 추가했다.

- [x] 다운로드한 Kubernetes 매니페스트를 `sed`로 직접 수정하는 방식을 제거한다.
  - 처리 결과: MicroK8s를 제외한 모든 클러스터를 Flannel로 전환하고 버전을 고정했다.
    `kubectl apply -f <원격 URL>` 방식은 `systems/local-*` 전체에서 사라졌다.
    의도한 설정은 inventory/group_vars에서 관리한다.

- [x] 외부 설치 파일의 `latest` 사용을 제거하고 버전을 고정한다.
  - 처리 결과: Minikube v1.38.1, KubeVirt/virtctl v1.8.2, Rook v1.20.0,
    Flannel v0.28.5, NVIDIA device plugin v0.17.0, K3s v1.32.3+k3s1 등으로 고정했다.
    GitHub API `latest` 조회는 제거했고, 가능한 경우 SHA-256 체크섬으로 검증한다.
    `local-k3s-ai`의 pipe-to-shell 설치는 검증된 로컬 설치 파일 실행으로 교체했다.

## Kubernetes 구현 수정

- [x] kubeadm 클러스터별 CNI를 하나로 명시한다.
  - 처리 결과: `local-kubeadm-vagrant`는 Calico를 제거하고 Flannel로 전환했다.
    두 Kubespray 클러스터도 inventory의 `kube_network_plugin=flannel`을 기준으로
    동작한다. `local-kubeadm-gpu`는 예외 원칙에 따라 기존 흐름을 유지하되
    Flannel 매니페스트를 저장소에 고정하고 체크섬을 검증한다.
    MicroK8s는 기본 CNI를 유지한다.

- [x] master가 password SSH로 worker join을 수행하는 방식을 제거한다.
  - 처리 결과: 노드 간 작업을 Ansible inventory 방식으로 전환했다. join 정보는
    파일 기반으로 전달한다.

- [x] root 비밀번호 변경과 sudoers 직접 append를 제거한다.
  - 처리 결과: vagrant 기본 sudo만 사용한다. root 비밀번호 변경, root SSH 허용,
    password auth 허용, sudoers append는 모두 제거되었다.
  - 추가로 `local-kubespray-cephfs-rocky9/common/config.sh`에 있던 과도한 호스트
    설정(`setenforce 0`, SELinux 설정 재작성, firewalld/NetworkManager 비활성화,
    `/etc/resolv.conf`를 8.8.8.8로 덮어쓰기)을 제거했다. 현재는 swap, `br_netfilter`,
    sysctl, `iproute-tc`만 남기고 각 항목에 필요한 이유를 주석으로 달았다.

- [x] kubeadm reset/destroy 동작은 rollback 스크립트로만 이동한다.
  - 처리 결과: `local-kubeadm-gpu/04_worker_join.sh`는 기존 kubeadm 상태를 발견하면
    cleanup하지 않고 `06_rollback.sh`를 안내하며 실패한다. 확인 대상 상태 파일을
    `kubelet.conf` 외에 `bootstrap-kubelet.conf`, `pki/ca.crt`,
    `/var/lib/kubelet/config.yaml`까지 확장했다.
  - `local-microk8s-kubeflow-gpu`의 `RESET_MICROK8S`/`RESET_JUJU` 분기도 설치 경로에서
    거부하고 `scripts/lifecycle/destroy_cluster.sh`로 이동했다.

- [x] `local-kubeadm-gpu/02_node_setup.sh`의 NVIDIA runtime 수정 방식을 재검토한다.
  - 처리 결과: 이 클러스터는 예외로 두고 기존 설정 변경을 유지했다. legacy mode,
    disable-require, containerd imports 수정이 필요한 이유를 스크립트 주석과
    README에 설명했다.

- [x] `local-kubeadm-gpu/03_master_init.sh`의 Flannel 매니페스트 버전을 고정한다.
  - 처리 결과: Flannel v0.28.5 매니페스트를 `manifests/kube-flannel-v0.28.5.yml`로
    저장소에 보관하고 `manifests/SHA256SUMS`로 적용 전 검증한다.
    `releases/latest/download` 사용은 제거되었다.

- [x] MicroK8s/Kubeflow 버전과 네트워크 가정을 고정한다.
  - 처리 결과: MicroK8s channel, Juju/Kubeflow 버전, MetalLB IP range,
    dashboard 포트/계정을 `config/cluster.env` 한 곳으로 분리하고 두 스크립트가
    이를 읽는다. MetalLB 대역은 문자열 형태만이 아니라 호스트에 실제로 구성된
    IPv4 네트워크에 속하는지 검증한 뒤 설치한다. MicroK8s CNI는 기본값을 유지한다.
  - 하드코딩되어 있던 `admin/admin` dex-auth 자격증명은 제거하고, 설정 파일에서
    받거나 생성하도록 바꾸었다. lab 전용임을 출력에 명시한다.

## Ceph/Rook/storage 수정

- [x] Ceph public network와 cluster network 선언을 정리한다.
  - 처리 결과: 프론트/백 네트워크를 실제로 분리했다. inventory에
    `ceph_public_network=192.168.60.0/24`, `ceph_cluster_network=192.168.61.0/24`로
    선언하고, 두 Vagrantfile이 각 노드에 두 개의 NIC를 붙이며 스크립트가 이를
    각각 사용하도록 했다.

- [x] Ceph monitor/manager placement를 의도에 맞게 정리한다.
  - 처리 결과: `mon_count = 1`, `mgr_count = 2`는 단일 monitor 실습 클러스터의
    의도된 값이므로 변경하지 않았다. 값 선언부 주석과 각 README에 non-HA임을
    명시했다.

- [x] Ceph OSD 적용에서 `--all-available-devices` 사용을 제거한다.
  - 처리 결과: inventory에 선언한 OSD 디스크만 대상으로 OSD를 적용한다.
    Vagrant provider가 만든 디스크 외의 장치는 자동 대상이 되지 않는다.

- [x] `local-kubespray-rook-ceph`의 Rook/Ceph 스크립트를 검토한다.
  - 처리 결과: Rook v1.20.0 업스트림 매니페스트를 고정 커밋
    (`51bca7e46d7557031dde89c900483e6c0681ce23`) 기준으로 저장소
    `manifests/rook-ceph/`에 보관(vendoring)했다. `~/rook/deploy/examples` 의존과
    `kubectl apply -f URL` 방식은 완전히 제거되었고, 실행 시 clone 폴백도 없다.
    block/filesystem/object 스크립트는 저장소 내 매니페스트만 적용하며,
    StorageClass 이름 충돌을 없애고 이미지 버전을 고정했다. 3-worker 실습 규모에
    맞춰 replica/pool 크기를 검토했다. Cephadm 방식과 Rook 방식은 서로 다른
    시스템 폴더로 분리되어 있어 한 클러스터 안에서 섞이지 않는다.
  - `local-kubespray-cephfs-rocky9`는 inventory에 선언한 `rook_device` 기준으로
    Rook 클러스터를 렌더링하는 `manifests/render_rook_cluster.py`를 추가했다.

## 저장소 정리 항목

- [x] 깨진 한글 주석과 echo 메시지를 복구한다.
  - 조사 결과: 손상 파일은 `systems/aws-k3s-storage-lab`과
    `aws-kubeadm-storage-lab` 하위 29개였다. 최초 가정과 달리 CP949/EUC-KR로 저장된
    파일이 아니라, **UTF-8 한글이 손실성 왕복 변환으로 파괴된** 상태였다
    (바이트 쌍이 리터럴 `0x3F`로 치환됨). 29개 중 26개는 cp949/euc-kr 디코딩이
    아예 실패했다.
  - 처리 결과: 손상 이전의 깨끗한 Git 리비전에서 원래 한글을 그대로 복원했다.
    추측으로 문장을 지어내거나 번역한 줄은 없다. 재편 이후의
    `scripts/lifecycle`, `scripts/provision`, `scripts/system` 구조는 유지했고,
    이동으로 깨진 AMI `LAB_DIR` 경로와 손상으로 망가진 셸 구문도 함께 고쳤다.
    실행 로그는 단계·대상 노드·실패 원인이 드러나도록 정리했다.
  - 검증: `devops` 하위 전체 파일이 UTF-8로 디코딩된다(비정상 0건).

- [x] 생성물/로컬 상태에 대한 `.gitignore` 항목을 추가한다.
  - 처리 결과: 최초 작성 시 추가한 패턴이 디렉터리 재편으로 죽은 경로
    (`devops/k8s/**`)를 가리키게 되어 실제로는 아무것도 차단하지 못하고 있었다.
    전부 `systems/**` 기준으로 재지정하고 `.generated/`, `.lab/`을 추가했다.
    기존 `.vagrant/`, `**/.claude`, `password.rb`는 중복 없이 유지했다.

- [x] 클러스터 정의와 무관한 앱 의존성 산출물을 정리한다.
  - 처리 결과: Ceph 클러스터 정의와 샘플 애플리케이션을 분리하여 각 시스템 폴더의
    `apps/` 아래로 이동했다.

- [x] 디렉터리 이름 규칙을 통일한다.
  - 처리 결과: 저장소 전체를 `systems/<위치>-<핵심기술>-<목적>` 규칙으로
    재편했다.

- [x] `destroy_cluster.sh` 오타를 수정한다.
  - 처리 결과: `destory_cluster.sh`를 `destroy_cluster.sh`로 변경했다.

- [x] 최상위 README를 추가한다.
  - 처리 결과: `devops/README.md`에 시스템 목록, 구성, 시작 명령, 폴더 규칙을
    정리했다. 각 시스템 폴더에도 목적, 지원 provider, 네트워크, inventory 위치,
    생성/삭제 명령, 고정 버전, non-HA/lab-only 가정을 담은 README를 두었다.

- [ ] 검증 진입점을 추가한다.
  - 현재 상태: **회귀 항목**. 이전에 추가했던 `devops/local/kubernetes/validate.ps1`이
    디렉터리 재편 과정에서 사라졌고 대체 진입점이 없다.
  - 수정 요청: `systems` 전체를 대상으로 shellcheck, `vagrant validate`,
    `ansible-inventory --list`를 설치된 도구 기준으로 실행하는 검증 스크립트를
    다시 추가한다.

## 클러스터별 처리 방향

- [x] `local-kubeadm-vagrant`: 스크립트 경로 불일치와 누락된 버전 인자를 해소했다.
  Flannel로 전환하고 KubeVirt addon 매니페스트를 저장소에 고정했다.

- [x] `local-kubespray-rook-ceph`: inventory/node count를 단일 소스로 만들고
  password SSH 자동화를 제거했다. Rook 매니페스트를 저장소에 고정했다.

- [x] `local-ceph-vagrant`: 별도 클러스터 정의로 유지하고, 위험한 SSH 설정과
  디스크 wipe 동작을 제거했다. `local-ceph-kvm`와의 provider/디스크/네트워크 차이를
  문서화했다.

- [x] `local-ceph-kvm`: 별도 클러스터 정의로 유지하고, libvirt 전용 디스크/provider
  전제를 문서화했다.

- [x] `local-kubeadm-gpu`: 예외 클러스터로 유지한다. 기존 VM 생성/SSH 기반 동작은
  유지하되 주석과 README로 이유를 문서화했다. Flannel 버전을 고정하고, 파괴적
  cleanup은 rollback에만 두었다.

- [x] 현재 `local-minikube-kubevirt-rocky`에 통합된 CentOS 8 변형: Minikube/KubeVirt
  버전을 고정하고 OS별 차이를 문서화했다. 실행 불가능했던 설치 흐름(`newgrp` 서브셸,
  `sudo reboot` 이후의 도달 불가 명령)을 pre/post-reboot 단계로 분리했다.
  - **당시 알려진 제약**: CentOS 8은 공개 저장소가 EOL이라 stock 이미지에서 패키지
    부트스트랩이 불가능했다. 버전 고정만으로는 해결되지 않아 README에 명시했다.
  - **해결 (2026-08-15)**: 중복 정의를 삭제하고 아래 Rocky Linux 9 정의로 통합했다.

- [x] `local-minikube-kubevirt-rocky`: 위와 동일하게 처리하고 CentOS 8 변형과의
  차이를 문서화했다.
  - **적용 (2026-08-15)**: `bento/rockylinux-9` `202510.26.0`으로 이주했다. 단,
    `192.168.81.10`이 VirtualBox 기본 허용 범위 밖인 H-3은 여전히 미해결이다.

- [x] `local-kubespray-cephfs-rocky9`: password SSH, sudoers append, expect 기반
  Kubespray 자동화, Rook 예제 디렉터리 의존, 외부 디스크 경로 하드코딩을 제거하고
  Ansible inventory/group vars 기준으로 전환했다.
  - **당시 알려진 제약**: CentOS 8 EOL 제약은 위와 동일했다.
  - **해결 (2026-08-15)**: 디렉터리를 현재 이름으로 바꾸고 Rocky Linux 9로 이주했다.
    NetworkManager 비활성화 문제(M-5)는 이 이주 전 커밋 `fc14c70`에서 이미 해결됐다.

- [x] `local-microk8s-kubeflow-gpu`: channel/version을 고정하고, 네트워크 대역을
  클러스터 설정값으로 관리하며, 일반 설치 흐름에서 광범위한 home/cache 삭제를
  제거했다.

- [x] `local-k3s-ai`: pipe-to-shell latest installer를 제거하고, 고정된 installer
  버전과 명시 설치 옵션을 사용한다. 설치 파일은 SHA-256으로 검증한다.

- [x] `local-hadoop-vagrant`: Kubernetes 클러스터 정의가 아니므로 별도 시스템 폴더로
  분리했다. 목적과 실행 방식은 해당 README에 정리되어 있다.

## 남은 작업

1. **검증 진입점 복구**: 위 "검증 진입점을 추가한다" 항목 참고.
2. **실기동 검증**: 모든 항목이 정적 검증까지만 수행되었다. 각 시스템을 실제로
   `vagrant up` 하여 클러스터가 기동되는지 확인하는 절차가 남아 있다.
3. **shellcheck 실행**: 작업 환경에 설치되어 있지 않아 실행하지 못했다.
4. **CentOS 8 EOL 대응 (해결, 2026-08-15)**: `local-kubespray-cephfs-rocky9`로
   이주했고, 중복 Minikube/KubeVirt 정의는 Rocky Linux 9 기반
   `local-minikube-kubevirt-rocky`로 통합했다. 이주 판단은
   `devops/docs/os-migration-rhel9-ubuntu2604.md` 참고.
5. **H-3 VirtualBox 네트워크 (미해결)**: `local-minikube-kubevirt-rocky`의
   `192.168.81.10`은 기본 허용 범위 `192.168.56.0/21` 밖에 있다.
6. **RHEL 9 이주 우선순위 3·4·5 (미적용)**: `aws-kubeadm-storage-lab`,
   `local-ceph-kvm`, `local-ceph-vagrant`, `local-kubespray-rook-ceph` 이주는 남아 있다.
7. **Ubuntu 26.04 이주 (보류)**: BeeGFS, Ceph, Kubespray 지원이 충족되지 않아 위 이주
   문서 7.1의 판단을 유지한다.

## 이번 검토 범위 밖에서 발견된 사항

- `AI/openclaw/opentofu/opentofu.tfvars`가 `AI/openclaw/.gitignore`에서 무시 대상으로
  지정되어 있음에도 Git에 추적되고 있다. tfvars 파일이므로 비밀정보 유출 여부를
  확인할 필요가 있다. 이번 작업에서는 범위 밖이므로 손대지 않았다.
