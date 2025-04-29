from langgraph.graph import StateGraph
from langchain_community.vectorstores import Chroma
from langchain_openai import OpenAIEmbeddings
from langchain_openai import ChatOpenAI
from langchain.chains import RetrievalQA
from langchain_core.runnables import RunnableLambda
from langchain_community.document_loaders import PyPDFLoader
from langchain.text_splitter import RecursiveCharacterTextSplitter
from dotenv import load_dotenv
from pathlib import Path

import os

load_dotenv() 

# set up OpenAI API key
api_key = os.getenv("OPENAI_API_KEY")
document_path = os.getenv("DOCUMENT_PATH")

# process document
def upload_and_extract(state):
    print("Loading & Chunking PDF...")

    document_path = os.getenv("DOCUMENT_PATH")
    loader = PyPDFLoader(document_path)
    documents = loader.load()

    # Split into chunks
    splitter = RecursiveCharacterTextSplitter(chunk_size=500, chunk_overlap=50)
    chunks = splitter.split_documents(documents)

    embeddings = OpenAIEmbeddings()

    vectorstore = Chroma.from_documents(chunks, embedding=embeddings)
    retriever = vectorstore.as_retriever()

    state["retriever"] = retriever
    return state

def check_compliance_with_retrieval(state):
    print("Checking for 'termination clause'...")

    qa = RetrievalQA.from_chain_type(
        llm=ChatOpenAI(model="gpt-4.1-mini"),
        retriever=state["retriever"],
        return_source_documents=True
    )

    query = "Does the document contain a termination clause? Answer yes or no, and explain."
    result = qa.invoke({"query": query})

    answer = result["result"].lower()
    compliant = "yes" in answer

    state["compliant"] = compliant
    state["compliance_explanation"] = answer
    return state

def respond(state):
    if state["compliant"]:
        msg = "Document Approved."
    else:
        msg = "Document Rejected. Missing termination clause."
    print(f"Final Response: {msg}")
    print(f"Reasoning: {state['compliance_explanation']}")
    return state

graph = StateGraph(dict)

graph.add_node("upload", RunnableLambda(upload_and_extract))
graph.add_node("check", RunnableLambda(check_compliance_with_retrieval))
graph.add_node("respond", RunnableLambda(respond))

graph.set_entry_point("upload")
graph.add_edge("upload", "check")
graph.add_edge("check", "respond")
graph.set_finish_point("respond")

# execute the workflow
workflow = graph.compile()
workflow.invoke({})