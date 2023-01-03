#!/bin/bash
# ==================================================================================================
# Tests the Envoy and Emissary samples...
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$( dirname "$DIR" )"

source "$DIR"/common.sh

# Defaults, inital values
DO_EGRESS="true"
DO_INGRESS="true"
DO_CLEAN="false"
VERBOSE="false"
SETTLE_TIME=5


# Get the IP of the specified pod. Assumes only one running instance of the pod.
get-podIP() { kubectl get pod -n "$1" -l "app=$2" -o jsonpath='{.items[0].status.podIP}'; }

make_int () {
    # Sanitize integer values
    # The 1st param is the default value to apply if the 2nd param is not sane.
    val=$(echo "$2" | grep "^[0-9]*$")

    if [ "$val" != "" ]; then
        echo "$val"
    else
        echo "$1"
    fi
}

all_clear() {
    # Check that none of listed pods are currently running..."
    for ((i=1;i<=20;i++)); do
        if ! kubectl get pods -n spire -o json | \
             jq -re '.items[] | select(.metadata.labels.app | match("spiffe-client|spiffe-client-envoy|spiffe-client-envoy-emissary"))' &>/dev/null
        then
            log "${green}All clear.${norm}"
            return 0
        fi
        sleep 3
    done

    log "${red}timed out waiting for old pods to terminate.${norm}"
    exit 1
}


usage () {
    echo ""
    echo "      Options:"
    echo "      -h, --help            display this message and exit"
    echo "      -e, --egress          run EGRESS tests only"
    echo "      -i, --ingress         run INGRESS tests only"
    echo "      -c, --clean           delete configmap on exit"
    echo "      -s, --settle          settling delay before each test (default 5s)"
    echo "      -v, --verbose         show more detail"
    echo ""
    exit 1
}

# Convert long options to short
for arg in "$@"; do
  shift
  case "$arg" in
    "--help")       set -- "$@" "-h" ;;
    "--egress")     set -- "$@" "-e" ;;
    "--ingress")    set -- "$@" "-i" ;;
    "--clean")      set -- "$@" "-c" ;;
    "--settle")     set -- "$@" "-s" ;;
    "--verbose")    set -- "$@" "-v" ;;
    *)              set -- "$@" "$arg"
  esac
done

# Process command-line arguments
while getopts \?heics:v opt
do
  case "${opt:?}" in
    h|\?) usage;;
    e) DO_EGRESS="true"; DO_INGRESS="false";;
    i) DO_INGRESS="true"; DO_EGRESS="false";;
    c) DO_CLEAN="true";;
    s) SETTLE="$OPTARG";;
    v) VERBOSE="true";;
  esac
done

# Sanitize default values
DO_EGRESS="$(make_bool "$DO_EGRESS")"
DO_INGRESS="$(make_bool "$DO_INGRESS")"
DO_CLEAN="$(make_bool "$DO_CLEAN")"
VERBOSE="$(make_bool "$VERBOSE")"
SETTLE_TIME="$(make_int "$SETTLE_TIME" "$SETTLE")"


log "Deploying configmap \"envoy-config\"..."
kubectl kustomize "${PARENT_DIR}"/deploy/envoy/ | kubectl apply -f -

