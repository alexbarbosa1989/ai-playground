# Remote LLM
export INFERENCE_MODEL="llama3" # This should match the model name expected by your remote LLM service. Adjust as needed.
export VLLM_URL="https://llama3-demo-llm.apps.aba-sno.test.com/v1" # Replace with your remote LLM service URL. MUST include /v1
export VLLM_TLS_VERIFY="false"   # Use "true" in production
export VLLM_API_TOKEN=""
export VLLM_MAX_TOKENS=1024

# Remote embedding configuration
export EMBEDDING_MODEL="Qwen/Qwen3-Embedding-0.6B" # This should match the model name expected by your embedding service. Adjust as needed.
export EMBEDDING_PROVIDER_MODEL_ID="Qwen/Qwen3-Embedding-0.6B" # This should match the model name expected by your embedding service. Adjust as needed.
export VLLM_EMBEDDING_URL="http://192.168.122.1:8000/v1" # Replace with your remote embedding service URL. MUST include /v1
export VLLM_EMBEDDING_API_TOKEN=""
export VLLM_EMBEDDING_MAX_TOKENS=1024
export VLLM_EMBEDDING_TLS_VERIFY="false"

oc create secret generic llama-stack-secret -n demo-llm \
  --from-literal=INFERENCE_MODEL="$INFERENCE_MODEL" \
  --from-literal=VLLM_URL="$VLLM_URL" \
  --from-literal=VLLM_TLS_VERIFY="$VLLM_TLS_VERIFY" \
  --from-literal=VLLM_API_TOKEN="$VLLM_API_TOKEN" \
  --from-literal=VLLM_MAX_TOKENS="$VLLM_MAX_TOKENS" \
  --from-literal=EMBEDDING_MODEL="$EMBEDDING_MODEL" \
  --from-literal=EMBEDDING_PROVIDER_MODEL_ID="$EMBEDDING_PROVIDER_MODEL_ID" \
  --from-literal=VLLM_EMBEDDING_URL="$VLLM_EMBEDDING_URL" \
  --from-literal=VLLM_EMBEDDING_TLS_VERIFY="$VLLM_EMBEDDING_TLS_VERIFY" \
  --from-literal=VLLM_EMBEDDING_API_TOKEN="$VLLM_EMBEDDING_API_TOKEN" \
  --from-literal=VLLM_EMBEDDING_MAX_TOKENS="$VLLM_EMBEDDING_MAX_TOKENS"
