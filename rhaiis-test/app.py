from langgraph.graph import StateGraph
from langchain_community.vectorstores import Chroma
from langchain_huggingface import HuggingFaceEmbeddings
from langchain_openai import ChatOpenAI
from langchain.chains.combine_documents import create_stuff_documents_chain
from langchain.chains.retrieval import create_retrieval_chain
from langchain_core.prompts import PromptTemplate
from langchain_core.runnables import RunnableLambda
from langchain_community.document_loaders import PyPDFLoader
from langchain.text_splitter import RecursiveCharacterTextSplitter
from dotenv import load_dotenv
from typing_extensions import TypedDict
from typing import Annotated, Literal
from langgraph.graph.message import add_messages

import os

load_dotenv() 

# define the state for the graph TypedDict
# this is used to define the state of the graph
class State(TypedDict):
    messages: Annotated[list, add_messages]
    retriever: any
    compliant: bool
    compliance_explanation: str

# define the node class
# this class is used to define the nodes in the graph
class MyNode:
    def __init__(self, name: str):
        self.name = name

    def __call__(self, state: State):
        return {"messages": [("assistant", f"Called node {self.name}")]}

# routine function to determine the next node based on the state
# this function is called after each node to determine the next node
def route(state) -> Literal["entry_node", "__end__"]:
    if len(state["messages"]) > 10:
        return "__end__"
    return "entry_node"

# get the document path from environment variable
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

    # Create embeddings
    embeddings = HuggingFaceEmbeddings(model_name="sentence-transformers/all-mpnet-base-v2")

    vectorstore = Chroma.from_documents(chunks, embedding=embeddings)
    retriever = vectorstore.as_retriever()

    state["retriever"] = retriever
    return {
        "messages": state.get("messages", []),
        "retriever": retriever
    }

def check_compliance_with_retrieval(state):
    print("Checking for 'termination clause'...")

    # Define a prompt
    prompt = PromptTemplate.from_template(
        "Use the following context to answer the question:\n\n{context}\n\nQuestion: {input}"
    )

    # define the LLM inference model
    llm = ChatOpenAI(
        base_url="http://localhost:8000/v1",
        model="RedHatAI/Qwen3-0.6B-FP8-dynamic",
        api_key="local-test-key",
    )


    # Create the document chain
    doc_chain = create_stuff_documents_chain(
            llm=llm,
            prompt=prompt,
    )

    # Create the retrieval chain
    chain = create_retrieval_chain(
        retriever=state["retriever"],
        combine_docs_chain=doc_chain,
    )

    # Ask the question
    query = "Does the document contain a termination clause? Answer yes or no, and explain."
    result = chain.invoke({"input": query})

    # Evaluate the result
    answer = result["answer"].lower()
    compliant = "yes" in answer

    # Update state
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

# build the state graph
graph = StateGraph(State)

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
 
# print the graph in ASCII format (OPTIONAL)
print(workflow.get_graph().draw_ascii())