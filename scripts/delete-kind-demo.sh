#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/kind-demo-common.sh"

CONFIG_FILE="$DEMO_DEFAULT_CONFIG"
DRY_RUN="false"

usage() {
  cat <<USAGE
Usage: $0 [options]

Delete the KinD clusters defined in config/demo-environment.yaml.

Options:
  -c, --config <file>  Path to the demo environment YAML
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
fi

cluster_count=0

while IFS='|' read -r cluster_name kind_config; do
  [ -n "$cluster_name" ] || continue

  demo_validate_cluster_name "$cluster_name"
  cluster_count=$((cluster_count + 1))

  if [ "$DRY_RUN" = "true" ]; then
    demo_run kind delete cluster --name "$cluster_name"
    continue
  fi

  if demo_cluster_exists "$cluster_name"; then
    printf 'Deleting KinD cluster: %s\n' "$cluster_name"
    demo_run kind delete cluster --name "$cluster_name"
  else
    printf 'KinD cluster does not exist, skipping: %s\n' "$cluster_name"
  fi
done < <(demo_parse_clusters)

[ "$cluster_count" -gt 0 ] || demo_die "No clusters found in config: $DEMO_CONFIG_FILE"
