# Hybrid Cloud Connectivity Lab – AWS Console Build Guide

> **Which guide is this?** This is the standalone, console-only build path (manual clicks, no Terraform). It uses its own names and addressing (for example tunnel 2 inside CIDR `169.254.20.0/30`, four TGW route tables, a separate on-prem client, and the older `ipsec.conf` + VTI style of strongSwan). The Terraform path in `terraform/` and `onprem/` is different, so build **one or the other**, not both in the same account.

## Project overview

This lab connects a simulated on-premises data center to three AWS VPCs over an IPsec Site-to-Site VPN through a Transit Gateway, built entirely in the AWS Console. Plan on 2–3 hours, and do it in one sitting because the setup is billed per hour.

The "on-prem" side is itself a VPC (onprem-vpc) with a Ubuntu EC2 running strongSwan as the customer's router. It reaches AWS only through the VPN, never by attaching to the Transit Gateway directly. Direct Connect needs a physical circuit, so it is covered as a design section.

> **Architecture diagram:** see [`diagrams/architecture.mmd`](../diagrams/architecture.mmd) in this repo.

The on-prem client sends AWS-bound traffic to the router, which carries it over either IPsec tunnel to the Transit Gateway; the TGW route tables then decide which VPCs each source may reach.

| Traffic | Allowed? | Enforced by |
| --- | --- | --- |
| On-prem → Prod, Dev, Shared | Yes | TGW route table rt-onprem |
| Prod → Shared, Dev → Shared | Yes | Propagations in rt-prod / rt-dev |
| Shared → Prod, Dev | Yes | Propagations in rt-shared |
| Prod ↔ Dev | No | No route between them in the TGW |

| Component | Name | CIDR / IP |
| --- | --- | --- |
| On-prem VPC | onprem-vpc | 10.0.0.0/16 |
| On-prem router (strongSwan) | onprem-router | 10.0.1.10 + Elastic IP |
| On-prem server | onprem-client | 10.0.2.10 |
| Prod VPC / server | prod-vpc / prod-server | 10.1.0.0/16 / 10.1.1.10 |
| Dev VPC / server | dev-vpc / dev-server | 10.2.0.0/16 / 10.2.1.10 |
| Shared Services VPC / server | shared-vpc / shared-server | 10.3.0.0/16 / 10.3.1.10 |
| VPN tunnel 1 inside | — | AWS 169.254.10.1, router 169.254.10.2 |
| VPN tunnel 2 inside | — | AWS 169.254.20.1, router 169.254.20.2 |

## Before you start

Use one region and one AZ for everything: Asia Pacific (Mumbai) ap-south-1, AZ ap-south-1a.

- Set a budget alert first: Billing → Budgets → Create budget (for example US$5).
- Running cost is roughly US$0.30–0.40 per hour (about ₹25–35), mostly Transit Gateway attachments, the VPN connection and public IPv4. Check the AWS pricing pages for current ap-south-1 rates.
- Keep a notepad of the values below; later steps need them.

| Value | Where you get it | Your value |
| --- | --- | --- |
| Router Elastic IP (EIP) | Step 4 |  |
| Tunnel 1 outside IP | Step 7 |  |
| Tunnel 2 outside IP | Step 7 |  |
| PSK 1 / PSK 2 | You choose them in Step 7 |  |

## Step 1: Create the 4 VPCs and 5 subnets

VPC console → Your VPCs → Create VPC → "VPC only". Leave other settings at defaults.

| Name tag | IPv4 CIDR |
| --- | --- |
| onprem-vpc | 10.0.0.0/16 |
| prod-vpc | 10.1.0.0/16 |
| dev-vpc | 10.2.0.0/16 |
| shared-vpc | 10.3.0.0/16 |

VPC → Subnets → Create subnet. Every subnet goes in AZ ap-south-1a.

