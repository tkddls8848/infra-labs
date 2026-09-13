# Local kubeadm Vagrant Lab

VirtualBox와 Vagrant로 kubeadm 기반 Kubernetes 실습 클러스터를 만드는 로컬 랩입니다. 운영 환경이 아니라 네트워크, 노드 조인, Flannel, KubeVirt 설치 흐름을 재현하는 용도입니다.

## 클러스터 구성

| 노드 | 역할 | 주소 | CPU | 메모리 |
|---|---|---:|---:|---:|
| `k8s-master` | control plane | `192.168.56.10` | 4 | 4 GiB |
| `k8s-worker-1` | worker | `192.168.56.11` | 2 | 2 GiB |
| `k8s-worker-2` | worker | `192.168.56.12` | 2 | 2 GiB |

- Pod CIDR: `10.244.0.0/16`
- Service CIDR: `10.96.0.0/12`
- CNI: Flannel `v0.28.5`
- Kubernetes: `1.31.4`
- Guest OS: `bento/ubuntu-22.04`

버전과 클러스터 CIDR의 기준 파일은 [`inventory/group_vars.yml`](inventory/group_vars.yml)입니다. 기본 `Vagrantfile`과 KubeVirt 애드온 `Vagrantfile`은 이 파일을 직접 읽습니다. 노드 주소와 Ansible 그룹은 [`inventory/inventory.ini`](inventory/inventory.ini)에 있습니다.

## 기본 클러스터 사용

VirtualBox와 Vagrant를 설치한 뒤 이 디렉터리에서 실행합니다.

```bash
vagrant up
vagrant ssh k8s-master
kubectl get nodes -o wide
```

클러스터를 삭제하려면 다음 명령을 사용합니다.

```bash
vagrant destroy -f
```

`kubeadm-master.sh`가 `/vagrant/.generated/kubeadm/join-command.sh`를 만들고 worker 프로비저너가 최대 600초 동안 이 파일을 기다립니다.

## KubeVirt 애드온 랩

KubeVirt는 기본 클러스터에 추가 설치하는 명령이 아니라, 별도의 Vagrant 정의로 독립된 3노드 랩을 만듭니다. 기본 랩과 VM 이름 및 SSH 전달 포트가 같으므로 두 랩을 동시에 실행하지 마십시오.

```bash
cd scripts/addons/kubevirt
vagrant up
INSTALL_KUBEVIRT=1 vagrant provision k8s-master
vagrant ssh k8s-master
kubectl -n kubevirt get pods -o wide
```

애드온 랩은 `192.168.60.10-12`를 사용하며 Kubernetes/Flannel 버전은 기본 inventory에서 읽습니다. `INSTALL_KUBEVIRT=1`을 지정한 두 번째 명령은 worker 조인이 끝난 뒤에만 애드온을 설치하도록 분리한 단계입니다. KubeVirt는 `v1.8.2`로 고정되어 있습니다. 설치 스크립트는 저장소의 `manifests/kubevirt-operator.yaml`과 `manifests/kubevirt-cr.yaml`만 적용하고 SHA-256을 확인한 뒤 `virt-operator`, `virt-api`, `virt-controller` 및 KubeVirt CR의 준비 상태를 제한 시간 내에 검증합니다.

```bash
vagrant destroy -f
```

## 랩 전제와 제한

- VirtualBox provider와 host-only network를 전제로 합니다.
- KubeVirt VM 실행에는 호스트 CPU 가상화와 중첩 가상화 지원이 필요합니다.
- Flannel 매니페스트와 고정 버전 `virtctl` 바이너리를 설치 시 GitHub에서 내려받으므로 인터넷 연결이 필요합니다. `virtctl`도 고정 SHA-256을 확인하며 KubeVirt operator/CR 매니페스트는 저장소에 포함되어 있습니다.
- 단일 control plane, 고정 IP, 공유 join 파일은 로컬 실습을 위한 선택이며 운영용 고가용성 또는 보안 구성이 아닙니다.
- 노드 자원은 최소 실습값입니다. KubeVirt 워크로드를 실행할 때는 호스트 여유 자원에 맞게 늘리십시오.
