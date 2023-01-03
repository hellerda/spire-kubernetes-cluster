#!/bin/bash
# ==================================================================================================
# Starts the cluster.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$( dirname "$DIR" )"

source "$DIR"/common.sh

set -e

# Defaults, inital values
GEN_UA="true"


usage () {
    echo ""
    echo "      Options:"
    echo "      -h, --help            display this message and exit"
    echo "      -u, --genUA           generate new UpstreamAuthority cert and update configmap"
    echo "                            and secret accordingly  (true/false; default=true)"
    echo ""
    exit 1
}

# Convert long options to short
for arg in "$@"; do
  shift
  case "$arg" in
    "--help")     set -- "$@" "-h" ;;
    "--genUA")    set -- "$@" "-u" ;;
    *)            set -- "$@" "$arg"
  esac
done

# Process command-line arguments
while getopts \?hu: opt
do
  case "${opt:?}" in
    u) GEN_UA="$OPTARG";;
    h|\?) usage;;
  esac
done

# Sanitize boolean values
GEN_UA="$(make_bool "$GEN_UA")"


log "Creating root-server base config..."
kubectl apply -f "${PARENT_DIR}"/deploy/root-server-base.yaml

# Gen a UpstreamAuthority cert, and create kubernetes ConfigMap and Secret for server
if [ "$GEN_UA" == "true" ]; then
    log "Generating UpstreamAuthority cert..."
    gen-upstream-authority-configmap "root-server-upstream-authority" "example.org" 365
fi

log "Starting root server (statefulset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/root-server.yaml

log "Waiting for root server to start..."
kubectl wait --for=condition=ready --timeout=60s pod -n spire -l app=root-server


log "Creating root-agent base config..."
kubectl apply -f "${PARENT_DIR}"/deploy/root-agent-base.yaml

if [ "$GEN_UA" == "true" ]; then
    log "Setting the bootstrap bundle for root-agent..."
    duplicate-configmap-simple "root-server-upstream-authority" "root-agent-bootstrap-cert"
fi

log "Starting root agent(s) (daemonset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/root-agent.yaml

log "Waiting for root agents to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=root-agent

log "Creating node-level alias for root agents..."
kubectl exec -n spire root-server-0 -- /opt/spire/bin/spire-server entry create -node \
    -spiffeID "spiffe://example.org/ns/spire/sa/root-agent" \
    -selector "k8s_sat:cluster:spire" \
    -selector "k8s_sat:agent_sa:root-agent"

log "Creating nestedA downstream registration entry..."
kubectl exec -n spire root-server-0 -- /opt/spire/bin/spire-server entry create -downstream \
    -parentID "spiffe://example.org/ns/spire/sa/root-agent" \
    -spiffeID "spiffe://example.org/ns/spire/sa/nesteda-server" \
    -selector "k8s:ns:spire" \
    -selector "k8s:sa:nesteda-server"

check-entry-is-propagated root-agent 2 spiffe://example.org/ns/spire/sa/nesteda-server

echo; log "Creating nestedB downstream registration entry..."
kubectl exec -n spire root-server-0 -- /opt/spire/bin/spire-server entry create -downstream \
    -parentID "spiffe://example.org/ns/spire/sa/root-agent" \
    -spiffeID "spiffe://example.org/ns/spire/sa/nestedb-server" \
    -selector "k8s:ns:spire" \
    -selector "k8s:sa:nestedb-server"

check-entry-is-propagated root-agent 2 spiffe://example.org/ns/spire/sa/nestedb-server


# Start the nested servers...
log "Starting nestedA-server (statefulset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/nestedA-server.yaml

log "Waiting for nestedA server to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=nesteda-server

log "Starting nestedB-server (statefulset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/nestedB-server.yaml

log "Waiting for nestedB server to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=nestedb-server


# Start the nested agents...
# Optional...
# log "Setting the bootstrap bundle for nesteda-agent..."
# duplicate-configmap-simple "root-server-upstream-authority" "nesteda-agent-bootstrap-cert"

log "Starting nestedA agent(s) (daemonset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/nestedA-agent.yaml

log "Waiting for nestedA agents to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=nesteda-agent

# Optional...
# log "Setting the bootstrap bundle for nestedb-agent..."
# duplicate-configmap-simple "root-server-upstream-authority" "nestedb-agent-bootstrap-cert"

log "Starting nestedB agent(s) (daemonset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/nestedB-agent.yaml

log "Waiting for nestedB agents to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=nestedb-agent
