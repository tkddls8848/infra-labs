source "amazon-ebs" "backend" {
  region        = var.aws_region
  source_ami    = var.base_ami
  instance_type = "t3.medium"
  ssh_username  = "ec2-user"
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

  ami_name        = "k3s-storage-lab-backend-{{timestamp}}"
  ami_description = "k3s backend: cephadm Squid + BeeGFS 8 packages (RHEL 9)"

  tags = {
    Project   = "k3s-storage-lab"
    Role      = "backend"
    OS        = "rhel-9"
    BeeGFS    = "8.x"
    BuildDate = "{{timestamp}}"
  }
}

build {
  sources = ["source.amazon-ebs.backend"]

  provisioner "shell" {
    script          = "scripts/base.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
  provisioner "shell" {
    script          = "scripts/backend.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
}
