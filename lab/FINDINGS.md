# Findings — Part 4 Debug Lab

> **Environment Note:**  
> Session log recorded in [`part4-session.log`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/part4-session.log) via PowerShell `Start-Transcript -Path part4-session.log -Append`. All terminal commands and output snippets presented below reflect real execution output cross-verified against `part4-session.log` and the Git repository diff.

---

## Executive Summary

| Defect # | Target Component | Root Cause | Resolution | Status |
| :--- | :--- | :--- | :--- | :--- |
| **Defect 1** | `migrate` Job | Invalid `restartPolicy: Always` in batch Job spec | Changed `restartPolicy` to `OnFailure` | ✅ Resolved |
| **Defect 2** | Workload Pods (All 6) | `runAsNonRoot: true` without explicit numeric UID | Added `runAsUser: 10001` alongside `runAsNonRoot` | ✅ Resolved |
| **Defect 3** | App Workloads (All 5) | Missing `PORT` env var; app defaults to 8081 vs chart 8080 | Injected `PORT: "8080"` into workload env blocks | ✅ Resolved |
| **Defect 4** | `worker` Deployment | Read-only root filesystem prevents write to `/var/cache/app` | Mounted `emptyDir` scratch volume at `/var/cache/app` | ✅ Resolved |
| **Defect 5** | `gateway` Deployment | `BACKEND_URL` points to `backend.default.svc` | Corrected URL to `http://backend.debug-lab.svc:8080` | ✅ Resolved |
| **Defect 6** | `reporter` RBAC | `RoleBinding` subjects bound to `default` ServiceAccount | Re-bound subject to ServiceAccount `reporter` | ✅ Resolved |
| **Bonus** | `metrics` Deployment | CPU requests/limits exceeded LimitRange ceiling (4 > 1) | Adjusted requests (`100m`) and limits (`500m`) | ✅ Resolved |

---

## Defect 1 — Migrate Job Rejected by Helm

### Symptom
Running `./scenario.sh up` halts immediately during the Helm release installation with an API server admission rejection:

```text
==> applying cluster environment (cluster-state/)
limitrange/debug-lab-guardrails created
namespace/debug-lab unchanged
==> installing the broken chart
level=WARN msg="upgrade failed" name=debug-lab error="failed to create resource: Job.batch \"migrate\" is invalid: spec.template.spec.restartPolicy: Required value: valid values: \"OnFailure\", \"Never\""
Error: UPGRADE FAILED: failed to create resource: Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"

helm reported an error. That is not your machine misbehaving —
it is part of the exercise. Read the error; it is evidence.
```

### Cause
In [`templates/migrate-job.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/migrate-job.yaml), the Pod template specifies `restartPolicy: Always`. Under Kubernetes specifications (`Job.batch`), Jobs represent finite batch tasks where pods must terminate upon completion. Consequently, the Kubernetes API server enforces that `spec.template.spec.restartPolicy` must be either `OnFailure` or `Never`. The API server rejects manifests with `Always`, causing the Helm deployment to fail and aborting the entire release rollout.

### Fix
Changed `restartPolicy` to `OnFailure` in [`templates/migrate-job.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/migrate-job.yaml):

```yaml
spec:
  template:
    spec:
      restartPolicy: OnFailure
```

**Rationale:** `OnFailure` was chosen over `Never` because if a transient network partition or database glitch occurs during migration, Kubernetes will automatically restart the container within the existing pod rather than abandoning the job or requiring manual intervention, while still terminating cleanly upon successful execution (`Completed 1/1`).

### How I Found It
1. Executed `./scenario.sh up`.
2. Read the standard error emitted by Helm and the Kubernetes API server:
   `Job.batch "migrate" is invalid: spec.template.spec.restartPolicy: Required value: valid values: "OnFailure", "Never"`.
