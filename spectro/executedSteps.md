### Single prompt to reproduce all changes

Use this single prompt:

- Modify main.go to allow running the same binary as either controller-only or webhook-only based on the existing --webhook-port flag:
  - The int flag --webhook-port (default 9443) already exists. Behavior:
    - If --webhook-port=0: controller-only mode. Do not create a webhook server; register reconcilers only. Initialize OCI clients (AUTH_CONFIG_DIR, ClientProvider). Enable instance metadata service lookup. Register feature-gated controllers (MachinePool).
    - If --webhook-port!=0 (e.g., 9443): webhook-only mode. Create webhook server with that port; register webhooks only (no reconcilers). Do not initialize OCI clients. Do not enable feature gates.
  - Only set ctrl.Options.WebhookServer when port != 0; keep health/ready probes and existing metrics handling.
  - Keep the existing cert/key flags (webhook-cert-dir) working.
  - Implemented in main.go with proper conditional logic for webhook server creation and controller setup.

- Add a new spectro/ folder with scripts and kustomizations to generate two sets of manifests from the same code/image:
  - spectro/controller/ (2 files only):
    - kustomization.yaml:
      - namePrefix: capoci-
      - namespace: capoci-system
      - labels: cluster.x-k8s.io/provider: "infrastructure-oci"
      - resources: ../../config/rbac, ../../config/manager
      - patches: manager_controller_patch.yaml (targeted at Deployment/controller-manager)
      - RBAC is included (service_account, role, role_binding, leader_election_role/binding, auth_proxy_*)
      - JSON patch to remove serviceAccountName field
      - JSON patch with `$patch: delete` to remove the Namespace resource (comes from config/manager/manager.yaml)
      - Do NOT include credentials, image patches, pull policy, webhooks, CRDs, or cert-manager.
    - manager_controller_patch.yaml:
      - Container args include:
        - --leader-elect
        - --feature-gates=MachinePool=${EXP_MACHINE_POOL:=true}
        - --metrics-bind-address=127.0.0.1:8080
        - --logging-format=${LOG_FORMAT:=text}
        - --init-oci-clients-on-startup=${INIT_OCI_CLIENTS_ON_STARTUP:=true}
        - --enable-instance-metadata-service-lookup=${ENABLE_INSTANCE_METADATA_SERVICE_LOOKUP:=false}
        - --webhook-port=0
  - spectro/webhook/ (5 files only):
    - kustomization.yaml:
      - namespace: capi-webhook-system
      - namePrefix: capoci-
      - labels: cluster.x-k8s.io/provider: "infrastructure-oci"
      - resources: ../../config/crd, ../../config/manager, ../../config/webhook, ../../config/certmanager
      - vars: CERTIFICATE_NAMESPACE, CERTIFICATE_NAME, SERVICE_NAMESPACE, SERVICE_NAME
      - configurations: [kustomizeconfig.yaml]
      - patches: manager_webhook_patch.yaml, webhook_ca_injection_patch.yaml, certificate_secretname_patch.yaml
      - JSON patch to remove serviceAccountName field
      - JSON patch with `$patch: delete` to remove the Namespace resource (comes from config/manager/manager.yaml)
      - Do NOT include RBAC, credentials, image patches, or pull policy
    - kustomizeconfig.yaml:
      - nameReference: Service v1 → webhooks/clientConfig/service/name in MutatingWebhookConfiguration and ValidatingWebhookConfiguration
      - namespace mapping: webhooks/clientConfig/service/namespace (create: true) in both webhook configurations
      - varReference: metadata/annotations
    - manager_webhook_patch.yaml:
      - Label the Deployment with control-plane: capoci-controller-manager (selector, pod template labels)
      - Set container args to --webhook-port=9443
      - Expose container port 9443 named webhook-server
      - Mount TLS certs at /tmp/k8s-webhook-server/serving-certs from a Secret named capoci-webhook-server-cert (hardcoded)
      - No --leader-elect, no --feature-gates, no OCI-specific flags
    - webhook_ca_injection_patch.yaml:
      - Add cert-manager.io/inject-ca-from: capi-webhook-system/capoci-serving-cert to MutatingWebhookConfiguration (hardcoded)
      - Add cert-manager.io/inject-ca-from: capi-webhook-system/capoci-serving-cert to ValidatingWebhookConfiguration (hardcoded)
      - CRITICAL: Must reference certificate resource name (capoci-serving-cert), not secret name
    - certificate_secretname_patch.yaml:
      - Patch Certificate resource to use correct secretName: capoci-webhook-server-cert
  - Scripts (make executable):
    - spectro/generate_controller.sh: kustomize build spectro/controller → spectro/generated/controller-manifests.yaml
    - spectro/generate_webhook.sh: kustomize build spectro/webhook → spectro/generated/webhook-manifests.yaml
    - spectro/generate_all.sh: runs both scripts

- Ensure generated outputs meet these checks:
  - Controller manifests:
    - Include args with --webhook-port=0
    - Do NOT contain serviceAccountName field (field completely absent)
    - Do not contain CRDs or webhook configs
    - Include RBAC resources (ClusterRole, ClusterRoleBinding, ServiceAccount, leader election Role/RoleBinding, auth proxy resources)
    - Do NOT contain credentials Secret or image patches (handled by Spectro platform)
    - Do NOT contain Namespace resource (namespace handled by Spectro platform)
  - Webhook manifests:
    - Include CRDs and Mutating/ValidatingWebhookConfiguration pointing to Service/capoci-webhook-service
    - Are in namespace capi-webhook-system
    - Include cert-manager resources (Issuer and Certificate)
    - cert-manager.io/inject-ca-from annotations resolve to capi-webhook-system/capoci-serving-cert (certificate name, not secret name)
    - Labels: control-plane=capoci-controller-manager (matches service selector)
    - Do NOT contain serviceAccountName field (field completely absent)
    - Do NOT contain RBAC resources
    - Do NOT contain credentials Secret or image patches (handled by Spectro platform)
    - Do NOT contain Namespace resource (namespace handled by Spectro platform)
    - Certificate creates secret: capoci-webhook-server-cert
    - CA bundle automatically injected into webhook configurations

