# Terraform owns "the platform exists"; Flux owns "what runs on it".
# The boundary is the cluster API: after `flux bootstrap` (run once,
# out-of-band or via a bootstrap null_resource), everything in-cluster
# reconciles from Git.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = "node-info-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
}

# --- Networking: private nodes, public subnets only for load balancers/NAT ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true

  # Subnet discovery for the AWS Load Balancer Controller
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}

# --- KMS: envelope encryption for EKS secrets, one key per environment ---
resource "aws_kms_key" "eks" {
  description             = "${local.name} EKS secrets encryption"
  deletion_window_in_days = 14
  enable_key_rotation     = true
}

# --- EKS: private nodes, IRSA enabled, control-plane logs on ---
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = local.name
  cluster_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Private API endpoint; public access only while bootstrapping, then off.
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  cluster_encryption_config = {
    provider_key_arn = aws_kms_key.eks.arn
    resources        = ["secrets"]
  }

  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # Workload identity: EKS Pod Identity (the agent runs as an addon).
  # The OIDC provider (IRSA) is kept only for third-party charts that
  # don't support Pod Identity yet.
  cluster_addons = {
    eks-pod-identity-agent = {}
  }
  enable_irsa = true

  # Baseline system node group; application capacity is provisioned
  # just-in-time by Karpenter (installed via Flux, infrastructure/).
  eks_managed_node_groups = {
    system = {
      instance_types = ["t4g.medium"] # Graviton: images are multi-arch
      ami_type       = "AL2023_ARM_64_STANDARD"
      min_size       = 2
      max_size       = 3
      desired_size   = 2
    }
  }
}

# --- ECR: immutable tags (sha-<commit> can never be overwritten) ---
resource "aws_ecr_repository" "node_info" {
  name                 = "node-info"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "node_info" {
  repository = aws_ecr_repository.node_info.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep last 50 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 50
      }
      action = { type = "expire" }
    }]
  })
}

# --- Pod Identity: External Secrets Operator may read only this env's secrets ---
# EKS Pod Identity replaces IRSA: the trust policy points at the EKS Pod
# Identity service instead of a per-cluster OIDC provider, and the binding
# to a ServiceAccount is a first-class AWS resource (association below) —
# no ServiceAccount annotations, no OIDC trust wiring per role.
data "aws_iam_policy_document" "eso_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "eso_read" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.region}:*:secret:${var.environment}/*"]
  }
}

resource "aws_iam_role" "eso" {
  name               = "${local.name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
}

resource "aws_iam_role_policy" "eso" {
  name   = "read-env-secrets"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.eso_read.json
}

# The actual binding: this ServiceAccount in this namespace gets this role.
resource "aws_eks_pod_identity_association" "eso" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.eso.arn
}

# The secret container the app's ExternalSecret syncs from
# (apps/<env>/eso/). Only the container is managed here — the VALUE is
# set out-of-band (console/CLI/rotation Lambda) so it never enters
# Terraform state.
resource "aws_secretsmanager_secret" "node_info" {
  name        = "${var.environment}/node-info"
  description = "node-info app secrets for ${var.environment}; synced into the cluster by External Secrets Operator"
}
