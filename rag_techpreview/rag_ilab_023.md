# Basic RAG test for Instructlab 0.23.1

Retrieval-Augmented Generation (RAG) was introduced in [Instructlab 0.23.0](https://github.com/instructlab/instructlab/releases/tag/v0.23.0) as an experimental/preview implementation 

The current test was made using Instructlab version 0.23.1

Test scenario description:

Testing RAG using a PDF document from the Red Hat portal. In this case, was used the [Getting Started Document for Openshift AI Self-Managed](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.16/pdf/getting_started_with_red_hat_openshift_ai_self-managed/Red_Hat_OpenShift_AI_Self-Managed-2.16-Getting_started_with_Red_Hat_OpenShift_AI_Self-Managed-en-US.pdf). Then, it was converted to JSON format to make it able to be ingested in a vector store and use the `--rag` pipeline when chatting with the model. All these steps are detailed in the [Instruct lab README RAG section](https://github.com/instructlab/instructlab?tab=readme-ov-file#-configure-retrieval-augmented-generation-developer-preview).

Once embedded the document info in a vector store, the model is with and without the `--rag` option and with prompts with different detail levels, in order to analyze the generated output in each chat interaction.


## Procedure:

- Download a PDF document from Red Hat portal. For this example was used [Getting Started Document for Openshift AI Self-Managed](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/2.16/pdf/getting_started_with_red_hat_openshift_ai_self-managed/Red_Hat_OpenShift_AI_Self-Managed-2.16-Getting_started_with_Red_Hat_OpenShift_AI_Self-Managed-en-US.pdf)

- Open a terminal and set the `ILAB_FEATURE_SCOPE` to enable the `--rag` pipeline
~~~
export ILAB_FEATURE_SCOPE=DevPreviewNoUpgrade
~~~
NOTE: If not set, it will generate the below error message when trying to chat with the model using `--rag` pipeline:
~~~
ERROR 2025-02-04 10:12:12,040 instructlab.model.chat:591: This functionality is experimental; set ILAB_FEATURE_SCOPE to "DevPreviewNoUpgrade" to enable.
~~~

- Download the `ibm-granite/granite-embedding-125m-english` model from HuggingFace. This is the default embedding model for Instructlab RAG and makes possible to ingest documents into a vector index and retrieve the stored data in the chat process:
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

- Ingest the data from the previously generated converted file into a vector store. The ingest process needs as input the entire dir path:
~~~
ilab rag ingest --input-dir ~/rag_tests/rag_docs_out/
~~~
It will create the `embeddings.db` file in `~/.local/share/instructlab/`:
~~~
ll ~/.local/share/instructlab/embeddings.db 
-rw-r--r--. 1 abarbosa abarbosa 1472527 Feb  4 10:10 /home/abarbosa/.local/share/instructlab/embeddings.db
~~~
It is possible to explore more options using the command `ilab rag ingest --help`

- In another terminal, serve the model:
~~~
ilab model serve --model-path ~/.cache/instructlab/models/granite-7b-lab-Q4_K_M.gguf
~~~

- Back to the previous working terminal, start a chat with the model:
~~~
ilab model chat
~~~

- Search for a topic that want to validate into the Openshift AI getting started document. In the current test case, it was used the "CHAPTER 3. CREATING A DATA SCIENCE PROJECT" - Procedure section.
![document_ref](https://github.com/user-attachments/assets/fecc5a7d-8037-4f9e-8620-01803a23f751)

- Write a basic prompt asking for a topic that can be validated into the Openshift AI document previously embedded.
~~~
give me the steps to configure a Workbench in Openshift AI  
~~~

Now, use the previous prompt to test chatting with the model with no `--rag` option and using it.

- Chat with the model:
  - With no `--rag` option:
    ![basic_promt_norag](https://github.com/user-attachments/assets/d5ac1626-799e-490e-a42c-e91b6f294cda)

  - With `--rag` option:
    ![basic_promt_rag](https://github.com/user-attachments/assets/09ed0bee-c0d8-42d3-a9c7-1b3ba48f2390)


In both cases, the model output is not accurate. That could indicate that the prompt used is too short and does not give enough context

- Testing with a more descriptive prompt:
~~~
I know that in order to implement a data science workflow, i must create a project. Please, provide me the steps to create a Data Science Project in Openshift AI
~~~

- Chat with the model:
  - With no `--rag` option:
    ![detailed_promt_norag_1](https://github.com/user-attachments/assets/663b8aab-d2c4-4482-96b0-eb6e27568c74)
    ![detailed_promt_norag_2](https://github.com/user-attachments/assets/688855cd-0b73-4b06-9c15-6741b8d7d10c)


  - With `--rag` option:
    ![detailed_promt_rag](https://github.com/user-attachments/assets/dc278e89-8b44-442a-9eee-a58dcaf35e05)

This test shows that with the more detailed prompt, the chat output with no `--rag` option is completely inaccurate, while the chat with the `--rag` option provides a more accurate answer, not exactly as is described in the document, but close to an expected answer. 
It is important to mention that in the performed tests the used model always was the base **granite-7b-lab-Q4_K_M.gguf** without any fine-tuning training process.
