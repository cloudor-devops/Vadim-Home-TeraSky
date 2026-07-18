# Production Design — AWS / EKS

How this reference implementation runs in a real AWS environment.

## Cluster architecture

- **One EKS cluster per environment** (dev, staging, production), separate
  AWS accounts under AWS Organizations (blast-radius isolation, per-account
  IAM boundaries, clean cost attribution).
- Each cluster bootstrapped with Flux pointing at its `clusters/<env>` path —
  same repo, same promotion model as the demo.
- Production: 3 AZs, control plane managed by EKS; nodes in private subnets.
- Add-ons via Flux (not `aws eks` CLI): VPC CNI, CoreDNS, kube-proxy managed
  add-ons pinned in Terraform; everything else (ingress-nginx or ALB
  controller, ESO, Kyverno, observability) as HelmReleases in
  `infrastructure/`.

## Networking

```
VPC per environment (10.x.0.0/16)
├── public subnets (3 AZ)  : NLB/ALB, NAT gateways only
└── private subnets (3 AZ) : EKS nodes, pods (VPC CNI), no public IPs
```

- Nodes/pods egress via NAT; no inbound from internet except through the LB.
- API server endpoint: private (+ temporary public with CIDR allowlist during
  migration). Access via SSM/VPN, not bastion SSH.
- NetworkPolicies (already in the chart) enforced by the VPC CNI's network
  policy agent or Cilium.

## Ingress, DNS, TLS

- AWS Load Balancer Controller → ALB (HTTP/2, WAF attachable) or
  ingress-nginx behind NLB (keeps manifests cloud-agnostic — chosen here,
  matching the chart's `ingressClassName: nginx`).
- ExternalDNS manages Route 53 records from Ingress hosts.
- cert-manager + Let's Encrypt (DNS-01 via Route 53) or ACM certs on the ALB.
  The chart's production values already carry the cert-manager annotation.

## IAM and workload identity

- **EKS Pod Identity** (implemented in `infra/terraform/`): each workload's
  ServiceAccount maps to an IAM role via a Pod Identity association — a
  first-class AWS resource, no per-cluster OIDC trust wiring and no
  ServiceAccount annotations. ESO's SA can read only its env's secrets
  path; no node-level credentials, no static keys in pods. IRSA (the OIDC
  provider) is kept only for third-party charts that don't support Pod
  Identity yet.
- Humans: SSO (IAM Identity Center) → `aws-auth`/access entries mapping to
  Kubernetes groups; read-only by default, changes via Git.
- CI: GitHub Actions **OIDC federation** — no long-lived AWS keys in GitHub;
  the workflow assumes a role scoped to ECR push only.

## Container registry

- **ECR** per account; CI pushes via OIDC-assumed role.
- Nodes pull via their instance role / pod identity — **no imagePullSecrets
  in production** (the GHCR PAT in the demo is explicitly a local shortcut).
- ECR scan-on-push (in addition to Trivy in CI); immutable tags enabled at
  the registry level — `sha-<commit>` cannot be overwritten.
- Cross-account replication: build once in a shared "tooling" account,
  replicate to env accounts; promotion never rebuilds.

## Secrets

AWS Secrets Manager + External Secrets Operator (full design in
`docs/security.md`). KMS CMK per environment; IRSA-scoped access;
CloudTrail audit; managed rotation for RDS-style credentials.

## Environment separation

| Layer | Mechanism |
|---|---|
| Accounts | one AWS account per env (Organizations) |
| Clusters | one EKS cluster per env |
| Git | one path per env (`clusters/<env>`, `apps/<env>`); production changes only by PR with CODEOWNERS |
| Secrets | per-env KMS keys + Secrets Manager instances |
| Images | per-env ECR with replication; envs never share mutable state |

## Audit logging

- EKS control-plane logs (api, audit, authenticator) → CloudWatch Logs.
- CloudTrail (org-wide, immutable S3 + Object Lock) for all AWS API calls.
- Git history + Flux events = deployment audit trail (who merged what, when
  it reconciled).

## Encryption

- etcd: EKS secrets envelope-encrypted with a KMS CMK.
- EBS volumes / S3 buckets: encrypted by default (KMS).
- In transit: TLS at the LB, cluster-internal mTLS via mesh (App Mesh/Istio)
  only when compliance requires it — not by default (operational cost).

## Backup and restore

- **Velero** → S3: cluster state + PV snapshots on schedule; but the primary
  recovery story is GitOps: a fresh cluster + `flux bootstrap` + the sops-age
  key restores everything stateless in minutes.
- Stateful data (RDS, etc.) uses native AWS backups/PITR — databases don't
  live in the cluster.

## Scaling and node provisioning

- **Karpenter**: right-sized nodes just-in-time, consolidation, Spot for
  dev/staging and stateless prod workloads with PDBs protecting availability
  (our PDB + anti-affinity already accommodate this).
- HPA (already in chart) for pods; Karpenter replaces Cluster Autoscaler.

## Cost considerations

- Spot for dev/staging (~70% savings); Graviton (arm64) nodes — our images
  are already multi-arch.
- Karpenter consolidation kills underutilized nodes.
- Kubecost or CloudZero for per-namespace showback.
- Right-size requests from Prometheus data (VPA in recommend-mode).
- One NAT gateway per AZ only in production; single NAT in dev.

## Disaster recovery

- **RTO driver is data, not compute**: clusters are cattle — re-bootstrap
  from Git (proven: this repo built the demo cluster from zero twice).
- Multi-AZ by default; multi-region only if the business case exists:
  ECR replication + Route 53 failover + warm standby cluster reconciled
  from the same Git repo (`clusters/production-dr`).
- Runbook: create cluster (Terraform) → restore sops-age/ESO IAM → flux
  bootstrap → verify Kustomizations Ready → shift DNS. Target < 1h for
  stateless tier.

## Infrastructure as code

Terraform (separate repo or `infra/` root): VPC, EKS, IAM roles (IRSA),
ECR, KMS, Secrets Manager, Route 53. Terraform owns "the platform exists";
Flux owns "what runs on it". The boundary is the cluster API: Terraform
never applies Kubernetes manifests beyond Flux's bootstrap.