| Subnet name | VPC | CIDR |
| --- | --- | --- |
| onprem-public | onprem-vpc | 10.0.1.0/24 |
| onprem-private | onprem-vpc | 10.0.2.0/24 |
| prod-subnet | prod-vpc | 10.1.1.0/24 |
| dev-subnet | dev-vpc | 10.2.1.0/24 |
| shared-subnet | shared-vpc | 10.3.1.0/24 |

Check: 5 subnets, all in ap-south-1a.

## Step 2: Internet access and route tables

The router needs the internet to reach AWS's VPN endpoints, just like a real data center firewall.

1. VPC → Internet gateways → Create `onprem-igw`, then Actions → Attach to VPC → onprem-vpc.
2. VPC → Route tables → Create route table:
    - `onprem-public-rt` (onprem-vpc): Routes → Edit routes → add `0.0.0.0/0` → Internet Gateway → onprem-igw. Subnet associations → onprem-public.
    - `onprem-private-rt` (onprem-vpc): Subnet associations → onprem-private. Routes come in Step 9.
3. Create `prod-rt`, `dev-rt` and `shared-rt` in their VPCs and associate each with that VPC's subnet. Routes come in Step 9.

Do not attach onprem-vpc to the Transit Gateway. It must reach AWS only through the VPN; otherwise you are not simulating on-prem.

## Step 3: Key pair and security groups

EC2 → Key Pairs → Create key pair: `hybrid-lab-key`, RSA, .pem. Save the file.

EC2 → Security Groups → Create security group, choosing the right VPC for each:

| SG name | VPC | Inbound rules |
| --- | --- | --- |
| onprem-router-sg | onprem-vpc | SSH 22 from My IP; All traffic from 10.0.0.0/8 |
| onprem-client-sg | onprem-vpc | All ICMP-IPv4 from 10.0.0.0/8; SSH from 10.0.0.0/16 |
| prod-sg | prod-vpc | All ICMP-IPv4 from 10.0.0.0/8; SSH from 10.0.0.0/16 |
| dev-sg | dev-vpc | Same as prod-sg |
| shared-sg | shared-vpc | Same as prod-sg |

Viva point: prod-sg allows ICMP from Dev's range, because 10.2.x is inside 10.0.0.0/8. So when Dev → Prod fails later, the block comes from the Transit Gateway route tables, not the security group.

## Step 4: Launch the 5 EC2 instances

EC2 → Launch instances. Every instance: type t3.micro, key hybrid-lab-key. In Network settings → Edit, choose the VPC and subnet, set Auto-assign public IP to Disable, select the existing SG, and under Advanced network configuration set the Primary IP from the table.

| Name | AMI | Subnet | SG | Primary IP |
| --- | --- | --- | --- | --- |
| onprem-router | Ubuntu Server 24.04 LTS | onprem-public | onprem-router-sg | 10.0.1.10 |
| onprem-client | Amazon Linux 2023 | onprem-private | onprem-client-sg | 10.0.2.10 |
| prod-server | Amazon Linux 2023 | prod-subnet | prod-sg | 10.1.1.10 |
| dev-server | Amazon Linux 2023 | dev-subnet | dev-sg | 10.2.1.10 |
| shared-server | Amazon Linux 2023 | shared-subnet | shared-sg | 10.3.1.10 |

Then set up the router:

1. EC2 → Elastic IPs → Allocate Elastic IP address → Allocate. Actions → Associate → Instance: onprem-router. Record the EIP.
2. Select onprem-router → Actions → Networking → Change source/destination check → tick Stop → Save. This lets the router forward packets that are not addressed to itself.

Check: all 5 instances are Running, and `ssh -i hybrid-lab-key.pem ubuntu@<EIP>` works from your laptop.

## Step 5: Create the Transit Gateway

VPC → Transit gateways → Create transit gateway:

- Name: `hybrid-tgw`; Amazon side ASN: 64512 (default)
- DNS support: on; VPN ECMP support: on
- Default route table association: untick
- Default route table propagation: untick

