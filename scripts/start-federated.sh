#!/bin/bash
# ==================================================================================================
# Starts the Federated server.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$( dirname "$DIR" )"

source "$DIR"/common.sh

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


# Start a server and agent for federated and nestedC, this will be the federated pair.
log "Checking that root-server and root-agent are available..."
kubectl wait --for=condition=ready --timeout=10s pod -n spire -l app=root-server
kubectl wait --for=condition=ready pod --timeout=10s -n spire -l app=root-agent

log "Creating a new downstream registration entry for nestedC..."
kubectl exec -n spire root-server-0 -- /opt/spire/bin/spire-server entry create -downstream \
    -parentID "spiffe://example.org/ns/spire/sa/root-agent" \
    -spiffeID "spiffe://example.org/ns/spire/sa/nestedc-server" \
    -selector "k8s:ns:spire" \
    -selector "k8s:sa:nestedc-server"

check-entry-is-propagated root-agent 2 spiffe://example.org/ns/spire/sa/nestedc-server


# IF we have k8sr integrated into Pod nestedc, we MUST add the SpiffeID CRDs first...
log "Adding SpiffeID CRDs (for k8sr)..."
kubectl apply -f "${PARENT_DIR}"/deploy/spiffeid.spiffe.io_spiffeids.yaml


# Start the nestedC server and agent...
log "Starting nestedC-server (statefulset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/nestedC-server.yaml

log "Waiting for nestedC server to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=nestedc-server

# We could create a separate configmap for each nested agent, but really it's not necessary,
# as they're all essentially the UpstreamAuthority cert.
# log "Setting the bootstrap bundle for nestedc-agent..."
# duplicate-configmap-simple "root-server-upstream-authority" "nestedc-agent-bootstrap-cert"

log "Starting nestedC agent(s) (daemonset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/nestedC-agent.yaml

log "Waiting for nestedC agents to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=nestedc-agent


# Start the Federated server and agent...
log "Creating federated-server base config..."
kubectl apply -f "${PARENT_DIR}"/deploy/federated-server-base.yaml

# Gen a UpstreamAuthority cert, and create kubernetes ConfigMap and Secret for server
if [ "$GEN_UA" == "true" ]; then
    log "Generating UpstreamAuthority cert..."
    gen-upstream-authority-configmap "federated-server-upstream-authority" "auxiliary.org" 365
fi

log "Starting federated server (statefulset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/federated-server.yaml

log "Waiting for federated server to start..."
kubectl wait --for=condition=ready --timeout=60s pod -n spire -l app=federated-server


log "Creating federated-agent base config..."
kubectl apply -f "${PARENT_DIR}"/deploy/federated-agent-base.yaml

if [ "$GEN_UA" == "true" ]; then
    log "Setting the bootstrap bundle for federated-agent..."
    duplicate-configmap-simple "federated-server-upstream-authority" "federated-agent-bootstrap-cert"
fi

log "Starting federated agent(s) (daemonset)..."
kubectl apply -f "${PARENT_DIR}"/deploy/federated-agent.yaml

log "Waiting for federated agents to start..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=federated-agent


log "Bootstrapping federated relationship..."
kubectl wait --for=condition=ready pod --timeout=60s -n spire -l app=nestedc-server

kubectl exec -it -n spire nestedc-server-0 -- /opt/spire/bin/spire-server federation create \
    -bundleEndpointProfile https_spiffe \
    -bundleEndpointURL "https://federated-server:8443/" \
    -endpointSpiffeID "spiffe://auxiliary.org/spire/server" \
    -trustDomain "auxiliary.org" \
    -trustDomainBundleFormat pem \
    -trustDomainBundlePath "/run/spire/fed-cert/bootstrap.crt"

kubectl exec -it -n spire federated-server-0 -- /opt/spire/bin/spire-server federation create \
    -bundleEndpointProfile https_spiffe \
    -bundleEndpointURL "https://nestedc-server:8443/" \
    -endpointSpiffeID "spiffe://example.org/spire/server" \
    -trustDomain "example.org" \
    -trustDomainBundleFormat pem \
    -trustDomainBundlePath "/run/spire/fed-cert/bootstrap.crt"


# Create federated workload entries...
log "Creating node-level alias for federated agents..."
kubectl exec -n spire federated-server-0 -- /opt/spire/bin/spire-server entry create -node \
    -spiffeID "spiffe://auxiliary.org/ns/spire/sa/federated-agent" \
    -selector "k8s_sat:cluster:spire" \
    -selector "k8s_sat:agent_sa:federated-agent"

log "Creating federated workload registration entry at federated-server..."
kubectl exec -n spire federated-server-0 -- /opt/spire/bin/spire-server entry create \
    -parentID "spiffe://auxiliary.org/ns/spire/sa/federated-agent" \
    -spiffeID "spiffe://auxiliary.org/ns/spire/sa/federated-workload" \
    -selector "k8s:ns:spire" \
    -selector "k8s:sa:federated-agent" \
    -federatesWith "spiffe://example.org"

check-entry-is-propagated federated-agent 2 spiffe://auxiliary.org/ns/spire/sa/federated-workload


log "Creating node-level alias for nestedc agents..."
kubectl exec -n spire nestedc-server-0 -- /opt/spire/bin/spire-server entry create -node \
    -spiffeID "spiffe://example.org/ns/spire/sa/nestedc-agent" \
    -selector "k8s_psat:cluster:spire" \
    -selector "k8s_psat:agent_sa:nestedc-agent"

    # -selector "k8s_sat:cluster:spire" \
    # -selector "k8s_sat:agent_sa:nestedc-agent"

log "Creating federated workload registration entry at nestedc-server..."
kubectl exec -n spire nestedc-server-0 -- /opt/spire/bin/spire-server entry create \
    -parentID "spiffe://example.org/ns/spire/sa/nestedc-agent" \
    -spiffeID "spiffe://example.org/ns/spire/sa/nestedc-workload" \
    -selector "k8s:ns:spire" \
    -selector "k8s:sa:nestedc-agent" \
    -federatesWith "spiffe://auxiliary.org"

check-entry-is-propagated nestedc-agent 2 spiffe://example.org/ns/spire/sa/nestedc-workload

