environment        = "staging"
region             = "eu-west-1"
vpc_cidr           = "10.10.0.0/16" # unique per env — keeps peering/TGW possible
single_nat_gateway = true           # cost saving acceptable outside production
