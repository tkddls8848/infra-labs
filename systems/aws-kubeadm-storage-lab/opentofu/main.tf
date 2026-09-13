terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ── Bastion IAM Role (동적 인벤토리용 최소 권한) ──
resource "aws_iam_role" "bastion" {
  name = "${var.project_name}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "bastion_ec2_read" {
  name = "ec2-describe"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "ec2:DescribeTags"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project_name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

module "vpc" {
  source       = "./modules/vpc"
  project_name = var.project_name
  vpc_cidr     = var.vpc_cidr
  aws_region   = var.aws_region
}

module "security_group" {
  source       = "./modules/security_group"
  project_name = var.project_name
  vpc_id       = module.vpc.vpc_id
  vpc_cidr     = var.vpc_cidr
}

module "ec2" {
  source              = "./modules/ec2"
  project_name        = var.project_name
  ami_id              = data.aws_ami.ubuntu.id
  ami_bastion         = var.ami_bastion
  ami_master          = var.ami_master
  ami_worker          = var.ami_worker
  key_name            = var.key_name
  subnet_bastion_id   = module.vpc.subnet_bastion_id
  subnet_k8s_id       = module.vpc.subnet_k8s_id
  sg_bastion_id       = module.security_group.sg_bastion_id
  sg_k8s_id           = module.security_group.sg_k8s_id
  master_count        = var.master_count
  worker_count        = var.worker_count
  bastion_iam_profile = aws_iam_instance_profile.bastion.name
}

module "ebs" {
  source              = "./modules/ebs"
  project_name        = var.project_name
  availability_zone   = "${var.aws_region}a"
  worker_instance_ids = module.ec2.worker_instance_ids
  worker_count        = var.worker_count
}
