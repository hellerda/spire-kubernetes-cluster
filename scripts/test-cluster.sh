#!/bin/bash
# ==================================================================================================
# Tests the Nested cluster operations.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$DIR"/common.sh


# Check that bundle keys are the same at all servers in the nested cluster...
log "Checking keys from Root server bundle..."
keylist=$(kubectl exec -n spire root-server-0 -- /opt/spire/bin/spire-server bundle show -format spiffe | get_kids)

if [ "$keylist" == "" ]; then
    echo "${red}Root bundle returned no JWKS.${norm}"
    exit 1
fi

root_bundle_keys=$(echo "$keylist" | openssl md5)

log "Checking keys from nestedA server bundle..."
keylist=$(kubectl exec -n spire nesteda-server-0 -- /opt/spire/bin/spire-server bundle show -format spiffe | get_kids)

if [ "$keylist" == "" ]; then
    echo "${red}NestedA bundle returned no JWKS.${norm}"
    exit 1
fi

nestedA_bundle_keys=$(echo "$keylist" | openssl md5)

log "Checking keys from nestedB server bundle..."
keylist=$(kubectl exec -n spire nestedb-server-0 -- /opt/spire/bin/spire-server bundle show -format spiffe | get_kids)

if [ "$keylist" == "" ]; then
    echo "${red}NestedA bundle returned no JWKS.${norm}"
    exit 1
fi

nestedB_bundle_keys=$(echo "$keylist" | openssl md5)


log "Comparing Root bundle keys to NestedA..."
if [ "$root_bundle_keys" == "$nestedA_bundle_keys" ]; then
    echo "${green}Keys match.${norm}"
else
    echo "${red}Failed! Mismatch between keys from Root and NestedA servers .${norm}"
    exit 1
fi

log "Comparing Root bundle keys to NestedB..."
if [ "$root_bundle_keys" == "$nestedB_bundle_keys" ]; then
    echo "${green}Keys match.${norm}"
else
    echo "${red}Failed! Mismatch between keys from Root and NestedB servers .${norm}"
    exit 1
fi


# Fetch an SVID from nestedA and validate it at nestedB...
log "Checking JWT-SVID validation across the cluster..."

token=$(exec-daemonset spire nesteda-agent \
    /opt/spire/bin/spire-agent api fetch jwt -audience testIt -socketPath /run/spire/sockets/agent.sock | sed -n '2p')

if [ "$token" == "" ]; then
    echo "${red}Failed! Unable to fetch JWT-SVID.${norm}"
    exit 1
fi

validation_result=$(exec-daemonset spire nestedb-agent \
    /opt/spire/bin/spire-agent api validate jwt -audience testIt -svid "${token}" -socketPath /run/spire/sockets/agent.sock)

if echo "$validation_result" | grep -qe "SVID is valid."; then
    echo "${green}SVID successfully verified.${norm}"
else
    echo "${red}Failed! JTW-SVID cannot be validated.${norm}"
    exit 1
fi
