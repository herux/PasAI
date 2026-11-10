unit PasAI.Search;

{ Ranked search results, and how to combine rankings from different
  retrievers.

  Keyword search (BM25) and vector search produce scores on completely
  different scales, so their scores cannot simply be added. Reciprocal Rank
  Fusion (RRF) sidesteps this by using only each result's rank:

    score(doc) = sum over rankings of 1 / (RRF_K + rank)

  A document near the top of either list scores well; one near the top of
  both scores best. RRF_K = 60 is the value from the original paper and
  works well in practice.

  A weight per ranking lets one method count more than the other, for
  example when queries are often in a different language than the
  documents and keyword matches are less trustworthy. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  PasAI.Types;

const
  RRF_K = 60;

type
  { One search hit: the position of a document in the indexed collection
    and its score. Higher scores are better. }
  TScoredIndex = record
    Index: Integer;
    Score: Double;
  end;

  TScoredIndices = array of TScoredIndex;

{ Sort by score, highest first. Equal scores keep their original order. }
procedure SortByScore(var AItems: TScoredIndices);

{ The first ACount items (or all, if there are fewer). }
function TakeTop(const AItems: TScoredIndices; ACount: Integer): TScoredIndices;

{ 1-based rank of AIndex in AItems, or 0 if it is not there. }
function RankOf(const AItems: TScoredIndices; AIndex: Integer): Integer;

{ Combine several rankings with Reciprocal Rank Fusion. Each list must
  already be sorted best first. The result is sorted best first. }
function FuseRRF(const ALists: array of TScoredIndices): TScoredIndices; overload;

{ The same, with one weight per list: score = sum of weight / (RRF_K + rank). }
function FuseRRF(const ALists: array of TScoredIndices;
  const AWeights: array of Double): TScoredIndices; overload;

implementation

procedure SortByScore(var AItems: TScoredIndices);
var
  I, J: Integer;
  Item: TScoredIndex;
begin
  { Insertion sort: stable, and fast enough for the hundreds of hits a
    single query produces. }
  for I := 1 to High(AItems) do
  begin
    Item := AItems[I];
    J := I - 1;
    while (J >= 0) and (AItems[J].Score < Item.Score) do
    begin
      AItems[J + 1] := AItems[J];
      Dec(J);
    end;
    AItems[J + 1] := Item;
  end;
end;

function TakeTop(const AItems: TScoredIndices; ACount: Integer): TScoredIndices;
begin
  if ACount < 0 then
    ACount := 0;
  Result := Copy(AItems, 0, ACount);
end;

function RankOf(const AItems: TScoredIndices; AIndex: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AItems) do
    if AItems[I].Index = AIndex then
      Exit(I + 1);
  Result := 0;
end;

function FuseRRF(const ALists: array of TScoredIndices): TScoredIndices;
var
  Weights: array of Double;
  I: Integer;
begin
  SetLength(Weights, Length(ALists));
  for I := 0 to High(Weights) do
    Weights[I] := 1;
  Result := FuseRRF(ALists, Weights);
end;

function FuseRRF(const ALists: array of TScoredIndices;
  const AWeights: array of Double): TScoredIndices;
var
  Scores: array of Double;
  Present: array of Boolean;
  MaxIndex, L, I, N: Integer;
begin
  if Length(AWeights) <> Length(ALists) then
    raise EPasAIError.Create('FuseRRF: one weight per list is required');
  MaxIndex := -1;
  for L := 0 to High(ALists) do
    for I := 0 to High(ALists[L]) do
      if ALists[L][I].Index > MaxIndex then
        MaxIndex := ALists[L][I].Index;

  SetLength(Scores, MaxIndex + 1);
  SetLength(Present, MaxIndex + 1);
  for I := 0 to MaxIndex do
  begin
    Scores[I] := 0;
    Present[I] := False;
  end;

  for L := 0 to High(ALists) do
    for I := 0 to High(ALists[L]) do
    begin
      Scores[ALists[L][I].Index] := Scores[ALists[L][I].Index] +
        AWeights[L] / (RRF_K + I + 1);
      Present[ALists[L][I].Index] := True;
    end;

  Result := nil;
  for I := 0 to MaxIndex do
    if Present[I] then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N].Index := I;
      Result[N].Score := Scores[I];
    end;
  SortByScore(Result);
end;

end.
