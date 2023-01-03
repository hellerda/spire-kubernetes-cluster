#!/bin/bash
# ==================================================================================================
# Tests the Federated deployment.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$DIR"/common.sh


log "Checking JWT-SVID validation across the federation...\n"

log "Checking that JWT from federated (auxiliary.org) can be validated by nestedC..."
log "Fetching JWT-SVID from federated-agent..."
token=$(exec-daemonset spire federated-agent \
    /opt/spire/bin/spire-agent api fetch jwt -audience testIt -socketPath /run/spire/sockets/agent.sock | sed -n '2p')

if [ "$token" == "" ]; then
    echo "${yellow}Failed! Unable to fetch JWT-SVID.${norm}"
else
    log "Verifying JWT-SVID at nestedc-agent..."
    validation_result=$(exec-daemonset spire nestedc-agent \
        /opt/spire/bin/spire-agent api validate jwt -audience testIt -svid "${token}" -socketPath /run/spire/sockets/agent.sock)

    if echo "$validation_result" | grep -qe "SVID is valid."; then
        echo "${green}SVID successfully verified.${norm}"
    else
        echo "${yellow}Failed! JTW-SVID cannot be validated.${norm}"
    fi
fi


log "Checking that JWT from nestedC (example.org) can be validated by federated..."
log "Fetching JWT-SVID from nestedc-agent..."
token=$(exec-daemonset spire nestedc-agent \
    /opt/spire/bin/spire-agent api fetch jwt -audience testIt -socketPath /run/spire/sockets/agent.sock | sed -n '2p')

if [ "$token" == "" ]; then
    echo "${yellow}Failed! Unable to fetch JWT-SVID.${norm}"
else
    log "Verifying JWT-SVID at federated-agent..."
    validation_result=$(exec-daemonset spire federated-agent \
        /opt/spire/bin/spire-agent api validate jwt -audience testIt -svid "${token}" -socketPath /run/spire/sockets/agent.sock)

    if echo "$validation_result" | grep -qe "SVID is valid."; then
        echo "${green}SVID successfully verified.${norm}"
    else
        echo "${yellow}Failed! JTW-SVID cannot be validated.${norm}"
    fi
fi


log "Checking that JWT from nestedB (example.org) can be validated by federated..."
log "Fetching JWT-SVID from nestedb-agent..."
token=$(exec-daemonset spire nestedb-agent \
    /opt/spire/bin/spire-agent api fetch jwt -audience testIt -socketPath /run/spire/sockets/agent.sock | sed -n '2p')

if [ "$token" == "" ]; then
    echo "${red}Failed! Unable to fetch JWT-SVID.${norm}"
else
    log "Verifying JWT-SVID at federated-agent..."
    validation_result=$(exec-daemonset spire federated-agent \
        /opt/spire/bin/spire-agent api validate jwt -audience testIt -svid "${token}" -socketPath /run/spire/sockets/agent.sock)

    if echo "$validation_result" | grep -qe "SVID is valid."; then
        echo "${green}SVID successfully verified.${norm}"
    else
        echo "${red}Failed! JTW-SVID cannot be validated.${norm}"
    fi
fi
