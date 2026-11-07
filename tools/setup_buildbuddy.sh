#!/usr/bin/env bash
set -euo pipefail

# Unifies the creation of .bazelrc.user containing BuildBuddy configuration
# for the root workspace and nested workspaces (e2e/*).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

ENDPOINT="${1:-${BUILDBUDDY_ENDPOINT:-}}"
ENDPOINT="${ENDPOINT%/}"
API_KEY="${2:-${BUILDBUDDY_TOKEN:-${BUILDBUDDY_API_KEY:-}}}"

if [ -z "${ENDPOINT}" ] || [ -z "${API_KEY}" ]; then
  echo "Usage: $0 [<endpoint> <api-key>] (or set BUILDBUDDY_ENDPOINT and BUILDBUDDY_TOKEN)" >&2
  exit 1
fi

config_profile="buildbuddy-rbe"
if [ "$(uname -s)" != "Linux" ]; then
  config_profile="buildbuddy"
fi

write_buildbuddy_rc() {
  local target_file="$1"
  local profile="$2"

  cat <<EOF > "${target_file}"
common --config=${profile}
common:buildbuddy --bes_backend=grpcs://${ENDPOINT}
common:buildbuddy --bes_results_url=https://${ENDPOINT}/invocation/
common:buildbuddy --remote_cache=grpcs://${ENDPOINT}
EOF
  if [ "${profile}" = "buildbuddy-rbe" ]; then
    echo "common:buildbuddy-rbe --remote_executor=grpcs://${ENDPOINT}" >> "${target_file}"
  fi
  echo "common:buildbuddy --remote_header=x-buildbuddy-api-key=${API_KEY}" >> "${target_file}"
}

write_buildbuddy_rc ".bazelrc.user" "${config_profile}"

for suite in e2e/*; do
  if [ -d "${suite}" ]; then
    write_buildbuddy_rc "${suite}/.bazelrc.user" "buildbuddy"
  fi
done
