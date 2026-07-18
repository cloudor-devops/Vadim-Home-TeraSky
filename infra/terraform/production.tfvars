environment        = "production"
region             = "eu-west-1"
vpc_cidr           = "10.20.0.0/16" # unique per env — keeps peering/TGW possible
single_nat_gateway = false          # one NAT per AZ: no single-AZ egress failure
