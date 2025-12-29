## Creating a Minio deployment in the Openshift Cluster

### Clone the current project and move to the `minio` directory:
~~~
git clone https://github.com/alexbarbosa1989/ai-playground
~~~ 
~~~
cd ai-playground/rhoai-tests/minio/
~~~

### Create a new project in the Openshift environment where will be deployed minio (assuming you're already logged in the OCP cluster):
~~~
oc new-project minio
~~~

### Deploy minio using the `minio-deployment.yaml` (it can be customized according each use case)
~~~
oc create -f minio-deployment.yaml 
~~~
Expected command output
~~~
persistentvolumeclaim/minio-pvc created
secret/minio-secret created
deployment.apps/minio created
service/minio-service created
route.route.openshift.io/minio-api created
route.route.openshift.io/minio-ui created
~~~
