#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

"$DIR"/start-cluster.sh
"$DIR"/create-workload-registration-entries.sh
"$DIR"/start-oidc-provider.sh
"$DIR"/start-federated.sh
