# Findings — Part 4 debug lab

lab/part4-session.log, captured with PowerShell Start-Transcript (I'm on Windows, so I used it instead of script; the file was appended with -Append after restarts).

Every "Symptom" below is real output from my own terminal. Lines marked PASTE need your own output from part4-session.log before you commit.

Fill in one entry per defect you find. Paste the *actual* output you saw —
we cross-check it against your session recording and your git diff, and the
diagnostic path matters more to us than the fix itself.

Before you start investigating, begin recording:
`script -q part4-session.log` (or `asciinema rec part4-session.cast`), and
commit that file alongside this one.

---

## Defect 1 — migrate Job rejected by Helm

**Symptom** (./scenario.sh up stopped at the Helm install step with an error on the migrate Job about restartPolicy):

**Cause** (templates/migrate-job.yaml set restartPolicy: Always. A Job's pod template only allows OnFailure or Never, so the API server rejected the Job and the release only partially installed.):

**Fix** (Changed it to OnFailure (use whichever you chose) so a failed migration is retried but a successful one stays Completed.):

**How I found it** (Read the helm error from scenario.sh up, which names the field. Fixed the template and re-ran up; the Job then showed Complete 1/1.):

---

## Defect 2 — pods stuck in CreateContainerConfigError

**Symptom:**

**Cause:** The pod spec had runAsNonRoot: true but no numeric runAsUser. The image declares its user by name (nonroot), and the kubelet cannot prove a named user is non-root, so it refuses to start the container.


**Fix:** Added runAsUser: 10001 next to runAsNonRoot: true in the six workload templates (backend, gateway, worker, reporter, metrics, migrate-job). I kept runAsNonRoot instead of removing it, so the hardening stays.

**How I found it:**
kubectl get pods then kubectl describe pod / get events showed the container-config error and its reason.
---

## Defect 3 - wrong listening port (8081 vs 8080)

**Symptom:**

**Cause:** The app listens on its default port 8081 unless PORT is set. The chart's Services and probes use common.port (8080), but the templates never passed PORT to the container.

**Fix:**
Added PORT: {{ .Values.common.port | quote }} as the first env var in backend, gateway, worker, reporter and metrics. I set the app to the port the chart already uses, not the other way round, so the Services and probes stay as they were.
**How I found it:**
Compared the probe port in describe with the port in the app's startup log.
---

## Defect 4
worker crashes on a read-only filesystem
**Symptom:**

**Cause:**
he worker template sets readOnlyRootFilesystem: true, but the worker needs a writable /var/cache/app.
**Fix:**
Mounted an emptyDir named cache at /var/cache/app (container volumeMounts, pod-level volumes). I kept the read-only root filesystem and gave the app one writable directory.
**How I found it:**
Read the previous container's logs, which named the path and the "read-only file system" error.
---

## Defect 5 gateway points at the wrong namespace

**Symptom:**

**Cause:**
values.yaml had BACKEND_URL pointing at backend.default.svc. The backend runs in debug-lab, so the name never resolved to it.
**Fix:**
Set BACKEND_URL: "http://backend.debug-lab.svc:8080". I used the explicit namespace and port so it doesn't depend on the pod's own namespace.
**How I found it:**
Checked the gateway's rendered env and compared its namespace with where the backend Service lives.
---

## Defect 6
reporter gets 403 from the Kubernetes API
**Symptom:**

**Cause:**
The RoleBinding reporter-read bound the Role to the ServiceAccount default, but the pod runs as reporter.
**Fix:**
Changed the RoleBinding subject to name: reporter. Granting default instead would have given every pod in the namespace those permissions.
**How I found it:**
The error names the exact user. I ran get rolebinding reporter-read -o yaml and saw subjects: name: default. After the fix can-i returned yes
---

If you ran out of time on any defect, say so here and describe what you would
have tried next — that section is read carefully and counts in your favour.
