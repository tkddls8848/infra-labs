packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "aws_region" { default = "ap-northeast-2" }
variable "base_ami"   { description = "RHEL 9 AMI ID (Phase 0 aws ec2 describe-images 명령으로 확인)" }
variable "key_name"          { description = "EC2 Key Pair 이름" }
variable "ssh_private_key_file" { description = "로컬 프라이빗 키 경로 (예: ~/.ssh/storage-lab.pem)" }

