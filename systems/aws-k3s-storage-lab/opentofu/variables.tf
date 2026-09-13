variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 이름 prefix"
  type        = string
  default     = "k3s-storage-lab"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "key_name" {
  description = "AWS EC2 Key Pair 이름 (terraform.tfvars에서 설정)"
  type        = string
}

variable "ami_frontend" {
  description = "Packer k3s-frontend AMI ID (미설정 시 RHEL 9 최신 AMI 자동 사용)"
  type        = string
  default     = null
}

variable "ami_backend" {
  description = "Packer k3s-backend AMI ID (미설정 시 RHEL 9 최신 AMI 자동 사용)"
  type        = string
  default     = null
}
