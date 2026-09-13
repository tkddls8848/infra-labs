# Frontend SG — k3s server + agent (EC2 #1)
resource "aws_security_group" "frontend" {
  name   = "${var.project_name}-sg-frontend"
  vpc_id = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # k3s API server
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # NodePort
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  # Flannel VXLAN (VPC 내부)
  ingress {
    from_port   = 8472
    to_port     = 8472
    protocol    = "udp"
    cidr_blocks = [var.vpc_cidr]
  }
  # kubelet
  ingress {
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # VPC 내부 전체 허용 (k3s 노드간, CSI 통신)
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
  tags = { Name = "${var.project_name}-sg-frontend" }
}

# Backend SG — cephadm + BeeGFS (EC2 #2)
resource "aws_security_group" "backend" {
  name   = "${var.project_name}-sg-backend"
  vpc_id = var.vpc_id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
  # BeeGFS storaged
  ingress {
    from_port   = 8003
    to_port     = 8003
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
  # VPC 내부 전체 허용
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
  tags = { Name = "${var.project_name}-sg-backend" }
}

output "sg_frontend_id" { value = aws_security_group.frontend.id }
output "sg_backend_id"  { value = aws_security_group.backend.id }
