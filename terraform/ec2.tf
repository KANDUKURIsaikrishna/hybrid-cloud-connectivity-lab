# Latest Ubuntu 22.04 LTS AMI published by Canonical (owner 099720109477 is Canonical's public publisher ID).
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# =============================================================================
# ON-PREM strongSwan EC2  (the "customer gateway device")
# =============================================================================
resource "aws_instance" "onprem" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.onprem_public.id
  vpc_security_group_ids = [aws_security_group.onprem.id]
  key_name               = var.key_name

  # CRITICAL for a VPN/router box. By default AWS drops any packet whose source or
  # destination is not the instance itself. A router forwards other hosts' packets,
  # so this check MUST be off. (OS-level IP forwarding is set by install_strongswan.sh.)
  source_dest_check = false

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-onprem-strongswan" }

  lifecycle {
    # A newer Ubuntu AMI must not silently replace the VPN box (and wipe its config).
    ignore_changes = [ami]
  }
}

# Elastic IP = the stable public address used as the Customer Gateway IP.
# Allocated separately from the association so the VPN can reference the IP
# without creating a dependency loop with the instance's security group.
resource "aws_eip" "onprem" {
  domain = "vpc"

  tags = { Name = "${var.project_name}-onprem-eip" }

  depends_on = [aws_internet_gateway.onprem]
}

resource "aws_eip_association" "onprem" {
  instance_id   = aws_instance.onprem.id
  allocation_id = aws_eip.onprem.id
}

# =============================================================================
# TEST EC2s in each AWS VPC (private subnet, no public IP, no internet)
# Reached by SSH-hopping through the on-prem box, over the VPN tunnel.
# =============================================================================
resource "aws_instance" "test" {
  for_each = var.aws_vpcs

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.aws_private[each.key].id
  vpc_security_group_ids = [aws_security_group.test[each.key].id]
  key_name               = var.key_name

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
  }

  tags = { Name = "${var.project_name}-${each.key}-test" }

  lifecycle {
    ignore_changes = [ami]
  }
}
