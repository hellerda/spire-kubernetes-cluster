# Envoy and Emissary samples

The project includes a sample deployment of `spiffe-client` that is integrated with Envoy and Emissary.

- **Envoy** is an open-source edge and service-level proxy designed for use with cloud-native applications.
- **Emissary** is a modular authorization service that interoperates with SPIRE to fetch and validate JWT SVIDs, as directed by Envoy's `ext_authz` filter.

Together they form an integrated, fully functional HTTP proxy that can handle all SPIRE authentication and authorization operations.

The `spiffe-client` samples run Envoy and Emissary as sidecar containers.  **Envoy** forms the basis of the service-level proxy.  It is the traffic router for the workload, and manages all TLS or mTLS connections.  When **Emissary** is enabled, it handles all JWT authorization operations for the workload.  Envoy passes authorization operations to Emissary, which handles them by fetching and injecting JWT tokens for outbound requests and validating incoming JWTs for inbound requests.  When both Envoy and Emissary are enabled, the workload can send and receive requests in plaintext while the service-level proxy handles all authentication and authorization operations for inbound and outbound connections.

For more information on Envoy and Emissary see:

- https://github.com/envoyproxy/envoy
- https://github.com/github/emissary


## How the samples work

The samples consist of two deployment YAMLs, `spiffe-client-envoy.yaml` and `spiffe-client-envoy-emissary.yaml`, found in the `./deploy/workload/` directory, and a set of Envoy configuration files found in `./deploy/envoy/`.  There is one Envoy config file for each traffic flow direction -- inbound or outbound -- using Envoy alone, or Envoy with Emissary.  Note these are Envoy configuration files, not Kube manifest files:

- `envoy-config-inbound.yaml`
- `envoy-config-outbound.yaml`

- `envoy-config-inbound-emissary.yaml`
- `envoy-config-outbound-emissary.yaml`

The first two are intended for use with `spiffe-client-envoy.yaml`, while the latter two are intended for `spiffe-client-envoy-emissary.yaml`.  You select which config you want to use by setting it in the appropriate deployment YAML.  The config you select is the one that Envoy will use for that deployment.  With these foundational files you can create deployments to handle any of the four fundamental use cases, corresponding to the four Envoy configs above.

Some example use cases include:

- A workload fronted by `envoy` and `emissary` communicating with another workload fronted by `envoy` and `emissary`.  In this case both workloads operate in plaintext, with AuthN and AuthZ handled by `envoy` and `emissary`.
- A workload fronted by `envoy` and `emissary` communicating with a workload fronted by `envoy` only.  In this case the workload with envoy-only must handle JWT creation or JWT validation/authorization *within the application*.
- A workload fronted by `envoy` and `emissary` communicating with a workload with no service proxy (e.g. vanilla `spiffe-client`).  In this case the workload with no proxy must handle both mTLS authentication and JWT authorization *within the application*.


## Creating the Envoy configuration ConfigMap

The Envoy configs are deployed using `kustomize`.  To create the configmap containing the four files run:

```
cd ./deploy/envoy/
kubectl kustomize | kubectl apply -f -
```

This creates a configmap named `envoy-config` with four data objects, one for each Envoy config file.  This configmap is mounted in the container at the path `/run/envoy/`, and the above filenames will appear there.  You determine which config Envoy uses by editing the `envoy` command line in `spiffe-client-envoy.yaml` or `spiffe-client-envoy-emissary.yaml`, as described above.

For any config you know you won't use and don't wish to deploy you can simply comment out that line from `kustomize.yaml`.  To add it later you can uncomment the line and re-run the `kubectl apply`.

To remove the configmap:

```
cd ./deploy/envoy/
kubectl kustomize | kubectl delete -f -
```

## A Note on Envoy configuration

Envoy uses the xDS protocol, which supports automated configuration of all aspects of Envoy operation including Listeners, Routes, Clusters, Endpoints and operating Secrets.  Of all these, we are leveraging only the SDS protocol, supporting auto-config of Secrets.  SPIRE supports SDS protocol directly, enabling the easy integration there.

