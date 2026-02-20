## Deploy [S4 storage](https://github.com/rh-aiservices-bu/s4) in Openshift

### Pre-requisites
- Log In in OCP via command line
- Having installed [helm command](https://helm.sh/docs/intro/install/).For Fedora:
~~~
sudo dnf install helm
~~~

1. Clone the Git Hub repository and move to the repo directory:
~~~
git clone https://github.com/rh-aiservices-bu/s4
~~~
~~~
cd s4/
~~~

2. Install S4 via helm command referencing the chart and the namespace: 
~~~
helm install s4 ./charts/s4 --namespace s4 --create-namespace
~~~
If get the following error, create a credentials values file with your current OpenShift cluster credentials:
~~~
Error: INSTALLATION FAILED: execution error at (s4/templates/secret.yaml:18:12): auth.username is required when auth.enabled=true
~~~
Create a YAML file with your OpenShift credentials:
~~~
vi my-credentials.yaml
~~~
~~~
auth:
  enabled: true
  username: "ocp-user"
  password: "ocp-password"
~~~

Then execute:
~~~
helm install s4 ./charts/s4 -f my-credentials.yaml --namespace s4 --create-namespace
~~~
This command produces below output:
~~~
NAME: s4
LAST DEPLOYED: Fri Feb 20 15:29:40 2026
NAMESPACE: s4
STATUS: deployed
REVISION: 1
TEST SUITE: None
NOTES:
S4 (Super Simple Storage Service) has been deployed!

Access the Web UI via OpenShift Route:
  kubectl get route s4 -n s4 -o jsonpath='{.spec.host}'

Authentication is enabled. Use the configured credentials to log in.

S3 Credentials:
  Access Key: s4admin
  Secret Key: (stored in secret s4-credentials)

For more information, see:
  https://github.com/rh-aiservices-bu/s4
~~~

3. Verify the deployed pod:
~~~
$ oc get pods
NAME                  READY   STATUS    RESTARTS   AGE
s4-7cb64f4bbc-cmjsm   1/1     Running   0          46s
~~~

4. Get the exposed route and test access:
~~~
oc get route
NAME   HOST/PORT                PATH   SERVICES   PORT     TERMINATION     WILDCARD
s4     s4-s4.apps-my-ocp.testing          s4         web-ui   edge/Redirect   None
~~~

<img width="1003" height="569" alt="s4-login-en" src="https://github.com/user-attachments/assets/5190149e-b414-45d2-93a9-984afabc91e9" />

### NOTE: The access user/password are the same configured in `my-credentials.yaml` (step 2).
