# Infrastructure as Code (reference)

Terraform for one environment's AWS footprint: VPC (private nodes, public
LB subnets), EKS (KMS-encrypted secrets, IRSA, audit logs), ECR (immutable
tags, scan-on-push), and the IRSA role for External Secrets Operator.

Not applied for the demo — the assignment runs on kind
(`kind-config.yaml`). This is the production shape described in
`docs/production-aws.md`.

## Usage (per environment)

```bash
terraform init          # configure the S3 backend per env first (providers.tf)
terraform plan  -var environment=staging -var single_nat_gateway=true
terraform apply -var environment=production -var single_nat_gateway=false

# then bootstrap GitOps (one-time):
aws eks update-kubeconfig --name node-info-production
kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=...
flux bootstrap github --owner=cloudor-devops --repository=Vadim-Home-TeraSky \
  --branch=main --path=clusters/production --token-auth
```

One state per environment (separate backends/workspaces; separate AWS
accounts in production). Terraform never applies Kubernetes manifests —
Flux owns everything inside the cluster.
