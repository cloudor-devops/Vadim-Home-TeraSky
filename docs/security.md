# Security: Secrets, RBAC, Policy-as-Code

## Secrets management (implemented: SOPS + [age](https://github.com/FiloSottile/age))

age is the file-encryption tool SOPS uses here for key management; the
lowercase name is the project's official spelling.

**Where stored:** encrypted in Git (`apps/<env>/*.enc.yaml`). Only `data`/
`stringData` values are ciphertext (`encrypted_regex`); metadata stays
diffable. Private age keys are never in Git.

**How workloads consume them:** Flux kustomize-controller decrypts at apply
time using the `sops-age` secret in `flux-system`; the decrypted Secret exists
only inside the cluster. The chart references it via
`secret.existingSecret` → `envFrom.secretRef` — the chart never templates
secret material.

**Access control:**
- Encrypt: anyone with the repo + public keys (`.sops.yaml`).
- Decrypt: only holders of the private key — i.e. the target cluster and
  break-glass operators. Git compromise alone leaks nothing.

**Environment separation:** one age keypair per environment. The dev
cluster's key cannot decrypt staging/production files (distinct
`creation_rules` per path in `.sops.yaml`).

**Rotation:**
- Secret value: edit with `sops`, commit → Flux applies; pods restarted to
  pick up env changes (reloader annotation in production).
- Key: `sops updatekeys` re-encrypts with the new recipient; replace the
  cluster's `sops-age` secret.

**Production path — External Secrets Operator:** store secrets in AWS
Secrets Manager; ESO syncs them into Kubernetes Secrets via an
`ExternalSecret` CR. Rotation happens in AWS (Lambda rotators / managed RDS
rotation) with no Git involvement; access controlled by IAM (IRSA per
namespace); audit via CloudTrail. SOPS remains for bootstrap secrets that
must exist before ESO does.

## RBAC

- Dedicated ServiceAccount per release; `automountServiceAccountToken` only
  where needed (this app needs it).
- ClusterRole: `get`,`list` on `nodes` — nothing else. Verified:
  `kubectl auth can-i list secrets --as=system:serviceaccount:node-info-dev:node-info` → no.
- Flux runs with its own controllers' RBAC; humans get read-only cluster
  access — changes go through Git.

## Policy-as-code (implemented: Kyverno, Enforce mode)

Installed by Flux (`infrastructure/controllers`), policies applied before
apps (`dependsOn` ordering). All policies actively **block** at admission —
verified live against `nginx:latest` and a privileged pod.

| Policy | Blocks | Rationale |
|---|---|---|
| disallow-latest-tag | untagged / `:latest` images | mutable tags break rollback + reproducibility |
| require-requests-limits | pods without CPU/mem requests+limits | scheduling, HPA, noisy-neighbour protection |
| require-probes | missing liveness/readiness | rollout safety, self-healing |
| require-run-as-nonroot | root containers | container escape ≠ node root |
| disallow-privileged | privileged / escalation | node takeover prevention |

System namespaces (kube-system, flux-system, kyverno) are excluded — cluster
components have different requirements and are managed by their own charts.

CI-side (shift-left): kube-linter lints the rendered chart on every PR, so
violations fail before merge; Kyverno is the runtime backstop for anything
that bypasses CI (manual applies, other tooling).

Supply chain (next step): cosign-sign images in CI; Kyverno `verifyImages`
admits only signatures from our CI identity.