Without some higher-level control plane (such as Istio) to manage Envoy configuration, the remaining configuration properties are by "static configuration" in Envoy.  This includes the destination address(es) of remote endpoints accessed by Envoy egress.  This means that the destination address of every configured endpoint must be set statically in the config.  (The same is true for Emissary, although config is by environment variable instead of config file).

As a workaround, we set the generic hostname "targethost" in the Envoy and Emissary configs.  Any egress endpoint accessed as "targethost" should match the static resource configured as this destination.  So for example, by adding an entry pointing to "targethost" in the `/etc/hosts` file on the client pod, a client using Envoy as forward proxy can match the necessary "static config" for Envoy and Emissary, and access the endpoint "targethost" via this config.

To complete the workaround, we employ a shell function `get-podIP` that can find the IP address of a specified pod:
```
get-podIP() { kubectl get pod -n "$1" -l "app=$2" -o jsonpath='{.items[0].status.podIP}'; }
```
Using this function we can easily add an `/etc/hosts/` entry to the client-side pod before each test.  The is the method we describe in the steps below, and this is the method used by the automated `test-envoy-emissary.sh` script.


# Example: Envoy and Emissary outbound

In this scenario you will communicate outbound from a pod fronted by Envoy, or Envoy with Emissary, to a pod with no service-level proxy.  Envoy acts as a *forward proxy* in this case.  The scenario uses three test pods:

- `spiffe-client` - A vanilla workload pod with `https-server` running.
- `spiffe-client-envoy` - A workload pod fronted by Envoy proxy that will connect using `https-client`.
- `spiffe-client-envoy-emissary` - A workload pod fronted by Envoy with Emissary that will connect using `https-client`.

When successful, `https-client` on either envoy-enabled pod will be able to communicate with `https-server` on the vanilla pod, with mTLS and JWT validation handled by SPIRE at all points.

## Prep

1. Make sure that NestedC Server and Agent are running (launch `start-federated.sh`) and make sure the deployment YAMLs for all three test pods point to `nestedc-agent` (as they should by default).  We need NestedC, as this is the server with SPIRE K8s Workload Registrar running, and we'll rely on this to automatically create workload registration entries.  Without this we would need to add the registration entries manually.  See the top-level README for details.

2. Make sure the deployment YAMLs for the `spiffe-client-envoy` and `spiffe-client-envoy-emissary` pods are configured to use `envoy-config-outbound.yaml` and `envoy-config-outbound-emissary.yaml` respectively.

3. Make sure the the `envoy-config` configmap is deployed as described above.

## Launch the pods

1. Deploy the test pods by applying the deployment YAMLs:
```
$ kubectl apply -n spire -f deploy/workload/spiffe-client.yaml
$ kubectl apply -n spire -f deploy/workload/spiffe-client-envoy.yaml
$ kubectl apply -n spire -f deploy/workload/spiffe-client-envoy-emissary.yaml
```
2. To avoid having to specify the SPIRE agent `--socketPath` on every `https-client` and `https-server` command line, on each pod, create a symbolic link from the actual socket path served by the agent (`/run/spire/sockets/agent.sock`) to the default socket path used by the test tools (`/tmp/spire-agent/public/api.sock`):
```
$ kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock
$ kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock
$ kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- ln -s /run/spire/sockets/agent.sock /tmp/spire-agent/public/api.sock
```

## Egress test 1 - Envoy only

In one terminal, launch the `https-server` process on the `spiffe-client` pod.  Note that the Spiffe ID specified by `-audience ` is that of the server, and the Spiffe ID specified by `-mTLS` is that of the remote client we are expecting to connect.
```
$ kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- \
  https-server -v -listenPort 2222 -audience "spiffe://example.org/ns/spire/sa/spiffe-client" \
  -mTLS "spiffe://example.org/ns/spire/sa/spiffe-client-envoy"
```

In another terminal, launch the `https-client`  process on the `spiffe-client-envoy` pod.  First you will need the IP address of the `spiffe-client` pod.  Enable the `get-podIP()` function mentioned above, by pasting the command line to your shell terminal or adding it to your `.bashrc`.  Then issue the following command to create the `/etc/hosts` entry:
```
kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- \
 sh -c "echo \"$(get-podIP spire spiffe-client) targethost\" >> /etc/hosts"
```

