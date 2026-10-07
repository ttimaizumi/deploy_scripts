#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <context> <overlay> <image>" >&2
    exit 2
fi

CONTEXT="$1"
OVERLAY="$2"
IMAGE="$3"
NAMESPACE="minimal-api"
OVERLAY_PATH="k8s/overlays/$OVERLAY"
MIGRATION_JOB="migration"

if [ ! -d "$OVERLAY_PATH" ]; then
    echo "Kustomize overlay not found: $OVERLAY_PATH" >&2
    exit 1
fi

if ! kubectl config get-contexts "$CONTEXT" >/dev/null 2>&1; then
    echo "Kubernetes context not found: $CONTEXT" >&2
    exit 1
fi

kubectl --context "$CONTEXT" get --raw=/readyz >/dev/null
kubectl --context "$CONTEXT" apply -k "$OVERLAY_PATH"
kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    set image deployment/api api="$IMAGE"

# Recreate the Job so migrations run for every deployment.
kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    delete job "$MIGRATION_JOB" --ignore-not-found --wait=true
kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    create job "$MIGRATION_JOB" --image="$IMAGE" -- migrate

if ! kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    wait --for=condition=complete --timeout=180s "job/$MIGRATION_JOB"; then
    kubectl --context "$CONTEXT" -n "$NAMESPACE" \
        logs "job/$MIGRATION_JOB" --all-containers=true || true
    exit 1
fi

kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    logs "job/$MIGRATION_JOB" --all-containers=true
kubectl --context "$CONTEXT" -n "$NAMESPACE" \
    rollout status deployment/api --timeout=180s
