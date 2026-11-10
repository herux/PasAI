program rageval;   // Delphi requires this name to match the file name

{ Example 7b: measuring retrieval, and choosing a configuration by numbers.

  Every configuration below is indexed from the same documents and run
  against the same cases in examples/07_rag/retrieval_cases.json, in three
  modes: keyword only, vector only, and hybrid. No chat model is needed.

  An embedding cache sits in front of Ollama, so text that was already
  embedded (the same chunk in another configuration, or a repeated query)
  is not sent again.

  Run:  ./bin/rageval [-e embed-model] [-v]
        -v  print the rank of every case, not only the hybrid misses }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  Classes, SysUtils,
  PasAI.Types, PasAI.Ollama, PasAI.Embed, PasAI.Chunk, PasAI.BM25, PasAI.Retriever,
  PasAI.RetrievalEval;

const
  DOCS_DIR = 'examples/07_rag/docs/';
  CASES_FILE = 'examples/07_rag/retrieval_cases.json';
  DEFAULT_EMBED_MODEL = 'bge-m3';
  MAX_K = 5;

type
  TConfig = record
    Name: string;
    ChunkSize: Integer;
    StopWords: Boolean;
    VectorWeight: Double;
  end;

const
  CONFIGS: array[0..4] of TConfig = (
    (Name: 'baseline';        ChunkSize: 400; StopWords: False; VectorWeight: 1.0),
    (Name: 'stopwords';       ChunkSize: 400; StopWords: True;  VectorWeight: 1.0),
    (Name: 'stopwords+vec2';  ChunkSize: 400; StopWords: True;  VectorWeight: 2.0),
    (Name: 'chunk250+stop';   ChunkSize: 250; StopWords: True;  VectorWeight: 1.0),
    (Name: 'chunk600+stop';   ChunkSize: 600; StopWords: True;  VectorWeight: 1.0)
  );

  MODES: array[TSearchMode] of string = ('keyword', 'vector', 'hybrid');

function RankText(ARank: Integer): string;
begin
  if ARank = 0 then
    Result := '-'
  else
    Result := IntToStr(ARank);
end;

function Ratio(AHits, ACases: Integer): string;
begin
  Result := Format('%d/%d', [AHits, ACases]);
end;

var
  Inner: TOllamaEmbedder;
  Cache: TCachedEmbedder;
  Retriever: THybridRetriever;
  Cases: TRetrievalCases;
  Chunks: TChunks;
  Ranks: array[TSearchMode] of TRanks;
  M: TRetrievalMetrics;
  Mode: TSearchMode;
  EmbedModel, Misses: string;
  Verbose: Boolean;
  C, I: Integer;
begin
  InitConsole;
  EmbedModel := DEFAULT_EMBED_MODEL;
  Verbose := False;
  I := 1;
  while I <= ParamCount do
  begin
    if (ParamStr(I) = '-e') and (I < ParamCount) then
    begin
      Inc(I);
      EmbedModel := ParamStr(I);
    end
    else if ParamStr(I) = '-v' then
      Verbose := True;
    Inc(I);
  end;

  Inner := TOllamaEmbedder.Create(EmbedModel);
  Cache := TCachedEmbedder.Create(Inner);
  try
    try
      Cases := LoadRetrievalCases(CASES_FILE);
      Writeln(Format('%d cases, embedding model %s, ranks counted up to %d',
        [Length(Cases), EmbedModel, MAX_K]));
      Writeln;
      Writeln(Format('%-16s %-8s %-7s %-7s %-7s %s',
        ['config', 'mode', 'hit@1', 'hit@3', 'hit@5', 'MRR']));

      for C := 0 to High(CONFIGS) do
      begin
        Chunks := ChunkFolder(DOCS_DIR, '*.md', CONFIGS[C].ChunkSize);
        Retriever := THybridRetriever.Create(Cache);
        try
          if CONFIGS[C].StopWords then
            Retriever.KeywordIndex.AddStopWords(STOP_WORDS_EN + ' ' + STOP_WORDS_ID);
          Retriever.VectorWeight := CONFIGS[C].VectorWeight;
          Retriever.AddChunks(Chunks);

          for Mode := Low(TSearchMode) to High(TSearchMode) do
          begin
            Ranks[Mode] := RankAll(Retriever, Cases, Mode, MAX_K);
            M := ComputeMetrics(Ranks[Mode]);
            Writeln(Format('%-16s %-8s %-7s %-7s %-7s %.2f', [
              CONFIGS[C].Name, MODES[Mode],
              Ratio(M.HitAt1, M.Cases), Ratio(M.HitAt3, M.Cases),
              Ratio(M.HitAt5, M.Cases), M.MRR]));
          end;

          if Verbose then
          begin
            for I := 0 to High(Cases) do
              Writeln(Format('    %-16s keyword %-3s vector %-3s hybrid %s', [Cases[I].Id,
                RankText(Ranks[smKeyword][I]), RankText(Ranks[smVector][I]),
                RankText(Ranks[smHybrid][I])]));
          end
          else
          begin
            { The cases a top-3 hybrid search would get wrong for the model. }
            Misses := '';
            for I := 0 to High(Cases) do
              if (Ranks[smHybrid][I] = 0) or (Ranks[smHybrid][I] > 3) then
              begin
                if Misses <> '' then
                  Misses := Misses + ', ';
                Misses := Misses + Cases[I].Id + ' (' + RankText(Ranks[smHybrid][I]) + ')';
              end;
            if Misses <> '' then
              Writeln('    hybrid misses at 3: ', Misses);
          end;
          Writeln(Format('    %d chunks', [Length(Chunks)]));
        finally
          Retriever.Free;
        end;
      end;

      Writeln;
      Writeln(Format('Embeddings computed: %d, served from cache: %d',
        [Cache.Misses, Cache.Hits]));
    except
      on E: Exception do
      begin
        Writeln('Error: ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Cache.Free;
    Inner.Free;
  end;
end.