Now issue the command to launch `https-client`:
```
$ kubectl exec -it -n spire deployment/spiffe-client-envoy -c spiffe-client -- \
  https-client -proxyURL http://localhost:2223 -host targethost -port 2222 \
  -audience "spiffe://example.org/ns/spire/sa/spiffe-client" -noTLS
```
The command uses the `-proxyURL` option to access Envoy as the outbound HTTP proxy running on port 2223.  The port of the remote server, port 2222, is specified by `-port`.  The `-audience` is the value that will be added to the outgoing JWT claim, and the specified value is the value expected by the server.  Note that the `https-client` program must handle the injection of the JWT (as fetched from SPIRE) into the `Authorization` header of the HTTP request, as there is no Emissary here to offload the task.  The mTLS however, will be handled by the Envoy proxy, which retrieves the x509 cert from SPIRE and acts as the TLS endpoint on behalf of the workload.  So the program need only specify the `-noTLS` option, to indicate it is running in plaintext (HTTP) mode.

The command should produce output similar to the example below.  Note the details of the outgoing JWT.  Note also there is no detail regarding the mTLS connection, as that is handled by Envoy, not the workload:
```
$ https-client -proxyURL http://localhost:2223 -host targethost -port 2222 -audience "spiffe://example.org/ns/spire/sa/spiffe-client" -noTLS
2022/11/28 22:09:17 Successfully fetched JWT SVID... this is what we will send...
2022/11/28 22:09:17 - JWT Header is {"alg":"RS256","kid":"R6tHiXFGT3MfARUkQrSffvSi5QA00OlH","typ":"JWT"}
2022/11/28 22:09:17 - JWT Payload is {"aud":["spiffe://example.org/ns/spire/sa/spiffe-client"],"exp":1669673657,"iat":1669673357,"iss":"https://oidc.spire.mydomain.com","sub":"spiffe://example.org/ns/spire/sa/spiffe-client-envoy"}
2022/11/28 22:09:17 Setting Authorization header with JWT Bearer token...
2022/11/28 22:09:17 Attempting to connect to the server...
2022/11/28 22:09:17 Login successful!!
```

At the server you will see output like this.  There is no Envoy on this side of the connection, so the workload must handle both the mTLS and JWT validation, and the output reflects these details:
```
$ https-server -v -listenPort 2222 -audience "spiffe://example.org/ns/spire/sa/spiffe-client" -mTLS "spiffe://example.org/ns/spire/sa/spiffe-client-envoy"
2022/11/28 22:07:14 Successfully retrieved TLS ServerConfig with ServerName ""...
2022/11/28 22:09:17 Connection received with JWT Bearer token from "Authorization" hdr...
2022/11/28 22:09:17 - JWT Header is {"alg":"RS256","kid":"R6tHiXFGT3MfARUkQrSffvSi5QA00OlH","typ":"JWT"}
2022/11/28 22:09:17 - JWT Payload is {"aud":["spiffe://example.org/ns/spire/sa/spiffe-client"],"exp":1669673657,"iat":1669673357,"iss":"https://oidc.spire.mydomain.com","sub":"spiffe://example.org/ns/spire/sa/spiffe-client-envoy"}
2022/11/28 22:09:17 Successfully verified JWT Bearer token...
2022/11/28 22:09:17 - Audience is "[spiffe://example.org/ns/spire/sa/spiffe-client]"
2022/11/28 22:09:17 - Subject is "spiffe://example.org/ns/spire/sa/spiffe-client-envoy"
2022/11/28 22:09:17 Peer certificate chain contains 3 certs.
2022/11/28 22:09:17 - Cert[0] Subject = CN=spiffe-client-envoy-dbf7ffbd4-gwtp8,O=SPIRE,C=US
2022/11/28 22:09:17 - Cert[0] Issuer  = OU=DOWNSTREAM-2,O=SPIFFE,C=US
2022/11/28 22:09:17 - Cert[1] Subject = OU=DOWNSTREAM-2,O=SPIFFE,C=US
2022/11/28 22:09:17 - Cert[1] Issuer  = O=SPIFFE,C=US
2022/11/28 22:09:17 - Cert[2] Subject = O=SPIFFE,C=US
2022/11/28 22:09:17 - Cert[2] Issuer  = CN=upstream-authority.example.org
2022/11/28 22:09:17 Client login successful.
```

