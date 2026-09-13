variable "project_name"        { type = string }
variable "ami_id"              { type = string }
variable "ami_bastion" {
  type        = string
  default     = null
  description = "Packer k8s-bastion AMI ID (null이면 ami_id 사용)"
}
variable "ami_master" {
  type        = string
  default     = null
  description = "Packer k8s-master AMI ID (null이면 ami_id 사용)"
}
variable "ami_worker" {
  type        = string
  default     = null
  description = "Packer k8s-worker AMI ID (null이면 ami_id 사용)"
}
variable "key_name"            { type = string }
variable "subnet_bastion_id"   { type = string }
variable "subnet_k8s_id"       { type = string }
variable "sg_bastion_id"       { type = string }
variable "sg_k8s_id"           { type = string }
variable "master_count"        { type = number }
variable "worker_count"        { type = number }
variable "bastion_iam_profile" { type = string }
