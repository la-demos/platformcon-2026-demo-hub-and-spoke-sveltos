#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

CONFIG_FILE="$DEMO_DEFAULT_CONFIG"
RECREATE="false"
DRY_RUN="false"
DEMO_ARTIFACT_DIR="${DEMO_REPO_ROOT}/tmp/platformcon-sveltos"
DEMO_TEMP_DIRS=()

cleanup_temp_dirs() {
  local temp_dir

  for temp_dir in "${DEMO_TEMP_DIRS[@]:-}"; do
    [ -n "$temp_dir" ] || continue
    rm -rf "$temp_dir"
  done
}

trap cleanup_temp_dirs EXIT

ensure_namespace_exists_with_kubeconfig() {
  local kubeconfig="$1"
  local namespace="$2"

  [ -n "$namespace" ] || demo_die "Missing namespace"

  if [ "$DRY_RUN" = "true" ]; then
    printf '+ kubectl --kubeconfig %q get namespace %q >/dev/null 2>&1 || kubectl --kubeconfig %q create namespace %q\n' "$kubeconfig" "$namespace" "$kubeconfig" "$namespace"
    return 0
  fi

  if ! kubectl --kubeconfig "$kubeconfig" get namespace "$namespace" >/dev/null 2>&1; then
    demo_run kubectl --kubeconfig "$kubeconfig" create namespace "$namespace"
  fi
}

ensure_namespace_exists_with_context() {
  local context="$1"
  local namespace="$2"

  [ -n "$namespace" ] || demo_die "Missing namespace"

  if [ "$DRY_RUN" = "true" ]; then
    printf '+ kubectl --context %q get namespace %q >/dev/null 2>&1 || kubectl --context %q create namespace %q\n' "$context" "$namespace" "$context" "$namespace"
    return 0
  fi

  if ! kubectl --context "$context" get namespace "$namespace" >/dev/null 2>&1; then
    demo_run kubectl --context "$context" create namespace "$namespace"
  fi
}

write_kind_kubeconfig() {
  local cluster_name="$1"
  local output_file="$2"
  local internal="${3:-false}"

  if [ "$DRY_RUN" = "true" ]; then
    if [ "$internal" = "true" ]; then
      printf '+ kind get kubeconfig --name %q --internal > %q\n' "$cluster_name" "$output_file"
    else
      printf '+ kind get kubeconfig --name %q > %q\n' "$cluster_name" "$output_file"
    fi
    return 0
  fi

  if [ "$internal" = "true" ]; then
    kind get kubeconfig --name "$cluster_name" --internal > "$output_file"
  else
    kind get kubeconfig --name "$cluster_name" > "$output_file"
  fi
}

ensure_artifact_dir() {
  if [ "$DRY_RUN" = "true" ]; then
    demo_run mkdir -p "$DEMO_ARTIFACT_DIR"
  else
    mkdir -p "$DEMO_ARTIFACT_DIR"
  fi
}

prepare_demo_kubeconfigs() {
  local cluster_name
  local kind_config

  ensure_artifact_dir

  while IFS='|' read -r cluster_name kind_config; do
    [ -n "$cluster_name" ] || continue
    write_kind_kubeconfig "$cluster_name" "${DEMO_ARTIFACT_DIR}/${cluster_name}.kubeconfig"
    write_kind_kubeconfig "$cluster_name" "${DEMO_ARTIFACT_DIR}/${cluster_name}.internal.kubeconfig" "true"
  done < <(demo_parse_clusters)
}

prepare_registration_namespaces() {
  local cluster_name
  local kind_config
  local hub_cluster
  local namespace
  local key
  local value
  local hub_kubeconfig

  while IFS='|' read -r cluster_name kind_config; do
    [ -n "$cluster_name" ] || continue

    hub_cluster="hub"
    namespace=""

    while IFS='|' read -r key value; do
      case "$key" in
        hub) hub_cluster="$value" ;;
        namespace) namespace="$value" ;;
      esac
    done < <(demo_parse_cluster_registration "$cluster_name")

    [ -n "$namespace" ] || continue
    demo_validate_cluster_name "$hub_cluster"

    hub_kubeconfig="${DEMO_ARTIFACT_DIR}/${hub_cluster}.kubeconfig"
    if [ "$DRY_RUN" != "true" ] && [ ! -f "$hub_kubeconfig" ]; then
      write_kind_kubeconfig "$hub_cluster" "$hub_kubeconfig"
    fi

    ensure_namespace_exists_with_kubeconfig "$hub_kubeconfig" "$namespace"
  done < <(demo_parse_clusters)
}

