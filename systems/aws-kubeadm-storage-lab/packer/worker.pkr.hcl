source "amazon-ebs" "worker" {
  region        = var.aws_region
  source_ami    = var.base_ami
  instance_type = "m5.large"
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

  ami_name        = "k8s-storage-lab-worker-{{timestamp}}"
  ami_description = "k8s worker(HCI): containerd + kubeadm + kernel 6.8 + BeeGFS 7.4.6 module (Ubuntu 24.04)"

  tags = {
    Project   = "k8s-storage-lab"
    Role      = "worker"
    OS        = "ubuntu-24.04"
    K8s       = "1.31"
    BeeGFS    = "7.4.6"
    Kernel    = "6.8"
    BuildDate = "{{timestamp}}"
  }
}

build {
  sources = ["source.amazon-ebs.worker"]

  provisioner "shell" {
    script          = "scripts/base.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
  # 커널 6.8 설치 + GRUB 설정
  provisioner "shell" {
    script          = "scripts/worker_kernel.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
  # 커널 전환을 위한 재부팅
  provisioner "shell" {
    inline = ["sudo reboot"]
    expect_disconnect = true
  }
  # 재부팅 후 BeeGFS 패키지 + 커널 모듈 빌드
  provisioner "shell" {
    pause_before    = "120s"
    script          = "scripts/worker.sh"
    execute_command = "sudo bash '{{.Path}}'"
  }
}
