resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# Bastion 전용 서브넷 (퍼블릭)
resource "aws_subnet" "bastion" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-subnet-bastion" }
}

# k8s 서브넷: master-1, worker-1~N (프라이빗)
resource "aws_subnet" "k8s" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false
  tags = { Name = "${var.project_name}-subnet-k8s" }
}

# NAT Gateway용 EIP
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-eip-nat" }
}

# NAT Gateway (퍼블릭 서브넷에 위치)
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.bastion.id
  tags          = { Name = "${var.project_name}-nat" }
  depends_on    = [aws_internet_gateway.main]
}

# 퍼블릭 라우팅 테이블 (bastion → IGW)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project_name}-rt-public" }
}

# 프라이빗 라우팅 테이블 (k8s → NAT GW)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.project_name}-rt-private" }
}

resource "aws_route_table_association" "bastion" {
  subnet_id      = aws_subnet.bastion.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "k8s" {
  subnet_id      = aws_subnet.k8s.id
  route_table_id = aws_route_table.private.id
}

output "vpc_id"            { value = aws_vpc.main.id }
output "subnet_bastion_id" { value = aws_subnet.bastion.id }
output "subnet_k8s_id"     { value = aws_subnet.k8s.id }
