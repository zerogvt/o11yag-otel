set -eo pipefail

# Usage:
#   ./build_deploy.sh                  build fresh images and deploy them
#   ./build_deploy.sh --no-build       redeploy the newest images already built
#   ./build_deploy.sh --tag 20260917184017   redeploy one specific build

BUILD=1
TAG=""
SVCS="orchestrator knowledge-worker action-worker mcp-crm approvals loadgen"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --tag)      shift; TAG="$1"; BUILD=0 ;;
    -h|--help)  sed -n '3,7p' "$0"; exit 0 ;;
    *)          echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

echo " * * * Creating namespace * * * "
kubectl apply -f k8s/o11yag_ns.yaml

echo " * * * Creating Dynatrace secret * * * "
# On a redeploy the secret usually survived (stop.sh removes Deployments, not
# the namespace or this imperatively-created secret), so don't prompt for a
# token we already have. Setting DT_API_TOKEN/DT_TENANT still forces a rewrite.
SECRET_WRITTEN=0
if [ -z "$DT_API_TOKEN" ] && kubectl get secret o11yag-collector -n o11yag-otel >/dev/null 2>&1; then
  echo "Secret o11yag-collector already exists, keeping it"
else
  if [ -n "$DT_API_TOKEN" ]; then
    echo "Using DT_API_TOKEN from environment"
  else
    read -s -p "Enter DT_API_TOKEN: " DT_API_TOKEN
    echo
  fi

  if [ -n "$DT_TENANT" ]; then
    echo "Using DT_TENANT from environment ($DT_TENANT)"
  else
    read -p "Enter DT_TENANT: " DT_TENANT
  fi
  if [ -z "$DT_TENANT" ]; then
    echo "DT_TENANT is required" >&2
    exit 1
  fi

  kubectl create secret generic o11yag-collector \
    --from-literal=DT_API_TOKEN="$DT_API_TOKEN" \
    --from-literal=DT_OTLP_ENDPOINT=https://$DT_TENANT.live.dynatrace.com/api/v2/otlp \
    -n o11yag-otel --dry-run=client -o yaml | kubectl apply -f -
  SECRET_WRITTEN=1
fi

# Stateful/pulled-image infrastructure first: the services below all fail their
# readiness probes until these are up, and Ollama in particular is slow on a
# cold start (two model pulls). Nothing here is built locally, so none of it
# takes a build tag.
echo " * * * Deploying infrastructure (redis, qdrant, ollama, litellm) * * * "
kubectl apply -f redis/k8s/o11yag-redis.yaml
kubectl apply -f qdrant/k8s/o11yag-qdrant.yaml
kubectl apply -f ollama/k8s/o11yag-ollama.yaml
kubectl apply -f litellm/k8s/o11yag-litellm.yaml

# Roll a Deployment whose ConfigMap changed but whose own spec did not.
#
# `kubectl apply` on a manifest holding both a ConfigMap and a Deployment updates
# the ConfigMap and leaves the Deployment alone, because the Deployment spec is
# byte-identical. The pod keeps running with the config it booted on. For the
# services this never shows, since every deploy gives them a fresh image tag —
# but LiteLLM and the Collector are not rebuilt, and both read their config file
# exactly once, at startup.
#
# It bit us for real: a new model alias was added to LiteLLM's config, applied,
# and every call for it came back `400 Invalid model name` — the alias present in
# the ConfigMap and absent from the running proxy. Nothing in the deploy output
# suggested the config had not taken.
#
# The annotation is a checksum of the manifest, so an unchanged file patches the
# same value and Kubernetes does nothing. Only a real change rolls the pod.
roll_on_config_change() {
  local name="$1" file="$2"
  local sum
  sum="$(sha256sum "$file" | cut -c1-12)"
  kubectl patch deployment "$name" -n o11yag-otel --type=strategic \
    -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"o11yag.config/checksum\":\"${sum}\"}}}}}" \
    >/dev/null
}
roll_on_config_change o11yag-litellm litellm/k8s/o11yag-litellm.yaml

