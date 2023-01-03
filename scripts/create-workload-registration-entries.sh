#!/bin/bash
# ==================================================================================================
# This creates the WORKLOAD registration entries, to test workloads in the nested cluster.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$DIR"/common.sh


log "Creating node-level alias for nestedA agents..."
kubectl exec -n spire nesteda-server-0 -- /opt/spire/bin/spire-server entry create -node \
    -spiffeID "spiffe://example.org/ns/spire/sa/nesteda-agent" \
    -selector "k8s_sat:cluster:spire" \
    -selector "k8s_sat:agent_sa:nesteda-agent"

log "Creating nestedA workload registration entry..."
kubectl exec -n spire nesteda-server-0 -- /opt/spire/bin/spire-server entry create -downstream \
    -parentID "spiffe://example.org/ns/spire/sa/nesteda-agent" \
    -spiffeID "spiffe://example.org/ns/spire/sa/nesteda-workload" \
    -selector "k8s:ns:spire" \
    -selector "k8s:sa:nesteda-agent"

check-entry-is-propagated nesteda-agent 2 spiffe://example.org/ns/spire/sa/nesteda-workload


log "Creating node-level alias for nestedB agents..."
kubectl exec -n spire nestedb-server-0 -- /opt/spire/bin/spire-server entry create -node \
    -spiffeID "spiffe://example.org/ns/spire/sa/nestedb-agent" \
    -selector "k8s_sat:cluster:spire" \
    -selector "k8s_sat:agent_sa:nestedb-agent"

log "Creating nestedB workload registration entry..."
kubectl exec -n spire nestedb-server-0 -- /opt/spire/bin/spire-server entry create -downstream \
    -parentID "spiffe://example.org/ns/spire/sa/nestedb-agent" \
    -spiffeID "spiffe://example.org/ns/spire/sa/nestedb-workload" \
    -selector "k8s:ns:spire" \
    -selector "k8s:sa:nestedb-agent"

check-entry-is-propagated nestedb-agent 2 spiffe://example.org/ns/spire/sa/nestedb-workload
