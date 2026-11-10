unit PasAI.VectorIndex;

{ An in-memory vector index with exact (brute force) search.

  Every query is compared with every stored vector. That sounds naive, but
  for thousands of chunks it takes milliseconds, and it is always exact.
  Approximate structures such as HNSW only pay off at hundreds of
  thousands of vectors, at the cost of complexity and occasional misses. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  SysUtils, PasAI.Types, PasAI.Search, PasAI.Embed;

type
  TVectorIndex = class
  private
    FVectors: TVectors;
    FDimensions: Integer;
    function GetCount: Integer;
  public
    { Stores a normalized copy. All vectors must have the same size. }
    procedure Add(const AVector: TVector);
    { The ATopK stored vectors most similar to AQuery (cosine similarity). }
    function Search(const AQuery: TVector; ATopK: Integer): TScoredIndices;
    property Count: Integer read GetCount;
    property Dimensions: Integer read FDimensions;
  end;

implementation

function TVectorIndex.GetCount: Integer;
begin
  Result := Length(FVectors);
end;

procedure TVectorIndex.Add(const AVector: TVector);
var
  V: TVector;
  N: Integer;
begin
  if Length(AVector) = 0 then
    raise EPasAIError.Create('Cannot index an empty vector');
  if FDimensions = 0 then
    FDimensions := Length(AVector)
  else if Length(AVector) <> FDimensions then
    raise EPasAIError.CreateFmt('Vector has %d dimensions, index has %d',
      [Length(AVector), FDimensions]);

  V := Copy(AVector);
  Normalize(V);
  N := Length(FVectors);
  SetLength(FVectors, N + 1);
  FVectors[N] := V;
end;

function TVectorIndex.Search(const AQuery: TVector; ATopK: Integer): TScoredIndices;
var
  Q: TVector;
  I: Integer;
begin
  Q := Copy(AQuery);
  Normalize(Q);
  SetLength(Result, Length(FVectors));
  for I := 0 to High(FVectors) do
  begin
    Result[I].Index := I;
    Result[I].Score := Dot(Q, FVectors[I]);   // both normalized: dot = cosine
  end;
  SortByScore(Result);
  Result := TakeTop(Result, ATopK);
end;

end.