if [ "$BUILD" -eq 1 ]; then
  echo "* * * Building * * *"
  TAG="$(date +%Y%m%d%H%M%S)"
  for svc in $SVCS; do
    docker build -t o11yag-${svc}:${TAG} ${svc}/
  done
elif [ -z "$TAG" ]; then
  # Reuse the newest build. Only timestamp tags are considered, and only a tag
  # present on ALL deployed services counts — a half-built tag would otherwise
  # deploy a mix of generations. Timestamps sort lexically, so newest is last.
  want="$(echo $SVCS | wc -w)"
  TAG="$(for svc in $SVCS; do
           docker images "o11yag-${svc}" --format '{{.Tag}}' | grep -E '^[0-9]{14}$'
         done | sort | uniq -c | awk -v n="$want" '$1 == n {print $2}' | sort -r | head -1)"
  if [ -z "$TAG" ]; then
    echo "No build found covering all of: $SVCS" >&2
    echo "Run without --no-build to build them, or pass --tag <tag>." >&2
    exit 1
  fi
  echo "* * * Reusing newest build ${TAG} * * *"
else
  for svc in $SVCS; do
    if ! docker image inspect "o11yag-${svc}:${TAG}" >/dev/null 2>&1; then
      echo "Image o11yag-${svc}:${TAG} not found locally" >&2
      exit 1
    fi
  done
  echo "* * * Reusing build ${TAG} * * *"
fi

# Deploy the built services via a Kustomize overlay generated fresh in a temp
# dir each run — so none of the checked-in Deployment yamls (or any other
# tracked file) ever change; only this throwaway overlay carries the tag.
# --load-restrictor is needed because the overlay's resource path points back
# into the repo, outside the temp dir Kustomize otherwise treats as its root.
echo "* * * Deploying ${TAG} * * *"
for svc in $SVCS; do
  tmp="$(mktemp -d)"
  # The checksum rides in the same overlay as the image tag, so one apply carries
  # both and the pod rolls at most once. Patching it afterwards would work too and
  # would roll a second time on every build.
  #
  # Without it, a ConfigMap-only change is a silent no-op on --no-build: the tag is
  # unchanged, so the Deployment spec is unchanged, so no pod restarts and the new
  # setting never reaches the process. That is how you switch KB_POISON_DOC on,
  # redeploy, and find the corpus still clean.
  sum="$(sha256sum "${svc}/k8s/o11yag-${svc}.yaml" | cut -c1-12)"
  cat > "${tmp}/kustomization.yaml" <<EOF
resources:
  - $(pwd)/${svc}/k8s/o11yag-${svc}.yaml
images:
  - name: o11yag-${svc}
    newTag: "${TAG}"
patches:
  - target:
      kind: Deployment
      name: o11yag-${svc}
    patch: |
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: o11yag-${svc}
      spec:
        template:
          metadata:
            annotations:
              o11yag.config/checksum: "${sum}"
EOF
  kubectl kustomize --load-restrictor LoadRestrictionsNone "${tmp}" | kubectl apply -f -
  rm -rf "${tmp}"
done

echo "* * * Deploying OTEL collector * * *"
kubectl apply -f collector/k8s/o11yag-collector.yaml
roll_on_config_change o11yag-otel-collector collector/k8s/o11yag-collector.yaml

# A rewritten Secret does not reach a running pod. Env vars are injected from it
# at container start, so the Collector goes on using the token it booted with and
# `kubectl apply` above changes nothing when the manifest itself is unchanged.
#
# The failure this produces is the nastiest kind: you rotate a token, fix its
# scopes, redeploy, and the exact same 403 keeps coming — which reads as the new
# token being wrong rather than as the new token never having been loaded. It
# cost a debugging session once. Hence the restart, only when the Secret actually
# changed, so an ordinary redeploy does not churn the Collector.
if [ "$SECRET_WRITTEN" -eq 1 ]; then
  echo "* * * Secret changed - restarting the collector so it picks up the token * * *"
  kubectl rollout restart deployment/o11yag-otel-collector -n o11yag-otel
  kubectl rollout status deployment/o11yag-otel-collector -n o11yag-otel --timeout=120s
fi

echo
echo "Done. Watch it come up with:   kubectl get pods -n o11yag-otel -w"
