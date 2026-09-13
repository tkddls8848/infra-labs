# ── BeeGFS 스토리지: worker 노드당 1개 (8GB, /dev/xvdd → nvme2n1) ──
resource "aws_ebs_volume" "beegfs_storage" {
  count             = var.worker_count
  availability_zone = var.availability_zone
  size              = 8
  type              = "gp2"
  tags              = { Name = "${var.project_name}-beegfs-storage-${count.index + 1}" }
}

resource "aws_volume_attachment" "beegfs_storage" {
  count        = var.worker_count
  device_name  = "/dev/xvdd"
  volume_id    = aws_ebs_volume.beegfs_storage[count.index].id
  instance_id  = var.worker_instance_ids[count.index]
  force_detach = true
}

# ── Ceph OSD: worker 노드당 1개 × 5GB ──
resource "aws_ebs_volume" "ceph_osd" {
  count             = var.worker_count
  availability_zone = var.availability_zone
  size              = 5
  type              = "gp2"
  tags              = { Name = "${var.project_name}-ceph-osd-${count.index + 1}" }
}

resource "aws_volume_attachment" "ceph_osd" {
  count        = var.worker_count
  device_name  = "/dev/xvdb"
  volume_id    = aws_ebs_volume.ceph_osd[count.index].id
  instance_id  = var.worker_instance_ids[count.index]
  force_detach = true
}
