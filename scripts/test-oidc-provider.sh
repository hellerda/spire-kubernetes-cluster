#!/bin/bash
# ==================================================================================================
# Test the OIDC Provider by comparing bundle retrieved by OIDC vs. bundle fron one of the cluster nodes.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$DIR"/common.sh

set -e


log "Checking that OIDC Provider is available..."
kubectl wait --for=condition=ready --timeout=10s pod -n spire -l app=oidc-provider

log "Starting test pod..."
if ! kubectl get pod -n spire alpine &>/dev/null; then
  kubectl run alpine -n spire --image alpine:latest --command -- sh -c "apk add curl && sleep 999999"
  kubectl wait --for=condition=ready --timeout=10s pod -n spire alpine >/dev/null
fi

# We could use any server really, they should all be the same.  Should be.
log "Checking keys from server bundle..."
keylist=$(kubectl exec -n spire nesteda-server-0 -- /opt/spire/bin/spire-server bundle show -format spiffe | get_kids)

if [ "$keylist" == "" ]; then
    echo "${red}NestedA bundle returned no JWKS.${norm}"
    exit 1
fi

bundle_keys=$(echo "$keylist" | openssl md5)

log "Checking keys from OIDC Provider..."

keylist=""

# Query the UDS...
if [ -z "$keylist" ]; then
    # Query the TCP port...
    targetip="$(get-podIP spire oidc-provider)"
    if isIPv6 "$targetip"; then targetip="[$targetip]"; fi
    keylist=$(kubectl exec -n spire pod/alpine -- curl -s http://"$targetip":2080/keys | sed -ne '/^{/,$ p' | get_kids)

    if [ -n "$keylist" ]; then
        echo "${green}Read OIDC keys from local TCP port.${norm}"
    else
        echo "${red}OIDC bundle returned no JWKS.${norm}"
        exit 1
    fi
fi

oidc_keys=$(echo "$keylist" | openssl md5)

log "Comparing server bundle keys to OIDC Provider keys..."
if [ "$bundle_keys" == "$oidc_keys" ]; then
    echo "${green}Keys match.${norm}"
else
    echo "${red}Failed! Mismatch between keys from server bundle and keys from OIDC provider.${norm}"
    exit 1
fi

log "Checking availability of OIDC Provider service..."
keylist=""
  keylist=$(kubectl exec -n spire pod/alpine -- curl -s http://oidc-provider:80/keys | sed -ne '/^{/,$ p' | get_kids)

if [ -z "$keylist" ]; then
    echo "${yellow}warning: Service \"oidc-provider\" is not available.${norm}"
else
    echo "${green}Service \"oidc-provider\" is available...${norm}"
    oidc_service_keys=$(echo "$keylist" | openssl md5)

    if [ "$bundle_keys" == "$oidc_service_keys" ]; then
        echo "${green}Keys from OIDC service match keys from OIDC local port.${norm}"
    else
        echo "${red}Failed! Mismatch between keys from OIDC provider service and keys from OIDC local port.${norm}"
        exit 1
    fi
fi

kubectl delete -n spire pod/alpine --now >/dev/null
