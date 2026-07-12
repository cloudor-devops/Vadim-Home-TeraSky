variable "environment" {
  description = "Environment name (dev, staging, production) — one root/workspace per env, separate AWS accounts in production"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR (unique per environment)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version"
  type        = string
  default     = "1.33"
}

variable "single_nat_gateway" {
  description = "One NAT for the whole VPC (dev/staging cost saving); false = one per AZ (production)"
  type        = bool
  default     = true
}