Unticking both makes segmentation possible. With the defaults on, every attachment lands in one shared route table and everything can reach everything. Wait until the state is Available.

## Step 6: Attach the 3 AWS VPCs

VPC → Transit gateway attachments → Create transit gateway attachment, type VPC:

| Name | VPC | Subnet |
| --- | --- | --- |
| tgw-attach-prod | prod-vpc | prod-subnet |
| tgw-attach-dev | dev-vpc | dev-subnet |
| tgw-attach-shared | shared-vpc | shared-subnet |

Check: all three show Available.

## Step 7: Customer Gateway and Site-to-Site VPN

1. VPC → Customer gateways → Create: name `onprem-cgw`, BGP ASN 65000 (required even for static routing), IP address = the router's EIP.
2. VPC → Site-to-Site VPN connections → Create VPN connection:
    - Name `onprem-vpn`; Target gateway type: Transit gateway → hybrid-tgw; Customer gateway: Existing → onprem-cgw
    - Routing options: Static; Tunnel inside IP version: IPv4
    - Local and remote IPv4 network CIDR: leave blank (0.0.0.0/0, which matches the router config)
    - Tunnel 1 options: inside IPv4 CIDR `169.254.10.0/30`, pre-shared key: your own random value (see the note below this list)
    - Tunnel 2 options: inside IPv4 CIDR `169.254.20.0/30`, pre-shared key: a different random value
    - PSK rules: 8–64 characters, only letters, numbers, `.` and `_`, must not start with 0. Generate one with `openssl rand -hex 24`. Keep it out of Git and out of screenshots.
3. Wait about 5–10 minutes for Pending → Available. Then open the VPN's Tunnel details tab and record both Outside IP addresses. Both tunnels show DOWN for now; that is expected.
4. In Transit gateway attachments, AWS created an attachment of type VPN. Name it `tgw-attach-vpn`.
5. Optional hardening: add to onprem-router-sg UDP 500 and UDP 4500 from each tunnel outside IP /32.

For each tunnel's inside IPs, AWS takes .1 and you take .2: tunnel 1 is AWS 169.254.10.1 and router 169.254.10.2; tunnel 2 is AWS 169.254.20.1 and router 169.254.20.2.

## Step 8: Transit Gateway route tables (segmentation)

VPC → Transit gateway route tables → Create four tables on hybrid-tgw: `rt-prod`, `rt-dev`, `rt-shared`, `rt-onprem`. Configure each with its Associations, Propagations and Routes tabs:

| Route table | Association | Propagations | Static route |
| --- | --- | --- | --- |
| rt-prod | tgw-attach-prod | tgw-attach-shared | 10.0.0.0/16 → tgw-attach-vpn |
| rt-dev | tgw-attach-dev | tgw-attach-shared | 10.0.0.0/16 → tgw-attach-vpn |
| rt-shared | tgw-attach-shared | tgw-attach-prod, tgw-attach-dev | 10.0.0.0/16 → tgw-attach-vpn |
| rt-onprem | tgw-attach-vpn | tgw-attach-prod, tgw-attach-dev, tgw-attach-shared | None |

- Association decides which route table an attachment's outgoing traffic uses.
- Propagation adds a VPC's CIDR into a table automatically.
- rt-dev has no route to 10.1.0.0/16, so Dev → Prod has nowhere to go.

Check the Routes tabs: rt-prod and rt-dev show 10.3.0.0/16 and 10.0.0.0/16; rt-shared shows 10.1, 10.2 and 10.0; rt-onprem shows 10.1, 10.2 and 10.3.

## Step 9: VPC route tables

VPC → Route tables → select table → Routes → Edit routes:

| Route table | Destination | Target |
| --- | --- | --- |
| prod-rt | 10.0.0.0/8 | Transit Gateway → hybrid-tgw |
| dev-rt | 10.0.0.0/8 | Transit Gateway → hybrid-tgw |
| shared-rt | 10.0.0.0/8 | Transit Gateway → hybrid-tgw |
| onprem-private-rt | 10.1.0.0/16, 10.2.0.0/16, 10.3.0.0/16 | Instance → onprem-router |

