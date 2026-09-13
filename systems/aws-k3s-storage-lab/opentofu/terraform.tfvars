key_name     = "storage-lab"   # ← 본인 Key Pair 이름으로 변경
project_name = "k3s-storage-lab"
aws_region   = "ap-northeast-2"

# Packer AMI 사용 시 아래 주석 해제 (packer build 출력값으로 교체)
 ami_frontend = "ami-098bf0bb69a017084"   # packer build frontend 출력값
 ami_backend  = "ami-0e57ecbc11f4e0861"   # packer build backend 출력값
