output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "ecr_repository_url" {
  value = aws_ecr_repository.node_info.repository_url
}

output "eso_role_arn" {
  description = "Annotate the external-secrets ServiceAccount with this role"
  value       = aws_iam_role.eso.arn
}
