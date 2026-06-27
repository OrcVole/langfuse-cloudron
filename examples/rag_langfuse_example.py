#!/usr/bin/env python3
"""
RAG tracing example -> Langfuse.

A minimal Retrieval-Augmented Generation pipeline that exercises a self-hosted
AI stack and traces the whole run to Langfuse, recording the LLM call as a
proper *generation* (prompt / completion / model / token usage):

  - Docling  document parsing                 DOCLING_URL  (X-Api-Key: DOCLING_API_KEY)
  - TEI      text embeddings (OpenAI-compat)   TEI_BASE_URL / TEI_API_KEY / EMBED_MODEL
  - Qdrant   vector store                      QDRANT_URL / QDRANT_API_KEY
  - an OpenAI-compatible LLM                   LLM_BASE_URL / LLM_API_KEY / LLM_MODEL
  - Langfuse tracing (SDK v4)                  LANGFUSE_PUBLIC_KEY / SECRET_KEY / HOST

Every endpoint is read from the environment with placeholder defaults. Provide
real values via your own environment (e.g. a .env file you do NOT commit); never
hardcode hosts or keys. Set RAG_DEBUG=1 for step timing on stderr.

    export LANGFUSE_PUBLIC_KEY=<your-public-key>   LANGFUSE_SECRET_KEY=<your-secret-key>
    export LANGFUSE_HOST=https://langfuse.example.com
    export LLM_BASE_URL=https://llm.example.com/v1   LLM_API_KEY=...   LLM_MODEL=your-model
    export TEI_BASE_URL=https://tei.example.com/v1   TEI_API_KEY=...   EMBED_MODEL=BAAI/bge-small-en-v1.5
    export QDRANT_URL=https://qdrant.example.com:443 QDRANT_API_KEY=...
    export DOCLING_URL=https://docling.example.com   DOCLING_API_KEY=...

    pip install langfuse openai qdrant-client
    python rag_langfuse_example.py
"""
import os, sys, json, base64, uuid, time, urllib.request

LANGFUSE_HOST  = os.environ.get("LANGFUSE_HOST",  "https://langfuse.example.com")
LLM_BASE_URL   = os.environ.get("LLM_BASE_URL",   "https://llm.example.com/v1")
LLM_API_KEY    = os.environ.get("LLM_API_KEY",    "")
LLM_MODEL      = os.environ.get("LLM_MODEL",      "your-model")
TEI_BASE_URL   = os.environ.get("TEI_BASE_URL",   "https://tei.example.com/v1")
TEI_API_KEY    = os.environ.get("TEI_API_KEY",    "")
EMBED_MODEL    = os.environ.get("EMBED_MODEL",    "BAAI/bge-small-en-v1.5")
QDRANT_URL     = os.environ.get("QDRANT_URL",     "https://qdrant.example.com:443")
QDRANT_API_KEY = os.environ.get("QDRANT_API_KEY", "")
DOCLING_URL    = os.environ.get("DOCLING_URL",    "https://docling.example.com")
DOCLING_API_KEY= os.environ.get("DOCLING_API_KEY", "")

_t0=time.time()
def _dbg(m):
    if os.environ.get("RAG_DEBUG"): print(f"[{time.time()-_t0:5.1f}s] {m}", file=sys.stderr, flush=True)

from langfuse import get_client, observe
from langfuse.openai import OpenAI            # drop-in: LLM calls auto-recorded as generations
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct

langfuse = get_client()                       # reads LANGFUSE_PUBLIC_KEY / SECRET_KEY / HOST

SAMPLE_DOC = """# The Aurora Borealis

The aurora borealis, or northern lights, is a natural light display in Earth's sky,
predominantly seen in high-latitude regions around the Arctic.

It is caused by charged particles from the Sun striking atoms in Earth's upper
atmosphere, exciting electrons that then release energy as light. Green, the most
common colour, is produced by oxygen atoms at roughly 100 km altitude; rarer red
auroras come from oxygen higher up, and nitrogen produces blue and purple hues.
"""

