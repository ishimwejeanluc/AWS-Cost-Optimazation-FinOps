terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Wasteful resources module
# Creates demo zombie assets for cost cleanup and policy testing.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# Minimal VPC for demo resources
data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Tier = "Public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Idle zombie EC2 instance
# Missing CostCenter to trigger Config compliance testing.
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "idle_instance" {
  name        = "${local.name_prefix}-idle-sg"
  description = "Security group for idle zombie instance (no inbound rules)"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${local.name_prefix}-idle-sg"
  }
}

resource "aws_instance" "idle" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = var.idle_instance_type
  subnet_id     = aws_subnet.public[0].id

  vpc_security_group_ids = [aws_security_group.idle_instance.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # CostCenter set to UNKNOWN to simulate a broken tag state.
  tags = {
    Name        = "${local.name_prefix}-ZOMBIE-idle-instance"
    Environment = var.environment
    Owner       = var.owner
    CostCenter  = "UNKNOWN"
  }

  lifecycle {
    ignore_changes = [ami]
  }
}

# Unattached EBS volumes that still incur storage charges
resource "aws_ebs_volume" "unattached" {
  count = length(var.ebs_volume_sizes_gb)

  availability_zone = data.aws_availability_zones.available.names[0]
  size              = var.ebs_volume_sizes_gb[count.index]
  type              = var.ebs_volume_types[count.index]

  # io1 requires IOPS settings
  iops = var.ebs_volume_types[count.index] == "io1" ? 3000 : null

  tags = {
    Name        = "${local.name_prefix}-ZOMBIE-unattached-vol-${count.index + 1}"
    Environment = var.environment
    Owner       = var.owner
    CostCenter  = "UNKNOWN"
    Status      = "unattached"
  }
}

# Unassociated Elastic IPs
resource "aws_eip" "orphaned" {
  count  = 2
  domain = "vpc"

  # EIPs created without attachment
  tags = {
    Name        = "${local.name_prefix}-ZOMBIE-orphaned-eip-${count.index + 1}"
    Environment = var.environment
    Owner       = var.owner
    CostCenter  = "UNKNOWN"
    Status      = "unassociated"
  }
}
