# =============================================================================
# TRANSIT GATEWAY
# Default association/propagation are DISABLED so that WE control routing.
# (If left on, every attachment would join one default table = everything talks
#  to everything, and Dev <-> Prod would NOT be blocked.)
# =============================================================================
resource "aws_ec2_transit_gateway" "main" {
  description     = "${var.project_name} hub"
  amazon_side_asn = var.tgw_asn

  default_route_table_association = "disable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  vpn_ecmp_support                = "enable"

  tags = { Name = "${var.project_name}-tgw" }
}

# ---------- VPC attachments (prod, dev, shared) ----------
resource "aws_ec2_transit_gateway_vpc_attachment" "spoke" {
  for_each = var.aws_vpcs

  transit_gateway_id = aws_ec2_transit_gateway.main.id
  vpc_id             = aws_vpc.aws[each.key].id
  subnet_ids         = [aws_subnet.aws_private[each.key].id]

  # We manage association/propagation ourselves, below.
  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  tags = { Name = "${var.project_name}-${each.key}-attachment" }
}

# =============================================================================
# THREE TGW ROUTE TABLES
#
#  tgw-rt-spokes  : used by Prod + Dev.    Knows Shared + on-prem. NOT each other.
#  tgw-rt-shared  : used by Shared.        Knows Prod + Dev + on-prem.
#  tgw-rt-onprem  : used by the VPN.       Knows Prod + Dev + Shared.
#
# "Association" = which table an attachment's OUTGOING traffic is looked up in.
# "Propagation" = which tables learn that attachment's CIDR.
# =============================================================================
resource "aws_ec2_transit_gateway_route_table" "spokes" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project_name}-tgw-rt-spokes" }
}

resource "aws_ec2_transit_gateway_route_table" "shared" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project_name}-tgw-rt-shared" }
}

resource "aws_ec2_transit_gateway_route_table" "onprem" {
  transit_gateway_id = aws_ec2_transit_gateway.main.id
  tags               = { Name = "${var.project_name}-tgw-rt-onprem" }
}

# ---------- Associations ----------
resource "aws_ec2_transit_gateway_route_table_association" "prod" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke["prod"].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route_table_association" "dev" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke["dev"].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route_table_association" "shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke["shared"].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

resource "aws_ec2_transit_gateway_route_table_association" "vpn" {
  transit_gateway_attachment_id  = aws_vpn_connection.onprem.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.onprem.id
}

# ---------- Propagations (who learns whose CIDR) ----------
# Prod and Dev tables learn ONLY Shared  => Prod cannot see Dev and vice versa.
resource "aws_ec2_transit_gateway_route_table_propagation" "shared_into_spokes" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke["shared"].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

# Shared table learns Prod + Dev  => replies to them can be routed back.
resource "aws_ec2_transit_gateway_route_table_propagation" "prod_into_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke["prod"].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "dev_into_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke["dev"].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

# On-prem (VPN) table learns all three VPCs  => on-prem reaches everything.
resource "aws_ec2_transit_gateway_route_table_propagation" "to_onprem_table" {
  for_each = var.aws_vpcs

  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.spoke[each.key].id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.onprem.id
}

# ---------- How do the VPC tables learn the ON-PREM CIDR? ----------
# STATIC mode: we write the route by hand, pointing at the VPN attachment.
resource "aws_ec2_transit_gateway_route" "onprem_from_spokes" {
  count = var.vpn_routing_mode == "static" ? 1 : 0

  destination_cidr_block         = var.onprem_vpc_cidr
  transit_gateway_attachment_id  = aws_vpn_connection.onprem.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route" "onprem_from_shared" {
  count = var.vpn_routing_mode == "static" ? 1 : 0

  destination_cidr_block         = var.onprem_vpc_cidr
  transit_gateway_attachment_id  = aws_vpn_connection.onprem.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}

# BGP mode: the VPN attachment propagates what the on-prem router advertises.
resource "aws_ec2_transit_gateway_route_table_propagation" "vpn_into_spokes" {
  count = var.vpn_routing_mode == "bgp" ? 1 : 0

  transit_gateway_attachment_id  = aws_vpn_connection.onprem.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.spokes.id
}

resource "aws_ec2_transit_gateway_route_table_propagation" "vpn_into_shared" {
  count = var.vpn_routing_mode == "bgp" ? 1 : 0

  transit_gateway_attachment_id  = aws_vpn_connection.onprem.transit_gateway_attachment_id
  transit_gateway_route_table_id = aws_ec2_transit_gateway_route_table.shared.id
}
