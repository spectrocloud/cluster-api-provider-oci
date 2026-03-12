#!/bin/bash

KUSTOMIZE=${KUSTOMIZE:-kustomize}

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

mkdir -p "$SCRIPTDIR/generated"
cd "$SCRIPTDIR/controller"
${KUSTOMIZE} build . > "$SCRIPTDIR/generated/controller-manifests.yaml"
echo "Generated: spectro/generated/controller-manifests.yaml"
