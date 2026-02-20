## Some AI tests

## Local VLLM/RHAIIS

### [VLLM Basics](https://github.com/alexbarbosa1989/ai-playground/blob/main/ai-basics/vllm-basics.md#vllm-basics)
 - Set local environment
 - Local VLLM usage (GPU and CPU)
 - Basic model chat template interactions via cURL

### [LangChain agent local usage](https://github.com/alexbarbosa1989/ai-playground/blob/main/langgraph-basic-agent/README.md)
- Running a basic agent on the local machine

### [RAIIS agent local usage](https://github.com/alexbarbosa1989/rhaiis-langchain)
- Running a basic agent on the local machine serving the model with RHAIIS

## RHOAI tests

### [Enable GPU in the Openshift cluster and Hardware Profiles](https://github.com/alexbarbosa1989/ai-playground/tree/main/rhoai-tests/hardware-profile)
- Enable GPU in the OpenShift Cluster
- Enable Hardware profile
- Create a Hardware profile

### [Configure S3 storage in the Openshift cluster](https://github.com/alexbarbosa1989/ai-playground/tree/main/rhoai-tests/storage)
- Procedure for [Minio deployment](https://github.com/alexbarbosa1989/ai-playground/tree/main/rhoai-tests/storage/minio) 
- Procedure for [S4 deployment](https://github.com/alexbarbosa1989/ai-playground/tree/main/rhoai-tests/storage/s4)

### [Serving a Model in RHOAI using modelcar](https://github.com/alexbarbosa1989/ai-playground/blob/main/rhoai-tests/serving-modelcar/README.md)
- Create an OCI connection referencing the model repository
- Serve the model via Single model deployment
- Test the served model

### [Serving models with custom vllm-cpu runtime in OpenShift AI](https://github.com/alexbarbosa1989/ai-playground/tree/main/rhoai-tests/rhoai2-cpu-tests)
- Create a custom vLLM custom runtime
- Serving a model using the custom runtime and testing it



