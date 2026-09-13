source "amazon-ebs" "bastion" {
  region        = var.aws_region
  source_ami    = var.base_ami
  instance_type = "t3.small"
  ssh_username  = "ubuntu"
  ssh_keypair_name     = var.key_name
  ssh_private_key_file = var.ssh_private_key_file
  associate_public_ip_address            = true
  temporary_security_group_source_cidrs = ["0.0.0.0/0"]

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  ami_name        = "k8s-storage-lab-bastion-{{timestamp}}"
  ami_description = "k8s bastion: ansible-core + boto3 + collections (Ubuntu 24.04)"

  tags = {
    Project   = "k8s-storage-lab"
    Role      = "bastion"
    OS        = "ubuntu-24.04"
    BuildDate = "{{timestamp}}"
  }
}

build {
  sources = ["source.amazon-ebs.bastion"]

  provisioner "shell" {
    script          = "scripts/bastion.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
}
