variable "project_name"   { type = string }
variable "ami_id"         { type = string }
variable "ami_frontend" {
  type        = string
  default     = null
  description = "Packer k3s-frontend AMI ID (null이면 ami_id 사용)"
}
variable "ami_backend" {
  type        = string
  default     = null
  description = "Packer k3s-backend AMI ID (null이면 ami_id 사용)"
}
variable "key_name"       { type = string }
variable "subnet_id"      { type = string }
variable "sg_frontend_id" { type = string }
variable "sg_backend_id"  { type = string }
variable "aws_region"     { type = string }
