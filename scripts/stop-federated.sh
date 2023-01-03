#!/bin/bash
# ==================================================================================================
# Stop all nodes / clear all data for Federated deployment.
# ==================================================================================================

# Set environment
P=${0##*/}

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$( dirname "$DIR" )"

source "$DIR"/common.sh

# Defaults, inital values
CLEAN_ALL="false"
R_WE_SURE="false"
FORCE="false"


usage () {
    echo ""
    echo "      Options:"
    echo "      -h, --help              display this message and exit"
    echo "      -f, --force             do all shutdown steps even if pods do not appear to be running"
    echo "      -c, --clean             delete all runtime data"
    echo "      -y, --yes               do not ask are you sure?"
    echo ""
    exit 1
}

# Convert long options to short
for arg in "$@"; do
  shift
  case "$arg" in
    "--help")       set -- "$@" "-h" ;;
    "--clean")      set -- "$@" "-c" ;;
    "--force")      set -- "$@" "-f" ;;
    "--yes")        set -- "$@" "-y" ;;
    *)              set -- "$@" "$arg"
  esac
done

# Process command-line arguments
while getopts \?hcfy opt
do
  case "${opt:?}" in
    c) CLEAN_ALL="true";;
    f) FORCE="true";;
    y) R_WE_SURE="true";;
    h|\?) usage;;
  esac
done

# Sanitize boolean values
CLEAN_ALL="$(make_bool "$CLEAN_ALL")"
R_WE_SURE="$(make_bool "$R_WE_SURE")"
FORCE="$(make_bool "$FORCE")"


# IF we have k8sr integrated into Pod nestedc, we MUST delete the SpiffeID CRDs first...
log "Deleting SpiffeID CRDs (for k8sr)..."
kubectl delete -f "${PARENT_DIR}"/deploy/spiffeid.spiffe.io_spiffeids.yaml


# Stop nodes...

if [ -n "$FORCE" ] || kubectl get daemonset -n spire federated-agent &>/dev/null
then
    log "Stopping federated agents..."
    kubectl delete -f "${PARENT_DIR}"/deploy/federated-agent.yaml
    sleep 5

    log "Removing federated-agent-base resources..."
    kubectl delete -f "${PARENT_DIR}"/deploy/federated-agent-base.yaml
    sleep 5
else
    log "federated-agent not running."
fi

if [ -n "$FORCE" ] || kubectl get statefulset -n spire federated-server &>/dev/null
then
    log "Stopping federated server..."
    kubectl delete -f "${PARENT_DIR}"/deploy/federated-server.yaml
    sleep 5

    log "Removing federated-server-base resources..."
    kubectl delete -f "${PARENT_DIR}"/deploy/federated-server-base.yaml
    sleep 5
else
    log "federated-server not running."
fi

if [ -n "$FORCE" ] || kubectl get daemonset -n spire nestedc-agent &>/dev/null
then
    log "Stopping nestedC agents..."
    kubectl delete -f "${PARENT_DIR}"/deploy/nestedC-agent.yaml
    sleep 5
else
    log "nestedC-agent not running."
fi

if [ -n "$FORCE" ] || kubectl get statefulset -n spire nestedc-server &>/dev/null
then
    log "Stopping nestedC server..."
    kubectl delete -f "${PARENT_DIR}"/deploy/nestedC-server.yaml
    sleep 5
else
    log "nestedC server not running."
fi

if [ -n "$(get_entry_by_spiffeID spire root-server-0 "spiffe://example.org/ns/spire/sa/nestedc-server")" ]
then
    log "Removing downstream registration entry for nestedC server..."
    delete_entry_by_spiffeID spire root-server-0 "spiffe://example.org/ns/spire/sa/nestedc-server"
else
    log "No downstream registration entry found for nestedC server."
fi

echo "${green}Federated nodes stopped.${norm}"


test "$CLEAN_ALL" != "true" && exit 0

if [ "$R_WE_SURE" != "true" ]; then
  echo -e "\n${red}About to delete all runtime data for the federated nodes...  are you sure?  (^C to abort)${norm}"
  count=5
  while [ "$count" -gt 0 ]; do
      echo -n "Continuing in $count seconds..."
      echo -en "\033[40D"
      sleep 1
      (( count-- ))
  done
fi

# If you don't do this, the server will use the exising DB in the PVC on next restart.
# Unless of course, the entire namespace was deleted like with "stop-cluster.sh"

log "Dropping PersistentVolumeClaim for nestedC server..."
kubectl delete persistentvolumeclaim -n spire spire-data-nestedc-server-0

log "Dropping PersistentVolumeClaim for Federated server..."
kubectl delete persistentvolumeclaim -n spire spire-data-federated-server-0

echo "${green}Runtime data deleted for federated nodes.${norm}"
