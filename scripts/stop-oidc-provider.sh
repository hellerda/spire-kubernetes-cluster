#!/bin/bash
# ==================================================================================================
# Stops the OIDC Provider.
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


if kubectl get deployment -n spire oidc-provider &>/dev/null
then
    log "Stopping OIDC Provider..."
    kubectl delete -f "${PARENT_DIR}"/deploy/oidc-provider.yaml
    sleep 5
else
    log "OIDC Provider not running."
fi

if [ "$REG" == "true" ]; then
    log "Removing workload registration entry for OIDC Provider..."
    delete_entry_by_spiffeID spire nesteda-server-0 "spiffe://example.org/ns/spire/sa/oidc-provider"
fi

echo "${green}OIDC Provider stopped.${norm}"
