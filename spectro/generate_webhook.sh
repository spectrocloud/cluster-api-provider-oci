#!/bin/bash

KUSTOMIZE=${KUSTOMIZE:-kustomize}

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

mkdir -p "$SCRIPTDIR/generated"
cd "$SCRIPTDIR/webhook"
${KUSTOMIZE} build . > "$SCRIPTDIR/generated/webhook-manifests.yaml"
echo "Generated: spectro/generated/webhook-manifests.yaml"
