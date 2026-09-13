# RHEL 9 / Ubuntu 26.04 이주 가능성 검토

검토 대상: `systems/*` (검토 시점 13개 → **현재 12개**)
최초 검토: 2026-08-12 (`f379280`) / **현행화: 2026-08-15**
선행 문서: [`os-compatibility-review.md`](./os-compatibility-review.md)

> **우선순위 1·2는 2026-08-15에 적용 완료됐다.** 해당 항목은 본문에서 `적용 완료`로
> 표시하고 판정 근거는 보존한다. 우선순위 3~5와 Ubuntu 26.04는 미적용이며,
> 그 판정은 현재도 유효하다. 경과는 문서 끝 [적용 이력](#적용-이력) 참조.

---

## 0. 판정 규칙

요구 조건은 두 가지다.

1. 기존 구현 요소는 **동일 조건·동일 버전**을 유지한다.
2. 버전 변경이 불가피하면, 변경 시 **기존 다른 구성요소와의 호환성이 완전히 확인**되어야 한다.

이에 따른 판정 등급:

| 등급 | 의미 |
| --- | --- |
| ✅ **가능** | 고정된 모든 버전을 대상 OS에서 그대로 설치 가능 |
| ⚠️ **조건부** | 상위(업스트림) 버전은 동일하나 패키지 릴리스 표기가 다르거나, 검증을 마친 변경이 필요 |
| ❌ **불가** | 어떤 버전 조합으로도 해당 OS에서 성립하지 않음 |

**패키지 릴리스 표기 차이는 버전 변경으로 보지 않는다.**
예: containerd `1.7.22-1`(deb) ↔ `1.7.22-3.1.el9`(rpm)은 동일 업스트림 `1.7.22`다.
반대로 containerd `1.7.22` → `2.2.x`는 명백한 버전 변경이며 조건 2의 검증 대상이다.

---

## 1. 검증 방법과 한계

추정을 배제하기 위해, 아래 모든 판정은 2026-08-12 기준으로 **각 배포 저장소의 인덱스를 직접 조회**한 결과에 근거한다.

- APT: `dists/<codename>/.../Packages` 파싱, `dists/<codename>/Release` HTTP 상태코드
- YUM/DNF: `repodata/repomd.xml` → `primary.xml.gz` 파싱, 디렉터리 인덱스 조회
- 배포판 패키지 버전: `packages.ubuntu.com/<suite>/<pkg>`
- Vagrant 박스: Vagrant Cloud API `/api/v2/box/<ns>/<name>` 상태코드, `chef/bento`의 `builds.yml`

**한계.** 실제 부팅·프로비저닝 검증은 수행하지 않았다(AWS 인스턴스·VM 미기동).
따라서 "패키지가 존재한다"까지는 확정이고, "부팅 후 정상 동작한다"는 별개다.
부팅해야만 드러나는 항목은 본문에서 **미검증**으로 명시했다.

---

## 2. 대상 OS 실측값

| 항목 | Ubuntu 24.04 (noble, 현행) | Ubuntu 26.04 (resolute) | RHEL 9.7 |
| --- | --- | --- | --- |
| 출시 | 2024-04 | **2026-04-23** | 2025 |
| 기본 커널 | 6.8 (`linux-image-aws` 6.8/6.14) | **7.0.0-29.29** / `linux-image-aws` **7.0.0-1010.10** | **5.14.0-611.5.1** |
| 기본 python3 | 3.12 | **3.14.3-0ubuntu2** | 3.9 (AppStream에 3.12 별도 제공, 9.4+) |
| `python3.12` 패키지 | 존재 | **없음** (검색 결과 0건) | 존재 (`dnf install python3.12` → `/usr/bin/python3.12`) |
| 배포판 ceph | **19.2.3** (Squid) | **20.2.0** (Tentacle) | 없음 (upstream 저장소 사용) |
| 배포판 cephadm | 19.2.3-0ubuntu0.24.04.3 | **20.2.0-0ubuntu2** | 없음 |
| 배포판 containerd | 2.2.1-0ubuntu1~24.04.3 | 2.2.2-0ubuntu1.1 | 없음 |
| AWS AMI | 있음 | **있음** (ap-northeast-2, amd64, gp3 — 예 `ami-0d0353075b90e6937`, 20260806) | 있음 |
| bento 박스 | `bento/ubuntu-24.04` | `bento/ubuntu-26.04` (libvirt 부팅 버그 #1684 미해결) | **없음** — bento는 `rhel` 빌드를 명시적으로 제외. `bento/rockylinux-9`, `bento/almalinux-9`로 대체 |

> RHEL은 무료 Vagrant 박스가 없다. 로컬 랩에서 "RHEL 9"는 실질적으로
> **Rocky Linux 9 / AlmaLinux 9**를 의미하며, 본 문서는 이 대체를 전제로 판정한다.
> AWS 랩은 Red Hat 공식 AMI(owner `309956199498`)를 쓰므로 진짜 RHEL 9다.

### 2.1 컴포넌트별 저장소 실측 (핵심 근거)

| 컴포넌트 | Ubuntu 24.04 | **Ubuntu 26.04** | **RHEL 9** |
| --- | --- | --- | --- |
| containerd `1.7.22` (Docker repo) | ✅ `1.7.22-1` 존재 | ❌ **없음** — resolute는 `2.2.2` ~ `2.3.3`만 제공 | ✅ `containerd.io-1.7.22-3.1.el9.x86_64.rpm` |
| Kubernetes `1.31` (pkgs.k8s.io) | ✅ deb `1.31.0-1.1`~`1.31.14-1.1` | ✅ 동일 (배포판 무관 저장소) | ✅ rpm `1.31.0`~`1.31.14` (`1.31.4-150500.1.1`) |
| BeeGFS `7.4.6` | ✅ `dists/noble` (200) | ❌ **`dists/resolute` 404** | ✅ `beegfs-rhel9.repo` (200) |
| BeeGFS `8.3` | ✅ `dists/noble` (200) | ❌ **`dists/resolute` 404** | ✅ `beegfs-rhel9.repo` (200) |
| Ceph Squid (upstream) | ❌ `debian-squid/dists/noble` 404 → 배포판 19.2.3 사용 | ❌ 404 (배포판은 v20) | ✅ `rpm-squid/el9`, **`rpm-19.2.1/el9`에 `cephadm-19.2.1-0.el9` 존재** |
| Kubespray `v2.31.0` CI 검증 OS | ✅ Ubuntu 24.04 | ❌ **미포함** (22.04·24.04까지) | ✅ RHEL/Rocky/Alma 9·10 |
| `k3s-selinux-1.6-1.el9` | — | — | ✅ 200 |
| `openjdk-17-jdk` | ✅ | ✅ `17.0.19+10-1~26.04.2` | ✅ |

---

## 3. 결론 요약

| 시스템 | 현행 OS | → **RHEL 9** | → **Ubuntu 26.04** |
| --- | --- | --- | --- |
| `aws-k3s-storage-lab` | RHEL 9.7 | **이미 적용됨** | ❌ BeeGFS 부재 |
| `aws-kubeadm-storage-lab` | Ubuntu 24.04 | ⚠️ **가능 — 전 구성요소 동일 버전 성립** | ❌ BeeGFS·containerd·python 3중 차단 |
| `local-ceph-kvm` | Ubuntu 24.04 (libvirt/podman) | ⚠️ 가능 — **버전 정합성이 오히려 개선** | ❌ Ceph 세대 불일치 |
| `local-ceph-vagrant` | Ubuntu 24.04 (vbox/docker) | ⚠️ 가능 — 동상. 단 docker→podman 전환 | ❌ Ceph 세대 불일치 |
| `local-kubespray-rook-ceph` | Ubuntu 24.04 | ✅ 가능 (Rocky 9, kubespray 공식 지원) | ❌ Kubespray v2.31.0 미지원 |
| `local-kubeadm-vagrant` | Ubuntu 22.04 | ⚠️ 가능 — containerd 조달 경로 변경 | ⚠️ 가능 — 고정 버전 없음 |
| `local-hadoop-vagrant` | Ubuntu 24.04 | ⚠️ 가능 — `JAVA_HOME` 경로만 변경 | ✅ **가능 (동일 버전)** |
| `local-k3s-ai` | 미선언 | ✅ 가능 (미검증) | ✅ 가능 (미검증) |
| `local-kubeadm-gpu` | Ubuntu 24.04 호스트+VM | ⚠️ 가능하나 대규모 개편 | ⚠️ 가능 — GPU 스택 재검증 필요 |
| `local-microk8s-kubeflow-gpu` | Ubuntu 호스트 (snap) | ❌ 부적합 — snap/Juju/Kubeflow가 Ubuntu 전제 | ⚠️ 미검증 |
| `local-kubespray-cephfs-centos8` | CentOS 8 (EOL) | ✅ **적용 완료** → `local-kubespray-cephfs-rocky9` | ❌ 배포판 계열 변경 |
| `local-minikube-kubevirt-centos8` | CentOS 8 (EOL) | ✅ **적용 완료** — 랩 제거 후 rocky 랩으로 통합 | ❌ 배포판 계열 변경 |
| `local-minikube-kubevirt-rocky` | Rocky 8 → **Rocky 9** | ✅ **적용 완료** | ❌ 배포판 계열 변경 |

**한 줄 요약.**
Ubuntu 26.04는 **스토리지 랩 전부(BeeGFS·Ceph 사용 5개)에서 불가**하며, 이는 버전 조정으로 우회할 수 없다.
RHEL 9는 **13개 중 11개에서 가능**하고, 그중 `aws-kubeadm-storage-lab`은 **고정 버전을 단 하나도 바꾸지 않고** 이주할 수 있는 유일한 사례다.

---

## 4. Ubuntu 26.04 — 차단 요인

### U-1. BeeGFS: 26.04용 패키지가 존재하지 않으며, 버전 변경으로 해소할 수 없다 (결정적)

```
$ for c in jammy noble oracular plucky questing resolute; do
    curl -o /dev/null -w "$c -> %{http_code}\n" \
      "https://www.beegfs.io/release/beegfs_7.4.6/dists/$c/Release"
  done
jammy    -> 200
noble    -> 200
oracular -> 404
plucky   -> 404
questing -> 404
resolute -> 404      # ← Ubuntu 26.04
```

BeeGFS **8.3**도 동일하다 (`dists/resolute` → 404). 즉 **현행 7.4.6도, 최신 8.3도 26.04용 APT 저장소가 없다.**

패키지 부재만이 아니라 커널 자체가 범위를 벗어난다.

| BeeGFS | 클라이언트 커널 상한 | 공식 지원 배포판 | Ubuntu 26.04(커널 7.0) |
| --- | --- | --- | --- |
| 7.4.6 | **Linux 6.11까지** | RHEL 8·9, Rocky/Alma, Ubuntu 20.04·22.04·24.04 | 범위 밖 |
| 8.3 | 테스트 최고 커널 6.14 (Ubuntu 24.04.3) | RHEL 8·9·10, SLES 15, Debian 11·12·13, Ubuntu 20.04·22.04·24.04 | 범위 밖 |

`aws-kubeadm-storage-lab`이 쓰는 **커널 6.8 다운그레이드 우회도 26.04에서는 성립하지 않는다.**
`worker_kernel.sh`는 `apt-cache search 'linux-image-6\.8.*-aws'`로 6.8 커널을 찾는데,
resolute 아카이브의 `linux-image-aws`는 **7.0.0-1010.10**뿐이다. 6.8 패키지는 noble 아카이브에만 있다.
스크립트는 `ERROR: linux-image-6.8.*-aws 패키지 없음`으로 종료한다.

> **판정.** BeeGFS를 쓰는 `aws-k3s-storage-lab`, `aws-kubeadm-storage-lab`은
> Ubuntu 26.04로 이주 **불가**다. 조건 2(버전 변경 후 호환성 확인)를 적용할 여지가 없다 —
> 26.04를 지원하는 BeeGFS 릴리스가 아직 존재하지 않기 때문이다.

### U-2. containerd 1.7.22가 Docker의 26.04 저장소에 없다

```
$ curl -s https://download.docker.com/linux/ubuntu/dists/resolute/stable/binary-amd64/Packages \
  | awk '/^Package: containerd.io$/{p=1} p&&/^Version:/{print $2; p=0}'
2.2.2-1~ubuntu.26.04~resolute
2.2.3-1~ubuntu.26.04~resolute
2.2.4-1~ubuntu.26.04~resolute
2.2.5-1~ubuntu.26.04~resolute
2.2.6-1~ubuntu.26.04~resolute
2.3.3-1~ubuntu.26.04~resolute
```

`group_vars/all.yml`의 `containerd_version: "1.7.22-1"`은 26.04에서 **설치 불가**다.
resolute 저장소의 최저 버전이 `2.2.2`이므로 1.7 계열 자체가 없다.

강행하면 containerd **1.7 → 2.x 메이저 업그레이드**가 강제되며, 이는 조건 2의 검증 대상이 된다.
(K8s 1.31은 CRI v1을 쓰고 containerd 2.x도 CRI v1을 제공하므로 원리상 호환이나,
`config.toml` 스키마가 v2→v3로 바뀌어 `sed`로 `SystemdCgroup`/`sandbox_image`를 고치는
현행 방식이 그대로 통하지 않는다. 이 랩은 U-1로 이미 차단이므로 추가 검증은 진행하지 않았다.)

### U-3. Ceph: 26.04는 Tentacle(v20), 랩은 Squid(v19.2.1) 고정

| | Ubuntu 24.04 | Ubuntu 26.04 |
| --- | --- | --- |
| 배포판 `cephadm` | 19.2.3 (Squid) | **20.2.0 (Tentacle)** |
| 랩 고정 이미지 | `quay.io/ceph/ceph:v19.2.1` | 동일 |

`local-ceph-kvm` / `local-ceph-vagrant`는 호스트 `cephadm`은 배포판 패키지를 쓰고,
클러스터 컨테이너만 `--image quay.io/ceph/ceph:v19.2.1`로 고정하는 구조다
(`common-setup.sh:114-119`, `cephadm-setup.sh:20`).

26.04에서는 호스트 cephadm이 **v20**이 되어 v19 클러스터를 부트스트랩하게 된다 — 릴리스를 건너뛰는 조합이다.
업스트림 `download.ceph.com/debian-squid`에는 `noble`·`resolute` dist가 **모두 없어**(404, `jammy`만 존재)
26.04에서 Squid cephadm을 조달할 경로도 없다.

> **판정.** Ceph를 19.2.1로 유지하려면 26.04는 **불가**.
> Tentacle v20으로 올리는 선택지는 있으나, 그 경우 `cephadm-rbd.sh`·`cephadm-object-storage.sh`·
> `cephadm-filesystem.sh`의 명령 호환성을 v20 기준으로 전면 재검증해야 한다(본 검토 범위 밖).

### U-4. `python3.12` 패키지가 26.04에 없다

`packages.ubuntu.com`에서 resolute 스위트의 `python3.12` 검색 결과는 **0건**이며, 기본 python3는 **3.14.3**이다.

- `ansible/inventory/group_vars/all.yml:4` → `ansible_python_interpreter: /usr/bin/python3.12`
- `node_base/tasks/packages.yml:22`, `packer/scripts/base.sh:12` → `python3.12` 패키지 설치

선행 문서 **M-4**가 지적한 하드코딩이 26.04에서 실제 장애로 전환된다.
(`ansible.cfg`에 `interpreter_python = auto_silent`가 있으므로 group_vars 한 줄 제거로 해소 가능하나,
패키지 설치 목록의 `python3.12`는 별도로 제거해야 한다.)

### U-5. Kubespray v2.31.0이 26.04를 검증하지 않는다

v2.31.0의 CI 검증 OS는 Ubuntu **22.04·24.04**, Debian 11·12·13, RHEL 계열(CentOS Stream/RHEL/Rocky/Alma) **9·10** 등이며 26.04는 포함되지 않는다.
`local-kubespray-rook-ceph`를 26.04로 옮기면 미지원 조합이 된다.

### U-6. bento/ubuntu-26.04의 libvirt 부팅 버그 (참고)

`bento/ubuntu-26.04` 박스는 존재하나(202606.01.0), libvirt 프로바이더에서 IP를 받지 못해
`Fog::Errors::TimeoutError`로 실패하는 이슈가 **미해결**이다(chef/bento #1684, 2026-06-10 보고).
VirtualBox 프로바이더 랩에는 해당하지 않는다.

### 26.04로 갈 수 있는 시스템

| 시스템 | 판정 | 근거 |
| --- | --- | --- |
| `local-hadoop-vagrant` | ✅ 동일 버전 성립 | Hadoop 3.5.0은 tarball(OS 무관), `openjdk-17-jdk` 26.04에 존재(`17.0.19+10-1~26.04.2`), `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64` 경로 유지 |
| `local-kubeadm-vagrant` | ⚠️ 가능 | 고정된 컨테이너 런타임 버전이 없음(`apt-get install -y containerd` — 22.04에서 이미 2.2.1을 받고 있음). K8s 1.31.4 deb는 배포판 무관 저장소에 존재. 단 22.04→26.04는 LTS 2단계 점프 |
| `local-k3s-ai` | ✅ 가능(미검증) | k3s는 정적 바이너리 + systemd만 요구 |

---

## 5. RHEL 9 — 시스템별 판정

### R-1. `aws-kubeadm-storage-lab` → RHEL 9: 고정 버전이 **하나도 바뀌지 않는다**

이 저장소에서 조건 1(동일 버전)을 완전히 만족하는 **유일한 이주**다.

| 고정 요소 | 현행 (Ubuntu 24.04) | RHEL 9 조달 경로 | 버전 변경? |
| --- | --- | --- | --- |
| Kubernetes | `1.31` (deb `1.31.x-1.1`) | `pkgs.k8s.io/core:/stable:/v1.31/rpm` — `1.31.0`~`1.31.14` 확인 | **없음** |
| containerd | `1.7.22-1` | Docker el9 repo — `containerd.io-1.7.22-3.1.el9.x86_64.rpm` 확인 | **없음** (릴리스 표기만 상이) |
| Flannel | `v0.26.1` | 컨테이너 이미지 — OS 무관 | **없음** |
| Rook | `v1.16.6` | Helm 차트 — OS 무관 | **없음** |
| Ceph | `quay.io/ceph/ceph:v19.2.3` | 컨테이너 이미지 — OS 무관 | **없음** |
| BeeGFS | `7.4.6` | `beegfs_7.4.6/dists/beegfs-rhel9.repo` 확인 (200) | **없음** |
| Python | `/usr/bin/python3.12` | RHEL 9.4+ AppStream `python3.12` — **경로까지 동일** | **없음** |
| pause 이미지 | `3.10` | 컨테이너 이미지 — OS 무관 | **없음** |

#### 이주로 **사라지는** 것 (순이득)

RHEL 9.7의 커널은 **5.14.0-611.5.1**이고, BeeGFS 7.4.6의 상한은 6.11이다.
즉 **커널이 이미 지원 범위 안에 있어, 커널 고정 장치 전체가 불필요해진다.**

제거 대상:
- `packer/scripts/worker_kernel.sh` (전체 ~60줄)
- `ansible/roles/beegfs_prep/tasks/kernel_pin.yml` (전체 ~90줄)
- `/etc/apt/preferences.d/kernel-68-pin`, `apt-mark hold`, `GRUB_DEFAULT` 조작, unattended-upgrades 블랙리스트
- 커널 6.8 전환용 **재부팅 1회**

이와 함께 선행 문서의 **M-1**(`linux-headers-aws` 메타패키지와 APT pin glob 불일치)이 **원인째 소멸**한다.
RHEL에는 해당 메타패키지 구조 자체가 없다.

#### 이주로 **새로 생기는** 위험

| # | 위험 | 내용 |
| --- | --- | --- |
| 1 | **H-4의 상속** | BeeGFS 클라이언트 모듈 빌드에 `kernel-devel-$(uname -r)`이 필요한데, RHEL AMI가 쓰는 RHUI는 통상 **최신 커널의 `kernel-devel`만 보유**한다. 선행 문서 H-4가 `aws-k3s-storage-lab`에서 지적한 위험을 이 랩도 그대로 떠안는다. AMI ID 고정이 사실상 필수 요건이 된다 |
| 2 | **`rbd`/`ceph` 커널 모듈** | RHEL 9에서 두 모듈은 기본 커널 패키지가 아니라 **`kernel-modules-extra`**에 있다. `hci_node/defaults/main.yml`의 `linux-modules-extra-aws`, `linux-headers-aws`를 각각 `kernel-modules-extra`, `kernel-devel`로 치환해야 Rook OSD가 뜬다 |
| 3 | **방화벽** | Ubuntu 랩은 nftables만 켜면 됐으나 RHEL 9는 firewalld가 기본 활성이다. `aws-k3s-storage-lab/packer/.../base.sh`처럼 `systemctl disable --now firewalld`가 필요 |
| 4 | **SELinux** | RHEL 9는 enforcing이 기본이다. k3s 랩은 `k3s-selinux` RPM으로 대응하지만 kubeadm+containerd 조합은 별도 정책 확인이 필요하다 — **미검증** |
| 5 | **기본 사용자** | `ubuntu` → `ec2-user`. Packer `ssh_username`, 모든 `ssh ...@` 대상, Ansible `remote_user` 일괄 변경 |

#### 이주 비용 (버전이 아닌 **구현** 변경)

`apt` → `dnf` 포팅이 실제 작업량이다. 버전 조정이 아니라 모듈 치환이다.

- Ansible: `ansible.builtin.apt` → `dnf`, `apt_repository` → `yum_repository`,
  `community.general.dpkg_selections`(hold) → `dnf` `versionlock` 또는 버전 명시 설치
- Docker 저장소: `download.docker.com/linux/ubuntu` + `{{ distribution_release }}` →
  `download.docker.com/linux/centos/9/x86_64/stable` (RHEL 9는 CentOS 9 경로 사용)
- `node_base/tasks/containerd.yml`은 **Ubuntu 경로가 하드코딩**돼 있다(선행 문서 M-4 후단) — 전면 교체 대상
- Packer 셸 스크립트 3종(`base.sh`, `master.sh`, `worker.sh`) 재작성

> **결론.** `aws-kubeadm-storage-lab` → RHEL 9은 **조건 1을 완전히 만족**한다.
> 버전은 그대로 두고 패키지 매니저 계층만 바꾸면 되며, 부수적으로 가장 취약한 서브시스템
> (커널 6.8 고정)을 통째로 제거한다. 다만 H-4형 `kernel-devel` 위험을 새로 떠안으므로
> **AMI ID 고정이 선행 조건**이다.

### R-2. `local-ceph-kvm` / `local-ceph-vagrant` → RHEL 9(Rocky 9): 버전 정합성이 **개선**된다

현재 두 랩은 호스트 cephadm과 클러스터 이미지 사이에 미세한 어긋남이 있다.

| | 현행 (Ubuntu 24.04) | Rocky 9 |
| --- | --- | --- |
| 호스트 `cephadm` | 배포판 **19.2.3** | `download.ceph.com/rpm-19.2.1/el9/noarch/cephadm-19.2.1-0.el9.noarch.rpm` — **19.2.1 정확 고정 가능** |
| 클러스터 이미지 | `quay.io/ceph/ceph:v19.2.1` | 동일 |

같은 Squid 계열이라 현행이 오작동한다는 뜻은 아니다. 다만 RHEL 9에서는 **호스트 도구와 클러스터 버전을 정확히 일치**시킬 수 있어 조건 1을 더 엄격히 만족한다.

변경 필요 사항:
- `local-ceph-vagrant`: docker-ce → **podman**. cephadm은 podman을 1급으로 지원하며,
  `local-ceph-kvm`이 이미 podman을 쓰고 있어 **두 랩의 런타임이 통일**된다
  (선행 문서 M-3의 드리프트 표면적이 줄어든다)
- 박스: `bento/ubuntu-24.04` → `bento/rockylinux-9` (VirtualBox), libvirt 쪽은 별도 박스 확인 필요
- 디바이스 이름: VirtualBox `sd*` / libvirt `vd*` 구분은 **현행 처리가 그대로 유효**
  (`common-setup.sh:139`가 두 패턴을 모두 확인)
- `local-ceph-kvm`의 `/vagrant` NFS 전제(M-2)는 OS와 무관하게 잔존

### R-3. Kubespray / kubeadm / minikube 계열

| 시스템 | 판정 | 비고 |
| --- | --- | --- |
| `local-kubespray-rook-ceph` | ✅ | Kubespray v2.31.0이 RHEL/Rocky/Alma **9·10을 공식 검증**. Rook v1.20.0은 컨테이너라 OS 무관. 다만 선행 문서 **H-1**(Ruby 히어독 `\b` → 백스페이스)은 OS와 무관하게 **먼저 고쳐야 한다** — Rocky 9로 옮겨도 swap 비활성화는 계속 무효다 |
| `local-kubeadm-vagrant` | ⚠️ | K8s 1.31.4 RPM 확인(`kubeadm-1.31.4-150500.1.1.x86_64.rpm`). 단 현재 배포판 `containerd`(22.04에서 2.2.1)를 쓰는데 RHEL에는 배포판 containerd가 없어 **Docker el9 저장소로 조달처가 바뀐다.** 고정 버전이 없으므로 조건 1 위반은 아니나, 명시적 버전 고정을 권한다 |
| `local-kubespray-cephfs-centos8` | ✅ **적용 완료 (2026-08-15)** | 선행 문서 **B-2**의 정공법 해결책. `local-kubespray-cephfs-rocky9`로 `git mv`하고 박스를 `bento/rockylinux-9` `202510.26.0`으로 교체했다. **M-5**(NetworkManager 비활성화)는 `fc14c70`에서 이미 제거된 상태였고 이주 후에도 되살아나지 않았음을 확인했다. Kubespray v2.25.0이 Rocky 9를 공식 지원함을 릴리스 README로 확인해 **버전을 그대로 유지**했다. OS가 강제한 변경은 CRB 저장소 활성화 한 가지뿐이다 (Rocky 9가 `gdbm-devel`/`uuid-devel`을 CRB로 이동) |
| `local-minikube-kubevirt-centos8` | ✅ **적용 완료 (2026-08-15)** | 사용자 결정으로 rocky 랩에 통합하고 랩을 제거했다. 제거 전 SHA-256 비교로 고유 내용이 없음을 확인했다 |
| `local-minikube-kubevirt-rocky` | ✅ **적용 완료 (2026-08-15)** | `generic/rocky8` → `bento/rockylinux-9` `202510.26.0`. OS가 강제한 변경은 `bridge-utils` 제거 한 가지뿐이다 (RHEL/Rocky 9에서 제공되지 않으며 libvirt 기본 네트워크는 `brctl`을 요구하지 않는다). **3개 랩이 하나의 베이스로 수렴**했다 |

### R-4. RHEL 9에 부적합한 시스템

| 시스템 | 판정 | 근거 |
| --- | --- | --- |
| `local-microk8s-kubeflow-gpu` | ❌ | MicroK8s(snap), Juju, Kubeflow-lite 전 계층이 Ubuntu를 전제한다. RHEL 9에서 snapd는 EPEL 경유 비표준 구성이며, Canonical의 Kubeflow 번들은 RHEL을 검증하지 않는다. 선행 문서 **L-7**이 지적한 "Ubuntu 호스트 전제"를 README에 명시하는 편이 옳다 |
| `local-kubeadm-gpu` | ⚠️ | 기술적으로 가능하나 개편 규모가 크다. NVIDIA 드라이버·container-toolkit 저장소 경로, libvirt `firewall_backend` 설정, cloud-image(`noble-server-cloudimg`), `--os-variant ubuntu24.04`가 모두 Ubuntu 기준이다. 선행 문서가 이 랩을 예외로 두는 방침과도 상충한다 |
| `local-hadoop-vagrant` | ⚠️ | 가능하지만 이득이 없다. `JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64` → RHEL은 `-amd64` 접미사가 없어 경로 변경 필수(선행 문서 **L-1**이 권한 `readlink` 방식으로 고치면 양쪽 모두 대응) |
| `local-k3s-ai` | ✅ | k3s는 RHEL 9를 공식 지원. 다만 SELinux enforcing 환경에서는 `k3s-selinux` 설치가 필요하다 — `aws-k3s-storage-lab`이 이미 쓰는 방식 |

---

## 6. 조건 2 적용: 버전 변경이 불가피한 경우

조건 1을 만족하지 못해 버전 변경을 검토해야 하는 조합은 아래 세 가지다.
**세 가지 모두 현시점에서는 "완전한 호환성 확인"에 도달하지 못했다.**

| # | 조합 | 강제되는 변경 | 검증 상태 |
| --- | --- | --- | --- |
| 1 | 스토리지 랩 → Ubuntu 26.04 | BeeGFS 7.4.6/8.3 → **해당 없음** | **검증 불가.** 26.04를 지원하는 BeeGFS 릴리스가 존재하지 않는다. 상위 버전으로도 해소되지 않으므로 조건 2를 적용할 대상이 아니다 |
| 2 | `aws-kubeadm-storage-lab` → Ubuntu 26.04 | containerd `1.7.22` → `2.2.x`/`2.3.x` | **미완료.** CRI 계층은 호환 가능성이 높으나, `config.toml` 스키마 v2→v3 전환으로 현행 `sed` 기반 설정(`SystemdCgroup`, `sandbox_image`)이 무효화된다. 1번으로 이미 차단이라 추가 검증은 보류 |
| 3 | `local-ceph-*` → Ubuntu 26.04 | Ceph Squid `19.2.1` → Tentacle `20.2.x` | **미완료.** `cephadm-rbd.sh` / `cephadm-filesystem.sh` / `cephadm-object-storage.sh`의 CLI 호환성을 v20 기준으로 재검증해야 한다. 별도 과제 |

> 조건 2의 문언대로라면 위 세 조합은 **모두 보류**가 맞다.
> 반대로 RHEL 9 이주는 조건 2를 발동시키지 않는다 — 버전 변경이 필요 없기 때문이다.

---

## 7. 권고

### 7.1 Ubuntu 26.04

**현시점 이주 보류.** 스토리지 랩 5개(`aws-k3s-storage-lab`, `aws-kubeadm-storage-lab`,
`local-ceph-kvm`, `local-ceph-vagrant`, `local-kubespray-rook-ceph`)가 차단되며,
차단 사유가 **BeeGFS·Ceph·Kubespray라는 서드파티 릴리스 일정**에 달려 있어 저장소 내부 수정으로 풀 수 없다.

재검토 트리거:
- BeeGFS가 `dists/resolute`를 게시할 때 (7.4.x 또는 8.x)
- Kubespray가 CI에 Ubuntu 26.04를 추가할 때

비스토리지 랩(`local-hadoop-vagrant`, `local-k3s-ai`)만 먼저 옮기는 선택지는 있으나,
`devops/README.md`의 "시스템별 자립" 정책상 OS 파편화만 늘리므로 권하지 않는다.

### 7.2 RHEL 9

우선순위 순:

| 순위 | 대상 | 상태 | 근거 |
| --- | --- | --- | --- |
| 1 | CentOS 8 랩 2개 → **Rocky 9** | ✅ **완료 (2026-08-15)** | 선행 문서 **B-2**의 정공법 해결. 이전에는 `vagrant up`조차 되지 않았다 |
| 2 | `local-minikube-kubevirt-rocky` → **Rocky 9** | ✅ **완료 (2026-08-15)** | 위 2개와 합쳐 3개 랩이 `bento/rockylinux-9` 단일 베이스로 수렴했다 |
| 3 | `aws-kubeadm-storage-lab` → **RHEL 9** | ⬜ 미적용 | 유일하게 전 버전이 그대로 유지되는 이주이며, 커널 6.8 고정 장치 150여 줄과 **M-1** 결함을 함께 제거. 단 **AMI ID 고정(H-4 대응)이 선행 조건** |
| 4 | `local-ceph-*` → **Rocky 9** | ⬜ 미적용 | cephadm 19.2.1 정확 고정 + podman 통일. 이득은 있으나 급하지 않음. 선행 문서 **M-3**(쌍둥이 랩 zap 하드닝 드리프트)이 아직 잔존하므로 이주 전 동기화가 필요하다 |
| 5 | `local-kubespray-rook-ceph` → **Rocky 9** | ⬜ 미적용 | 선택. 전제였던 **H-1**은 2026-08-15에 해결됐다 |

### 7.3 이주 전 선결 과제 — ✅ 전부 해소

OS 이주는 아래를 해결한 **뒤에** 착수해야 했다. 그렇지 않으면 깨진 코드를 그대로 옮기게 된다.
**세 항목 모두 우선순위 1·2 착수 시점에 해소된 상태였다.**

1. 선행 문서 **B-1** — 셸 스크립트 16개 구문 오류. ✅ `fc14c70`에서 복구됐다.
   현재 추적 중인 셸 99개 전부 `bash -n`을 통과하고 추적 파일 전체가 UTF-8 검증을 통과한다.
   다만 **재발 방지 CI 게이트는 여전히 없다.**
2. 선행 문서 **H-1** — Vagrantfile 히어독 `<<-'SHELL'`. ✅ 2026-08-15에 적용했다.
   Vagrant 내장 ruby로 실제 평가해 백스페이스 바이트 0개를 확인했다.
3. 선행 문서 **M-5** — CentOS 8 랩의 NetworkManager 비활성화. ✅ `fc14c70`에서 제거됐고,
   Rocky 9 이주 후에도 되살아나지 않았음을 확인했다.

우선순위 3~5를 착수할 때는 **H-4(AMI ID 고정)**와 **M-3(쌍둥이 랩 드리프트)**가
각각 3번과 4번의 선행 조건이라는 점에 유의한다.

---

## 8. 미검증 항목

부팅·실행 검증을 하지 않았으므로 아래는 **가정**으로 남는다.

| 항목 | 내용 |
| --- | --- |
| RHEL 9 + kubeadm + containerd의 SELinux | k3s는 `k3s-selinux`로 대응하지만, kubeadm 경로는 enforcing 환경에서 별도 정책이 필요한지 확인하지 않았다 |
| RHUI `kernel-devel` 가용성 | AMI 릴리스 시점 커널의 `kernel-devel-$(uname -r)`이 RHUI에 실제로 있는지 부팅 없이는 확인 불가 (H-4와 동일한 미검증 가정) |
| BeeGFS 7.4.6 RHEL 9 클라이언트 모듈 빌드 | `beegfs-rhel9.repo` 존재는 확인했으나, RHEL 9.7 커널 5.14.0-611에서 실제 빌드가 통과하는지는 미검증 |
| `bento/rockylinux-9`의 VirtualBox 프로바이더 동작 | `builds.yml`에 항목이 있음은 확인했으나 실제 `vagrant up`은 미시도 |
| MicroK8s/Kubeflow의 Ubuntu 26.04 동작 | snap 기반이라 원리상 가능하나 Canonical의 26.04 검증 여부 불명 |
| Ubuntu 26.04 AMI의 cloud-init/기본 사용자 | AMI 존재는 확인(`ami-0d0353075b90e6937`, ap-northeast-2). 기본 사용자가 `ubuntu`로 유지되는지는 미검증 |

---

## 적용 이력

### 2026-08-15 — 우선순위 1·2 적용

**조건 1(동일 버전 유지)을 완전히 만족했다.** 이주로 바뀐 상위 버전은 하나도 없다:
K8s 1.29.5, Kubespray v2.25.0(+커밋 `7e0a4072`), Flannel v0.22.0, MetalLB v0.13.9,
Python 3.11.9, Rook v1.14.8, Ceph v18.2.2, Minikube v1.38.1, KubeVirt v1.8.2.
따라서 **조건 2(변경 시 호환성 확인)는 발동하지 않았다.**

OS가 강제한 구현 변경은 두 가지뿐이다.

| 변경 | 사유 |
| --- | --- |
| `kubespray.sh`에 CRB 저장소 활성화 추가 | Rocky 9가 `gdbm-devel`·`uuid-devel`을 CRB로 이동 |
| `kubevirt_install.sh`에서 `bridge-utils` 제거 | RHEL/Rocky 9에서 제공되지 않음. libvirt 기본 네트워크는 `brctl`을 요구하지 않는다 |

검증 근거:

- 박스 `bento/rockylinux-9` `202510.26.0`이 active이며 `virtualbox/amd64` 프로바이더를
  제공함을 Vagrant Cloud API로 확인
- Kubespray v2.25.0 README의 지원 배포판 목록에 **Rocky Linux 8, 9**가 명시돼 있고,
  `git ls-remote`의 `refs/tags/v2.25.0` 커밋이 고정값과 일치함을 확인
- Vagrantfile 8개 `ruby -c` 통과, 셸 99개 `bash -n` 통과, 추적 파일 전체 UTF-8 검증 통과

### 미적용 (판정은 현재도 유효)

| 항목 | 상태 |
| --- | --- |
| 우선순위 3 `aws-kubeadm-storage-lab` → RHEL 9 | 미적용. **H-4(AMI ID 고정)가 선행 조건** |
| 우선순위 4 `local-ceph-*` → Rocky 9 | 미적용. **M-3(쌍둥이 랩 드리프트)가 선행 조건** |
| 우선순위 5 `local-kubespray-rook-ceph` → Rocky 9 | 미적용. 전제였던 H-1은 해결됨 |
| 선행 문서 **H-3** | 미해결. `local-hadoop-vagrant`, `local-minikube-kubevirt-rocky` 2개 랩이 VirtualBox 허용 대역 밖이라 현재도 `vagrant up` 실패 |
| **Ubuntu 26.04 이주** | §7.1 판단대로 계속 보류. BeeGFS·Ceph·Kubespray의 서드파티 릴리스 일정에 달려 있어 저장소 내부 수정으로 풀 수 없다 |
