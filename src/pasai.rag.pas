unit PasAI.Rag;

{ Retrieval-augmented generation: answering from your documents instead of
  from the model's memory.

  The model is given the retrieved chunks as numbered context and told to
  answer only from them, cite them, and admit when they do not contain the
  answer. Two things make this work:
  - Numbered sources let the answer be checked: every claim should point
    at a [n] that actually says it.
  - Permission to say "I don't know" is essential. Without it, a model asked
    about something missing from the context fills the gap from memory or
    invention, which is exactly what RAG is meant to prevent. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, PasAI.Types, PasAI.Chunk, PasAI.Retriever;

const
  RAG_SYSTEM_PROMPT =
    'Answer the question using only the numbered context passages. ' +
    'After each fact, cite the passage it came from, like [1] or [2]. ' +
    'If the passages do not contain the answer, say that you do not know; ' +
    'do not use outside knowledge. ' +
    'Reply in the language of the question.';

{ The retrieved chunks as numbered passages:
    [1] (battery.md: Battery)
    text... }
function FormatContext(const AChunks: TChunks; const AHits: TSearchHits): string;

{ System prompt, then one user message holding the context and the question. }
function BuildRagMessages(const AQuestion: string; const AChunks: TChunks;
  const AHits: TSearchHits; const ASystemPrompt: string = RAG_SYSTEM_PROMPT): TChatMessages;

implementation

function FormatContext(const AChunks: TChunks; const AHits: TSearchHits): string;
var
  I: Integer;
  C: TChunk;
begin
  Result := '';
  for I := 0 to High(AHits) do
  begin
    C := AChunks[AHits[I].ChunkIndex];
    if Result <> '' then
      Result := Result + #10#10;
    Result := Result + Format('[%d] (%s: %s)', [I + 1, C.Source, C.Title]) + #10 + C.Text;
  end;
end;

function BuildRagMessages(const AQuestion: string; const AChunks: TChunks;
  const AHits: TSearchHits; const ASystemPrompt: string): TChatMessages;
begin
  Result := nil;
  AddMessage(Result, ROLE_SYSTEM, ASystemPrompt);
  AddMessage(Result, ROLE_USER,
    'Context:' + #10#10 + FormatContext(AChunks, AHits) + #10#10 +
    'Question: ' + AQuestion);
end;

end.
