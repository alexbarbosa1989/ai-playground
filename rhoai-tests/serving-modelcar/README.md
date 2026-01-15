## Serving a Model in RHOAI using modelcar

### Create a data science project. Navigate **Data science projects** > **Create project**
That action create a new OpenShift namespace. For example if the data-scienc project's name is `dsc-test`, it creates the `dsc-test` namespace

<img width="857" height="264" alt="create-dsc-project" src="https://github.com/user-attachments/assets/1ae79f25-c87f-488b-94dc-5041d105ad7f" />

### Create an OCI connection
- Navigate **Data science projects** > **dsc-test** > **Connections** > **Create connection**
- Fill the connection form with your required values. Current test was made using below values:
  - Connection type: URI - v1
  - URI: oci://quay.io/rh-aiservices-bu/tinyllama:1.0
<img width="749" height="585" alt="create-oci-connection" src="https://github.com/user-attachments/assets/9db2bc3b-6769-448d-8cba-1c8e87b38c46" />

- Finish the OCI connection configuration
<img width="1066" height="308" alt="finish-oci-connection" src="https://github.com/user-attachments/assets/fd4cc500-cc3f-4a1a-ab9e-29f11a8f864c" />
 
### Serving the model
- Navigate **Data science projects** > **dsc-test** > **Models** > **Single-model serving platform** > **Deploy model**

- Fill the `Deploy model` form making sure you're selecting the **vLLM NVIDIA GPU ServingRuntime for KServe** provided by RHOAI and the [previously created Hardware Profile](https://github.com/alexbarbosa1989/ai-playground/blob/main/rhoai-tests/hardware-profile/README.md). The **Make deployed models available through an external route** checkbox should be marked if you want access to the model outside the OpenShift cluster
<img width="834" height="496" alt="deploy-single-model-vllm" src="https://github.com/user-attachments/assets/a66ae30c-1724-40e1-83f5-4d5073e0a83a" />

<img width="841" height="427" alt="set-hw-profile-model-edit" src="https://github.com/user-attachments/assets/e1ff420e-9551-4b5b-8c33-ebfc33baeb71" />

- Finish the model deployment and wait until the model is served and running
<img width="1052" height="486" alt="finish-single-model-deployment" src="https://github.com/user-attachments/assets/03abc95e-cd51-4c44-be40-e9d5aee468f1" />

## Checking the Served Model
- Check the project and deployed pods
~~~
oc project dsc-test
~~~
~~~
oc get pods
~~~
Expected output:
~~~
NAME                                   READY   STATUS    RESTARTS   AGE
tinyllama-predictor-5bb5f8f886-2zh6m   2/2     Running   0          7m3s
~~~

- (Optional) Check the pod's GPU details
~~~
oc rsh tinyllama-predictor-5bb5f8f886-2zh6m
~~~
~~~

sh-5.1$ nvidia-smi
Mon Dec 22 16:53:51 2025       
+-----------------------------------------------------------------------------------------+
| NVIDIA-SMI 580.105.08             Driver Version: 580.105.08     CUDA Version: 13.0     |
+-----------------------------------------+------------------------+----------------------+
| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |
| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |
|                                         |                        |               MIG M. |
|=========================================+========================+======================|
|   0  NVIDIA GeForce RTX 4060 Ti     On  |   00000000:06:00.0 Off |                  N/A |
|  0%   52C    P8             13W /  165W |   14921MiB /  16380MiB |      0%      Default |
|                                         |                        |                  N/A |
+-----------------------------------------+------------------------+----------------------+

+-----------------------------------------------------------------------------------------+
| Processes:                                                                              |
|  GPU   GI   CI              PID   Type   Process name                        GPU Memory |
|        ID   ID                                                               Usage      |
|=========================================================================================|
|    0   N/A  N/A              87      C   VLLM::EngineCore                      14912MiB |
+-----------------------------------------------------------------------------------------+
~~~

### Interact with the served model
- Get the exposed route:
~~~
oc get routes
~~~
~~~
NAME        HOST/PORT                             PATH   SERVICES              PORT   TERMINATION     WILDCARD
tinyllama   tinyllama-dsc-test.apps-crc.testing          tinyllama-predictor   http   edge/Redirect   None
~~~

- Perform a curl request to chat with the model
~~~
curl -v --connect-timeout 5 --max-time 30 \
  --trace-time --trace debug.txt \
  -X POST "https://tinyllama-dsc-test.apps-crc.testing/v1/chat/completions" \
  -H "Content-Type: application/json"  \
  --data '{"model": "tinyllama","messages": [{"role": "user","content": "What is the capital of France?"}]}' \
  --insecure
~~~
Expected output:
~~~
Warning: --trace overrides an earlier trace/verbose option
Note: Unnecessary use of -X or --request, POST is already inferred.
{"id":"chatcmpl-651e941e964942b8b1e53660e7329864","object":"chat.completion","created":1766422534,"model":"tinyllama","choices":[{"index":0,"message":{"role":"assistant","content":"The capital of France is Paris, located in the Ile-de-France region.","refusal":null,"annotations":null,"audio":null,"function_call":null,"tool_calls":[],"reasoning_content":null},"logprobs":null,"finish_reason":"stop","stop_reason":null,"token_ids":null}],"service_tier":null,"system_fingerprint":null,"usage":{"prompt_tokens":23,"total_tokens":42,"completion_tokens":19,"prompt_tokens_details":null},"prompt_logprobs":null,"prompt_token_ids":null,"kv_transfer_params":null}
~~~

- (Optional) check the pods' logs:
~~~
oc logs -f tinyllama-predictor-5bb5f8f886-2zh6m
~~~
~~~
...
(APIServer pid=4) INFO 12-22 16:55:34 [chat_utils.py:470] Detected the chat template content format to be 'string'. You can set `--chat-template-content-format` to override this.
(APIServer pid=4) INFO: 10.217.0.2:59560 - "POST /v1/chat/completions HTTP/1.1" 200 OK
(APIServer pid=4) INFO 12-22 16:55:43 [loggers.py:123] Engine 000: Avg prompt throughput: 2.3 tokens/s, Avg generation throughput: 1.9 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 0.0%
(APIServer pid=4) INFO 12-22 16:55:53 [loggers.py:123] Engine 000: Avg prompt throughput: 0.0 tokens/s, Avg generation throughput: 0.0 tokens/s, Running: 0 reqs, Waiting: 0 reqs, GPU KV cache usage: 0.0%, Prefix cache hit rate: 0.0%
~~~