## Egress test 2 - Envoy with Emissary

In the terminal running the `https-server` process on the `spiffe-client` pod: terminate the program with Ctrl-C and launch a new process with the following command.  Note it is the same as the previous case, except the `-mTLS` value is updated to reflect the new client Spiffe ID:
```
$ kubectl exec -it -n spire deployment/spiffe-client -c spiffe-client -- \
  https-server -v -listenPort 2222 -audience "spiffe://example.org/ns/spire/sa/spiffe-client" \
  -mTLS "spiffe://example.org/ns/spire/sa/spiffe-client-envoy-emissary"
```

In the other terminal, launch the `https-client`  process on the `spiffe-client-envoy-emissary` pod.  First, issue the command to create the `/etc/hosts` entry:
```
$ kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- \
  sh -c "echo \"$(get-podIP spire spiffe-client) targethost\" >> /etc/hosts"
```

Now issue the command to launch `https-client`:
```
$ kubectl exec -it -n spire deployment/spiffe-client-envoy-emissary -c spiffe-client -- \
  https-client -proxyURL http://localhost:2223 -host targethost -port 2222 -noJWT -noTLS
```
As we have both Envoy and Emissary here, the workload doesn't need to handle the JWT or mTLS operations.  The program need only specify the `-noJWT` and `-noTLS` options, to indicate it not handling either.

The command should produce output similar to the example below.  Note there is no detail regarding the mTLS or JWT authentication, as these are handled by Envoy and Emissary, not the workload:
```
$ https-client -proxyURL http://localhost:2223 -host targethost -port 2222 -noJWT -noTLS
2022/11/28 22:42:15 Attempting to connect to the server...
2022/11/28 22:42:15 Login successful!!
```
At the server you will see output similar to the previous example.  The only difference is the subject of the client pod, which will be `spiffe://example.org/ns/spire/sa/spiffe-client-envoy-emissary` rather than `spiffe://example.org/ns/spire/sa/spiffe-client-envoy`.

## Cleanup

Issue the following commands to delete the test pods:
```
$ kubectl delete -n spire -f deploy/workload/spiffe-client.yaml
$ kubectl delete -n spire -f deploy/workload/spiffe-client-envoy.yaml
$ kubectl delete -n spire -f deploy/workload/spiffe-client-envoy-emissary.yaml
```

# Example: Envoy and Emissary inbound

The scenario is similar to the outbound case, except that the `http-client` connection is sourced from the pod with no service-level proxy, to the pods fronted by Envoy, or Envoy with Emissary.  Details are not shown here, but you can glean the test sequence from the INGRESS tests in the `test-envoy-emissary.sh` script.  There you will find all the commands to run the tests manually, in a manner similar to the outbound tests above.

# Test script

The project includes a test script, `test-envoy-emissary.sh`, that will automatically execute the four test scenarios:

1. EGRESS (outbound) with Envoy only
2. EGRESS (outbound) with Envoy and Emissary
3. INGRESS (inbound) with Envoy only
4. INGRESS (inbound) with Envoy and Emissary

The script automatically launches the test pods and performs the `https-client/server` tests between endpoints.  Results are displayed to stdout.

## Usage
```
$ scripts/test-envoy-emissary.sh --help

      Options:
      -h, --help            display this message and exit
      -e, --egress          run EGRESS tests only
      -i, --ingress         run INGRESS tests only
      -c, --clean           delete configmap on exit
      -s, --settle          settling delay before each test (default 5s)
      -v, --verbose         show more detail
```

## Settle time

On a slow or heavily loaded system, tests may fail due to lack of readiness of the test workload.  The problem usually stems from the delay in the workload (or envoy or emissary processes) retrieving its SVID from SPIRE.  In lieu of a retry, or a true check of process readiness, the workaround is to insert a short sleep before launching the `https-client` process.  The sleep time is controlled by the `--settle` command line option, with a default of 5 s.  If you experience intermittent test failures you may specify a longer `--settle` time on the command line.
