### Reference document
https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/working_with_llama_stack/llama-stack-adv-examples_rag#deploying-a-llamastackdistribution-instance_rag


Prerequisites:
- OpenShift cluster with NVIDIA GPU enabled
- OpenShift AI cluster with llamastack operator set **Managed**:
~~~
      llamastackoperator:
        managementState: Managed
~~~
- GenAIStudio enabled in the OpenShift AI Dashboard:
~~~
oc patch OdhDashboardConfig odh-dashboard-config -n redhat-ods-applications --type=merge --patch='{"spec":{"dashboardConfig":{"genAiStudio": true}}}'
~~~

## Executed procedure ["Example A: Inline Milvus (embedded, single-node, remote embeddings)"](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.3/html/working_with_llama_stack/llama-stack-adv-examples_rag#example_a_llamastackdistribution_with_inline_milvus)

1. Create a project where will be allocated the resources
~~~
oc new-project demo-llm
~~~

2. Deploy a postgresql database (**Important:** must use Postgresql 14 or upper)
Navigate in the OpenShift Web Console left panel **Ecosystem > Software Catalog** and search for **PostgreSQL template**. There **Instantiate Template** with preferred values:
For current example:

| Field                          | Value      |
|--------------------------------|------------|
| Namespace                      | demo-llm   |
| Memory Limit                   | 512Mi      |
| Namespace                      | openshift  |
| Database Service Name          | postgresql |
| PostgreSQL Connection Username | <dbuser>   |
| PostgreSQL Connection Password | <dbpass>   |
| PostgreSQL Database Name       | llamastack |
| Volume Capacity                | 1Gi        |
| Version of PostgreSQL Image    | latest     |

Once created, it will create the postgresql deployment, pod and service
~~~
$ oc get pods 
NAME                                      READY   STATUS      RESTARTS   AGE
postgresql-1-deploy                       0/1     Completed   0          7h30m
postgresql-1-pl944                        1/1     Running     0          7h30m
~~~
~~~
oc get svc
NAME                              TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
postgresql                        ClusterIP   172.30.200.94   <none>        5432/TCP   7h32m
~~~

[Optional] Test the connection:
~~~
sh-4.4$ psql -h postgresql.demo-llm.svc.cluster.local -p 5432 -U <dbuser> -d llamastack -c "SELECT 1"
Password for user <dbuser>: 
 ?column? 
----------
        1
(1 row)

sh-4.4$ 
~~~

