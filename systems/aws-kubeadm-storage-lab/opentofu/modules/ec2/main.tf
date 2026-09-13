locals {
  # Packer AMI 사용 시: bastion은 ansible-ready 신호만, master/worker는 user_data 불필요
  bastion_user_data = var.ami_bastion != null ? "#!/bin/bash\ntouch /tmp/ansible-ready\n" : file("${path.module}/user_data/bastion.sh")
  master_user_data  = var.ami_master  != null ? null : file("${path.module}/user_data/common.sh")
  worker_user_data  = var.ami_worker  != null ? null : file("${path.module}/user_data/worker.sh")
}

# ── Bastion 노드 (Ansible 제어 노드 + HAProxy) ──
resource "aws_instance" "bastion" {
  ami                    = coalesce(var.ami_bastion, var.ami_id)
  instance_type          = "t3.small"
  key_name               = var.key_name
  subnet_id              = var.subnet_bastion_id
  vpc_security_group_ids = [var.sg_bastion_id]
  iam_instance_profile   = var.bastion_iam_profile
  user_data              = local.bastion_user_data

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-bastion"
    Role = "bastion"
  }
}

# ── Master 노드 (HA 3식, t3.large: etcd + BeeGFS mgmtd/meta + Ceph CSI 안정성) ──
resource "aws_instance" "master" {
  count                  = var.master_count
  ami                    = coalesce(var.ami_master, var.ami_id)
  instance_type          = "t3.large"
  key_name               = var.key_name
  subnet_id              = var.subnet_k8s_id
  vpc_security_group_ids = [var.sg_k8s_id]
  user_data              = local.master_user_data

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-master-${count.index + 1}"
    Role = "master"
  }
}

# ── Worker 노드 (HCI: k8s + Ceph OSD + BeeGFS storaged) ──
resource "aws_instance" "worker" {
  count                  = var.worker_count
  ami                    = coalesce(var.ami_worker, var.ami_id)
  instance_type          = "m5.large"
  key_name               = var.key_name
  subnet_id              = var.subnet_k8s_id
  vpc_security_group_ids = [var.sg_k8s_id]
  user_data              = local.worker_user_data

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-worker-${count.index + 1}"
    Role = "worker"
  }
}

output "bastion_public_ip"   { value = aws_instance.bastion.public_ip }
output "bastion_private_ip"  { value = aws_instance.bastion.private_ip }
output "master_public_ips"   { value = aws_instance.master[*].public_ip }
output "master_private_ips"  { value = aws_instance.master[*].private_ip }
output "worker_public_ips"   { value = aws_instance.worker[*].public_ip }
output "worker_private_ips"  { value = aws_instance.worker[*].private_ip }
output "worker_instance_ids" { value = aws_instance.worker[*].id }