run_sveltosctl_register_pullmode() {
  local hub_kubeconfig="$1"
  local namespace="$2"
  local registered_cluster="$3"
  local labels="$4"
  local output_file="$5"

  if [ "$DRY_RUN" = "true" ]; then
    if [ -n "$labels" ]; then
      printf '+ env KUBECONFIG=%q sveltosctl register cluster --namespace=%q --cluster=%q --pullmode --labels=%q > %q\n' "$hub_kubeconfig" "$namespace" "$registered_cluster" "$labels" "$output_file"
    else
      printf '+ env KUBECONFIG=%q sveltosctl register cluster --namespace=%q --cluster=%q --pullmode > %q\n' "$hub_kubeconfig" "$namespace" "$registered_cluster" "$output_file"
    fi
    return 0
  fi

  if [ -n "$labels" ]; then
    env "KUBECONFIG=$hub_kubeconfig" sveltosctl register cluster --namespace="$namespace" --cluster="$registered_cluster" --pullmode --labels="$labels" > "$output_file"
  else
    env "KUBECONFIG=$hub_kubeconfig" sveltosctl register cluster --namespace="$namespace" --cluster="$registered_cluster" --pullmode > "$output_file"
  fi
}

ensure_sveltos_pull_mode_supported() {
  local hub_kubeconfig="$1"
  local pull_mode_type

  if [ "$DRY_RUN" = "true" ]; then
    printf '+ kubectl --kubeconfig %q get crd sveltosclusters.lib.projectsveltos.io -o jsonpath=%q\n' "$hub_kubeconfig" '{.spec.versions[?(@.name=="v1beta1")].schema.openAPIV3Schema.properties.spec.properties.pullMode.type}'
    return 0
  fi

  pull_mode_type="$(kubectl --kubeconfig "$hub_kubeconfig" get crd sveltosclusters.lib.projectsveltos.io -o jsonpath='{.spec.versions[?(@.name=="v1beta1")].schema.openAPIV3Schema.properties.spec.properties.pullMode.type}')"
  [ "$pull_mode_type" = "boolean" ] || demo_die "Sveltos pull mode requires SveltosCluster spec.pullMode support. Use Sveltos v1.9.0 or newer."
}

bootstrap_sveltos() {
  local cluster_name="$1"
  local enabled="false"
  local cluster_profiles=""
  local context="kind-${cluster_name}"
  local prerequisite_manifests=()
  local prerequisite_wait_crds=()
  local manifests=()
  local wait_crds=()
  local key
  local value
  local cluster_profiles_path

  while IFS='|' read -r key value; do
    case "$key" in
      enabled) enabled="$value" ;;
      prerequisite_manifest) prerequisite_manifests+=("$value") ;;
      prerequisite_wait_crd) prerequisite_wait_crds+=("$value") ;;
      manifest) manifests+=("$value") ;;
      wait_crd) wait_crds+=("$value") ;;
      cluster_profiles) cluster_profiles="$value" ;;
    esac
  done < <(demo_parse_sveltos_bootstrap "$cluster_name")

  [ "$enabled" = "true" ] || return 0
  [ "${#manifests[@]}" -gt 0 ] || demo_die "Sveltos bootstrap for ${cluster_name} has no manifests"

  printf 'Bootstrapping Sveltos on KinD cluster: %s\n' "$cluster_name"

  for manifest in "${prerequisite_manifests[@]}"; do
    demo_run kubectl --context "$context" apply -f "$manifest"
  done

  for crd in "${prerequisite_wait_crds[@]}"; do
    demo_run kubectl --context "$context" wait --for=condition=Established "crd/${crd}" --timeout=180s
  done

  for manifest in "${manifests[@]}"; do
    demo_run kubectl --context "$context" apply -f "$manifest"
    for crd in "${wait_crds[@]}"; do
      demo_run kubectl --context "$context" wait --for=condition=Established "crd/${crd}" --timeout=180s
    done
  done

  if [ -n "$cluster_profiles" ]; then
    cluster_profiles_path="$(demo_resolve_config_path "$cluster_profiles")"
    [ -f "$cluster_profiles_path" ] || demo_die "ClusterProfile manifest not found for ${cluster_name}: $cluster_profiles_path"
    demo_run kubectl --context "$context" apply -f "$cluster_profiles_path"
  fi
}

