# PasAI

An AI engineering library for **Free Pascal** (with **Delphi** support planned), written from scratch.

PasAI has two goals: to understand AI engineering from first principles, without
frameworks hiding how things work, and to give the Pascal ecosystem solid,
dependency-free tools for building AI applications.

Models run locally and for free through [Ollama](https://ollama.com).

## Features

- Chat client for Ollama, blocking and streaming
- Streaming without threads, built on a line-splitting `TStream`
- Provider abstraction (`TLLMProvider`): application code is independent of the backend
- Mock provider for deterministic tests and prompt inspection without a model
- Structured output: JSON schema validation with automatic retry and feedback to the model
- Tool calling and an agent loop: tools are plain Pascal functions; arguments are validated before anything runs
- A record-based JSON schema builder
- An evaluation harness: JSON datasets, deterministic checks, repeated runs per model, pass-rate tables and CSV output
- Retrieval-augmented generation: paragraph chunking, BM25, vector search over Ollama embeddings, hybrid ranking with Reciprocal Rank Fusion, and prompts with numbered citations; retrieval evaluation with hit@k and MRR
- No third-party dependencies: only the Free Pascal RTL and FCL

## Roadmap

1. Ollama client: chat and streaming *(done)*
2. Provider abstraction and structured output *(done)*, embeddings
3. Tool calling and agent loop *(done)*
4. RAG: chunking, BM25, vector store, hybrid retrieval *(done)*
5. Evaluation harness *(done, ahead of step 4)*
6. Conversation memory, state machines, guardrails, human handover
7. PostgreSQL persistence
8. Delphi port

## Requirements

- Free Pascal 3.2.2 (`fpc -iV` prints `3.2.2`)
- [Ollama](https://ollama.com/download), running locally
- At least one chat model:
  ```sh
  ollama pull qwen2.5:7b-instruct   # default model used by the examples
  ```
- For the RAG example, an embedding model:
  ```sh
  ollama pull bge-m3
  ```
  7–8B models (about 5 GB with Ollama's default quantization) run comfortably on
  a machine with 16 GB of RAM. Browse models at https://ollama.com/library

Developed and tested on macOS (Apple Silicon); Linux and Windows should work with
Free Pascal 3.2.2.

## Build and run

```sh
./build.sh
./bin/hello               # blocking chat + streaming
./bin/chat                # interactive chat with history
./bin/chat llama3.1       # use a different model
./bin/providers          # same code running on a mock and on Ollama
./bin/extract            # free text to a Pascal record via JSON schema
./bin/agent              # a model using Pascal tools for math and dates
./bin/runeval -p v1,v2 qwen2.5:7b-instruct llama3.1   # compare models x prompt versions
./bin/rag                # answers from documents, with citations (needs: ollama pull bge-m3)
./bin/rageval            # retrieval quality (hit@k, MRR) for several configurations
```

## Usage

```pascal
uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  PasAI.Types, PasAI.Ollama;   // TOllamaClient descends from TLLMProvider

procedure PrintChunk(const AText: string);
begin
  Write(AText);
end;

var
  Client: TOllamaClient;
  Msgs: TChatMessages;
begin
  Client := TOllamaClient.Create('qwen2.5:7b-instruct');
  try
    // One question, wait for the full answer
    Writeln(Client.Ask('What is a large language model?'));

    // A conversation, streamed as it is generated
    Msgs := nil;
    AddMessage(Msgs, ROLE_SYSTEM, 'You are a concise assistant.');
    AddMessage(Msgs, ROLE_USER, 'Name 3 strengths of Pascal.');
    Client.ChatStream(Msgs, PrintChunk);
  finally
    Client.Free;
  end;
end.
```

## Project layout

```
src/        library units (PasAI.*)
examples/   example programs, one folder per concept
examples/common/   units shared by several examples
lib/ bin/   build output (not tracked)
```