Design point: the VPCs send all 10.x traffic to the Transit Gateway, and the TGW route tables decide what is allowed. Policy stays in one central place.

## Step 10: Configure strongSwan on the router

The router runs a route-based VPN: two VTI tunnel interfaces, with tunnel 1 as primary and tunnel 2 as backup. SSH in from your laptop with `ssh -i hybrid-lab-key.pem ubuntu@<ROUTER_EIP>`, then paste each block in the same session.

**10a. Set your values** (edit before pasting):

```bash
EIP="x.x.x.x"          # router Elastic IP
T1="x.x.x.x"           # Tunnel 1 outside IP
T2="x.x.x.x"           # Tunnel 2 outside IP
PSK1="<PSK_1>"            # the key you set for tunnel 1 in Step 7
PSK2="<PSK_2>"            # the key you set for tunnel 2 in Step 7
LOCAL="10.0.1.10"      # router private IP
```

**10b. Install strongSwan and turn the instance into a router:**

```bash
sudo apt update && sudo apt install -y strongswan strongswan-starter traceroute

sudo tee /etc/sysctl.d/99-vpn.conf >/dev/null <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sudo sysctl --system

# Stop strongSwan installing its own routes (otherwise you lose SSH)
sudo sed -i 's/^\s*#\?\s*install_routes\s*=.*/    install_routes = no/' /etc/strongswan.d/charon.conf
grep install_routes /etc/strongswan.d/charon.conf   # must show: install_routes = no
```

**10c. Write the IPsec config and secrets:**

```bash
sudo tee /etc/ipsec.conf >/dev/null <<EOF
config setup
    uniqueids=no

conn %default
    type=tunnel
    keyexchange=ikev2
    authby=psk
    left=%defaultroute
    leftid=$EIP
    leftsubnet=0.0.0.0/0
    rightsubnet=0.0.0.0/0
    ike=aes128-sha1-modp2048!
    esp=aes128-sha1-modp2048!
    ikelifetime=28800s
    lifetime=3600s
    dpddelay=10s
    dpdtimeout=30s
    dpdaction=restart
    keyingtries=%forever
    auto=start

conn aws-tunnel1
    right=$T1
    rightid=$T1
    mark=100

conn aws-tunnel2
    right=$T2
    rightid=$T2
    mark=200
EOF

sudo tee /etc/ipsec.secrets >/dev/null <<EOF
$EIP $T1 : PSK "$PSK1"
$EIP $T2 : PSK "$PSK2"
EOF
sudo chmod 600 /etc/ipsec.secrets
```

**10d. Create the tunnel interfaces and routes:**

```bash
sudo tee /usr/local/bin/aws-vti.sh >/dev/null <<EOF
#!/bin/bash
modprobe ip_vti
ip link del vti1 2>/dev/null; ip link del vti2 2>/dev/null
ip tunnel add vti1 local $LOCAL remote $T1 mode vti key 100
ip tunnel add vti2 local $LOCAL remote $T2 mode vti key 200
ip addr add 169.254.10.2/30 dev vti1
ip addr add 169.254.20.2/30 dev vti2
ip link set vti1 up mtu 1419
ip link set vti2 up mtu 1419
sysctl -qw net.ipv4.conf.vti1.disable_policy=1 net.ipv4.conf.vti2.disable_policy=1
sysctl -qw net.ipv4.conf.vti1.rp_filter=0 net.ipv4.conf.vti2.rp_filter=0
# Tunnel 1 = primary (metric 100), Tunnel 2 = backup (metric 200)
for NET in 10.1.0.0/16 10.2.0.0/16 10.3.0.0/16; do
  ip route replace \$NET dev vti1 metric 100 src $LOCAL
  ip route replace \$NET dev vti2 metric 200 src $LOCAL
done
# Avoid MTU problems for TCP (SSH etc.) through the tunnel
iptables -t mangle -C FORWARD -o vti+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
iptables -t mangle -A FORWARD -o vti+ -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
EOF
sudo chmod +x /usr/local/bin/aws-vti.sh
sudo /usr/local/bin/aws-vti.sh

# Re-create the tunnels automatically after a reboot
(sudo crontab -l 2>/dev/null; echo "@reboot /usr/local/bin/aws-vti.sh") | sudo crontab -
```

