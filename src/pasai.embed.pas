unit PasAI.Embed;

{ Embeddings: turning text into vectors of numbers so that texts with
  similar meaning end up close together.

  An embedding model maps a text to a fixed-length vector (1024 numbers for
  bge-m3). Similarity is then just geometry: the cosine of the angle between
  two vectors, 1 for the same direction, around 0 for unrelated texts. This
  works across wording and even across languages: "lama terbang" and
  "flight time" land near each other, although they share no characters.

  TEmbedder is the provider-independent base class, mirroring TLLMProvider. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types;

type
  { Single precision halves memory compared to Double, and embeddings do
    not need more. }
  TVector = array of Single;
  TVectors = array of TVector;

  TEmbedder = class
  private
    FModel: string;
  public
    constructor Create(const AModel: string);
    function Name: string; virtual; abstract;
    { One vector per input text, in the same order. }
    function Embed(const ATexts: array of string): TVectors; virtual; abstract;
    function EmbedOne(const AText: string): TVector;
    property Model: string read FModel write FModel;
  end;

  { Wraps another embedder and remembers every vector it has produced, keyed
    by the exact text. Re-indexing the same documents (for example when
    comparing configurations) or repeating a query then costs nothing.
    The inner embedder is not owned. }
  TCachedEmbedder = class(TEmbedder)
  private
    FInner: TEmbedder;
    FKeys: TStringList;      // sorted texts; Objects holds the index into FVectors
    FVectors: TVectors;
    FHits: Integer;
    FMisses: Integer;
  public
    constructor Create(AInner: TEmbedder);
    destructor Destroy; override;
    function Name: string; override;
    function Embed(const ATexts: array of string): TVectors; override;
    property Hits: Integer read FHits;
    property Misses: Integer read FMisses;
  end;

{ Scale V to length 1. After this, the dot product of two vectors equals
  their cosine similarity, which makes search a simple sum of products. }
procedure Normalize(var V: TVector);
function Dot(const A, B: TVector): Double;
function CosineSimilarity(const A, B: TVector): Double;

implementation

constructor TEmbedder.Create(const AModel: string);
begin
  inherited Create;
  FModel := AModel;
end;

function TEmbedder.EmbedOne(const AText: string): TVector;
var
  R: TVectors;
begin
  R := Embed([AText]);
  if Length(R) <> 1 then
    raise EPasAIError.Create('Embedder returned no vector');
  Result := R[0];
end;

{ TCachedEmbedder }

constructor TCachedEmbedder.Create(AInner: TEmbedder);
begin
  inherited Create(AInner.Model);
  FInner := AInner;
  FKeys := TStringList.Create;
  FKeys.CaseSensitive := True;
  FKeys.Duplicates := dupIgnore;
  FKeys.Sorted := True;
end;

destructor TCachedEmbedder.Destroy;
begin
  FKeys.Free;
  inherited Destroy;
end;

function TCachedEmbedder.Name: string;
begin
  Result := FInner.Name + '+cache';
end;

function TCachedEmbedder.Embed(const ATexts: array of string): TVectors;
var
  Missing: array of string;
  NewVectors: TVectors;
  I, K, N: Integer;
begin
  { First collect the texts not seen before, and embed them in one call. }
  Missing := nil;
  for I := 0 to High(ATexts) do
    if FKeys.IndexOf(ATexts[I]) < 0 then
    begin
      N := Length(Missing);
      SetLength(Missing, N + 1);
      Missing[N] := ATexts[I];
    end;

  if Length(Missing) > 0 then
  begin
    NewVectors := FInner.Embed(Missing);
    for I := 0 to High(Missing) do
      if FKeys.IndexOf(Missing[I]) < 0 then   // the same text may repeat
      begin
        N := Length(FVectors);
        SetLength(FVectors, N + 1);
        FVectors[N] := NewVectors[I];
        K := FKeys.Add(Missing[I]);
        FKeys.Objects[K] := TObject(PtrInt(N));
      end;
  end;
  Inc(FMisses, Length(Missing));
  Inc(FHits, Length(ATexts) - Length(Missing));

  SetLength(Result, Length(ATexts));
  for I := 0 to High(ATexts) do
    Result[I] := FVectors[PtrInt(FKeys.Objects[FKeys.IndexOf(ATexts[I])])];
end;

function Dot(const A, B: TVector): Double;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    raise EPasAIError.CreateFmt('Vector sizes differ: %d and %d', [Length(A), Length(B)]);
  Result := 0;
  for I := 0 to High(A) do
    Result := Result + A[I] * B[I];
end;

procedure Normalize(var V: TVector);
var
  Len: Double;
  I: Integer;
begin
  Len := Sqrt(Dot(V, V));
  if Len = 0 then
    Exit;
  for I := 0 to High(V) do
    V[I] := V[I] / Len;
end;

function CosineSimilarity(const A, B: TVector): Double;
var
  LenA, LenB: Double;
begin
  LenA := Sqrt(Dot(A, A));
  LenB := Sqrt(Dot(B, B));
  if (LenA = 0) or (LenB = 0) then
    Exit(0);
  Result := Dot(A, B) / (LenA * LenB);
end;

end.
