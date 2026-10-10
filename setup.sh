#!/usr/bin/env bash
# One-command setup: kind cluster "demo" + ingress-nginx + image + Helm release.
# Idempotent: safe to run any number of times.
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER="${CLUSTER:-demo}"
NAMESPACE="${NAMESPACE:-demo}"
RELEASE="${RELEASE:-demo}"
IMAGE_REPO="${IMAGE_REPO:-demo-service}"
IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
INGRESS_NGINX_VERSION="${INGRESS_NGINX_VERSION:-controller-v1.11.2}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for bin in docker kind kubectl helm; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required but not installed"
done
docker info >/dev/null 2>&1 || die "Docker daemon is not running"

# 1. kind cluster (reuse if it exists) ---------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "kind cluster '$CLUSTER' already exists - reusing"
else
  log "Creating kind cluster '$CLUSTER'"
  cat <<KINDCFG | kind create cluster --name "$CLUSTER" --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
KINDCFG
fi
kubectl config use-context "kind-${CLUSTER}" >/dev/null

# 2. ingress-nginx (apply is idempotent) -------------------------------------
log "Installing ingress-nginx (${INGRESS_NGINX_VERSION})"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_VERSION}/deploy/static/provider/kind/deploy.yaml"
log "Waiting for ingress-nginx controller to be ready"
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
kubectl -n ingress-nginx wait --for=condition=complete job/ingress-nginx-admission-patch --timeout=120s 2>/dev/null || true

# 3. build + load image -------------------------------------------------------
log "Building image ${IMAGE_REPO}:${IMAGE_TAG}"
docker build -t "${IMAGE_REPO}:${IMAGE_TAG}" ./service
log "Loading image into kind cluster"
kind load docker-image "${IMAGE_REPO}:${IMAGE_TAG}" --name "$CLUSTER"

# 4. helm release (retry: the ingress admission webhook can lag behind) ------
log "Installing chart as release '${RELEASE}' in namespace '${NAMESPACE}'"
ok=0
for attempt in 1 2 3 4 5; do
  if helm upgrade --install "$RELEASE" ./chart \
       --namespace "$NAMESPACE" --create-namespace \
       --set image.repository="$IMAGE_REPO" --set image.tag="$IMAGE_TAG" \
       --wait --timeout 120s; then
    ok=1; break
  fi
  echo "helm attempt ${attempt} failed, retrying in 10s..."; sleep 10
done
[ "$ok" = 1 ] || die "helm install failed"

log "Done. Verify with:"
echo "  kubectl -n ${NAMESPACE} get pods,svc,ingress"
echo "  curl -s -H 'Host: demo.local' http://localhost/"