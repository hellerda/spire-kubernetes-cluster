#!/bin/bash
# ==================================================================================================
# Common bits
# ==================================================================================================

green=$(tput setaf 2) || true
red=$(tput setaf 1) || true
yellow=$(tput setaf 3) || true
bold=$(tput bold) || true
norm=$(tput sgr0) || true

timestamp() {
    date -u "+[%Y-%m-%dT%H:%M:%SZ]"
}

log() {
    echo -e "${bold}$(timestamp) $*${norm}"
}

die () {
    echo "${red}$P: $*${norm}" 1>&2
    exit 1
}

to_lower () {
    echo "$1" | tr "[:upper:]" "[:lower:]"
}

to_upper () {
    echo "$1" | tr "[:upper:]" "[:lower:]"
}

make_bool () {
    # Sanitize boolean values so that on input:
    # - True = set to "true" or "y", case insensitive
    # - False = set to any other string, or unset
    # On output:
    # - True = set to a non-zero length string
    # - False = set to a zero length string
    if [ "$(to_lower "$1")" == true ] || [ "$(to_lower "$1")" == y ]
    then
        echo true
    else
        echo ""
    fi
}

check-entry-is-propagated() {
    # Check up to 30 times on 1s intervals that workload entry is synced to all agent(s).
    log "Checking registration entry is propagated..."
    for ((i=1;i<=30;i++)); do
        # shellcheck disable=SC2126
        n=$(kubectl -n spire logs -l app="$1" --prefix | grep "SVID updated" | grep "$3" | wc -l)
        if [ "$n" -gt 0 ]; then
            log "${green}$n entries are propagated...${norm}"
            if [ "$n" -ge "$2" ]; then
                log "${green}All entries have been propagated.${norm}"
                return 0
            fi
        fi
        sleep 1
    done

    log "${red}timed out waiting for entry to progagate to agent(s)${norm}"
    exit 1
}

# Assumes only one entry per Spiffe ID, which is generally not assured.
get_entry_by_spiffeID() {
    kubectl exec -n "$1" "$2" -- /opt/spire/bin/spire-server entry show -spiffeID "$3" | grep "Entry ID" | cut -d: -f2 | tr -d ' '
}

delete_entry_by_spiffeID() {
    kubectl exec -n "$1" "$2" -- /opt/spire/bin/spire-server entry delete -entryID "$(get_entry_by_spiffeID "$1" "$2" "$3")"
}

get_kids() {
    jq -r '.keys[].kid | select(. != null)' | sort | xargs
}

exec-daemonset() {
    # The daemonset is selected by "app" label.
    # The JSON chooses one pod out of the daemonset on which to run the command.
    # Limitation: stderr gets buried.
    # usage: exec-daemonset <namespace> <label> <command>
    kubectl exec -n "$1" "$(kubectl get pod -n "$1" -l "app=$2" -o jsonpath='{.items[0].metadata.name}')" -- "${@:3}" 2>/dev/null
}

gen-upstream-authority-cert() {
    openssl req -x509 -days "$3" -newkey ec:<(openssl ecparam -name prime256v1) \
    -subj "/CN=upstream-authority.$2/" -nodes \
    -addext "subjectAltName = URI:spiffe://$2" \
    -addext "keyUsage = critical,keyCertSign,cRLSign" \
    -out "$1"/upstream-authority.cert.pem -keyout "$1"/upstream-authority.key.pem
}

gen-upstream-authority-configmap() {
    # Creates a ConfigMap/Secret pair by the given name, for the UpstreamAuthority cert & key.
    dir="$(mktemp -d)"
    openssl req -x509 -days "$3" -newkey ec:<(openssl ecparam -name prime256v1) \
    -subj "/CN=upstream-authority.$2/" -nodes \
    -addext "subjectAltName = URI:spiffe://$2" \
    -addext "keyUsage = critical,keyCertSign,cRLSign" \
    -out "$dir"/upstream-authority.cert.pem -keyout "$dir"/upstream-authority.key.pem

    kubectl create configmap -n spire --dry-run=client -o yaml "$1" \
    --from-file=bootstrap.crt="$dir"/upstream-authority.cert.pem | kubectl apply -f -
    kubectl create secret generic -n spire --dry-run=client -o yaml "$1" \
    --from-file=bootstrap.key="$dir"/upstream-authority.key.pem | kubectl apply -f -
    rm -rf "$dir"
}

duplicate-configmap-simple() {
    # Creates a copy of a ConfigMap within the same namespace.
    kubectl get configmap -n spire -o yaml "$1" | \
    grep -Ev "creationTimestamp:|resourceVersion:|uid:" | \
    sed "s/name: $1/name: $2/" | kubectl apply -f-
}

# Check required programs
for prog in jq openssl; do
    if ! hash $prog; then
        echo "${red}Please install \"$prog\".${norm}"
        exit 1
    fi
done
