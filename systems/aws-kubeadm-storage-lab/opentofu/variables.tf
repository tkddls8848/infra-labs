variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "리소스 이름 prefix"
  type        = string
  default     = "k8s-storage-lab"
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

variable "master_count" {
  description = "K8s Master 노드 수 (etcd HA quorum: 3 권장)"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "K8s Worker(HCI) 노드 수"
  type        = number
}

variable "ami_bastion" {
  description = "Packer k8s-bastion AMI ID (미설정 시 Ubuntu 최신 AMI 자동 사용)"
  type        = string
  default     = null
}

variable "ami_master" {
  description = "Packer k8s-master AMI ID (미설정 시 Ubuntu 최신 AMI 자동 사용)"
  type        = string
  default     = null
}

variable "ami_worker" {
  description = "Packer k8s-worker AMI ID (미설정 시 Ubuntu 최신 AMI 자동 사용)"
  type        = string
  default     = null
}
