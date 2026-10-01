# =============================================================================
# ON-PREM strongSwan instance
# =============================================================================
resource "aws_security_group" "onprem" {
  name_prefix = "${var.project_name}-onprem-"
  description = "strongSwan VPN box: SSH from my IP, IKE/NAT-T from AWS tunnel endpoints only"
  vpc_id      = aws_vpc.onprem.id

  tags = { Name = "${var.project_name}-onprem-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

# SSH only from my own public IP.
resource "aws_vpc_security_group_ingress_rule" "onprem_ssh" {
  security_group_id = aws_security_group.onprem.id
  description       = "SSH from my IP"
  cidr_ipv4         = var.my_ip_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# ICMP only from the three AWS VPCs (so their test EC2s can ping on-prem).
resource "aws_vpc_security_group_ingress_rule" "onprem_icmp" {
  for_each = var.aws_vpcs

  security_group_id = aws_security_group.onprem.id
  description       = "ICMP from ${each.key} VPC"
  cidr_ipv4         = each.value.vpc_cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
}

# IKE (UDP 500) and NAT-T (UDP 4500) ONLY from the two AWS tunnel endpoints.
# The EIP is NAT'd by the Internet Gateway, so IPsec runs inside UDP 4500 (NAT-T), not raw ESP.
# BGP (TCP 179) needs NO rule: it travels INSIDE the encrypted tunnel, which the SG never sees.
resource "aws_vpc_security_group_ingress_rule" "onprem_ike" {
  for_each = {
    t1_500  = { ip = aws_vpn_connection.onprem.tunnel1_address, port = 500 }
    t1_4500 = { ip = aws_vpn_connection.onprem.tunnel1_address, port = 4500 }
    t2_500  = { ip = aws_vpn_connection.onprem.tunnel2_address, port = 500 }
    t2_4500 = { ip = aws_vpn_connection.onprem.tunnel2_address, port = 4500 }
  }

  security_group_id = aws_security_group.onprem.id
  description       = "IPsec ${each.key} from AWS tunnel endpoint"
  cidr_ipv4         = "${each.value.ip}/32"
  ip_protocol       = "udp"
  from_port         = each.value.port
  to_port           = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "onprem_all" {
  security_group_id = aws_security_group.onprem.id
  description       = "Allow all outbound (apt, IPsec, replies)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# =============================================================================
# TEST EC2 security groups (prod, dev, shared)
#
# Least privilege: each VPC only accepts ICMP from CIDRs that NEED to reach it.
#   prod   <- on-prem, shared
#   dev    <- on-prem, shared
#   shared <- on-prem, prod, dev
# SSH only from the on-prem VPC (we hop through the strongSwan box).
#
# Security groups are the SECOND layer. The FIRST layer is the TGW route tables.
# =============================================================================
locals {
  onprem_cidr = var.onprem_vpc_cidr
  cidr        = { for k, v in var.aws_vpcs : k => v.vpc_cidr }

  spoke_icmp_sources = {
    prod   = concat([local.onprem_cidr, local.cidr["shared"]], var.allow_spoke_icmp_in_sg ? [local.cidr["dev"]] : [])
    dev    = concat([local.onprem_cidr, local.cidr["shared"]], var.allow_spoke_icmp_in_sg ? [local.cidr["prod"]] : [])
    shared = [local.onprem_cidr, local.cidr["prod"], local.cidr["dev"]]
  }

  # Flatten {vpc => [cidr, ...]} into one rule per (vpc, cidr) pair.
  icmp_rules = {
    for pair in flatten([
      for vpc, cidrs in local.spoke_icmp_sources : [
        for c in cidrs : { vpc = vpc, cidr = c }
      ]
    ]) : "${pair.vpc}|${pair.cidr}" => pair
  }
}

resource "aws_security_group" "test" {
  for_each = var.aws_vpcs

  name_prefix = "${var.project_name}-${each.key}-test-"
  description = "Test EC2 in ${each.key}: ICMP from needed CIDRs, SSH from on-prem"
  vpc_id      = aws_vpc.aws[each.key].id

  tags = { Name = "${var.project_name}-${each.key}-test-sg" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "test_icmp" {
  for_each = local.icmp_rules

  security_group_id = aws_security_group.test[each.value.vpc].id
  description       = "ICMP from ${each.value.cidr}"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "icmp"
  from_port         = -1
  to_port           = -1
}

resource "aws_vpc_security_group_ingress_rule" "test_ssh" {
  for_each = var.aws_vpcs

  security_group_id = aws_security_group.test[each.key].id
  description       = "SSH from on-prem (via the strongSwan jump host)"
  cidr_ipv4         = var.onprem_vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_egress_rule" "test_all" {
  for_each = var.aws_vpcs

  security_group_id = aws_security_group.test[each.key].id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
