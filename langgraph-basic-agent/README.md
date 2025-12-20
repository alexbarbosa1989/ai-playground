# Running the LangGraph Agent

### 1. activate python venv
~~~
source ~/myenv/bin/activate
~~~

### 2. Install app requirements
~~~
pip install requirements.txt
~~~

### 3. Set local .env file
echo "DOCUMENT_PATH=<local-dir>/ai-playground/langgraph-basic-agent/example/contract-template.pdf" >> .env

### 4. Set is_vllm in the app.py. Set to True for vllm, False for OpenAI:
~~~
is_vllm = True
~~~