#!/bin/bash
# ==================================================================================================
# Starts the OIDC Provider.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$( dirname "$DIR" )"

source "$DIR"/common.sh

# Defaults, inital values
REG="true"


usage () {
    echo ""
    echo "      Options:"
    echo "      -h, --help            display this message and exit"
    echo "      -r, --registration    automatically handle registration entries (true/false; default=true)"
    echo ""
    exit 1
}

# Convert long options to short
for arg in "$@"; do
  shift
  case "$arg" in
    "--help")          set -- "$@" "-h" ;;
    "--registration")  set -- "$@" "-r" ;;
    *)                 set -- "$@" "$arg"
  esac
done

# Process command-line arguments
while getopts \?hr: opt
do
  case "${opt:?}" in
    r) REG="$OPTARG";;
    h|\?) usage;;
  esac
done

# Sanitize boolean values
REG="$(make_bool "$REG")"


# Create reg entries to enable OIDCP to access Workload API socket on nesteda-agent...
if [ "$REG" == "true" ]; then
    if [ -z "$(get_entry_by_spiffeID spire nesteda-server-0 "spiffe://example.org/ns/spire/sa/nesteda-agent")" ]
    then
        log "Creating node-level alias for nestedA agents..."
        kubectl exec -n spire nesteda-server-0 -- /opt/spire/bin/spire-server entry create -node \
            -spiffeID "spiffe://example.org/ns/spire/sa/nesteda-agent" \
            -selector "k8s_sat:cluster:spire" \
            -selector "k8s_sat:agent_sa:nesteda-agent"
    fi

    if [ -z "$(get_entry_by_spiffeID spire nesteda-server-0 "spiffe://example.org/ns/spire/sa/oidc-provider")" ]
    then
        log "Creating workload registration entry for oidc-provider..."
        kubectl exec -n spire nesteda-server-0 -- /opt/spire/bin/spire-server entry create \
            -parentID "spiffe://example.org/ns/spire/sa/nesteda-agent" \
            -spiffeID "spiffe://example.org/ns/spire/sa/oidc-provider" \
            -selector "k8s:ns:spire" \
            -selector "k8s:sa:oidc-provider"

        check-entry-is-propagated nesteda-agent 2 spiffe://example.org/ns/spire/sa/oidc-provider
    fi
fi


# Start the OIDC Provider
log "Starting OIDC Provider..."
kubectl apply -f "${PARENT_DIR}"/deploy/oidc-provider.yaml

log "Waiting for OIDC Provider to start..."
kubectl wait --for=condition=ready --timeout=60s pod -n spire -l app=oidc-provider
