# 05. 온프레미스 전환 가이드

현재 코드는 AWS 기반으로 작성되어 있습니다. 온프레미스 환경에 적용 시 수정이 필요한 항목을 정리합니다.

---

## 제거 항목

| 항목 | 이유 |
|------|------|
| `opentofu/` 전체 | AWS EC2/EBS/VPC 프로비저닝 불필요 |
| `start_k8s.sh` 중 tofu 관련 블록 | EC2 생성 불필요 |
| `pause.sh` / `resume.sh` | EC2 중지/시작 불필요 |
| `worker_add.sh`, `worker_remove.sh` 중 tofu 블록 | EC2 생성/삭제 불필요 |
| `ansible/roles/addons/tasks/metallb.yml` 중 Source/Dest Check 비활성화 | AWS EC2 전용 API |

---

## 1. Ansible 인벤토리 교체

현재 AWS EC2 동적 인벤토리(`aws_ec2.yml`)를 정적 인벤토리로 교체합니다.

**온프레미스 교체:**
```ini
# ansible/inventory/hosts.ini
[master]
master-1 ansible_host=192.168.1.10
master-2 ansible_host=192.168.1.11
master-3 ansible_host=192.168.1.12

[worker]
worker-1 ansible_host=192.168.1.21
worker-2 ansible_host=192.168.1.22
worker-3 ansible_host=192.168.1.23

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/storage-lab.pem
```

---

## 2. ec2_tags 참조 제거

노드명을 AWS 태그에서 추출하는 코드를 `inventory_hostname` 직접 사용으로 변경합니다.

### worker/tasks/main.yml

**현재 (AWS):**
```yaml
worker_node_name: >-
  {{ hostvars[inventory_hostname]['ec2_tags']['Name'] | regex_replace('k8s-storage-lab-', '')
     if not kubelet_conf.stat.exists
     else ansible_facts['hostname'] }}
```

**온프레미스:**
```yaml
worker_node_name: >-
  {{ inventory_hostname
     if not kubelet_conf.stat.exists
     else ansible_facts['hostname'] }}
```

### control_plane/tasks/main.yml, control_plane_join/tasks/main.yml

동일하게 `ec2_tags` 참조 제거:
```yaml
master_node_name: >-
  {{ inventory_hostname
     if not k8s_admin_conf.stat.exists
     else ansible_facts['hostname'] }}
```

### playbooks/k8s.yml (HA master 구분 조건)

**현재 (AWS):**
```yaml
when: hostvars[inventory_hostname]['ec2_tags']['Name'] == project_name + '-master-1'
```

**온프레미스:**
```yaml
when: inventory_hostname == groups['master'][0]
```

### playbooks/k8s.yml (/etc/hosts 설정 플레이)

**현재 (AWS):**
```yaml
line: >-
  {{ hostvars[item]['ansible_host'] }}
  {{ hostvars[item]['ec2_tags']['Name'] | regex_replace('k8s-storage-lab-', '') }}
```

**온프레미스:**
```yaml
line: >-
  {{ hostvars[item]['ansible_host'] }}
  {{ item }}
```

---

## 3. group_vars/all.yml

AWS 전용 변수 제거:

**제거 대상:**
```yaml
aws_region: "ap-northeast-2"
project_name: "k8s-storage-lab"
```

**control_plane_endpoint** 고정값으로 설정 (HAProxy 호스트 또는 VIP):
```yaml
control_plane_endpoint: "192.168.1.100"  # HAProxy 또는 L4 VIP
```

---

## 4. MetalLB

온프레미스에서는 ARP가 정상 동작하므로 MetalLB L2 모드 **그대로 사용 가능**.
단, AWS EC2 Source/Dest Check 비활성화 태스크만 제거합니다.

**IP 대역 변경** (`ansible/roles/addons/defaults/main.yml`):
```yaml
metallb_ip_range: "192.168.1.200-192.168.1.220"
```

---

## 5. HAProxy

온프레미스 HA 구성 시 HAProxy를 별도 서버 또는 마스터 앞단 L4 스위치로 대체 가능.
`control_plane_endpoint`는 해당 VIP/LB 주소로 설정합니다.

---

## 6. BeeGFS 스토리지 디스크

온프레미스에서는 EBS 대신 물리 디스크를 사용합니다.

`ansible/roles/beegfs_prep/defaults/main.yml`:
```yaml
beegfs_storage_device: /dev/sdb   # 실제 디스크 경로로 변경
```

---

## 7. Ansible Collections

온프레미스에서는 `amazon.aws` collection 불필요:
```bash
ansible-galaxy collection install \
  ansible.posix \
  community.general \
  community.crypto
```

---

## 변경 범위 요약

| 파일 | 변경 내용 | 난이도 |
|------|-----------|--------|
| `ansible/inventory/aws_ec2.yml` | → `hosts.ini` 교체 | 낮음 |
| `ansible/roles/worker/tasks/main.yml` | ec2_tags 제거 | 낮음 |
| `ansible/roles/control_plane*/tasks/main.yml` | ec2_tags → inventory_hostname | 낮음 |
| `ansible/playbooks/k8s.yml` | ec2_tags 참조 제거, master-1 구분 조건 | 낮음 |
| `ansible/roles/addons/tasks/metallb.yml` | Source/Dest Check 태스크 제거 | 낮음 |
| `ansible/roles/addons/defaults/main.yml` | metallb_ip_range 변경 | 낮음 |
| `ansible/roles/beegfs_prep/defaults/main.yml` | beegfs_storage_device 변경 | 낮음 |
| `ansible/inventory/group_vars/all.yml` | aws_region 제거, control_plane_endpoint 고정 | 낮음 |
| `start_k8s.sh` | tofu 블록 제거, ansible-playbook 직접 실행 | 중간 |
| `opentofu/` | 전체 미사용 | - |

> Ansible 역할 대부분(k8s_common, control_plane*, worker, cni, addons, beegfs_prep)은 수정 없이 그대로 사용 가능합니다.