register_sveltos_cluster() {
  local target_cluster_name="$1"
  local enabled="false"
  local mode="push"
  local hub_cluster="hub"
  local namespace="$target_cluster_name"
  local registered_cluster="$target_cluster_name"
  local previous_clusters=()
  local labels=""
  local refresh="false"
  local key
  local value
  local previous_cluster
  local temp_dir
  local hub_kubeconfig
  local managed_kubeconfig

  while IFS='|' read -r key value; do
    case "$key" in
      enabled) enabled="$value" ;;
      hub) hub_cluster="$value" ;;
      namespace) namespace="$value" ;;
      cluster) registered_cluster="$value" ;;
      previous_cluster) previous_clusters+=("$value") ;;
      mode) mode="$value" ;;
      labels) labels="$value" ;;
      refresh) refresh="$value" ;;
    esac
  done < <(demo_parse_cluster_registration "$target_cluster_name")

  [ "$enabled" = "true" ] || return 0

  demo_validate_cluster_name "$hub_cluster"
  demo_validate_cluster_name "$target_cluster_name"
  demo_validate_cluster_name "$registered_cluster"
  for previous_cluster in "${previous_clusters[@]:-}"; do
    [ -n "$previous_cluster" ] || continue
    demo_validate_cluster_name "$previous_cluster"
  done
  [ -n "$namespace" ] || demo_die "Missing registration namespace for cluster: $target_cluster_name"

  if [ "$DRY_RUN" != "true" ]; then
    demo_require_cmd sveltosctl
  fi

  temp_dir="$DEMO_ARTIFACT_DIR"
  if [ "$DRY_RUN" != "true" ]; then
    mkdir -p "$temp_dir"
  fi

  hub_kubeconfig="${temp_dir}/${hub_cluster}.kubeconfig"
  managed_kubeconfig="${temp_dir}/${target_cluster_name}.internal.kubeconfig"

  printf 'Registering Sveltos cluster: %s/%s via hub %s (%s mode)\n' "$namespace" "$registered_cluster" "$hub_cluster" "$mode"
  write_kind_kubeconfig "$hub_cluster" "$hub_kubeconfig"

  ensure_namespace_exists_with_kubeconfig "$hub_kubeconfig" "$namespace"

  for previous_cluster in "${previous_clusters[@]:-}"; do
    [ -n "$previous_cluster" ] || continue
    [ "$previous_cluster" != "$registered_cluster" ] || continue

    if [ "$DRY_RUN" = "true" ]; then
      demo_run env "KUBECONFIG=$hub_kubeconfig" sveltosctl deregister cluster --namespace="$namespace" --cluster="$previous_cluster"
    elif kubectl --kubeconfig "$hub_kubeconfig" get sveltoscluster "$previous_cluster" -n "$namespace" >/dev/null 2>&1; then
      printf 'Removing previous Sveltos registration: %s/%s\n' "$namespace" "$previous_cluster"
      demo_run env "KUBECONFIG=$hub_kubeconfig" sveltosctl deregister cluster --namespace="$namespace" --cluster="$previous_cluster"
    fi
  done

  if [ "$DRY_RUN" = "true" ]; then
    if [ "$refresh" = "true" ]; then
      demo_run env "KUBECONFIG=$hub_kubeconfig" sveltosctl deregister cluster --namespace="$namespace" --cluster="$registered_cluster"
    fi
  elif [ "$refresh" = "true" ] && kubectl --kubeconfig "$hub_kubeconfig" get sveltoscluster "$registered_cluster" -n "$namespace" >/dev/null 2>&1; then
    printf 'Refreshing existing Sveltos registration: %s/%s\n' "$namespace" "$registered_cluster"
    demo_run env "KUBECONFIG=$hub_kubeconfig" sveltosctl deregister cluster --namespace="$namespace" --cluster="$registered_cluster"
  fi

  case "$mode" in
    push)
      write_kind_kubeconfig "$target_cluster_name" "$managed_kubeconfig" "true"

      if [ -n "$labels" ]; then
        demo_run env "KUBECONFIG=$hub_kubeconfig" sveltosctl register cluster --namespace="$namespace" --cluster="$registered_cluster" --kubeconfig="$managed_kubeconfig" --labels="$labels"
      else
        demo_run env "KUBECONFIG=$hub_kubeconfig" sveltosctl register cluster --namespace="$namespace" --cluster="$registered_cluster" --kubeconfig="$managed_kubeconfig"
      fi
      ;;
    pull)
      register_sveltos_pull_cluster "$target_cluster_name" "$hub_cluster" "$namespace" "$registered_cluster" "$labels" "$hub_kubeconfig" "$temp_dir"
      ;;
    *)
      demo_die "Unsupported Sveltos registration mode for ${target_cluster_name}: $mode"
      ;;
  esac
}

