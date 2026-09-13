# Bastion SG — 외부 SSH 유일 진입점 + HAProxy K8s API
resource "aws_security_group" "bastion" {
  name   = "${var.project_name}-sg-bastion"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # HAProxy K8s API (외부 kubectl 접근)
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # HAProxy 통계 페이지 (VPC 내부만)
  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg-bastion" }
}

# HCI SG: k8s + Ceph + BeeGFS 포트 통합 (master-1, worker-1~N)
resource "aws_security_group" "k8s" {
  name   = "${var.project_name}-sg-k8s"
  vpc_id = var.vpc_id

  # SSH — Bastion에서만 허용
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }
  # k8s API server
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # etcd
  ingress {
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # kubelet, controller-manager, scheduler
  ingress {
    from_port   = 10250
    to_port     = 10252
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # NodePort
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # Calico BGP
  ingress {
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # Calico VXLAN (UDP 4789) / Flannel VXLAN (UDP 8472)
  ingress {
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }
  ingress {
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }
  # Ceph MON
  ingress {
    from_port   = 6789
    to_port     = 6789
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # Ceph MON v2
  ingress {
    from_port   = 3300
    to_port     = 3300
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # Ceph OSD/MDS/MGR
  ingress {
    from_port   = 6800
    to_port     = 7300
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # Ceph Dashboard
  ingress {
    from_port   = 8080
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # BeeGFS mgmtd
  ingress {
    from_port   = 8008
    to_port     = 8008
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # BeeGFS meta
  ingress {
    from_port   = 8005
    to_port     = 8005
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # BeeGFS storage
  ingress {
    from_port   = 8003
    to_port     = 8003
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # BeeGFS client / helperd
  ingress {
    from_port   = 8004
    to_port     = 8004
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # VPC 내부 전체 허용 (k8s 노드간 통신)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${var.project_name}-sg-k8s" }
}

output "sg_bastion_id" { value = aws_security_group.bastion.id }
output "sg_k8s_id"     { value = aws_security_group.k8s.id }