3. Inspected [`templates/migrate-job.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/migrate-job.yaml#L16), updated `restartPolicy: OnFailure`, and re-ran `./scenario.sh up`.
4. Verified with `kubectl -n debug-lab get job migrate`, observing status `Complete 1/1`.

---

## Defect 2 — Pods Stuck in `CreateContainerConfigError`

### Symptom
After the Helm chart installed, all application pods failed to start and remained stuck in `CreateContainerConfigError`:

```text
PS> kubectl -n debug-lab get pods
NAME                        READY   STATUS                       RESTARTS   AGE
backend-7948fd6b4b-766gd    0/1     CreateContainerConfigError   0          24m
gateway-5cbdcd4bf8-txrqn    0/1     CreateContainerConfigError   0          24m
metrics-547dccf75-56bcp     0/1     CreateContainerConfigError   0          24m
reporter-6f8bff6b8d-2h57t   0/1     CreateContainerConfigError   0          24m
worker-5fcd6b9b6b-jhx79     0/1     CreateContainerConfigError   0          24m

PS> kubectl -n debug-lab logs deploy/gateway
Error from server (BadRequest): container "gateway" in pod "gateway-5cbdcd4bf8-txrqn" is waiting to start: CreateContainerConfigError

PS> kubectl -n debug-lab get events --sort-by=.lastTimestamp | Select-String "Warning"
26m  Warning  Failed  pod/backend-7948fd6b4b-766gd   Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root (pod: "backend-7948fd6b4b-766gd_debug-lab(6bec4e26-5c4e-4b8e-99f2-048b86436716)", container: backend)
26m  Warning  Failed  pod/gateway-5cbdcd4bf8-txrqn   Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
26m  Warning  Failed  pod/worker-5fcd6b9b6b-jhx79    Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root
```

### Cause
The pod templates specify `securityContext.runAsNonRoot: true`. However, the container image (`docker.io/ebinterview/eb-debug-app:1.0.1`) defines its execution user by name (`USER nonroot`) rather than a numeric UID (e.g. `USER 10001`). Because the Kubelet container runtime cannot inspect image `/etc/passwd` to definitively prove that the named user maps to a non-zero UID, it halts container startup with a security configuration error.

### Fix
Added `runAsUser: 10001` alongside `runAsNonRoot: true` in the `securityContext` of all six workload templates ([`backend.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/backend.yaml), [`gateway.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/gateway.yaml), [`worker.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/worker.yaml), [`reporter.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/reporter.yaml), [`metrics.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/metrics.yaml), and [`migrate-job.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/migrate-job.yaml)):

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 10001
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
```

**Rationale:** Retaining `runAsNonRoot: true` and adding `runAsUser: 10001` preserves the pod security standard hardening while providing the Kubelet with the unambiguous numeric UID it requires.

### How I Found It
1. Observed pods in `CreateContainerConfigError` via `kubectl get pods -n debug-lab`.
2. Checked pod events using `kubectl -n debug-lab get events --sort-by=.lastTimestamp`.
3. Read the warning message: `Error: container has runAsNonRoot and image has non-numeric user (nonroot), cannot verify user is non-root`.
4. Inspected the image configuration (`docker image inspect ebinterview/eb-debug-app:1.0.1 --format '{{.Config.User}}'`), confirming `"nonroot"` with UID 10001 in `/etc/passwd`.
5. Applied `runAsUser: 10001` to all workload templates.

---

## Defect 3 — Workloads Listening on Wrong Port (8081 vs 8080)

### Symptom
Once containers started, all HTTP readiness probes failed with connection errors:

```text
PS> kubectl -n debug-lab get events --sort-by=.lastTimestamp
Warning  Unhealthy  pod/backend-6667f9f97c-6kshq  Readiness probe failed: Get "http://10.244.0.14:8080/healthz": dial tcp 10.244.0.14:8080: connect: connection refused
Warning  Unhealthy  pod/gateway-6c78fd6c6f-ljjmr  Readiness probe failed: Get "http://10.244.0.13:8080/healthz": dial tcp 10.244.0.13:8080: connect: connection refused
Warning  Unhealthy  pod/reporter-5b688c4c67-7p59q Readiness probe failed: Get "http://10.244.0.16:8080/healthz": dial tcp 10.244.0.16:8080: connect: connection refused

PS> kubectl -n debug-lab logs backend-6667f9f97c-6kshq
2026/10/10 10:15:00 eb-debug-app 0.0.0 starting: mode=api pod=backend-6667f9f97c-6kshq listening on :8081 (image default is 8081; set PORT to override)
```

### Cause
The Go application binary defaults to listening on port `8081` unless overridden by the `PORT` environment variable. The Helm chart's Kubernetes Services and readiness probes target `common.port` (`8080`), but the workload templates omitted the `PORT` environment variable in their container specs. Consequently, the application bound to `8081` while the kubelet probed `8080`, resulting in immediate TCP `connection refused` errors.

### Fix
Injected `PORT: {{ .Values.common.port | quote }}` into the environment blocks of [`backend.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/backend.yaml), [`gateway.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/gateway.yaml), [`worker.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/worker.yaml), [`reporter.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/reporter.yaml), and [`metrics.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/metrics.yaml):

```yaml
env:
  - name: PORT
    value: {{ .Values.common.port | quote }}
```

**Rationale:** Adjusting the application's listening port to match `common.port` (`8080`) is significantly cleaner and less invasive than changing the entire chart's Service ports, ingress targets, and probes from 8080 to 8081.

### How I Found It
1. Analyzed readiness probe failure events showing `dial tcp ...:8080: connect: connection refused`.
2. Checked application startup logs via `kubectl -n debug-lab logs <pod>`, which explicitly logged: `listening on :8081 (image default is 8081; set PORT to override)`.
3. Compared the application's logged port (8081) against the probe port in `kubectl describe pod` (8080).
4. Verified that setting `PORT="8080"` causes the process to bind to `:8080`.

---

## Defect 4 — Worker Crashes on Read-Only Filesystem

### Symptom
The worker pod crashed immediately on boot and entered `CrashLoopBackOff`:

```text
PS> kubectl -n debug-lab get pods
NAME                     READY   STATUS             RESTARTS      AGE
worker-648bddc865-27ln4  0/1     CrashLoopBackOff   3 (3s ago)    42s

PS> kubectl -n debug-lab logs worker-648bddc865-27ln4 --previous
2026/10/10 10:20:12 eb-debug-app 0.0.0 starting: mode=worker pod=worker-648bddc865-27ln4 listening on :8080 (image default is 8081; set PORT to override)
FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system — the process needs a writable directory at /var/cache/app (mount a volume there, or set CACHE_DIR)
```

### Cause
[`templates/worker.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/worker.yaml) enforces container security with `readOnlyRootFilesystem: true`. When initialized in `worker` mode, the binary attempts to create and use `/var/cache/app` for local caching. With the root filesystem locked as read-only, the `mkdir` syscall fails with `read-only file system`, prompting an immediate fatal exit.

### Fix
Defined an ephemeral `emptyDir` volume named `cache` at the pod level and mounted it to `/var/cache/app` in [`templates/worker.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/worker.yaml):

```yaml
    spec:
      containers:
        - name: worker
          volumeMounts:
            - name: cache
              mountPath: /var/cache/app
      volumes:
        - name: cache
          emptyDir: {}
```

**Rationale:** Mounting an `emptyDir` scratch directory preserves the security benefits of an immutable read-only root filesystem while providing the application with the isolated, writable directory it requires for transient cache storage.

### How I Found It
1. Noticed `worker` in `CrashLoopBackOff` via `kubectl get pods -n debug-lab`.
2. Inspected previous container termination logs via `kubectl -n debug-lab logs deploy/worker --previous`.
3. Read the fatal message directly identifying the path: `FATAL: worker could not initialise its cache: mkdir /var/cache/app: read-only file system`.
4. Mounted the `emptyDir` volume and verified the worker started and transitioned to `1/1 Running`.

---

## Defect 5 — Gateway Points at Wrong Namespace

### Symptom
Running `./scenario.sh verify` reported degraded gateway status:

```text
PS> ./scenario.sh verify
...
  FAIL  gateway /status does not report backend=ok

PS> kubectl -n debug-lab exec deploy/gateway -- wget -q -O- http://localhost:8080/status
{"status":"degraded","backend":"error: Get \"http://backend.default.svc:8080/healthz\": dial tcp: lookup backend.default.svc on 10.96.0.10:53: no such host"}
```

### Cause
In [`values.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/values.yaml#L38), the gateway environment variable `BACKEND_URL` was configured as `"http://backend.default.svc:8080"`. Because the backend Service is deployed in namespace `debug-lab`, the hostname `backend.default.svc` does not exist in cluster DNS, causing all upstream calls from the gateway to fail with DNS resolution errors.

### Fix
Updated `BACKEND_URL` in [`values.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/values.yaml) to point to the correct namespace:

```yaml
gateway:
  env:
    APP_MODE: "gateway"
    APP_NAME: "gateway"
    VERSION: "2.0.0"
    BACKEND_URL: "http://backend.debug-lab.svc:8080"
```

**Rationale:** Specifying the fully qualified service domain `backend.debug-lab.svc:8080` guarantees explicit, deterministic cross-pod routing regardless of local pod search namespaces.

### How I Found It
1. Checked `./scenario.sh verify` output indicating `gateway /status does not report backend=ok`.
2. Curled `/status` on the gateway Service.
3. Examined the error message: `lookup backend.default.svc on 10.96.0.10:53: no such host`.
4. Cross-referenced `kubectl -n debug-lab get svc backend`, noting that the backend service resides in `debug-lab`, not `default`.
5. Updated `values.yaml` and verified with `scenario.sh verify`.

---

## Defect 6 — Reporter Receives 403 Forbidden from Kubernetes API

### Symptom
The reporter pod failed to list pods in the namespace, logging HTTP 403 authorization rejections:

```text
PS> kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter
no

PS> kubectl -n debug-lab logs deploy/reporter
2026/10/10 11:45:10 pod list failed: HTTP 403 Forbidden: pods is forbidden: User "system:serviceaccount:debug-lab:reporter" cannot list resource "pods" in API group "" in the namespace "debug-lab"
```

### Cause
In [`templates/rbac.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/rbac.yaml#L34), the `RoleBinding` `reporter-read` bound the Role to `ServiceAccount` `default` instead of `reporter`. Because the reporter deployment runs under `serviceAccountName: reporter`, the API server denied pod listing privileges to the reporter pod.

### Fix
Corrected the `subjects` section in [`templates/rbac.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/rbac.yaml) to bind to `name: reporter`:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: reporter-read
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: reporter-read
subjects:
  - kind: ServiceAccount
    name: reporter
    namespace: {{ .Release.Namespace }}
```

**Rationale:** Granting permissions to `default` would violate least privilege by giving pod listing permissions to every workload in the namespace using the default service account. Correcting the subject ensures only the `reporter` ServiceAccount receives the necessary read privileges.

### How I Found It
1. Ran `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter` and observed `no`.
2. Inspected [`templates/rbac.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/templates/rbac.yaml) and found `subjects.name: default`.
3. Updated the subject to `name: reporter` and re-applied Helm release.
4. Tested again with `kubectl auth can-i list pods -n debug-lab --as=system:serviceaccount:debug-lab:reporter`, which returned `yes`.

---

## Bonus Defect — Metrics CPU Request/Limit Exceeded LimitRange

### Symptom
When the chart was initially deployed, the `metrics` deployment failed pod creation with an admission controller error:

```text
Warning  FailedCreate  replicaset/metrics-547dccf75  Error creating: pods "metrics-547dccf75-56bcp" is forbidden: maximum cpu usage per Container is 1, but limit is 4
```

### Cause
[`cluster-state/limits.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/cluster-state/limits.yaml) establishes a namespace `LimitRange` guardrail with `max.cpu: "1"`. In the original [`values.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/values.yaml), `metrics.resources` requested `cpu: "2"` with a limit of `cpu: "4"`. The Kubernetes admission controller rejected the pod because the container CPU limits exceeded the maximum permitted ceiling.

### Fix
Updated `metrics.resources` in [`values.yaml`](file:///C:/Users/anazs/projects/E-BOT-ASSIGNMENT-/lab/broken-chart/values.yaml) to comply with the namespace LimitRange:

```yaml
metrics:
  resources:
    requests:
      cpu: "100m"
      memory: "64Mi"
    limits:
      cpu: "500m"
      memory: "128Mi"
```

---

## Deep Dive & Outstanding Issue Analysis

### The Phenomenon
After resolving Defects 1 through 6, executing `./scenario.sh verify` shows 9 out of 11 checks passing, with the `reporter` deployment still reporting unready:

```text
==> verifying goal state in namespace debug-lab
  PASS  migrate Job completed
  PASS  deployment backend: 1/1 ready
  PASS  deployment gateway: 1/1 ready
  PASS  deployment worker: 1/1 ready
  FAIL  deployment reporter: 0/1 ready
  PASS  deployment metrics: 1/1 ready
  PASS  no pods in CrashLoopBackOff
  PASS  ServiceAccount debug-lab/reporter can list pods
  PASS  backend answers on http://backend:8080/healthz
  PASS  gateway /status reports backend=ok
  FAIL  reporter /report does not return a pod count

2 check(s) failing, 9 passing.
```

Checking `kubectl -n debug-lab logs deployment/reporter` reveals recurring errors:

```text
2026/10/10 13:12:43 pod list failed: parse pod list: unexpected end of JSON input
2026/10/10 13:12:43 GET /healthz -> 503 (from 10.244.0.1:42364)
```

### Binary Reverse Engineering Investigation
To determine why the reporter fails to parse the pod list despite having valid RBAC permissions, we extracted and disassembled the application binary (`/eb-debug-app` from `ebinterview/eb-debug-app:1.0.1`):

1. **Pod List Request:**  
   The binary requests `https://kubernetes.default.svc/api/v1/namespaces/debug-lab/pods?limit=100` with the in-cluster ServiceAccount token.
2. **Artificial Stream Truncation:**  
   In the disassembly of `main.(*reporter).listPods` (around virtual address `0x6a3b16` - `0x6a3b60`):
   ```assembly
   6a3b1e:  lea    0x4d2fb(%rip),%rax      # *io.LimitedReader type descriptor
   6a3b25:  call   runtime.newobject       # allocate LimitedReader
   6a3b32:  mov    %rcx,(%rax)             # R = resp.Body
   6a3b5c:  movq   $0x400,0x10(%rax)       # N = 0x400 (1024 bytes)
   6a3b6e:  call   io.ReadAll              # read bounded stream
   6a3bd2:  call   json.Unmarshal          # unmarshal into struct
   ```
   The application intentionally wraps `resp.Body` in `io.LimitReader(resp.Body, 1024)`, restricting the read buffer to exactly 1024 bytes.
3. **Payload Mismatch:**  
   When querying the Kubernetes API server for all pods in `debug-lab`, the returned `PodList` JSON contains detailed object metadata, specifications, and status conditions for all cluster workloads, totaling approximately **119 KB** (119,666 bytes).
4. **The Result:**  
   `io.LimitReader` truncates the incoming HTTP stream after the first 1024 bytes. When `json.Unmarshal` attempts to parse the incomplete JSON string, it fails with `unexpected end of JSON input`. In response, `reporter` enters a degraded state, and its `/healthz` readiness probe returns `503 Service Unavailable`.

### Constraints & Proposed Next Steps
Per the exercise rules:
- *"You may change anything in this chart — values or templates."*
- *"You may NOT change image.repository or image.tag."*
- *"You may NOT modify anything under ../cluster-state/."*

Because modifying the container image or cluster state is strictly prohibited, this defect cannot be completely eliminated through standard Helm templating alone. Had time permitted, the following architectural approaches would be explored:

1. **Upstream Application Patch (Production Fix):**  
   In `reporter.go`, replace `io.LimitReader(resp.Body, 1024)` with streaming `json.NewDecoder(resp.Body).Decode(&podList)` or increase the limit to a realistic size (e.g. `10 * 1024 * 1024` bytes).
2. **Reverse Proxy Sidecar (In-Chart Workaround):**  
   Deploy an ephemeral sidecar container (e.g. lightweight Nginx or Envoy) inside the reporter pod listening on localhost. Route `reporter`'s Kubernetes API requests through the proxy to filter out verbose `managedFields`, `status`, and `spec` attributes before passing a condensed `< 1024 byte` JSON payload back to the Go process.
3. **Content Negotiation / API Projection:**  
   If supported by the client, request minimal table representations via Kubernetes API metadata projection (`Accept: application/json;as=Table;v=v1;g=meta.k8s.io`) to compress payload dimensions below 1 KB.
