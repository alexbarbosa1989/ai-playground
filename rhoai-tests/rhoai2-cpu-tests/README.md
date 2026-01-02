Verified in KBase article https://access.redhat.com/solutions/7134585

## RHOAI Configuration

1. Create the custom runtime: 
- In the RHOAI Dashboard, navigate in the left panel to Settings > Runtimes. Then, 
- Click "Add serving runtime" button. 
- In the editor, copy the contents from the `llm-cpu-custom-runtime.yaml` file in https://github.com/alexbarbosa1989/ai-playground/blob/main/rhoai2-cpu-tests/vllm-cpu-custom-runtime.yaml. It references the `quay.io/abarbosa/vllm-cpu:0.11.2` image built for these test purposes.
- Click the "Create" button.

2. Create a DS project and deploy the model.
- Create the DS project
- Create the connection with the URI oci://quay.io/rh-aiservices-bu/tinyllama:1.0
- Serve the model select "vLLM custom CPU ServingRuntime for KServe" as `Serving Runtime` and `Accelerator=None`.
**The serving process will take some minutes while pulling the images.**

3. Test the served model:
~~~
curl -X POST "<external-inference-endpoint-url>/v1/chat/completions"        -H "Content-Type: application/json"     --data '{
                "model": "tinyllama",
                "messages": [
                        {
                                "role": "user",
                                "content": "What is the capital of France?"
                        }
                ]
        }'  --insecure
~~~
Expected output:
~~~
{"id":"chatcmpl-97f3dc8a37345948","object":"chat.completion","created":1764685941,"model":"tinyllama","choices":[{"index":0,"message":{"role":"assistant","content":"The capital of France is Paris.","refusal":null,"annotations":null,"audio":null,"function_call":null,"tool_calls":[],"reasoning":null,"reasoning_content":null},"logprobs":null,"finish_reason":"stop","stop_reason":null,"token_ids":null}],"service_tier":null,"system_fingerprint":null,"usage":{"prompt_tokens":23,"total_tokens":31,"completion_tokens":8,"prompt_tokens_details":null},"prompt_logprobs":null,"prompt_token_ids":null,"kv_transfer_params":null}
~~~
