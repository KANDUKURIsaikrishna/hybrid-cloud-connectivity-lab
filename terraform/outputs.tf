# ---------- Where things are ----------
output "onprem_public_ip" {
  description = "Elastic IP of the strongSwan box (also the Customer Gateway IP)."
  value       = aws_eip.onprem.public_ip
}

output "onprem_private_ip" {
  value = aws_instance.onprem.private_ip
}

output "prod_private_ip" {
  value = aws_instance.test["prod"].private_ip
}

output "dev_private_ip" {
  value = aws_instance.test["dev"].private_ip
}

output "shared_private_ip" {
  value = aws_instance.test["shared"].private_ip
}

# ---------- Handy commands ----------
output "ssh_onprem" {
  description = "SSH into the strongSwan box."
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.onprem.public_ip}"
}

output "ssh_test_via_onprem" {
  description = "SSH into each private test EC2 by hopping through the strongSwan box."
  value = {
    for k, i in aws_instance.test :
    k => "ssh -i ~/.ssh/${var.key_name}.pem -o ProxyCommand=\"ssh -i ~/.ssh/${var.key_name}.pem -W %h:%p ubuntu@${aws_eip.onprem.public_ip}\" ubuntu@${i.private_ip}"
  }
}

# ---------- Transit Gateway ----------
output "tgw_id" {
  value = aws_ec2_transit_gateway.main.id
}

output "tgw_route_table_ids" {
  value = {
    spokes = aws_ec2_transit_gateway_route_table.spokes.id
    shared = aws_ec2_transit_gateway_route_table.shared.id
    onprem = aws_ec2_transit_gateway_route_table.onprem.id
  }
}

# ---------- VPN ----------
output "vpn_connection_id" {
  value = aws_vpn_connection.onprem.id
}

output "tunnel1_outside_ip" {
  description = "AWS public endpoint of tunnel 1."
  value       = aws_vpn_connection.onprem.tunnel1_address
}

output "tunnel2_outside_ip" {
  description = "AWS public endpoint of tunnel 2."
  value       = aws_vpn_connection.onprem.tunnel2_address
}

output "tunnel1_inside" {
  description = "Link-local /30 addresses inside tunnel 1."
  value = {
    aws = aws_vpn_connection.onprem.tunnel1_vgw_inside_address
    cgw = aws_vpn_connection.onprem.tunnel1_cgw_inside_address
  }
}

output "tunnel2_inside" {
  description = "Link-local /30 addresses inside tunnel 2."
  value = {
    aws = aws_vpn_connection.onprem.tunnel2_vgw_inside_address
    cgw = aws_vpn_connection.onprem.tunnel2_cgw_inside_address
  }
}

# ---------- SECRETS (hidden in the terminal) ----------
# View on purpose with:  terraform output -raw tunnel1_preshared_key
# `sensitive` only hides them on screen. They are STILL in terraform.tfstate in plain text,
# which is why *.tfstate is gitignored.
output "tunnel1_preshared_key" {
  description = "IPsec pre-shared key, tunnel 1."
  value       = aws_vpn_connection.onprem.tunnel1_preshared_key
  sensitive   = true
}

output "tunnel2_preshared_key" {
  description = "IPsec pre-shared key, tunnel 2."
  value       = aws_vpn_connection.onprem.tunnel2_preshared_key
  sensitive   = true
}
