# infra-labs

Kubernetes·Ceph·BeeGFS·Hadoop 등 인프라 학습 랩을 모아둔 저장소다. 각 랩은 로컬(Vagrant·KVM)
또는 AWS 위에서 독립적으로 올렸다 내릴 수 있고, 자기 README를 가진다.

## 구성

| 위치 | 내용 |
|---|---|
| [`systems/`](systems/) | 실행 가능한 랩 |
| [`docs/`](docs/) | 검토·호환성·마이그레이션 문서 |

### systems/

| 랩 | 내용 |
|---|---|
| [`aws-k3s-storage-lab/`](systems/aws-k3s-storage-lab/) | AWS k3s 스토리지 랩 |
| [`aws-kubeadm-storage-lab/`](systems/aws-kubeadm-storage-lab/) | AWS kubeadm 스토리지 랩 |
| [`local-ceph-kvm/`](systems/local-ceph-kvm/) | libvirt/KVM 기반 로컬 Ceph 랩 |
| [`local-ceph-vagrant/`](systems/local-ceph-vagrant/) | VirtualBox 기반 로컬 Ceph 랩 |
| [`local-hadoop-vagrant/`](systems/local-hadoop-vagrant/) | Ubuntu Vagrant Hadoop 랩 |
| [`local-k3s-ai/`](systems/local-k3s-ai/) | 로컬 K3s AI 랩 |
| [`local-kubeadm-gpu/`](systems/local-kubeadm-gpu/) | KVM 마스터 + 베어메탈 GPU 워커 클러스터 |
| [`local-kubeadm-vagrant/`](systems/local-kubeadm-vagrant/) | 로컬 kubeadm Vagrant 랩 |
| [`local-kubespray-cephfs-rocky9/`](systems/local-kubespray-cephfs-rocky9/) | Rocky Linux 9 Kubespray + Rook CephFS |
| [`local-kubespray-rook-ceph/`](systems/local-kubespray-rook-ceph/) | 로컬 Kubespray + Rook Ceph |
| [`local-microk8s-kubeflow-gpu/`](systems/local-microk8s-kubeflow-gpu/) | MicroK8s Kubeflow GPU 랩 |
| [`local-minikube-kubevirt-rocky/`](systems/local-minikube-kubevirt-rocky/) | Rocky 9 Minikube + KubeVirt 랩 |
| [`local-spectrum-scale-ces-s3/`](systems/local-spectrum-scale-ces-s3/) | IBM Storage Scale CES S3 축소 랩 |

### docs/

- [`kubernetes-review-fix-list.md`](docs/kubernetes-review-fix-list.md)
- [`os-compatibility-review.md`](docs/os-compatibility-review.md)
- [`os-migration-rhel9-ubuntu2604.md`](docs/os-migration-rhel9-ubuntu2604.md)
- [`spectrum-scale-ces-lab-feasibility.md`](docs/spectrum-scale-ces-lab-feasibility.md)

## 비밀정보와 상태 파일

Terraform/OpenTofu state, VM 디스크 이미지, `kubeconfig`, 클러스터 join 시크릿, `.env`,
SSH 키는 커밋하지 않는다. 랩마다 커밋하는 `*.tfvars` 는 실제 값이 아니라 플레이스홀더다.
폴더 구조를 바꿀 때는 `.gitignore` 의 `systems/**` 접두사도 같이 고친다.
