locals {
  # Every lab CIDR lives inside 10.0.0.0/8. AWS-side private subnets send this whole
  # supernet to the Transit Gateway. The TGW ROUTE TABLES then decide who may talk to whom.
  # (Own-VPC traffic never leaves: the more specific "local" route wins.)
  internal_supernet = "10.0.0.0/8"
}

# =============================================================================
# "ON-PREM" VPC  (pretend data center)
# =============================================================================
resource "aws_vpc" "onprem" {
  cidr_block           = var.onprem_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-onprem-vpc" }
}

resource "aws_internet_gateway" "onprem" {
  vpc_id = aws_vpc.onprem.id

  tags = { Name = "${var.project_name}-onprem-igw" }
}

resource "aws_subnet" "onprem_public" {
  vpc_id                  = aws_vpc.onprem.id
  cidr_block              = var.onprem_public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-onprem-public" }
}

resource "aws_route_table" "onprem_public" {
  vpc_id = aws_vpc.onprem.id

  tags = { Name = "${var.project_name}-onprem-public-rt" }
}

# Internet access: needed for apt install and for IPsec to reach AWS tunnel endpoints.
resource "aws_route" "onprem_default" {
  route_table_id         = aws_route_table.onprem_public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.onprem.id
}

# Realism: in a real data center, other servers would send traffic for the cloud to the
# VPN device. Here we point the AWS CIDRs at the strongSwan instance's network interface.
resource "aws_route" "onprem_to_aws" {
  for_each = var.aws_vpcs

  route_table_id         = aws_route_table.onprem_public.id
  destination_cidr_block = each.value.vpc_cidr
  network_interface_id   = aws_instance.onprem.primary_network_interface_id
}

resource "aws_route_table_association" "onprem_public" {
  subnet_id      = aws_subnet.onprem_public.id
  route_table_id = aws_route_table.onprem_public.id
}

# =============================================================================
# AWS VPCs  (prod, dev, shared)  - one private subnet each, NO internet
# =============================================================================
resource "aws_vpc" "aws" {
  for_each = var.aws_vpcs

  cidr_block           = each.value.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.project_name}-${each.key}-vpc" }
}

resource "aws_subnet" "aws_private" {
  for_each = var.aws_vpcs

  vpc_id            = aws_vpc.aws[each.key].id
  cidr_block        = each.value.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = { Name = "${var.project_name}-${each.key}-private" }
}

resource "aws_route_table" "aws_private" {
  for_each = var.aws_vpcs

  vpc_id = aws_vpc.aws[each.key].id

  tags = { Name = "${var.project_name}-${each.key}-private-rt" }
}

# All other 10.x traffic goes to the Transit Gateway. Segmentation happens THERE.
resource "aws_route" "aws_private_to_tgw" {
  for_each = var.aws_vpcs

  route_table_id         = aws_route_table.aws_private[each.key].id
  destination_cidr_block = local.internal_supernet
  transit_gateway_id     = aws_ec2_transit_gateway.main.id

  # The route is only valid once the VPC is attached to the TGW.
  depends_on = [aws_ec2_transit_gateway_vpc_attachment.spoke]
}

resource "aws_route_table_association" "aws_private" {
  for_each = var.aws_vpcs

  subnet_id      = aws_subnet.aws_private[each.key].id
  route_table_id = aws_route_table.aws_private[each.key].id
}
