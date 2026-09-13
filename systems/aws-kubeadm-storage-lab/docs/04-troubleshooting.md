# 04. 트러블슈팅

---

## 인프라 (OpenTofu)

### `tofu apply` 시 Key Pair 오류
```
Error: InvalidKeyPair.NotFound
```
`terraform.tfvars`의 `key_name`이 해당 리전에 없음.
```bash
aws ec2 describe-key-pairs --region ap-northeast-2 --query 'KeyPairs[].KeyName'
```

### user_data 실행 실패
```bash
ssh -i ~/.ssh/storage-lab.pem ubuntu@<ip>
sudo cat /var/log/cloud-init-output.log
```

---

## SSH / 부팅

### SSH 타임아웃
인스턴스 부팅 미완료 또는 SG 문제. `start_k8s.sh`는 SSH 루프로 자동 대기.
수동 확인:
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-storage-lab-*" \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`].Value|[0],State.Name,PublicIpAddress]' \
  --output table
```

---

## Kubernetes

### kube-proxy CrashLoopBackOff (exit code 2)
**원인**: Ubuntu 24.04 nftables 환경에서 kube-proxy iptables 모드 기동 시
Flannel과 `/run/xtables.lock` 경합.

**현재 구성**: `kubeadm init` 시 `KubeProxyConfiguration mode: nftables` 기본 적용으로 재발 없음.

수동 적용:
```bash
kubectl -n kube-system get configmap kube-proxy -o yaml \
  | sed 's/mode: ""/mode: "nftables"/' \
  | kubectl apply -f -
kubectl -n kube-system rollout restart daemonset kube-proxy
```

### kubeadm init 실패 (etcd context deadline)
```bash
ssh ubuntu@<master-1-ip>
sudo kubeadm reset -f
sudo rm -rf /etc/cni /etc/kubernetes /var/lib/kubelet /var/lib/etcd ~/.kube
sudo systemctl restart containerd
```
이후 `start_k8s.sh` 재실행.

### Master-2/3 control-plane join 실패 (certificate-key 만료)
kubeadm certificate-key는 2시간 유효. 만료 시:
```bash
# master-1에서
sudo kubeadm init phase upload-certs --upload-certs
# 출력된 cert-key로 재시도
sudo kubeadm join BASTION_PRIVATE_IP:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane \
  --certificate-key <NEW_CERT_KEY> \
  --node-name master-2
```

### HAProxy health check 실패 (master backend DOWN)
```bash
# bastion에서
sudo cat /etc/haproxy/haproxy.cfg
curl http://localhost:9000/stats
# 특정 master가 DOWN이면 해당 master의 kubelet 확인
ssh ubuntu@<master-ip> "sudo systemctl status kubelet"
```

### Worker join 실패 (token 만료)
```bash
# master-1에서
sudo kubeadm token create --print-join-command
```

### Flannel Pod Pending / 노드 NotReady
```bash
VER=v0.26.1
kubectl delete -f https://github.com/flannel-io/flannel/releases/download/${VER}/kube-flannel.yml
kubectl apply  -f https://github.com/flannel-io/flannel/releases/download/${VER}/kube-flannel.yml
```

### Worker 커널 고정 실패 (NotReady, SSH 거절)
kernel_pin.yml reboot 후 복구 타임아웃:
```bash
# EC2 강제 재시작
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-ip-address,Values=<worker-ip>" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
aws ec2 reboot-instances --instance-ids $INSTANCE_ID

# 복구 대기
until ssh -o ConnectTimeout=5 <worker-name> "uname -r" 2>/dev/null; do
  echo "waiting..."; sleep 10
done
# 이후 start_beegfs.sh 재실행 (이미 6.8이면 pin 스킵)
```

---

## rook-ceph

### OSD Pod가 생성되지 않음

rbd 모듈 미로드 확인:
```bash
ssh ubuntu@<worker-ip> "lsmod | grep rbd || sudo modprobe rbd"
```

디스크에 기존 시그니처가 남아있는 경우:
```bash
bash scripts/lifecycle/destroy_ceph.sh && bash scripts/lifecycle/start_ceph.sh
```

### Ceph HEALTH_WARN TOO_FEW_OSDS
`osd_pool_default_size: "2"`에서 OSD 2개 이상이면 정상.
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
```

### rook-ceph-tools 상태 확인
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph df
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
```

---

## BeeGFS

### beegfs-mgmtd/meta Pod CrashLoopBackOff (Exit Code 127)
바이너리 경로 오류. BeeGFS 7.4.6은 `/opt/beegfs/sbin/`에 설치됨.
```bash
kubectl -n beegfs-system logs deploy/beegfs-mgmtd
# master-1에서 바이너리 위치 확인
find /opt/beegfs/sbin -name 'beegfs-mgmtd'
# 설치 여부 확인
ls /opt/beegfs/sbin/
```

### beegfs-mgmtd/meta/storage Pod CrashLoopBackOff (Exit Code 3)
`connDisableAuthentication` 미설정. 기존 패키지 기본값은 `false`.
```bash
kubectl -n beegfs-system logs deploy/beegfs-mgmtd
# 오류 예시: "No connAuthFile configured... set connDisableAuthentication to true"
# master-1에서 conf 확인
grep connDisableAuthentication /etc/beegfs/beegfs-mgmtd.conf
# fix: ansible beegfs.yml 재실행 (force: yes로 conf 덮어쓰기)
```

### beegfs-exporter OOMKilled
exporter가 ubuntu:24.04에서 python3 apt-get 설치 시 메모리 초과.
현재 구성: `python:3.12-slim` 이미지 사용 (apt-get 불필요).
```bash
kubectl -n beegfs-system describe pod <exporter-pod>
# limits.memory: 128Mi 확인
```

### storaged DaemonSet Pod Pending (node selector 불일치)
Worker 노드에 `role=worker` 레이블 확인:
```bash
kubectl get nodes --show-labels | grep worker
# 레이블이 없으면
kubectl label node worker-1 role=worker
```

### BeeGFS 스토리지 디스크 마운트 실패
```bash
ssh -i ~/.ssh/storage-lab.pem ubuntu@<worker-ip>
lsblk                     # nvme3n1 확인
sudo blkid /dev/nvme3n1   # 파일시스템 확인
mount | grep beegfs       # 마운트 여부 확인
```

### BeeGFS 재설치
```bash
bash scripts/lifecycle/destroy_beegfs.sh && bash scripts/lifecycle/start_beegfs.sh
```

---

## PVC / CSI

### PVC Pending 상태 지속
```bash
kubectl describe pvc <pvc-name>
kubectl logs -n rook-ceph deploy/rook-ceph-operator | tail -50
```

### StorageClass 없음
```bash
kubectl get storageclass
# ceph-rbd, ceph-cephfs 없으면
bash scripts/lifecycle/start_ceph.sh

# beegfs-scratch 없으면
bash scripts/lifecycle/start_beegfs.sh
```
