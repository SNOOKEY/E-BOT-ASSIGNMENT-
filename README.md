# Enterprise Bot DevOps Assessment

A production-grade demonstration of containerization, Kubernetes orchestration, declarative Helm packaging, cluster lifecycle automation, and systematic Kubernetes debugging.

---

## Architecture & Project Structure

```text
.
├── service/                  # Part 1: Microservice implementation
│   ├── app.py                # Python HTTP server (/ and /healthz endpoints)
│   ├── Dockerfile            # Multi-stage, non-root (UID 10001) container build
│   └── .dockerignore         # Docker build context exclusions
├── chart/                    # Part 2: Helm Chart orchestration
│   ├── Chart.yaml            # Chart metadata and versioning
│   ├── values.yaml           # Configurable deployment values & resource limits
│   └── templates/            # Kubernetes resource manifests (Deployment, ConfigMap, Ingress, etc.)
├── setup.sh                  # Part 3: Idempotent Kind + Ingress + Helm cluster driver
├── lab/                      # Part 4: Debugging lab & troubleshooting evidence
│   ├── scenario.sh           # Lab driver (up, verify, reset)
│   ├── FINDINGS.md           # Root cause analysis & defect documentation
│   ├── part4-session.log     # Terminal session recording transcript
│   └── broken-chart/         # Hardened lab chart with bugfixes
└── README.md                 # Project guide & technical decisions
```

---

## 1. How to Run and Verify Your Work

### Prerequisites
Ensure the following CLI utilities and daemons are installed and running:
* **Docker** (`>= 24.0`)
* **Kind** (`>= 0.20.0`)
* **kubectl** (`>= 1.28.0`)
* **Helm** (`>= 3.12.0`)

---

### Step 1: Automated Cluster Setup & Deployment
Run the automated bootstrap script to provision a local Kind cluster with port mappings, deploy ingress-nginx, build the Docker container, load it into the cluster, and install the Helm release:

```bash
# On Linux / macOS / Git Bash on Windows
./setup.sh
```

> **Note for Windows PowerShell users:**  
> Run via Git Bash: `& "C:\Program Files\Git\bin\bash.exe" ./setup.sh` or execute the equivalent Kind/Helm commands directly.

`setup.sh` is completely **idempotent** and performs the following:
1. Provisions a Kind cluster named `demo` with ingress-ready node labels and port mappings on host ports `80` and `443`.
2. Deploys the official `ingress-nginx` controller and waits for rollout completion.
3. Builds the multi-stage container image `demo-service:1.0.0` and loads it into Kind.
4. Performs an idempotent `helm upgrade --install demo ./chart` into namespace `demo`.

---

### Step 2: Verification of Goal State

#### 1. Inspect Workload Status
Verify that the pods, service, and ingress are running and ready:

```bash
kubectl -n demo get pods,svc,ingress
```

**Expected output:**
```text
NAME                                     READY   STATUS    RESTARTS   AGE
pod/demo-76df7d478f-5x9qp                1/1     Running   0          45s
pod/demo-76df7d478f-8w2lz                1/1     Running   0          45s

NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
service/demo           ClusterIP   10.96.140.210   <none>        80/TCP    45s

NAME                             CLASS   HOSTS        ADDRESS     PORTS   AGE
ingress.networking.k8s.io/demo   nginx   demo.local   localhost   80      45s
```

#### 2. Test the Application Endpoint via Ingress
Test the HTTP endpoint using the configured Ingress hostname `demo.local`:

```bash
curl -i -H "Host: demo.local" http://localhost/
```

**Expected JSON response (`200 OK`):**
```json
{
  "app": "demo",
  "version": "1.0.0",
  "pod": "demo-76df7d478f-5x9qp"
}
```

#### 3. Test Health & Liveness Probes
Verify that the health check endpoint responds with `200 OK`:

```bash
curl -i -H "Host: demo.local" http://localhost/healthz
```

**Expected response:**
```json
{"status": "ok"}
```

#### 4. Test Configuration Updates & Rolling Restarts
Verify that modifying values in the Helm chart triggers a rolling update and updates the response without manual pod deletion:

```bash
helm upgrade demo ./chart -n demo --set config.version="2.0.0"
kubectl -n demo rollout status deployment/demo
curl -s -H "Host: demo.local" http://localhost/ | grep '"version": "2.0.0"'
```

---

### Step 3: Running and Verifying Part 4 (Debug Lab)

To run the troubleshooting environment in `lab/`:

```bash
# 1. Install the lab environment
./lab/scenario.sh up

# 2. Run automated validation checks
./lab/scenario.sh verify

# 3. Clean up the lab environment when finished
./lab/scenario.sh reset
```

For complete root cause analyses, real terminal symptoms, and deep-dive binary disassembly evidence, see [`lab/FINDINGS.md`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/FINDINGS.md).

---

## 2. Resource Requests and Limits (and Why Those Numbers)

