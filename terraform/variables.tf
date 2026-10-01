# ---------- General ----------
variable "region" {
  description = "AWS region for the whole lab."
  type        = string
  default     = "ap-south-1"
}

variable "availability_zone" {
  description = "Single AZ used for every subnet in the lab."
  type        = string
  default     = "ap-south-1a"
}

variable "project_name" {
  description = "Prefix for resource names and the Project tag."
  type        = string
  default     = "hybrid-lab"
}

# ---------- Access ----------
variable "my_ip_cidr" {
  description = "Your public IP as a /32, used to allow SSH to the on-prem EC2. Example: 203.0.113.25/32"
  type        = string

  validation {
    condition     = can(cidrhost(var.my_ip_cidr, 0)) && var.my_ip_cidr != "0.0.0.0/0"
    error_message = "my_ip_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "key_name" {
  description = "Name of an EXISTING EC2 key pair in the region (create it in the console first)."
  type        = string
}

variable "instance_type" {
  description = "Instance type for all EC2s. t3.micro is the smallest size that runs strongSwan comfortably."
  type        = string
  default     = "t3.micro"
}

# ---------- "On-prem" simulated data center ----------
variable "onprem_vpc_cidr" {
  description = "CIDR of the simulated on-prem VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "onprem_public_subnet_cidr" {
  description = "Public subnet inside the on-prem VPC (holds the strongSwan EC2)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "onprem_bgp_asn" {
  description = "Private ASN of the customer gateway. Used by BGP mode, and required by AWS even for static."
  type        = number
  default     = 65000
}

# ---------- AWS side ----------
variable "aws_vpcs" {
  description = "The three AWS VPCs. Keys MUST be prod, dev and shared (TGW route tables rely on these names)."
  type = map(object({
    vpc_cidr            = string
    private_subnet_cidr = string
  }))

  default = {
    prod = {
      vpc_cidr            = "10.1.0.0/16"
      private_subnet_cidr = "10.1.1.0/24"
    }
    dev = {
      vpc_cidr            = "10.2.0.0/16"
      private_subnet_cidr = "10.2.1.0/24"
    }
    shared = {
      vpc_cidr            = "10.3.0.0/16"
      private_subnet_cidr = "10.3.1.0/24"
    }
  }

  validation {
    condition     = toset(keys(var.aws_vpcs)) == toset(["prod", "dev", "shared"])
    error_message = "aws_vpcs must have exactly the keys: prod, dev, shared."
  }
}

variable "tgw_asn" {
  description = "Amazon-side ASN of the Transit Gateway. Must differ from onprem_bgp_asn."
  type        = number
  default     = 64512
}

# ---------- VPN ----------
variable "vpn_routing_mode" {
  description = "static = on-prem CIDR is entered by hand in TGW route tables. bgp = routes are exchanged dynamically (optional upgrade)."
  type        = string
  default     = "static"

  validation {
    condition     = contains(["static", "bgp"], var.vpn_routing_mode)
    error_message = "vpn_routing_mode must be \"static\" or \"bgp\"."
  }
}

# ---------- Teaching switch ----------
variable "allow_spoke_icmp_in_sg" {
  description = <<-EOT
    false (default): Prod/Dev security groups only accept ICMP from on-prem and Shared (least privilege).
    true: Prod and Dev security groups ALSO accept ICMP from each other. Use this only to PROVE that the
    Transit Gateway route tables (not the security groups) are what block Dev <-> Prod.
  EOT
  type        = bool
  default     = false
}
