unit PasAI.RetrievalEval;

(* Measuring retrieval on its own, before any answer is generated.

  When a RAG answer is wrong, the first question is whether the right text
  was retrieved at all. If not, no prompt can fix it; if it was, the
  problem is in generation. This unit answers the first question with
  numbers, and needs no chat model: only embeddings, which are
  deterministic, so each case runs once and finishes in seconds.

  Each case lists text snippets the right chunk contains, rather than a
  chunk id such as "baterai.md#1". Chunk ids change whenever the chunk size
  changes; snippets survive, so the same dataset can compare chunk sizes.

    {"cases": [
      {"id": "charge-en",
       "query": "How long does it take to charge the standard battery?",
       "expect": ["70 menit"]}
    ]}

  Metrics, over all cases:
    hit@k  share of cases where a matching chunk is among the top k
    MRR    mean of 1/rank of the first matching chunk (0 when not found);
           1.0 means always first, 0.5 means typically second *)

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Retriever;

type
  TRetrievalCase = record
    Id: string;
    Query: string;
    Expect: array of string;   // a hit is a chunk containing any of these
  end;

  TRetrievalCases = array of TRetrievalCase;

  TRanks = array of Integer;   // per case: 1-based rank of first hit, 0 = none

  TRetrievalMetrics = record
    Cases: Integer;
    HitAt1: Integer;
    HitAt3: Integer;
    HitAt5: Integer;
    MRR: Double;
  end;

function LoadRetrievalCases(const AFileName: string): TRetrievalCases;

{ Rank of the first retrieved chunk (within AMaxK) whose text contains one
  of the expected snippets, compared case-insensitively; 0 if none. }
function FindRank(ARetriever: THybridRetriever; const ACase: TRetrievalCase;
  AMode: TSearchMode; AMaxK: Integer): Integer;

{ FindRank for every case. }
function RankAll(ARetriever: THybridRetriever; const ACases: TRetrievalCases;
  AMode: TSearchMode; AMaxK: Integer): TRanks;

function ComputeMetrics(const ARanks: TRanks): TRetrievalMetrics;

implementation

uses
  fpjson, jsonparser;

function LoadRetrievalCases(const AFileName: string): TRetrievalCases;
var
  FS: TFileStream;
  Root, Cases, Expect, D: TJSONData;
  C: TJSONObject;
  I, J: Integer;
begin
  Result := nil;
  try
    FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      Root := GetJSON(FS);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
      raise EPasAIError.CreateFmt('Cannot read %s: %s', [AFileName, E.Message]);
  end;

  try
    Cases := nil;
    if Root.JSONType = jtObject then
      Cases := TJSONObject(Root).Find('cases');
    if (Cases = nil) or (Cases.JSONType <> jtArray) then
      raise EPasAIError.CreateFmt('%s: expected an object with a "cases" array', [AFileName]);

    SetLength(Result, Cases.Count);
    for I := 0 to Cases.Count - 1 do
    begin
      if Cases.Items[I].JSONType <> jtObject then
        raise EPasAIError.CreateFmt('%s: case #%d is not an object', [AFileName, I + 1]);
      C := TJSONObject(Cases.Items[I]);

      D := C.Find('id');
      if (D = nil) or (D.JSONType <> jtString) then
        raise EPasAIError.CreateFmt('%s: case #%d has no "id"', [AFileName, I + 1]);
      Result[I].Id := D.AsString;

      D := C.Find('query');
      if (D = nil) or (D.JSONType <> jtString) then
        raise EPasAIError.CreateFmt('%s: case "%s" has no "query"', [AFileName, Result[I].Id]);
      Result[I].Query := D.AsString;

      Expect := C.Find('expect');
      if (Expect = nil) or (Expect.JSONType <> jtArray) or (Expect.Count = 0) then
        raise EPasAIError.CreateFmt('%s: case "%s" needs a non-empty "expect" array',
          [AFileName, Result[I].Id]);
      SetLength(Result[I].Expect, Expect.Count);
      for J := 0 to Expect.Count - 1 do
        Result[I].Expect[J] := Expect.Items[J].AsString;
    end;
  finally
    Root.Free;
  end;
end;

function FindRank(ARetriever: THybridRetriever; const ACase: TRetrievalCase;
  AMode: TSearchMode; AMaxK: Integer): Integer;
var
  Hits: TSearchHits;
  Text: string;
  I, J: Integer;
begin
  Hits := ARetriever.Search(ACase.Query, AMaxK, AMode);
  for I := 0 to High(Hits) do
  begin
    Text := LowerCase(ARetriever.Chunks[Hits[I].ChunkIndex].Text);
    for J := 0 to High(ACase.Expect) do
      if Pos(LowerCase(ACase.Expect[J]), Text) > 0 then
        Exit(I + 1);
  end;
  Result := 0;
end;

function RankAll(ARetriever: THybridRetriever; const ACases: TRetrievalCases;
  AMode: TSearchMode; AMaxK: Integer): TRanks;
var
  I: Integer;
begin
  SetLength(Result, Length(ACases));
  for I := 0 to High(ACases) do
    Result[I] := FindRank(ARetriever, ACases[I], AMode, AMaxK);
end;

function ComputeMetrics(const ARanks: TRanks): TRetrievalMetrics;
var
  I: Integer;
  SumReciprocal: Double;
begin
  Result.Cases := Length(ARanks);
  Result.HitAt1 := 0;
  Result.HitAt3 := 0;
  Result.HitAt5 := 0;
  SumReciprocal := 0;
  for I := 0 to High(ARanks) do
    if ARanks[I] > 0 then
    begin
      if ARanks[I] <= 1 then
        Inc(Result.HitAt1);
      if ARanks[I] <= 3 then
        Inc(Result.HitAt3);
      if ARanks[I] <= 5 then
        Inc(Result.HitAt5);
      SumReciprocal := SumReciprocal + 1 / ARanks[I];
    end;
  if Result.Cases > 0 then
    Result.MRR := SumReciprocal / Result.Cases
  else
    Result.MRR := 0;
end;

end.