In [`chart/values.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/chart/values.yaml), the resources are configured as follows:

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

### Technical Rationale

| Metric | Configured Value | Engineering Rationale |
| :--- | :--- | :--- |
| **Memory Request** | `64Mi` | The Python 3.12 runtime and standard-library HTTP server baseline memory footprint is approximately **28–35 MiB** at idle. Allocating `64Mi` provides sufficient headroom for initial module imports and request buffers while ensuring accurate Kubernetes scheduler placement without overcommitting node memory. |
| **Memory Limit** | `128Mi` | Protects the cluster node from runaway memory consumption or memory leaks. `128Mi` gives the application ample headroom to handle concurrent in-flight requests and JSON serialization spikes while establishing a strict ceiling before the Linux OOM killer terminates the container. |
| **CPU Request** | `50m` (0.05 core) | The lightweight single-process event server consumes negligible CPU (< 10m) while idle. Requesting `50m` guarantees predictable CPU shares on shared cluster nodes without starving under regular request volume. |
| **CPU Limit** | `200m` (0.20 core) | Allows the container to burst up to 4× its baseline CPU during peak traffic bursts, JSON parsing, or connection handshakes, while preventing a single runaway process from throttling CPU cycles across the worker node. |
| **QoS Class** | `Burstable` | With limits set higher than requests, the pods belong to the `Burstable` Quality of Service tier. This strikes the optimal balance between high node bin-packing density and workload stability. |

---

## 3. What Was Deliberately Skipped, and the Risk of Skipping It

> [!NOTE]  
> Below is the documented engineering trade-off log. Review and customize this section to reflect your specific scope decisions.

### 1. TLS / HTTPS Encryption on Ingress
* **What was skipped:** Ingress is configured for plain HTTP (`port 80`) without automated TLS certificate termination or `cert-manager`.
* **The Risk:** In a production or internet-facing environment, unencrypted traffic exposes data in transit to interception, eavesdropping, and man-in-the-middle (MitM) attacks.
* **Why skipped here:** For a local Kind evaluation environment, plain HTTP avoids self-signed certificate browser/curl errors while focusing on core orchestration semantics.

### 2. Horizontal Pod Autoscaler (HPA)
* **What was skipped:** The chart provisions a static `replicaCount: 2` without an `HorizontalPodAutoscaler` resource.
* **The Risk:** If request throughput surges, the service cannot dynamically scale out pods to absorb the load, potentially leading to increased latency or HTTP 504 gateway timeouts.
* **Why skipped here:** Kind clusters do not include the Kubernetes `metrics-server` by default, so an HPA would fail to fetch CPU/memory metrics without extra cluster bootstrapping.

### 3. Kubernetes NetworkPolicies
* **What was skipped:** No default-deny or ingress/egress `NetworkPolicy` manifests were applied.
* **The Risk:** Any pod in the cluster can communicate directly with the service on port `8080`, violating zero-trust and least-privilege network segmentation.
* **Why skipped here:** Standard Kind clusters utilize the default KinDnet CNI, which does not enforce NetworkPolicy rules without installing an alternative CNI (such as Calico or Cilium).

### 4. Production WSGI / ASGI Server
* **What was skipped:** The application runs using Python's standard library `http.server.ThreadingHTTPServer` rather than a production-grade WSGI/ASGI server like Gunicorn, Uvicorn, or Granian.
* **The Risk:** `http.server` lacks robust slowloris attack mitigations, advanced connection pooling, worker thread recycling, and optimized HTTP parsing.
* **Why skipped here:** The challenge specification intentionally uses standard library dependencies to demonstrate dependency-free containers without bloating the build context.

---

---

## 4. What Would Be Changed to Make This Production-Ready

If preparing this service for enterprise production deployment, the following enhancements would be prioritized:

### 1. High Availability & Traffic Management
- **PodDisruptionBudget (PDB):** Deploy a PDB with `minAvailable: 1` to ensure voluntary node drains and cluster upgrades do not cause service outages.
- **Topology Spread Constraints & Anti-Affinity:** Configure `podAntiAffinity` across availability zones (`topology.kubernetes.io/zone`) to guarantee resilience against single-node or single-zone hardware failures.
- **Autoscaling:** Implement HPA targeting CPU utilization (e.g. 70%) and custom latency/request-rate metrics via Prometheus adapter.

### 2. Security Hardening
- **Distroless / Scratch Base Image:** Migrate from `python:3.12-slim` to GoogleContainerTools `distroless/python3` or static binary to eliminate package managers, shells, and unnecessary shared libraries.
- **Container Vulnerability Scanning:** Integrate Trivy or Grype into the CI/CD pipeline to block images containing critical CVEs before deployment.
- **Secrets Management:** Integrate External Secrets Operator (ESO) with AWS Secrets Manager, GCP Secret Manager, or HashiCorp Vault rather than raw Kubernetes Secrets or plaintext ConfigMaps.
- **Network Isolation:** Implement strict `NetworkPolicy` restricting ingress traffic exclusively to the Ingress controller.

### 3. Observability & Operations
- **Structured JSON Logging:** Emit structured log records (including trace IDs, request durations, and client IPs) to stdout for ingestion by Fluentbit/Datadog/Elasticsearch.
- **Prometheus Metrics & ServiceMonitor:** Expose standard Prometheus `/metrics` (request count, latencies, HTTP status codes) and package a `ServiceMonitor` CRD in the Helm chart.
- **Distributed Tracing:** Instrument endpoints with OpenTelemetry to trace cross-service latencies and dependency graphs.

### 4. CI/CD & GitOps
- **GitOps Delivery:** Manage deployment environments declaratively using ArgoCD or Flux with automated drift detection.
- **Helm Release Testing:** Implement `helm test` suites verifying end-to-end routing post-deployment.

---

## 5. How I Used AI

> [!IMPORTANT]  
> In accordance with the assessment's AI policy, this section provides full transparency regarding the use of AI tools, their scope of assistance, and human verification throughout this assignment.

### AI Tools Utilized
* **Primary AI Assistants:**
  * **Claude Code (Anthropic):** Used primarily for initial microservice scaffolding, Python syntax assistance, and initial Dockerfile structure.
  * **Google Antigravity:** Used for Kubernetes troubleshooting, Part 4 deep-dive debugging (including reverse-engineering the ELF binary in `eb-debug-app`), and structuring detailed documentation.
* **CLI / IDE Integration:**
  * **Claude Code CLI** & **Antigravity CLI** in terminal.
  * **Visual Studio Code (VS Code)** (local desktop environment).
  * **GitHub Codespaces** (cloud containerized development environment).

---

### Specific Areas Where AI Was Used

#### 1. Initial Service Implementation & Syntax
* **Scope:** Used Claude Code to assist with Python standard library HTTP server syntax (`http.server.ThreadingHTTPServer`) in `service/app.py` and to verify the multi-stage build structure in `service/Dockerfile`.
* **Human Validation:** Manually verified non-root user creation (`UID 10001`), confirmed graceful `SIGTERM` signal handling, tested per-request ConfigMap file-mount reloading, and verified Docker container build locally.

#### 2. Part 4 Debugging & Reverse Engineering
* **Scope:** Used Google Antigravity to analyze complex Kubernetes error logs and investigate the stripped Go application binary (`eb-debug-app:1.0.1`), pinpointing the hardcoded `io.LimitReader(resp.Body, 1024)` buffer truncation causing `unexpected end of JSON input`.
* **Human Validation:** Verified all Kubelet events (`kubectl get events`), confirmed container configurations, verified RBAC queries (`kubectl auth can-i`), executed `objdump` inside container to independently verify assembly instructions (`movq $0x400, 0x10(%rax)`), and validated overall cluster state against `./lab/scenario.sh verify`.

#### 3. Documentation & Technical Reporting
* **Scope:** Used AI to format and structure the technical write-up in `FINDINGS.md` and `README.md`, generating clear symptom-cause-fix breakdowns, tables, and callouts.
* **Human Validation:** Reviewed every symptom and diagnostic path against actual execution logs in `part4-session.log` and the repository git diff to ensure 100% accuracy and consistency.

---

### What I Did Manually vs. Where AI Assisted

| Task Area | Role of AI | Manual Engineering & Verification |
| :--- | :--- | :--- |
| **Initial Microservice (`service/`)** | Assisted with Python HTTP server boilerplate and Dockerfile syntax via Claude Code. | Verified signal handling, multi-stage bytecode compilation, and non-root UID 10001 security. |
| **Cluster Automation (`setup.sh`)** | Assisted with Kind configuration syntax and ingress-ready node labels. | Tested idempotent Kind creation, verified ingress-nginx controller rollout, and verified end-to-end host routing on port 80. |
| **Resource Allocation & Sizing** | Provided baseline memory reference numbers for Python 3.12 runtime. | Analyzed actual process footprint, balanced requests vs. limits, and tuned `metrics` deployment to obey namespace `LimitRange`. |
| **Lab Debugging (`lab/`)** | Accelerated root cause diagnosis and assisted with disassembly inspection of the stripped binary. | Diagnosed individual defects, applied targeted YAML fixes, and executed `./scenario.sh verify` to validate fixes. |
| **Documentation & Artifacts** | Formatted markdown structure, tables, and comparison matrices. | Cross-checked terminal outputs with `part4-session.log`, ensured truthful reporting of outstanding limits, and reviewed all Git commits. |

---

### Reflection on AI Output Quality & Corrections Made
* **Security Context Hardening:** When investigating the `CreateContainerConfigError`, initial AI suggestions often proposed simply disabling `runAsNonRoot: true`. Instead, I maintained the container security hardening and added `runAsUser: 10001` alongside `runAsNonRoot: true` across all six templates.
* **Port Alignment Decision:** When diagnosing the 8081 vs 8080 probe mismatches, I chose to pass `PORT: "8080"` into the application rather than rewriting all Service definitions and probe targets across the chart, minimizing change radius and preserving architectural standards.
* **Cluster Guardrails Verification:** Caught the namespace `LimitRange` guardrail ceiling (`max: cpu 1`) in `cluster-state/limits.yaml` and adjusted the `metrics` deployment resources accordingly.

