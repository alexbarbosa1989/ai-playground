# Running the LangGraph Agent

### 1. activate python venv
~~~
source ~/myenv/bin/activate
~~~
Note: if need set from scratch the python venv, refers [VLLM Basics notes](https://github.com/alexbarbosa1989/ai-playground/blob/main/ai-basics/vllm-basics.md#vllm-basics)

### 2. Install app requirements
~~~
pip install requirements.txt
~~~

### 3. Set the PDF document path in a .env file
~~~
echo "DOCUMENT_PATH=<local-dir>/ai-playground/langgraph-basic-agent/example/contract-template.pdf" >> .env
~~~

### 4. In a another terminal, serve the model:
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

### 5. Run the app:
~~~
python app.py
~~~
Expected output:
~~~
Loading & Chunking PDF...
Checking for 'termination clause'...
Final Response: Document Approved.
Reasoning: <think>
okay, let me look at the user's question. they want to know if the provided document contains a termination clause. the user also wants the answer to be "yes" or "no" and explain.

looking at the context given, there are three sections: termination, liability, and governing law. each of these sections starts with "3." so, the document does have a termination clause. 

section 3 is specifically about termination, which states that either party can terminate with 30 days of written notice. also, upon termination, all outstanding balances must be paid. that's the main point. the other sections talk about payment terms, confidentiality, and governing law, which are separate. 

so, the answer should be yes, and explain that section 3 includes the termination clause. i need to make sure i didn't miss any other parts. the user might be checking if the document includes all necessary terms for termination, and they might be preparing a contract or something similar. the key here is to identify the exact section where the termination is outlined.
</think>

**answer:** yes.  

the document contains a termination clause, as specified in section 3 ("3. termination"), which outlines that either party may terminate the agreement with 30 days of written notice. additionally, upon termination, all outstanding balances must be paid. this satisfies the requirement for a termination clause as requested.
+-----------+  
| __start__ |  
+-----------+  
      *        
      *        
      *        
  +--------+   
  | upload |   
  +--------+   
      *        
      *        
      *        
  +-------+    
  | check |    
  +-------+    
      *        
      *        
      *        
 +---------+   
 | respond |   
 +---------+   
      *        
      *        
      *        
 +---------+   
 | __end__ |   
 +---------+ 
~~~
