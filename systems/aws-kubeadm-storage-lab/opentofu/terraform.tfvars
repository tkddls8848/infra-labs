key_name     = "storage-lab"   # ← 본인 Key Pair 이름으로 변경
project_name = "k8s-storage-lab"
aws_region   = "ap-northeast-2"
worker_count = 3               # K8s Worker(HCI) 노드 수

# Packer AMI 사용 시 아래 주석 해제 (packer build 출력값으로 교체)
# ami_bastion = "ami-0aaa..."   # packer build bastion 출력값
# ami_master  = "ami-0bbb..."   # packer build master 출력값
# ami_worker  = "ami-0ccc..."   # packer build worker 출력값
