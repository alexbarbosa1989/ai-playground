# rag-instructlab-langflow
Basic RAG test using Langflow and Instructlab

## Requirements

This test makes a basic RAG implementation using:
- [Langflow 1.1.0](https://github.com/langflow-ai/langflow) as IDE/App builder.
- [Instructlab 0.21.0 + granite-7b-lab-Q4_K_M.gguf](https://github.com/instructlab/instructlab) as LLM agent.
- [ChromaDB 1.9.4](https://github.com/chroma-core/chroma) for Vector data storage.
- [Ollama 0.4.4 + mxbai-embed-large](https://ollama.com/blog/embedding-models) model for Vector embedding process in the Chroma Database
- Python 3.11

For this test, it is required to have running the Langflow and the Instructlab instances. For installation process I strongly recommend following each project setup process described in their respective GitHub project repository:
- Langflow installation: https://github.com/langflow-ai/langflow?tab=readme-ov-file#-quickstart
- Instructlab: https://github.com/instructlab/instructlab#-getting-started
- Ollama Embedding Models: https://ollama.com/blog/embedding-models
- Chroma doesn't require any installation process. The files are automatically created in the path that is set in the Langflow schema.

## Starting the environment:

### Langflow 
- Open a terminal session and activate the python environment for Langflow:
~~~
$ source venv-langflow/bin/activat
~~~
- Start the Langflow instance:
~~~
$ langflow run
~~~
This action will show the URL access point for the running instance:
~~~
 Access http://127.0.0.1:7860           
~~~

### Instructlab
- In a different terminal session activate the python environment for Instructlab:
~~~
$ source venv/bin/activate
~~~
- [Download the model](https://github.com/instructlab/instructlab?tab=readme-ov-file#-download-the-model) (If haven't already downloaded the Granite model):
~~~
ilab model download --repository instructlab/granite-7b-lab-GGUF --filename granite-7b-lab-Q4_K_M.gguf --hf-token <your-huggingface-token>
~~~
- Serve the model:
~~~
$ ilab model serve
~~~
This action will also show the URL access point for the running instance:
~~~
... instructlab.model.backends.llama_cpp:233: After application startup complete see http://127.0.0.1:8000/docs for API.
~~~

### Ollama Embedding
- [Download Ollama](https://ollama.com/download):
~~~
$ curl -fsSL https://ollama.com/install.sh | sh
~~~
- Download the embedding model:
~~~
$ ollama pull mxbai-embed-large
~~~

## Test the Granite Model without any training

- Having the granite-lab model served in Instructlab, in a separate terminal session start a chat session:
~~~
$ source venv/bin/activate
~~~
~~~
$ ilab model chat
~~~
- Then ask for recent information on a particular topic. Current test is asking for Bucaramanga city information:
~~~
>>> who is the current mayor of Bucaramanga?
~~~
- Since I'm asking directly to the served model without any previous training, it will provide inaccurate information (a hallucination):
~~~
╭───────────────────────────────────────────────────────────────────── granite-7b-lab-Q4_K_M.gguf ─────────────────────────────────────────────────────────────────────╮
│ The current mayor of Bucaramanga is Gabriel Gomez. He was inaugurated on June 21, 2016, and is serving his second term as the head of the city's government. As the  │
│ mayor, Gomez leads the Municipal Administration of Bucaramanga (AMBU), which is responsible for managing the city's affairs and ensuring the well-being of its       │
│ residents.                                                                                                                                                           │
│ ...
~~~

Therefore, here is where RAG can be used for this purpose.

## Build RAG in LangFlow

### Import the RAG project in Langflow
Access the LangFlow builder URL `http://127.0.0.1:7860` in a browser and import the `BasicRAG-URL.json` file which contains the built flow for the RAG test. 
There are two main flows:
1. For Vector Database population:
   ![Screenshot From 2024-11-26 11-57-05](https://github.com/user-attachments/assets/a3aae1ec-aca6-4c9f-9a92-d769432f1a75)

2. For Model interaction:
   ![Screenshot From 2024-11-26 11-59-26](https://github.com/user-attachments/assets/783bbe31-f16e-42eb-950d-dd1e8ef379f1)

### Populate the vector database
This is the first step that should be executed. This is the workflow:
- Define a URL that will be used as base content. In this case I set the [Wikipedia entry](https://en.wikipedia.org/wiki/Bucaramanga) for Bucaramanga City. This initial data source could also be a local document, such as a PDF, text file, etc., if you don't want to use online data.
- Set a Recursive Character Text Splitter to separate the document (web page) data into a set of chunks.
- Also it is required to set an Embedding model to generate the vectors for the input data and store it into the vector database.
- Define the vector store: in this case, set a Chroma DB configuring a local path where the store files will be located. Once run the Chroma DB process, the other components in the flow will be executed, storing the source data in the vector store.

The stored data can be checked in the defined local path:
~~~
(venv) abarbosa@192:~/instructlab$ tree chroma-db
chroma-db
├── b70f467c-c818-464f-a299-f1af9a69cfc5
│   ├── data_level0.bin
│   ├── header.bin
│   ├── length.bin
│   └── link_lists.bin
└── chroma.sqlite3

2 directories, 5 files
~~~

Also can be visualized in the Chroma Component output in Langflow:
![Screenshot From 2024-11-26 14-42-09](https://github.com/user-attachments/assets/3f68420d-3ecc-43dc-9112-a255db201413)


### Interact with the served model in Instruclab
Having populated the vector store, now that data can be used as context for prompts outputs:
- Set a Chat input with the same question earlier test directly with the model chat `Who is the current mayor of Bucaramanga?
- Create a Promt setting a template that will contain two variables `context` and `question`:
~~~
{context} -- Prompt from a person that looks for information about Bucaramanga City.
In their {question} could request details from Bucaramanga City most recent available information
~~~
The question will be connected to the Chat Input and for the Context we need to connect the data that is stored in the Vector Database.
- To connect the Vector store to the Prompt context, we need to Set a parser, that will convert the data from the Chroma DB to plain text. The Chroma DB will be also connected to an embedding, exactly with the same configuration as in the previously executed flow.
- Now we need to set the Intructlab as an Agent, that is running locally in the URL `http://127.0.0.1:8000/v1`. We set the model name (no required to match exactly our actual running model) and We can also set Agent instructions (to set agent behavior), for example:
~~~
You will provide clear and neat answers for the provided promts
~~~
or:
~~~
You are a tourist guide and will answer the questions to promote activities in the city
~~~
- These are the agent configuration details: 
- ![Screenshot From 2024-11-26 14-55-13](https://github.com/user-attachments/assets/ca033bae-d702-48e8-9893-3c3c233a0e59)
- Now we can set a chat output connected to the agent response and check the results:
![Screenshot From 2024-11-26 13-06-49](https://github.com/user-attachments/assets/8be11bc6-48fe-47d8-b99b-6dbbbbcef60f)

Now We're getting more accurate information, based on the updated information from the internet data that We set into the vector store
