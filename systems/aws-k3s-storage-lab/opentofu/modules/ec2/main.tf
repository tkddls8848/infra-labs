# ── EC2 #1 Frontend (k3s server + agent × 2) ──
resource "aws_instance" "frontend" {
  ami                    = coalesce(var.ami_frontend, var.ami_id)
  instance_type          = "t3.medium"
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_frontend_id]

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-frontend"
    Role = "frontend"
  }
}

# ── EC2 #2 Backend (cephadm + BeeGFS) ──
resource "aws_instance" "backend" {
  ami                    = coalesce(var.ami_backend, var.ami_id)
  instance_type          = "t3.medium"
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.sg_backend_id]

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-backend"
    Role = "backend"
  }
}

# ── EBS 5GB (Ceph OSD #1) → EC2 #2 — Nitro: OS에서 /dev/nvme*n1로 노출, device_name 무시됨 ──
resource "aws_ebs_volume" "ceph_osd_1" {
  availability_zone = "${var.aws_region}a"
  size              = 5
  type              = "gp3"
  tags = { Name = "${var.project_name}-ebs-ceph-osd-1" }
}

resource "aws_volume_attachment" "ceph_osd_1" {
  device_name = "/dev/xvdb"
  volume_id   = aws_ebs_volume.ceph_osd_1.id
  instance_id = aws_instance.backend.id
}

# ── EBS 5GB (Ceph OSD #2) → EC2 #2 — Nitro: OS에서 /dev/nvme*n1로 노출, device_name 무시됨 ──
resource "aws_ebs_volume" "ceph_osd_2" {
  availability_zone = "${var.aws_region}a"
  size              = 5
  type              = "gp3"
  tags = { Name = "${var.project_name}-ebs-ceph-osd-2" }
}

resource "aws_volume_attachment" "ceph_osd_2" {
  device_name = "/dev/xvdc"
  volume_id   = aws_ebs_volume.ceph_osd_2.id
  instance_id = aws_instance.backend.id
}

# ── EBS 5GB (BeeGFS storage #1) → EC2 #2 — Nitro: OS에서 /dev/nvme*n1로 노출, device_name 무시됨 ──
resource "aws_ebs_volume" "beegfs_storage_1" {
  availability_zone = "${var.aws_region}a"
  size              = 5
  type              = "gp3"
  tags = { Name = "${var.project_name}-ebs-beegfs-storage-1" }
}

resource "aws_volume_attachment" "beegfs_storage_1" {
  device_name = "/dev/xvdd"
  volume_id   = aws_ebs_volume.beegfs_storage_1.id
  instance_id = aws_instance.backend.id
}

# ── EBS 5GB (BeeGFS storage #2) → EC2 #2 — Nitro: OS에서 /dev/nvme*n1로 노출, device_name 무시됨 ──
resource "aws_ebs_volume" "beegfs_storage_2" {
  availability_zone = "${var.aws_region}a"
  size              = 5
  type              = "gp3"
  tags = { Name = "${var.project_name}-ebs-beegfs-storage-2" }
}

resource "aws_volume_attachment" "beegfs_storage_2" {
  device_name = "/dev/xvde"
  volume_id   = aws_ebs_volume.beegfs_storage_2.id
  instance_id = aws_instance.backend.id
}

output "frontend_public_ip"        { value = aws_instance.frontend.public_ip }
output "frontend_private_ip"       { value = aws_instance.frontend.private_ip }
output "backend_public_ip"         { value = aws_instance.backend.public_ip }
output "backend_private_ip"        { value = aws_instance.backend.private_ip }
output "ceph_osd_1_volume_id"      { value = aws_ebs_volume.ceph_osd_1.id }
output "ceph_osd_2_volume_id"      { value = aws_ebs_volume.ceph_osd_2.id }
output "beegfs_storage_1_volume_id" { value = aws_ebs_volume.beegfs_storage_1.id }
output "beegfs_storage_2_volume_id" { value = aws_ebs_volume.beegfs_storage_2.id }
