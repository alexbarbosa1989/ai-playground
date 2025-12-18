## VLLM Basics

## Local environment setup

### Set python venv
**Important:** it is recommended having a Python `venv`. It can be set using [uv](https://docs.astral.sh/uv/):
~~~
curl -LsSf https://astral.sh/uv/install.sh | sh
uv python install 3.12
uv venv myenv --python 3.12 --seed
source myenv/bin/activate
~~~

### Configure [NVIDIA container toolkit](https://docs.nvidia.com/ai-enterprise/deployment/rhel-with-kvm/latest/podman.html)

~~~
curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
  sudo tee /etc/yum.repos.d/nvidia-container-toolkit.repo
~~~
~~~
sudo dnf install -y nvidia-container-toolkit
~~~
~~~
reboot
~~~
Set CDI https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/cdi-support.html:
~~~
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
~~~
List the available GPUS:
~~~
nvidia-ctk cdi list
~~~

### Configure HuggignFace CLI
~~~
source myenv/bin/activate
pip install -U "huggingface_hub"
~~~
~~~
source myenv/bin/activate
~~~

### Run vllm into a podman container
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
--model Qwen/Qwen3-0.6B --max_model_len=4096
~~~

### Test the model 
Once finish, in another terminal test chat with the model:
~~~
curl -X POST "http://localhost:8000/v1/chat/completions"        -H "Content-Type: application/json"     --data '{
                "model": "Qwen/Qwen3-0.6B",
                "messages": [
                        {
                                "role": "user",
                                "content": "What is the capital of France?"
                        }
                ]
        }'
~~~
Expected output:
~~~
{"id":"chatcmpl-8b29171c942b1065","object":"chat.completion","created":1766068536,"model":"Qwen/Qwen3-0.6B","choices":[{"index":0,"message":{"role":"assistant","content":"<think>\nOkay, the user is asking for the capital of France. I need to confirm the correct answer. France's capital is Paris. Let me make sure there's no other city that's commonly referred to as the capital. I think Paris is the official name, and it's a major city. No, I'm not mistaken. So the answer should be Paris.\n</think>\n\nThe capital of France is **Paris**.","refusal":null,"annotations":null,"audio":null,"function_call":null,"tool_calls":[],"reasoning":null,"reasoning_content":null},"logprobs":null,"finish_reason":"stop","stop_reason":null,"token_ids":null}],"service_tier":null,"system_fingerprint":null,"usage":{"prompt_tokens":15,"total_tokens":102,"completion_tokens":87,"prompt_tokens_details":null},"prompt_logprobs":null,"prompt_token_ids":null,"kv_transfer_params":null}
~~~

## For CPU setup

### Build the custom image: 
~~~
$ source myenv/bin/activate
$ git clone https://github.com/vllm-project/vllm/ 
$ cd ./vllm 
$ pip install "cmake>=3.26" wheel packaging ninja "setuptools-scm>=8" numpy
$ pip install -v -r requirements/cpu.txt --extra-index-url https://download.pytorch.org/whl/cpu
$ podman build --security-opt label=disable -f docker/Dockerfile.cpu -t quay.io/abarbosa/vllm-nvidia:0.11.2 --shm-size=4g .
~~~
Note: quay.io/abarbosa/vllm-nvidia:0.11.2 is already available to pull in public quay.io reposotory:
~~~
podman pull quay.io/abarbosa/vllm-nvidia:0.11.2
~~~

### Run vllm into a podman container
~~~
podman run -ti --rm --pull=newer \
--user 0 --shm-size=0 --name vllm \
--env "HUGGING_FACE_HUB_TOKEN=$HF_TOKEN" \
--env "HF_HUB_OFFLINE=0" \
--replace -v ~/.cache/huggingface:/root/.cache/huggingface \
--stop-signal=SIGKILL \
--security-opt=label=disable --hooks-dir=/etc/containers/oci/hooks.d/ \
-p 8000:8000 \
quay.io/abarbosa/vllm-cpu:0.11.2 \
--model Qwen/Qwen3-0.6B --max_model_len=4096
~~~

### Test the model 
Once finish, in another terminal test chat with the model:
~~~
curl -X POST "http://localhost:8000/v1/chat/completions"        -H "Content-Type: application/json"     --data '{
                "model": "Qwen/Qwen3-0.6B",
                "messages": [
                        {
                                "role": "user",
                                "content": "What is the capital of France?"
                        }
                ]
        }'
~~~

Expected output:
~~~
{"id":"chatcmpl-9710e9fc620cf92a","object":"chat.completion","created":1766073083,"model":"Qwen/Qwen3-0.6B","choices":[{"index":0,"message":{"role":"assistant","content":"<think>\nOkay, the user is asking for the capital of France. I know that France's capital is Paris. But wait, maybe they're confused because sometimes countries have different capitals. Let me double-check. France is in the Western Europe, right? The capital is indeed Paris. I should confirm that there's no other city with the same name. Also, maybe they're thinking of a different country's capital. No, France's capital is definitely Paris. I need to make sure the answer is clear and correct. Let me just write it down.\n</think>\n\nThe capital of France is **Paris**.","refusal":null,"annotations":null,"audio":null,"function_call":null,"tool_calls":[],"reasoning":null,"reasoning_content":null},"logprobs":null,"finish_reason":"stop","stop_reason":null,"token_ids":null}],"service_tier":null,"system_fingerprint":null,"usage":{"prompt_tokens":15,"total_tokens":139,"completion_tokens":124,"prompt_tokens_details":null},"prompt_logprobs":null,"prompt_token_ids":null,"kv_transfer_params":null}
~~~