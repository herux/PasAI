program RagDemo;   // Delphi requires this name to match the file name

{ Example 7: retrieval-augmented generation over a small document set.

  The documents in examples/07_rag/docs describe a fictional drone, mixing
  Indonesian and English, so the model cannot know the answers from its
  training data. The program:

  1. chunks the documents and indexes them for keyword (BM25) and vector
     search;
  2. asks one question WITHOUT retrieval, to show the model guessing;
  3. asks several questions WITH retrieval, printing which chunks were
     found by which method, then the answer with citations.

  The questions are picked to show each method's strength: an exact error
  code (keyword), a question in another language than its document
  (vector), a paraphrase ("lake" vs "water"), and a question the documents
  cannot answer.

  Needs an embedding model:  ollama pull bge-m3
  Run:  ./bin/ragdemo [-e embed-model] [-m mode] [chat-model]
        mode is keyword, vector (default) or hybrid. Vector is the default
        because it scored best on these documents in ./bin/rageval. }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  Classes, SysUtils,
  PasAI.Types, PasAI.Ollama, PasAI.Embed, PasAI.Chunk, PasAI.BM25,
  PasAI.Retriever, PasAI.Rag;

const
  DOCS_DIR = 'examples/07_rag/docs/';
  CHUNK_SIZE = 400;
  TOP_K = 3;
  DEFAULT_CHAT_MODEL = 'qwen2.5:7b-instruct';
  DEFAULT_EMBED_MODEL = 'bge-m3';

  MODE_NAMES: array[TSearchMode] of string = ('keyword', 'vector', 'hybrid');

  QUESTIONS: array[0..4] of string = (
    'Berapa lama PasDrone P1 bisa terbang dengan baterai Plus?',
    'How long does it take to charge the standard battery?',
    'My drone shows E07. What should I do?',
    'Apakah garansi menanggung drone yang jatuh ke danau?',
    'Berapa harga PasDrone P1?'
  );

procedure PrintChunk(const AText: string);
begin
  Write(AText);
  Flush(Output);
end;

function LoadCorpus: TChunks;
begin
  Result := ChunkFolder(DOCS_DIR, '*.md', CHUNK_SIZE);
end;

function RankText(ARank: Integer): string;
begin
  if ARank = 0 then
    Result := '-'
  else
    Result := IntToStr(ARank);
end;

function Preview(const AText: string): string;
begin
  Result := StringReplace(AText, #10, ' ', [rfReplaceAll]);
  if Length(Result) > 60 then
    Result := Copy(Result, 1, 57) + '...';
end;

procedure ShowHits(ARetriever: THybridRetriever; const AHits: TSearchHits);
var
  I: Integer;
  C: TChunk;
begin
  Writeln('  retrieved          keyword  vector');
  for I := 0 to High(AHits) do
  begin
    C := ARetriever.Chunks[AHits[I].ChunkIndex];
    Writeln(Format('  [%d] %-16s %-8s %-7s %s', [I + 1,
      C.Source + '#' + IntToStr(C.Index),
      RankText(AHits[I].KeywordRank), RankText(AHits[I].VectorRank),
      Preview(C.Text)]));
  end;
end;

var
  Chat: TOllamaClient;
  Embedder: TOllamaEmbedder;
  Retriever: THybridRetriever;
  Chunks: TChunks;
  Hits: TSearchHits;
  Msgs: TChatMessages;
  ChatModel, EmbedModel: string;
  Mode, M: TSearchMode;
  ModeFound: Boolean;
  Start: UInt64;
  I: Integer;
begin
  InitConsole;
  ChatModel := DEFAULT_CHAT_MODEL;
  EmbedModel := DEFAULT_EMBED_MODEL;
  Mode := smVector;
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '-e') and (I < ParamCount) then
    begin
      Inc(I);
      EmbedModel := ParamStr(I);
    end
    else if (ParamStr(I) = '-m') and (I < ParamCount) then
    begin
      Inc(I);
      ModeFound := False;
      for M := Low(TSearchMode) to High(TSearchMode) do
        if ParamStr(I) = MODE_NAMES[M] then
        begin
          Mode := M;
          ModeFound := True;
        end;
      if not ModeFound then
      begin
        Writeln('Unknown mode "', ParamStr(I), '"; use keyword, vector or hybrid');
        Halt(1);
      end;
    end
    else
      ChatModel := ParamStr(I);
    Inc(I);
  end;

  Chat := TOllamaClient.Create(ChatModel);
  Embedder := TOllamaEmbedder.Create(EmbedModel);
  Retriever := THybridRetriever.Create(Embedder);
  try
    try
      Chat.Temperature := 0;

      { Stop words improved hybrid retrieval in ./bin/rageval and never hurt;
        they must be set before the chunks are added. }
      Retriever.KeywordIndex.AddStopWords(STOP_WORDS_EN + ' ' + STOP_WORDS_ID);

      Chunks := LoadCorpus;
      Writeln(Format('Loaded %d chunks from %s', [Length(Chunks), DOCS_DIR]));
      Start := TickMs;
      Retriever.AddChunks(Chunks);
      Writeln(Format('Indexed with %s: %d dimensions, %.1f s',
        [EmbedModel, Retriever.Dimensions, (TickMs - Start) / 1000]));
      Writeln;

      Writeln('=== Without retrieval ===');
      Writeln('> ', QUESTIONS[0]);
      Write('  answer: ');
      Msgs := nil;
      AddMessage(Msgs, ROLE_USER, QUESTIONS[0]);
      Chat.ChatStream(Msgs, PrintChunk);
      Writeln;
      Writeln;

      Writeln('=== With retrieval (', MODE_NAMES[Mode], ', top ', TOP_K, ') ===');
      for I := 0 to High(QUESTIONS) do
      begin
        Writeln('> ', QUESTIONS[I]);
        Hits := Retriever.Search(QUESTIONS[I], TOP_K, Mode);
        ShowHits(Retriever, Hits);
        Write('  answer: ');
        Chat.ChatStream(BuildRagMessages(QUESTIONS[I], Retriever.Chunks, Hits), PrintChunk);
        Writeln;
        Writeln;
      end;
    except
      on E: Exception do
      begin
        Writeln;
        Writeln('Error: ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Retriever.Free;
    Embedder.Free;
    Chat.Free;
  end;
end.