def _post(url, payload, headers=None, timeout=60):
    data=json.dumps(payload).encode()
    h={"Content-Type":"application/json"}; h.update(headers or {})
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=h), timeout=timeout) as r:
        return json.loads(r.read().decode())

def docling_parse(markdown_text):
    headers={"X-Api-Key": DOCLING_API_KEY} if DOCLING_API_KEY else {}
    res=_post(DOCLING_URL+"/v1/convert/source", {
        "sources":[{"kind":"file",
                    "base64_string": base64.b64encode(markdown_text.encode()).decode(),
                    "filename":"sample.md"}],
        "options":{"to_formats":["md"]},
    }, headers, timeout=45)
    doc=res.get("document", res)
    return doc.get("md_content") or doc.get("text_content") or markdown_text

def tei_embed(texts):
    res=_post(TEI_BASE_URL+"/embeddings", {"input":texts, "model":EMBED_MODEL},
              {"Authorization":"Bearer "+TEI_API_KEY}, timeout=45)
    return [d["embedding"] for d in res["data"]]

@observe(name="rag-pipeline")
def rag(question):
    # 1. Parse a source document (Docling); degrade to raw text on any failure.
    with langfuse.start_as_current_observation(as_type="span", name="docling-parse") as sp:
        try:
            text=docling_parse(SAMPLE_DOC); parser="docling"
        except Exception as e:
            text=SAMPLE_DOC; parser="fallback-raw"
            sp.update(level="WARNING", status_message=f"docling unavailable: {e}")
        chunks=[c.strip() for c in text.split("\n\n") if c.strip()]
        sp.update(input={"filename":"sample.md","parser":parser}, output={"n_chunks":len(chunks)})
    _dbg(f"docling done ({parser}, {len(chunks)} chunks)")

    # 2. Embed the chunks (TEI)
    with langfuse.start_as_current_observation(as_type="span", name="tei-embed") as sp:
        vecs=tei_embed(chunks); dim=len(vecs[0])
        sp.update(output={"n_vectors":len(vecs), "dim":dim})
    _dbg(f"tei done (dim {dim})")

    # 3. Index + retrieve (Qdrant, throwaway collection)
    coll="rag_example_"+uuid.uuid4().hex[:8]
    qc=QdrantClient(url=QDRANT_URL, api_key=QDRANT_API_KEY, prefer_grpc=False, timeout=30)
    with langfuse.start_as_current_observation(as_type="retriever", name="qdrant-retrieve") as sp:
        qc.create_collection(coll, vectors_config=VectorParams(size=dim, distance=Distance.COSINE))
        qc.upsert(coll, points=[PointStruct(id=i, vector=v, payload={"text":chunks[i]}) for i,v in enumerate(vecs)])
        qvec=tei_embed([question])[0]
        hits=qc.query_points(coll, query=qvec, limit=2).points
        contexts=[h.payload["text"] for h in hits]
        sp.update(input={"question":question}, output={"retrieved_chunks":len(contexts)})
    qc.delete_collection(coll)
    _dbg(f"qdrant done ({len(contexts)} ctx)")

    # 4. Generate the answer (LLM) -> recorded as a GENERATION by the langfuse.openai drop-in
    client=OpenAI(base_url=LLM_BASE_URL, api_key=LLM_API_KEY, timeout=120, max_retries=2)
    prompt=("Answer the question using ONLY the context below.\n\nContext:\n"
            + "\n---\n".join(contexts) + f"\n\nQuestion: {question}")
    resp=client.chat.completions.create(
        model=LLM_MODEL, temperature=0, max_tokens=32,
        messages=[{"role":"user","content":prompt}],
    )
    _dbg("llm done")
    return resp.choices[0].message.content, langfuse.get_current_trace_id()

if __name__=="__main__":
    question="What produces the green colour in the aurora, and at what altitude?"
    _dbg("start")
    answer, trace_id = rag(question)
    print("Q:", question)
    print("A:", answer)
    print("TRACE_ID:", trace_id)
    _dbg("flushing")
    langfuse.flush(); langfuse.shutdown()
    _dbg("done")