register_sveltos_pull_cluster() {
  local target_cluster_name="$1"
  local hub_cluster="$2"
  local namespace="$3"
  local registered_cluster="$4"
  local labels="$5"
  local hub_kubeconfig="$6"
  local temp_dir="$7"
  local target_context="kind-${target_cluster_name}"
  local pull_manifest="${temp_dir}/${registered_cluster}-pullmode.yaml"
  local applier_kubeconfig="${temp_dir}/${registered_cluster}-applier.kubeconfig"
  local patched_secret_manifest="${temp_dir}/${registered_cluster}-patched-secret.yaml"
  local secret_name="${registered_cluster}-sveltos-kubeconfig"
  local applier_namespace="projectsveltos"
  local hub_internal_server="https://${hub_cluster}-control-plane:6443"
  local applier_kubeconfig_cluster

  ensure_sveltos_pull_mode_supported "$hub_kubeconfig"
  run_sveltosctl_register_pullmode "$hub_kubeconfig" "$namespace" "$registered_cluster" "$labels" "$pull_manifest"

  ensure_namespace_exists_with_context "$target_context" "$namespace"

  demo_run kubectl --context "$target_context" apply -f "$pull_manifest"

  if [ "$DRY_RUN" = "true" ]; then
    printf '+ kubectl --context %q -n %q get secret %q -o go-template=%q > %q\n' "$target_context" "$applier_namespace" "$secret_name" '{{index .data "kubeconfig" | base64decode}}' "$applier_kubeconfig"
    printf '+ kubectl config set-cluster <cluster-from-%q> --kubeconfig %q --server %q\n' "$applier_kubeconfig" "$applier_kubeconfig" "$hub_internal_server"
    printf '+ kubectl --context %q -n %q create secret generic %q --from-file=kubeconfig=%q --dry-run=client -o yaml > %q\n' "$target_context" "$applier_namespace" "$secret_name" "$applier_kubeconfig" "$patched_secret_manifest"
    demo_run kubectl --context "$target_context" apply -f "$patched_secret_manifest"
    demo_run kubectl --context "$target_context" -n "$applier_namespace" rollout restart deployment/sveltos-applier-manager
    demo_run kubectl --context "$target_context" -n "$applier_namespace" rollout status deployment/sveltos-applier-manager --timeout=180s
    return 0
  fi

  kubectl --context "$target_context" -n "$applier_namespace" get secret "$secret_name" -o go-template='{{index .data "kubeconfig" | base64decode}}' > "$applier_kubeconfig"
  applier_kubeconfig_cluster="$(kubectl config view --kubeconfig "$applier_kubeconfig" -o jsonpath='{.clusters[0].name}')"
  [ -n "$applier_kubeconfig_cluster" ] || demo_die "Could not find cluster name in pull-mode kubeconfig: $applier_kubeconfig"

  demo_run kubectl config set-cluster "$applier_kubeconfig_cluster" --kubeconfig "$applier_kubeconfig" --server "$hub_internal_server"
  kubectl --context "$target_context" -n "$applier_namespace" create secret generic "$secret_name" --from-file=kubeconfig="$applier_kubeconfig" --dry-run=client -o yaml > "$patched_secret_manifest"
  demo_run kubectl --context "$target_context" apply -f "$patched_secret_manifest"
  demo_run kubectl --context "$target_context" -n "$applier_namespace" rollout restart deployment/sveltos-applier-manager
  demo_run kubectl --context "$target_context" -n "$applier_namespace" rollout status deployment/sveltos-applier-manager --timeout=180s
}