- Do not add or depend on namespace.yaml; do not include RBAC in webhook.
- Controller manifests INCLUDE RBAC resources for API permissions.
- Webhook deployment INCLUDES cert-manager resources for automatic certificate management.
- Image, pull policy, and credentials are handled by the Spectro platform at deployment time.

### Testing and Validation

- Verify controller manifests:
  - Deployment: --webhook-port=0, no serviceAccountName field
  - RBAC: ClusterRole (manager-role), ClusterRoleBinding, ServiceAccount, leader election resources
  - No CRDs, no webhook configurations, no cert-manager resources, no credentials
- Verify webhook manifests:
  - Deployment: --webhook-port=9443, no serviceAccountName field, port 9443 exposed, cert volume mounted
  - Cert-manager: Issuer and Certificate created
  - CA injection: annotations on both webhook configurations (capi-webhook-system/capoci-serving-cert)
  - Service selector: capoci-webhook-service correctly routes to control-plane=capoci-controller-manager pods
  - CRDs: All OCI CRDs deployed
  - No RBAC, no credentials

### Critical Fixes Applied

1. **ServiceAccountName Removal**: Completely removed serviceAccountName field from both deployments using JSON patches with `op: remove`
2. **RBAC Inclusion**: RBAC resources included in controller manifests (not webhook) for proper API permissions
3. **Cert-Manager Integration**: Added full cert-manager resource inclusion in webhook manifests with automatic certificate generation and CA injection
4. **Hardcoded Values**: CA injection annotations and certificate secretName are hardcoded (not var-substituted) matching the CloudStack pattern
5. **Conditional Main Logic**: OCI client initialization, feature gates, and instance metadata service only active in controller mode
6. **Minimal File Structure**: Controller has 2 files, webhook has 5 files — image, pull policy, and credentials handled externally by Spectro platform
7. **Namespace Removal**: Namespace resource from config/manager/manager.yaml excluded via `$patch: delete` in both kustomizations — namespace creation handled by Spectro platform

---

### CI/CD Image Build Changes

- Rewrite Dockerfile to use Spectro build-base-images pattern:
  - Builder base: `us-docker.pkg.dev/palette-images/build-base-images/golang:${BUILDER_GOLANG_VERSION}-alpine`
  - FIPS support via `CRYPTO_LIB` build arg → `GOEXPERIMENT=boringcrypto`
  - Conditional build: `go-build-fips.sh` (FIPS) or `go-build-static.sh` (standard) — scripts from base image
  - FIPS assertions: `assert-static.sh` and `assert-fips.sh` run when CRYPTO_LIB is set
  - Vulnerability scanning: `scan-govulncheck.sh` always runs
  - Runtime image: `gcr.io/distroless/static:latest` (replaces Oracle Linux)
  - Go module caching via `--mount=type=cache`
  - Copy entire workspace (`COPY ./ ./`) instead of individual directories
  - Multi-platform support via `--platform=$TARGETPLATFORM`

- Modify Makefile Docker section:
  - Add variables: `FIPS_ENABLE ?= ""`, `BUILDER_GOLANG_VERSION ?= 1.24`, `SPECTRO_VERSION ?= 4.0.0-dev`
  - Add `BUILD_ARGS = --build-arg CRYPTO_LIB=${FIPS_ENABLE} --build-arg BUILDER_GOLANG_VERSION=${BUILDER_GOLANG_VERSION}`
  - Add `RELEASE_LOC` (release or release-fips based on FIPS_ENABLE)
  - Update `REGISTRY ?= gcr.io/spectro-dev-public/release`
  - Update `TAG ?= v0.23.0-spectro-${SPECTRO_VERSION}`
  - Update `docker-build` target: `docker buildx build --load --platform linux/${ARCH} ${BUILD_ARGS}` (replaces plain `docker build`)
  - Remove `docker-pull-prerequisites` target (no longer needed)
  - Keep existing `docker-build-all`, `docker-push-all`, `docker-push-manifest` targets unchanged

- Add new `.github/workflows/spectro-release.yaml`:
  - `workflow_dispatch` with `release_version` and `rel_type` (release/rc) inputs
  - Dual registry: `LEGACY_REGISTRY` (us-docker.pkg.dev/palette-images/palette/cluster-api-oci) and `FIPS_REGISTRY` (us-docker.pkg.dev/palette-images-fips/palette/cluster-api-oci)
  - RC builds use dev registries: `us-east1-docker.pkg.dev/spectro-images/dev/cluster-api-oci` and `us-east1-docker.pkg.dev/spectro-images/dev-fips/cluster-api-oci`
  - Tag-exists check prevents duplicate releases
  - Docker Buildx setup for multi-arch builds
  - Dual registry login (production + dev)
  - Standard image build: `make docker-build-all && make docker-push-all`
  - FIPS image build: `FIPS_ENABLE=yes make docker-build-all && make docker-push-all`
  - GitHub Release creation for non-rc builds (tag: v{version}-spectro)
  - `BUILDER_GOLANG_VERSION: 1.24.3` (matches go.mod toolchain)
