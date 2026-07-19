# Infrastructure as Code — staging & production EKS

This Terraform is the substrate for the **staging and production clusters**:
VPC (private nodes, public LB subnets), EKS (KMS-encrypted secrets, audit
logs, Pod Identity agent), ECR (immutable tags, scan-on-push), and an EKS
Pod Identity role + association for External Secrets Operator (IRSA's OIDC
provider is kept only for charts that don't support Pod Identity yet).

Dev is the local kind cluster (`kind-config.yaml` at the repo root) and is
not provisioned from here. One tfvars file per environment creates two
clusters from the same module; reference-quality, not applied for the demo.

## Usage (per environment)

```bash
terraform init          # configure the S3 backend per env first (providers.tf)

terraform apply -var-file=staging.tfvars
terraform apply -var-file=production.tfvars

# then hand the cluster to GitOps (one-time per cluster):
aws eks update-kubeconfig --name node-info-staging
kubectl create ns flux-system
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=<that env's age private key>   # see .sops.yaml
flux bootstrap github --owner=<github-owner> --repository=Vadim-Home-TeraSky \
  --branch=main --path=clusters/staging --token-auth
```

One state per environment (separate backends or workspaces). Terraform never applies Kubernetes manifests —
Flux owns everything inside the cluster.