**10e. Start the VPN and check it:**

```bash
sudo ipsec restart
sleep 30
sudo ipsec statusall | grep -E "ESTABLISHED|INSTALLED"
ip route | grep vti
```

Check: aws-tunnel1 and aws-tunnel2 both show ESTABLISHED and INSTALLED, and the console's VPN Tunnel details shows both tunnels UP within 1–2 minutes. Screenshot it.

## Step 11: Test connectivity

**11a. Copy the key so you can hop between machines** (fine for a lab; delete the copies afterwards):

```bash
# From your laptop
scp -i hybrid-lab-key.pem hybrid-lab-key.pem ubuntu@<EIP>:~/
# On the router
chmod 400 hybrid-lab-key.pem
scp -i hybrid-lab-key.pem hybrid-lab-key.pem ec2-user@10.0.2.10:~/
```

**11b. Test from on-prem.** Run the pings on the router, then on the client to prove the router forwards traffic:

```bash
ping -c 4 10.1.1.10 ; ping -c 4 10.2.1.10 ; ping -c 4 10.3.1.10

ssh -i hybrid-lab-key.pem ec2-user@10.0.2.10
ping -c 4 10.1.1.10 ; ping -c 4 10.2.1.10 ; ping -c 4 10.3.1.10
```

**11c. Test segmentation.** From the client, SSH into Dev through the VPN:

```bash
ssh -i hybrid-lab-key.pem ec2-user@10.2.1.10
ping -c 4 10.1.1.10    # Prod    -> should FAIL (100% packet loss)
ping -c 4 10.3.1.10    # Shared  -> should work
ping -c 4 10.0.2.10    # On-prem -> should work
```

Then SSH from the client into Prod (10.1.1.10) and confirm that Dev fails and Shared works. Screenshot each result.

| Test | From | To | Expected |
| --- | --- | --- | --- |
| T1 | On-prem client | Prod 10.1.1.10 | Reply |
| T2 | On-prem client | Dev 10.2.1.10 | Reply |
| T3 | On-prem client | Shared 10.3.1.10 | Reply |
| T4 | Dev | Prod | Timeout (blocked by TGW) |
| T5 | Prod | Dev | Timeout |
| T6 | Dev / Prod | Shared | Reply |
| T7 | Shared | Prod / Dev | Reply |

## Step 12: Tunnel failover test

1. On the client, start a continuous ping: `ping 10.3.1.10`
2. On the router, take tunnel 1 down:

```bash
sudo ipsec down aws-tunnel1
sudo ip link set vti1 down
ip route | grep 10.3     # now only via vti2
```

3. A few pings drop, then replies resume over tunnel 2. The console shows tunnel 1 DOWN and tunnel 2 UP; screenshot it.
4. Restore tunnel 1:

```bash
sudo /usr/local/bin/aws-vti.sh && sudo ipsec up aws-tunnel1
```

Viva point: with static routing you moved the on-prem route by hand. With BGP, both sides detect the failure and reroute automatically, which is why production setups use BGP.

## Step 13: Monitoring in CloudWatch

CloudWatch → Metrics → All metrics → VPN → VPN Tunnel Metrics:

- `TunnelState`: 1 = up, 0 = down. The failover test shows as a dip.
- `TunnelDataIn` / `TunnelDataOut`: traffic through each tunnel.
- Optional: an alarm on TunnelState < 1 that emails you through SNS.