if [ "$DO_EGRESS" == "true" ]
then
    log "=== BEGIN EGRESS TESTS ==="
    log "Checking to make sure test pods are not currently running..."
    all_clear

    log "Preparing test configs..."
    echo -e "# This file created by \"$P\".\n" > /tmp/spiffe-client-envoy.yaml
    cat "${PARENT_DIR}"/deploy/workload/spiffe-client-envoy.yaml >> /tmp/spiffe-client-envoy.yaml
    sed -i 's/envoy-config-inbound.yaml/envoy-config-outbound.yaml/' /tmp/spiffe-client-envoy.yaml
    echo -e "# This file created by \"$P\".\n" > /tmp/spiffe-client-envoy-emissary.yaml
    cat "${PARENT_DIR}"/deploy/workload/spiffe-client-envoy-emissary.yaml >> /tmp/spiffe-client-envoy-emissary.yaml
    sed -i 's/envoy-config-inbound-emissary.yaml/envoy-config-outbound-emissary.yaml/' /tmp/spiffe-client-envoy-emissary.yaml

    log "Starting \"spiffe-client\" deployment..."
    kubectl apply -n spire -f "${PARENT_DIR}"/deploy/workload/spiffe-client.yaml
    log "Starting \"spiffe-client-envoy\" deployment..."
    kubectl apply -n spire -f /tmp/spiffe-client-envoy.yaml
    log "Starting \"spiffe-client-envoy-emissary\" deployment..."
    kubectl apply -n spire -f /tmp/spiffe-client-envoy-emissary.yaml
    echo

    log "=== BEGIN EGRESS TEST 1 - ENVOY only ==="
    log "Waiting for \"spiffe-client\" deployment to be ready..."
    kubectl wait --for=condition=ready pod --timeout=60s -n spire -l "app=spiffe-client"
    kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock

    log "Waiting for \"spiffe-client-envoy\" deployment to be ready..."
    kubectl wait --for=condition=ready pod --timeout=60s -n spire -l "app=spiffe-client-envoy"
    kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock

    log "Starting egress test 1..."
    kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- \
    https-server -v -listenPort 2222 -audience "spiffe://example.org/ns/spire/sa/spiffe-client" -mTLS "spiffe://example.org/ns/spire/sa/spiffe-client-envoy" &>/dev/null &

    log "Waiting for https-server to start on \"spiffe-client\"..."
    sleep 10

    log "Getting target podIP..."
    kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- \
    sh -c "echo \"$(get-podIP spire spiffe-client) targethost\" >> /etc/hosts"

    log "Settling..."
    sleep "$SETTLE_TIME"

    log "Connecting..."
    CMD1="https-client -proxyURL http://localhost:2223 -host targethost -port 2222 -audience spiffe://example.org/ns/spire/sa/spiffe-client -noTLS -fc"
    CMD2="kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- $CMD1"
    CMD_OUT=$($CMD2)

    test "$VERBOSE" && echo -e "\$ $CMD1\n$CMD_OUT"

    if echo "$CMD_OUT" | grep "Login successful" &>/dev/null; then
        echo "${green}Connection successful: Egress test 1.${norm}"
    else
        echo "${red}Connection FAILED: Egress test 1.${norm}"
    fi

    log "Stopping https-server on \"spiffe-client\"..."
    kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- killall -INT https-server

    sleep 5
    echo

    log "=== BEGIN EGRESS TEST 2 - ENVOY with EMISSARY ==="
    log "Waiting for \"spiffe-client-envoy-emissary\" deployment to be ready..."
    kubectl wait --for=condition=ready pod --timeout=60s -n spire -l "app=spiffe-client-envoy-emissary"
    kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock

    log "Starting egress test 2..."
    kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- \
    https-server -v -listenPort 2222 -audience "spiffe://example.org/ns/spire/sa/spiffe-client" -mTLS "spiffe://example.org/ns/spire/sa/spiffe-client-envoy-emissary" &>/dev/null &

    log "Waiting for https-server to start on \"spiffe-client\"..."
    sleep 10

    log "Getting target podIP..."
    kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- \
    sh -c "echo \"$(get-podIP spire spiffe-client) targethost\" >> /etc/hosts"

    log "Settling..."
    sleep "$SETTLE_TIME"

    log "Connecting..."
    CMD1="https-client -proxyURL http://localhost:2223 -host targethost -port 2222 -noJWT -noTLS -fc"
    CMD2="kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- $CMD1"
    CMD_OUT=$($CMD2)

    test "$VERBOSE" && echo -e "\$ $CMD1\n$CMD_OUT"

    if echo "$CMD_OUT" | grep "Login successful" &>/dev/null; then
        echo "${green}Connection successful: Egress test 2.${norm}"
    else
        echo "${red}Connection FAILED: Egress test 2.${norm}"
    fi

    sleep 10
    echo

    log "Cleaning up from EGRESS tests..."
    log "Stopping \"spiffe-client\" deployment..."
    kubectl delete -n spire -f "${PARENT_DIR}"/deploy/workload/spiffe-client.yaml
    log "Stopping \"spiffe-client-envoy\" deployment..."
    kubectl delete -n spire -f /tmp/spiffe-client-envoy.yaml
    log "Stopping \"spiffe-client-envoy-emissary\" deployment..."
    kubectl delete -n spire -f /tmp/spiffe-client-envoy-emissary.yaml
fi


