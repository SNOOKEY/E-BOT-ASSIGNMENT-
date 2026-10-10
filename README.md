# Enterprise Bot DevOps Assessment

A streamlined Kubernetes deployment showcasing microservice containerization, Helm orchestration, cluster automation, and systematic debugging.

---

## 1. How to Run and Verify

### Prerequisites
* Docker, Kind, kubectl, Helm.

### Automated Setup
Run the bootstrap script to create the local Kind cluster, install Ingress-Nginx, build the image, and deploy the Helm release:

```bash
./setup.sh
```

### Verification Steps

1. **Check cluster workloads:**
   ```bash
   kubectl -n demo get pods,svc,ingress
   ```

2. **Test application endpoint (via Ingress):**
   ```bash
   curl -i -H "Host: demo.local" http://localhost/
   ```
   *Expected response (`200 OK`):*
   ```json
   {"app": "demo", "version": "1.0.0", "pod": "<pod-name>"}
   ```

3. **Check health probe:**
   ```bash
   curl -i -H "Host: demo.local" http://localhost/healthz
   ```

4. **Verify zero-downtime rolling update:**
   ```bash
   helm upgrade demo ./chart -n demo --set config.version="2.0.0"
   curl -s -H "Host: demo.local" http://localhost/
   ```

### Debug Lab (Part 4)
Run and verify the debugging lab:
```bash
./lab/scenario.sh up      # Install lab
./lab/scenario.sh verify  # Run validation checks
./lab/scenario.sh reset   # Clean up
```
*For detailed root-cause analyses and defect evidence, see [`lab/FINDINGS.md`](lab/FINDINGS.md).*

---

## 2. Resource Requests and Limits

Configured in `chart/values.yaml`:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

### Why These Numbers?
* **Memory (`64Mi` request / `128Mi` limit):** Python 3.12 baseline idle memory footprint is ~30 MiB. A `64Mi` request guarantees safe scheduling without overcommitting node memory, while a `128Mi` limit provides sufficient headroom for request bursts without triggering OOMKills.
* **CPU (`50m` request / `200m` limit):** The lightweight single-threaded HTTP server consumes < 10m idle. Requesting `50m` guarantees CPU scheduling on shared nodes, while `200m` allows up to 4× bursting during traffic spikes and JSON serialization.
* **QoS Tier:** `Burstable`, balancing node bin-packing density with workload stability.

---

## 3. What Was Deliberately Skipped (and the Risks)

| Skipped Item | Risk of Skipping | Why Skipped |
| :--- | :--- | :--- |
| **TLS / HTTPS on Ingress** | Unencrypted traffic is vulnerable to interception and MitM attacks in transit. | Simplifies local Kind evaluation; avoids self-signed certificate browser/curl errors. |
| **Horizontal Pod Autoscaler (HPA)** | Service cannot scale out automatically during sudden traffic spikes. | Kind clusters do not include `metrics-server` out of the box. |
| **NetworkPolicies** | Any pod in the cluster can communicate directly with the service port. | Default KinDnet CNI does not enforce NetworkPolicy rules without a custom CNI. |
| **Production WSGI/ASGI Server** | Standard library `http.server` lacks advanced connection pooling and worker recycling. | Kept dependency-free per assignment requirements. |

---

## 4. What Would Be Changed for Production

To make this enterprise-ready:
* **High Availability:** Add a `PodDisruptionBudget` (`minAvailable: 1`) and `podAntiAffinity` across availability zones.
* **Security Hardening:** Migrate to a distroless container image (`distroless/python3`), manage secrets via External Secrets Operator / Vault, and enforce network isolation via `NetworkPolicy`.
* **Observability:** Implement structured JSON logging, export Prometheus metrics with a `ServiceMonitor`, and configure OpenTelemetry distributed tracing.
* **Ingress & TLS:** Enable automated TLS certificates via Cert-Manager and configure rate limiting.

---

## 5. How I Used AI

### Tools & Environments
* **Claude Code (Anthropic):** Used for Python standard library HTTP server syntax in `service/app.py` and initial Dockerfile multi-stage structure.
* **Google Antigravity:** Used for Part 4 Kubernetes troubleshooting (including analyzing the stripped binary in `eb-debug-app` to identify the hardcoded `io.LimitReader` 1024-byte truncation) and technical documentation.
* **Environments:** Visual Studio Code, GitHub Codespaces, and terminal CLIs.

### Manual Verification
* Tested and verified Kind cluster creation, Ingress routing, and Helm rollouts locally.
* Preserved container security hardening (`runAsUser: 10001` with `runAsNonRoot: true`) rather than simply disabling security controls.
* Adjusted workload resources to comply with namespace `LimitRange` guardrails (`limits.yaml`).
* Confirmed all bug fixes against `./lab/scenario.sh verify` and validated CI pipeline checks.
