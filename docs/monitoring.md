# Monitoring and Logging

Not deployed in the demo (per assignment); this is the production design.

## Stack

| Layer | Tool | Why |
|---|---|---|
| Metrics collection | Prometheus (kube-prometheus-stack via Flux HelmRelease) | De-facto standard; Operator manages scrape configs via ServiceMonitor CRDs |
| Dashboards | Grafana (bundled) | Provisioned dashboards as ConfigMaps → GitOps-managed |
| Alert routing | Alertmanager → Slack/PagerDuty | Dedup, grouping, silence windows |
| Logs | Loki + promtail (or Fluent Bit → CloudWatch on EKS) | Label-based, cheap storage; same query UX as Prometheus |
| Traces (later) | OpenTelemetry → Tempo/X-Ray | Only when service count justifies it |

## Application metrics

The app already exposes `/metrics` (Prometheus format):
- `http_requests_total{method,path,status}` — traffic and error rate
- `http_request_duration_seconds{method,path}` — latency histogram (p50/p95/p99 via `histogram_quantile`)

A `ServiceMonitor` selects the app Service; the Operator generates the scrape
config. RED method: Rate, Errors, Duration per endpoint.

## Workload / cluster monitoring

- **kube-state-metrics** (in kube-prometheus-stack): deployment availability,
  pod restarts, HPA state, PDB status.
- **node-exporter**: CPU, memory, disk, network per node.
- **Control plane**: on EKS, API server/etcd metrics are exposed by AWS;
  scrape `apiserver_request_duration_seconds` for API latency.

## Example alerts (PromQL)

```yaml
# 1. High 5xx error rate (>5% for 5m)
- alert: NodeInfoHighErrorRate
  expr: |
    sum(rate(http_requests_total{status=~"5..", job="node-info"}[5m]))
      / sum(rate(http_requests_total{job="node-info"}[5m])) > 0.05
  for: 5m
  labels: {severity: critical}

# 2. Pod crash looping
- alert: PodCrashLooping
  expr: |
    increase(kube_pod_container_status_restarts_total[15m]) > 3
  for: 5m
  labels: {severity: critical}

# 3. Deployment below desired replicas
- alert: DeploymentUnavailable
  expr: |
    kube_deployment_status_replicas_available{deployment="node-info"}
      < kube_deployment_spec_replicas{deployment="node-info"}
  for: 10m
  labels: {severity: warning}

# 4. HPA pinned at max (can't scale further)
- alert: HPAMaxedOut
  expr: |
    kube_horizontalpodautoscaler_status_current_replicas
      >= kube_horizontalpodautoscaler_spec_max_replicas
  for: 15m
  labels: {severity: warning}

# 5. High p95 latency
- alert: NodeInfoSlowRequests
  expr: |
    histogram_quantile(0.95,
      sum(rate(http_request_duration_seconds_bucket{job="node-info"}[5m])) by (le)
    ) > 0.5
  for: 10m
  labels: {severity: warning}

# 6. Node memory pressure
- alert: NodeMemoryPressure
  expr: kube_node_status_condition{condition="MemoryPressure",status="true"} == 1
  for: 5m
  labels: {severity: critical}
```

## Centralized logging

App logs to stdout (12-factor; already JSON-ready via uvicorn config).
promtail/Fluent Bit tails container logs on every node, attaches
namespace/pod/container labels, ships to Loki (or CloudWatch Logs on EKS).
Retention: 14d hot, archive to S3. No log files in pods — read-only root FS.

## Incident investigation flow

1. Alert fires → Alertmanager → Slack with runbook link.
2. Grafana dashboard: error rate/latency panel → affected pods.
3. Loki: `{namespace="node-info-production"} |= "ERROR"` correlated by time.
4. `kubectl describe pod` / events (via Grafana or CLI) for scheduling/OOM.
5. Flux: `flux get helmreleases` — was there a recent deploy? `git log` the
   overlay → suspect commit → `git revert` = rollback.
