#!/usr/bin/env bash

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
provider_jar=${1:-"$repository_root/target/keycloak-rfc1123-username.jar"}
keycloak_version=${KEYCLOAK_KUBERNETES_TEST_VERSION:-26.7.4}
kind_node_image=${KIND_NODE_IMAGE:-kindest/node:v1.35.0@sha256:452d707d4862f52530247495d180205e029056831160e22870e37e3f6c1ac31f}
cluster_name="rfc1123-provider-$$"
stage=initialization

if [[ ! -f "$provider_jar" ]]; then
    printf 'Provider JAR does not exist: %s\n' "$provider_jar" >&2
    exit 1
fi
for command in docker jar kind kubectl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is unavailable: %s\n' "$command" >&2
        exit 1
    fi
done
if ! docker info >/dev/null 2>&1; then
    printf '%s\n' 'Docker is required for the Kubernetes integration test.' >&2
    exit 1
fi

provider_jar=$(cd "$(dirname "$provider_jar")" && pwd)/$(basename "$provider_jar")
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/keycloak-rfc1123-kubernetes.XXXXXX")
kubeconfig="$test_directory/kubeconfig"
export KUBECONFIG="$kubeconfig"

cleanup() {
    local exit_status=$?
    kind delete cluster --name "$cluster_name" >/dev/null 2>&1 || true
    if (( exit_status == 0 )); then
        case "$test_directory" in
            "${TMPDIR:-/tmp}"/keycloak-rfc1123-kubernetes.*) rm -rf -- "$test_directory" ;;
        esac
    else
        printf 'Kubernetes integration stage failed: %s\n' "$stage" >&2
        printf 'Preserved failed test files: %s\n' "$test_directory" >&2
    fi
}
trap cleanup EXIT

fail() {
    printf 'Kubernetes integration test failed: %s\n' "$1" >&2
    kubectl describe pod provider-validation 2>/dev/null >&2 || true
    kubectl logs pod/provider-validation --all-containers=true 2>/dev/null >&2 || true
    exit 1
}

stage='test artifact preparation'
mkdir "$test_directory/empty-jar"
(cd "$test_directory/empty-jar" && jar --create --file "$test_directory/theme-onyxia-web.jar" .)
cp "$provider_jar" "$test_directory/keycloak-rfc1123-username.jar"

stage='isolated Kind cluster creation'
kind create cluster \
    --name "$cluster_name" \
    --kubeconfig "$kubeconfig" \
    --image "$kind_node_image" \
    --wait 180s

stage='in-cluster artifact server startup'
kubectl create configmap provider-downloads \
    --from-file="$test_directory/theme-onyxia-web.jar" \
    --from-file="$test_directory/keycloak-rfc1123-username.jar"
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: provider-downloads
  labels:
    app: provider-downloads
spec:
  containers:
    - name: server
      image: busybox:1.36.1
      command: ["httpd", "-f", "-p", "8080", "-h", "/srv"]
      ports:
        - name: http
          containerPort: 8080
      volumeMounts:
        - name: downloads
          mountPath: /srv
          readOnly: true
  volumes:
    - name: downloads
      configMap:
        name: provider-downloads
---
apiVersion: v1
kind: Service
metadata:
  name: provider-downloads
spec:
  selector:
    app: provider-downloads
  ports:
    - port: 8080
      targetPort: http
EOF
kubectl wait --for=condition=Ready pod/provider-downloads --timeout=120s

stage='initContainer and shared provider-volume validation'
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: provider-validation
spec:
  restartPolicy: Never
  initContainers:
    - name: realm-ext-provider
      image: curlimages/curl
      imagePullPolicy: IfNotPresent
      command:
        - sh
      args:
        - -c
        - |
          set -eu
          curl -L -f -S -o /extensions/theme-onyxia-web.jar http://provider-downloads:8080/theme-onyxia-web.jar
          curl -L -f -S -o /extensions/rfc1123-username.jar http://provider-downloads:8080/keycloak-rfc1123-username.jar
      volumeMounts:
        - name: empty-dir
          mountPath: /extensions
          subPath: app-providers-dir
  containers:
    - name: keycloak
      image: quay.io/keycloak/keycloak:$keycloak_version
      command:
        - /bin/bash
      args:
        - -ec
        - |
          test -s /opt/keycloak/providers/theme-onyxia-web.jar
          test -s /opt/keycloak/providers/rfc1123-username.jar
          /opt/keycloak/bin/kc.sh build
          printf '%s\n' 'Provider volume and Keycloak build verified.'
      volumeMounts:
        - name: empty-dir
          mountPath: /opt/keycloak/providers
          subPath: app-providers-dir
  volumes:
    - name: empty-dir
      emptyDir: {}
EOF

for attempt in $(seq 1 300); do
    phase=$(kubectl get pod provider-validation -o jsonpath='{.status.phase}')
    case "$phase" in
        Succeeded)
            kubectl logs pod/provider-validation -c keycloak
            stage=complete
            printf 'Kubernetes initContainer test passed with Keycloak %s.\n' "$keycloak_version"
            exit 0
            ;;
        Failed)
            fail 'provider validation pod failed'
            ;;
    esac
    sleep 1
done
fail 'provider validation pod did not complete within 300 seconds'