Screenshot the graph.

## Step 14: Screenshots for your report

- [ ] The 4 VPCs and 5 subnets
- [ ] The Transit Gateway and its 4 attachments
- [ ] All 4 TGW route tables: Associations, Propagations and Routes tabs
- [ ] VPC route tables, especially onprem-private-rt pointing to the router
- [ ] Customer gateway and VPN with both tunnels UP
- [ ] `sudo ipsec statusall` output
- [ ] Ping results T1–T7, especially the Dev → Prod failure
- [ ] Failover screenshots and the CloudWatch TunnelState graph

## Step 15: Direct Connect (design only)

Direct Connect needs a physical circuit from a provider, so present it in your report as a design. The path is: on-prem router → DX location → Direct Connect connection → transit virtual interface → Direct Connect Gateway → hybrid-tgw. Keep the existing VPN as the backup: Direct Connect is primary and the VPN is the failover path.

- Dedicated connections come straight from AWS at fixed port speeds; hosted connections come through an AWS partner, in smaller sizes.
- Virtual interfaces: private (one VPC via a gateway), public (AWS public services), transit (Transit Gateway via a Direct Connect Gateway).

|  | Site-to-Site VPN | Direct Connect |
| --- | --- | --- |
| Path | Encrypted IPsec over the public internet | Private dedicated link via a DX location |
| Setup time | Minutes | Weeks (provider + physical cross-connect) |
| Bandwidth / latency | Limited per tunnel, variable latency | High, consistent bandwidth and latency |
| Encryption | Built in | Not encrypted by default (add MACsec or VPN over DX) |
| Cost | Low | Higher (port hours plus provider charges) |
| Typical use | Quick start, backup link, small sites | Large data transfer, steady production traffic |

Transit Gateway fits once there are many VPCs or on-prem links. VPC peering is one-to-one and doesn't route through a middle VPC, so it doesn't scale; a Transit Gateway gives one hub with central routing and segmentation.

## Step 16: Teardown (same day)

Delete in this order, because dependencies block deletion otherwise:

1. EC2: terminate all 5 instances.
2. Site-to-Site VPN connections: delete onprem-vpn (this also removes its TGW attachment).
3. Transit gateway attachments: delete the 3 VPC attachments and wait until they show Deleted.
4. Transit gateway route tables: delete all 4.
5. Transit gateways: delete hybrid-tgw.
6. Customer gateways: delete onprem-cgw.
7. Elastic IPs: release the router's EIP. It is easy to forget and is billed while it exists.
8. Your VPCs: delete all 4, which removes their subnets, route tables, SGs and the IGW.
9. Check the Billing page the next day to confirm nothing is still running.

## Troubleshooting

Watch strongSwan's log while you debug with `sudo journalctl -f | grep charon`.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `statusall` shows no ESTABLISHED | Wrong PSK, outside IP or EIP | Recheck the variables in 10a and the log |
| Log says AUTHENTICATION_FAILED | PSK mismatch, or leftid is not the EIP | Match the PSKs to the console; leftid must be the EIP, not 10.0.1.10 |
| Log says NO_PROPOSAL_CHOSEN | Encryption settings mismatch | Keep the ike= / esp= lines as given; leave AWS tunnel options at defaults |
| Lost SSH after `ipsec restart` | install_routes still enabled | Reboot from the console, then redo the sed command in 10b |
| Tunnels UP, but router ping fails | Missing TGW or VPC routes | Recheck Steps 8 and 9, and that SGs allow ICMP from 10.0.0.0/8 |
| Router ping works, client ping fails | onprem-private-rt route missing, or source/destination check still on | Redo Step 9 (last row) and Step 4 |
| Dev can reach Prod | Default association/propagation left on, or a wrong propagation | rt-dev must hold only 10.3.0.0/16 and 10.0.0.0/16 |
| Ping works, SSH hangs | MTU problem | Confirm the iptables TCPMSS rule from 10d ran |
