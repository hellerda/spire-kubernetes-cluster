#!/bin/bash

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

"$DIR"/test-cluster.sh
"$DIR"/test-oidc-provider.sh
"$DIR"/test-federated.sh
