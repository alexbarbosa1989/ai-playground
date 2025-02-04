Basic RAG test for Instructlab 0.23.1

Retrieval-Augmented Generation (RAG) was introduced in Instructlab 0.23.0 as an experimental/preview implementation (https://github.com/instructlab/instructlab/releases/tag/v0.23.0)

Current test was made using current latest Instructlab version 0.23.1

Test scenario description:

Testing RAG using a PDF document from Red Hat portal. In this case was used the [Getting Started Document for Openshift AI Self-Managed](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.16/pdf/getting_started_with_red_hat_openshift_ai_self-managed/Red_Hat_OpenShift_AI_Self-Managed-2.16-Getting_started_with_Red_Hat_OpenShift_AI_Self-Managed-en-US.pdf). Then, was convert to json format to make it able to be ingested in a vector database and use the `--rag` pipeline when chat with the model. All these steps are detailed in the [Instruct lab README RAG section](https://github.com/instructlab/instructlab?tab=readme-ov-file#-configure-retrieval-augmented-generation-developer-preview)


Procedure:

- It was download a PDF document from Red Hat portal. For this example was used [Getting Started Document for Openshift AI Self-Managed](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.16/pdf/getting_started_with_red_hat_openshift_ai_self-managed/Red_Hat_OpenShift_AI_Self-Managed-2.16-Getting_started_with_Red_Hat_OpenShift_AI_Self-Managed-en-US.pdf)

- Open a terminal and set the ``ILAB_FEATURE_SCOPE` to enable the `--rag` pipeline
~~~
export ILAB_FEATURE_SCOPE=DevPreviewNoUpgrade
~~~
NOTE: If not set, it will generate below error message when try to chat with the model using `--rag` pipeline:
~~~
ERROR 2025-02-04 10:12:12,040 instructlab.model.chat:591: This functionality is experimental; set ILAB_FEATURE_SCOPE to "DevPreviewNoUpgrade" to enable.
~~~

- Download the `ibm-granite/granite-embedding-125m-english` model from HuggingFace. This is the default embedding model for Instructlab RAG and makes possible to ingest documents into a vector index and retrive the stored data in the chat process:
~~~
ilab model download --repository ibm-granite/granite-embedding-125m-english --hf-token <huggingface-token>
~~~

- Convert the downloaded PDF to a valid index format:
~~~
ilab rag convert --input-dir ~/rag_tests/rag_docs_in/ --output-dir ~/rag_tests/rag_docs_out/
~~~
~~~
...
INFO 2025-02-04 10:05:57,433 docling.document_converter:234: Finished converting document OCP_AI_getting_started.pdf in 16.42 sec.
INFO 2025-02-04 10:05:57,439 instructlab.rag.convert:134: Processed 1 docs, of which 0 failed and 0 were partially converted.
INFO 2025-02-04 10:05:57,440 instructlab.rag.convert:71: Document conversion complete in 16.42 seconds.
~~~
Once finished, it will create a `.json` file in the output directory:
~~~
tree .
.
├── rag_docs_in
│   └── OCP_AI_getting_started.pdf
└── rag_docs_out
    └── OCP_AI_getting_started.json
~~~

- Ingest the data from the previously generated converted file into a vector db. The ingest process needs as input the entire dir path:
~~~
ilab rag ingest --input-dir ~/rag_tests/rag_docs_out/
~~~
It will create the `embeddings.db` file in `~/.local/share/instructlab/`:
~~~
ll ~/.local/share/instructlab/embeddings.db 
-rw-r--r--. 1 abarbosa abarbosa 1472527 Feb  4 10:10 /home/abarbosa/.local/share/instructlab/embeddings.db
~~~
It is possible to explre more options using the command `ilab rag ingest --help`:
