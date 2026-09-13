packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

variable "aws_region"           { default = "ap-northeast-2" }
variable "base_ami"             { description = "Ubuntu 24.04 AMI ID" }
variable "key_name"             { description = "EC2 Key Pair 이름" }
variable "ssh_private_key_file" { description = "로컬 프라이빗 키 경로 (예: ~/.ssh/storage-lab.pem)" }
