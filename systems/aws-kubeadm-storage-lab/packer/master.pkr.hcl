source "amazon-ebs" "master" {
  region        = var.aws_region
  source_ami    = var.base_ami
  instance_type = "t3.large"
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

  ami_name        = "k8s-storage-lab-master-{{timestamp}}"
  ami_description = "k8s master: containerd 1.7.22 + kubeadm/kubelet/kubectl 1.31 (Ubuntu 24.04)"

  tags = {
    Project     = "k8s-storage-lab"
    Role        = "master"
    OS          = "ubuntu-24.04"
    K8s         = "1.31"
    containerd  = "1.7.22"
    BuildDate   = "{{timestamp}}"
  }
}

build {
  sources = ["source.amazon-ebs.master"]

  provisioner "shell" {
    script          = "scripts/base.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
  provisioner "shell" {
    script          = "scripts/master.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
}