register_sveltos_clusters() {
  local cluster_name
  local kind_config

  while IFS='|' read -r cluster_name kind_config; do
    [ -n "$cluster_name" ] || continue
    register_sveltos_cluster "$cluster_name"
  done < <(demo_parse_clusters)
}

usage() {
  cat <<USAGE
Usage: $0 [options]

Create the KinD clusters defined in config/demo-environment.yaml.

Options:
  -c, --config <file>  Path to the demo environment YAML
      --recreate       Delete existing demo clusters before creating them
      --dry-run        Print the KinD commands without executing them
  -h, --help           Show this help
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -c|--config)
      [ -n "${2:-}" ] || demo_die "Missing value for $1"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --config=*)
      CONFIG_FILE="${1#*=}"
      shift
      ;;
    --recreate)
      RECREATE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      demo_die "Unknown argument: $1"
      ;;
  esac
done

demo_load_config "$CONFIG_FILE"

if [ "$DRY_RUN" != "true" ]; then
  demo_require_cmd kind
  demo_require_cmd kubectl
fi

cluster_count=0
cluster_names=""

while IFS='|' read -r cluster_name kind_config; do
  [ -n "$cluster_name" ] || continue

  demo_validate_cluster_name "$cluster_name"
  [ -n "$kind_config" ] || demo_die "Missing kind_config for cluster: $cluster_name"

  kind_config_path="$(demo_resolve_kind_config_path "$kind_config")"
  [ -f "$kind_config_path" ] || demo_die "KinD config not found for ${cluster_name}: $kind_config_path"

  cluster_count=$((cluster_count + 1))
  cluster_names="${cluster_names} ${cluster_name}"

  if [ "$DRY_RUN" = "true" ]; then
    if [ "$RECREATE" = "true" ]; then
      demo_run kind delete cluster --name "$cluster_name"
    fi
    demo_run kind create cluster --name "$cluster_name" --config "$kind_config_path"
    bootstrap_sveltos "$cluster_name"
    continue
  fi

  if demo_cluster_exists "$cluster_name"; then
    if [ "$RECREATE" = "true" ]; then
      printf 'Recreating KinD cluster: %s\n' "$cluster_name"
      demo_run kind delete cluster --name "$cluster_name"
      demo_run kind create cluster --name "$cluster_name" --config "$kind_config_path"
    else
      printf 'KinD cluster already exists, skipping: %s\n' "$cluster_name"
    fi
  else
    printf 'Creating KinD cluster: %s\n' "$cluster_name"
    demo_run kind create cluster --name "$cluster_name" --config "$kind_config_path"
  fi

  bootstrap_sveltos "$cluster_name"
done < <(demo_parse_clusters)

[ "$cluster_count" -gt 0 ] || demo_die "No clusters found in config: $DEMO_CONFIG_FILE"

prepare_demo_kubeconfigs
prepare_registration_namespaces
register_sveltos_clusters

printf '\nDemo clusters configured:\n'
for cluster_name in $cluster_names; do
  printf '  - %s (kubectl context: kind-%s)\n' "$cluster_name" "$cluster_name"
done

printf '\nSwitch context example:\n'
printf '  kubectl config use-context kind-hub\n'