3. Serve a model
Follow the same procedure from [Serving modelcar](https://github.com/alexbarbosa1989/ai-playground/tree/main/rhoai-tests/serving-modelcar) example, but instead of deploying the model in `dsc-test` namespace, must created in `demo-llm`.

In this case, a `Llama 3 model` was used with the following values:

| Field                          | Value                                                |
|--------------------------------|------------------------------------------------------|
| Conection URI                  | oci://quay.io/rhoai-genaiops/llama32-3b-instruct-fp8 |
| Model type                     | Generative AI model (Example, LLM)                   |
| Model location                 | URI                                                  |
| Connection name                | llama3                                               |
| Project                        | demo-llm                                             |
| Model deployment name          | llama3                                               |
| Hardware profile               | local-gpu                                            |
| Model format                   | vLLM                                                 |
| Serving runtime                | vLLM NVIDIA GPU ServingRuntime for KServe            |
| Replicas                       | 1                                                    |
| AI asset endpoint              | Yes                                                  |
| Use case                       | llama3-tests                                         |
| External route                 | Yes                                                  |
| Token authentication           | No                                                   |
| Additional runtime arguments   | 3                                                    |
|                                | --max-model-len=16000,                               |
|                                | --enable-auto-tool-choice,                           |
|                                | --tool-call-parser=llama3_json                       |
| Deployment strategy            | Rolling update                                       |

**Important:** In the deployment configuration, set the **Additional runtime arguments** and check the **Add as AI asset endpoint** box
<img width="777" height="193" alt="llama3-args" src="https://github.com/user-attachments/assets/ce8636a7-879c-42b3-9b00-18001fe2c580" />

<img width="637" height="556" alt="llama3-summary" src="https://github.com/user-attachments/assets/f7bf4829-48f5-4fd1-b5eb-84b3d153561b" />


~~~
oc get InferenceService -n demo-llm
~~~
~~~
NAME     URL                                             READY   PREV   LATEST   PREVROLLEDOUTREVISION   LATESTREADYREVISION   AGE
llama3   https://llama3-demo-llm.apps.aba-sno.test.com   True  
~~~
~~~
oc get pods
~~~
~~~
NAME                               READY   STATUS      RESTARTS   AGE
llama3-predictor-8bbb6c578-bqbt5   2/2     Running     0          7m19s
postgresql-1-deploy                0/1     Completed   0          46h
postgresql-1-pl944                 1/1     Running     1          46h
~~~
Test the deployed model
~~~
curl -X POST "https://llama3-demo-llm.apps.aba-sno.test.com/v1/chat/completions" \
  -H "Content-Type: application/json"  \
  --data '{"model": "llama3","messages": [{"role": "user","content": "What is the capital of France?"}]}' \
  --insecure
~~~
Expected output:
~~~
{"id":"chatcmpl-a3a9ed13b68a563d","object":"chat.completion","created":1773331003,"model":"llama3","choices":[{"index":0,"message":{"role":"assistant","content":"The capital of France is Paris.","refusal":null,"annotations":null,"audio":null,"function_call":null,"tool_calls":[],"reasoning":null,"reasoning_content":null},"logprobs":null,"finish_reason":"stop","stop_reason":null,"token_ids":null}],"service_tier":null,"system_fingerprint":null,"usage":{"prompt_tokens":42,"total_tokens":50,"completion_tokens":8,"prompt_tokens_details":null},"prompt_logprobs":null,"prompt_token_ids":null,"kv_transfer_params":null}
~~~

4. Deploy embeddings service. (Due my lack of hardware CPU resources, I had to deploy the embeddings outside the SNO).

~~~
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
~~~
~~~
podman run -ti --rm --pull=newer \
--user 0 --shm-size=0 --name vllm \
--env "HUGGING_FACE_HUB_TOKEN=$HF_TOKEN" \
--env "HF_HUB_OFFLINE=0" \
--replace -v ~/.cache/huggingface:/root/.cache/huggingface \
--stop-signal=SIGKILL --device nvidia.com/gpu=all \
--security-opt=label=disable --hooks-dir=/etc/containers/oci/hooks.d/ \
-p 8000:8000 \
vllm/vllm-openai:latest \
--model Qwen/Qwen3-Embedding-0.6B --max_model_len=8192
~~~

On the host, find the bridge/NAT IP the VM uses
~~~
ip addr show | grep -E "virbr|vnet|bridge"
~~~
Typically something like 192.168.122.1 for libvirt NAT
~~~
3: virbr0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc htb state UP group default qlen 1000
    inet 192.168.122.1/24 brd 192.168.122.255 scope global virbr0
~~~

Test local:
~~~
curl http://192.168.122.1:8000/v1/models
{"object":"list","data":[{"id":"Qwen/Qwen3-Embedding-0.6B","object":"model","created":1773178248,"owned_by":"vllm","root":"Qwen/Qwen3-Embedding-0.6B","parent":null,"max_model_len":4096,"permission":[{"id":"modelperm-a183e096a4d3f619","object":"model_permission","created":1773178248,"allow_create_engine":false,"allow_sampling":true,"allow_logprobs":true,"allow_search_indices":false,"allow_view":true,"allow_fine_tuning":false,"organization":"*","group":null,"is_blocking":false}]}]}
~~~
That will be the IP to reference the Embedding model service in the **lsd-llama-milvus-inline.yaml** file.

Create the `llama-stack-secret` from the **secret-values.sh** script. It must be customized with the valid values for each environment:
~~~
./secret-values.sh 
~~~
Deploy the the `LlamaStackDistribution` CR. The **lsd-llama-milvus-inline.yaml** file should also be modified with the valid environment values: 
~~~
oc apply -f lsd-llama-milvus-inline.yaml 
~~~

Validate the `lsd-llama-milvus-inline` resources creation process:
~~~
oc get pods
~~~
~~~
NAME                                      READY   STATUS      RESTARTS   AGE
llama3-predictor-8bbb6c578-bqbt5          2/2     Running     0          17m
lsd-llama-milvus-inline-7b67d4f74-grt2z   1/1     Running     0          2m7s
postgresql-1-deploy                       0/1     Completed   0          47h
postgresql-1-pl944                        1/1     Running     1          47h
~~~
~~~
oc get svc
~~~
~~~
NAME                              TYPE        CLUSTER-IP       EXTERNAL-IP   PORT(S)    AGE
llama3-metrics                    ClusterIP   172.30.104.153   <none>        8080/TCP   154m
llama3-predictor                  ClusterIP   None             <none>        80/TCP     18m
lsd-llama-milvus-inline-service   ClusterIP   172.30.148.147   <none>        8321/TCP   2m26s
postgresql                        ClusterIP   172.30.200.94    <none>        5432/TCP   47h
~~~
~~~
oc get routes
~~~
~~~
NAME                              HOST/PORT                                                        PATH   SERVICES                          PORT   TERMINATION     WILDCARD
llama3                            llama3-demo-llm.apps.aba-sno.test.com                                   llama3-predictor                  http   edge/Redirect   None
~~~
~~~
oc get deployments
~~~
~~~
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
llama3-predictor          1/1     1            1           18m
lsd-llama-milvus-inline   1/1     1            1           3m
~~~
~~~ 
oc get secrets
NAME                                     TYPE                DATA   AGE
llama-stack-secret                       Opaque              11     3m16s
llama3                                   Opaque              1      155m
llama3-predictor-serving-cert            kubernetes.io/tls   2      19m
postgresql                               Opaque              3      47h
postgresql-persistent-parameters-vghlr   Opaque              8      47h
~~~

Expose the **lsd-llama-milvus-inline-service** via OCP route:
~~~
oc expose svc lsd-llama-milvus-inline-service
~~~
~~~
oc get route
NAME                              HOST/PORT                                                        PATH   SERVICES                          PORT   TERMINATION     WILDCARD
llama3                            llama3-demo-llm.apps.aba-sno.test.com                                   llama3-predictor                  http   edge/Redirect   None
lsd-llama-milvus-inline-service   lsd-llama-milvus-inline-service-demo-llm.apps.aba-sno.test.com          lsd-llama-milvus-inline-service   http                   None
~~~

Test llamastack API
~~~
curl http://lsd-llama-milvus-inline-service-demo-llm.apps.aba-sno.test.com/v1/models
~~~
~~~
{"data":[{"id":"vllm-embedding/Qwen/Qwen3-Embedding-0.6B","object":"model","created":1773413468,"owned_by":"llama_stack","custom_metadata":{"model_type":"embedding","provider_id":"vllm-embedding","provider_resource_id":"Qwen/Qwen3-Embedding-0.6B","embedding_dimension":768}},{"id":"vllm-inference/llama3","object":"model","created":1773413468,"owned_by":"llama_stack","custom_metadata":{"model_type":"llm","provider_id":"vllm-inference","provider_resource_id":"llama3"}},{"id":"vllm-inference/tinyllama","object":"model","created":1773413468,"owned_by":"llama_stack","custom_metadata":{"model_type":"llm","provider_id":"vllm-inference","provider_resource_id":"tinyllama"}}]}
~~~

After testing the llamastack API successfully, it can be run the `llamastack.test.ipynb` notebook, wich contains a basic usage for llamastack + embedding a document + RAG.
