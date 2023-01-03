#!/bin/bash
# ==================================================================================================
# Stops (destroys) the cluster.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$( dirname "$DIR" )"

source "$DIR"/common.sh

log "Stopping nestedB agents..."
kubectl delete -f "${PARENT_DIR}"/deploy/nestedB-agent.yaml
sleep 3

log "Stopping nestedA agents..."
kubectl delete -f "${PARENT_DIR}"/deploy/nestedA-agent.yaml
sleep 3


log "Stopping nestedB server..."
kubectl delete -f "${PARENT_DIR}"/deploy/nestedB-server.yaml
sleep 3

log "Stopping nestedA server..."
kubectl delete -f "${PARENT_DIR}"/deploy/nestedA-server.yaml
sleep 3


log "Stopping root agents..."
kubectl delete -f "${PARENT_DIR}"/deploy/root-agent.yaml
sleep 3

log "Stopping root server..."
kubectl delete -f "${PARENT_DIR}"/deploy/root-server.yaml

log "Flushing all namespace resources..."
kubectl delete -f "${PARENT_DIR}"/deploy/root-server-base.yaml