if [ "$DO_INGRESS" == "true" ]
then
    log "=== BEGIN INGRESS TESTS ==="
    log "Checking to make sure test pods are not currently running..."
    all_clear

    log "Preparing test configs..."
    echo -e "# This file created by \"$P\".\n" > /tmp/spiffe-client-envoy.yaml
    cat "${PARENT_DIR}"/deploy/workload/spiffe-client-envoy.yaml >> /tmp/spiffe-client-envoy.yaml
    sed -i 's/envoy-config-outbound.yaml/envoy-config-inbound.yaml/' /tmp/spiffe-client-envoy.yaml
    echo -e "# This file created by \"$P\".\n" > /tmp/spiffe-client-envoy-emissary.yaml
    cat "${PARENT_DIR}"/deploy/workload/spiffe-client-envoy-emissary.yaml >> /tmp/spiffe-client-envoy-emissary.yaml
    sed -i 's/envoy-config-outbound-emissary.yaml/envoy-config-inbound-emissary.yaml/' /tmp/spiffe-client-envoy-emissary.yaml

    log "Starting \"spiffe-client\" deployment..."
    kubectl apply -n spire -f "${PARENT_DIR}"/deploy/workload/spiffe-client.yaml
    log "Starting \"spiffe-client-envoy\" deployment..."
    kubectl apply -n spire -f /tmp/spiffe-client-envoy.yaml
    log "Starting \"spiffe-client-envoy-emissary\" deployment..."
    kubectl apply -n spire -f /tmp/spiffe-client-envoy-emissary.yaml
    echo

    log "=== BEGIN INGRESS TEST 1 - ENVOY only ==="
    log "Waiting for \"spiffe-client\" deployment to be ready..."
    kubectl wait --for=condition=ready pod --timeout=60s -n spire -l "app=spiffe-client"
    kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock

    log "Waiting for \"spiffe-client-envoy\" deployment to be ready..."
    kubectl wait --for=condition=ready pod --timeout=60s -n spire -l "app=spiffe-client-envoy"
    kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock

    log "Starting ingress test 1..."
    kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- \
    https-server -v -listenPort 2223 -audience "spiffe://example.org/ns/spire/sa/spiffe-client-envoy" -noTLS &>/dev/null &

    log "Waiting for https-server to start on \"spiffe-client-envoy\"..."
    sleep 10

    log "Getting target podIP..."
    kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- \
    sh -c "echo \"$(get-podIP spire spiffe-client-envoy) targethost\" >> /etc/hosts"

    log "Settling..."
    sleep "$SETTLE_TIME"

    log "Connecting..."
    CMD1="https-client -host targethost -port 2222 -audience spiffe://example.org/ns/spire/sa/spiffe-client-envoy -peerSpiffeID spiffe://example.org/ns/spire/sa/spiffe-client-envoy -mTLS -fc"
    CMD2="kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- $CMD1"
    CMD_OUT=$($CMD2)

    test "$VERBOSE" && echo -e "\$ $CMD1\n$CMD_OUT"

    if echo "$CMD_OUT" | grep "Login successful" &>/dev/null; then
        echo "${green}Connection successful: Ingress test 1.${norm}"
    else
        echo "${red}Connection FAILED: Ingress test 1.${norm}"
    fi

    sleep 5
    echo

    log "=== BEGIN INGRESS TEST 2 - ENVOY with EMISSARY ==="
    log "Waiting for \"spiffe-client-envoy-emissary\" deployment to be ready..."
    kubectl wait --for=condition=ready pod --timeout=60s -n spire -l "app=spiffe-client-envoy-emissary"
    kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock

    log "Starting ingress test 2..."
    kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- \
    https-server -v -listenPort 2223 -noJWT -noTLS &>/dev/null &

    log "Waiting for https-server to start on \"spiffe-client-envoy-emissary\"..."
    sleep 10

    log "Getting target podIP..."
    kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- \
    sh -c "echo \"$(get-podIP spire spiffe-client-envoy-emissary) targethost2\" >> /etc/hosts"

    log "Settling..."
    sleep "$SETTLE_TIME"

    log "Connecting..."
    CMD1="https-client -host targethost2 -port 2222 -audience spiffe://example.org/ns/spire/sa/spiffe-client-envoy-emissary -peerSpiffeID spiffe://example.org/ns/spire/sa/spiffe-client-envoy-emissary -mTLS -fc"
    CMD2="kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- $CMD1"
    CMD_OUT=$($CMD2)

    test "$VERBOSE" && echo -e "\$ $CMD1\n$CMD_OUT"

    if echo "$CMD_OUT" | grep "Login successful" &>/dev/null; then
        echo "${green}Connection successful: Ingress test 2.${norm}"
    else
        echo "${red}Connection FAILED: Ingress test 2.${norm}"
    fi

    sleep 10
    echo

    log "Cleaning up from INGRESS tests..."
    log "Stopping \"spiffe-client\" deployment..."
    kubectl delete -n spire -f "${PARENT_DIR}"/deploy/workload/spiffe-client.yaml
    log "Stopping \"spiffe-client-envoy\" deployment..."
    kubectl delete -n spire -f /tmp/spiffe-client-envoy.yaml
    log "Stopping \"spiffe-client-envoy-emissary\" deployment..."
    kubectl delete -n spire -f /tmp/spiffe-client-envoy-emissary.yaml
fi

test "$DO_CLEAN" != "true" && exit 0

log "Deleting configmap \"envoy-config\"..."
kubectl kustomize "${PARENT_DIR}"/deploy/envoy/ | kubectl delete -f -
