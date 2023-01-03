#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

"$DIR"/stop-federated.sh
"$DIR"/stop-oidc-provider.sh
"$DIR"/stop-cluster.sh
