unit PasAI.Retriever;

{ Hybrid retrieval: keyword search and vector search over the same chunks,
  combined with Reciprocal Rank Fusion.

  The two methods fail in opposite ways:
  - BM25 finds exact strings (an error code, a model name) but misses a
    question worded differently from the document, or in another language.
  - Vectors find meaning across wording and languages, but are vague about
    exact codes and numbers.
  Fusing their rankings catches what either one alone would miss. Each hit
  records its rank in both searches, which makes it easy to see which
  method found what. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  SysUtils, PasAI.Types, PasAI.Search, PasAI.Embed, PasAI.Chunk, PasAI.BM25,
  PasAI.VectorIndex;

type
  TSearchMode = (smKeyword, smVector, smHybrid);

  TSearchHit = record
    ChunkIndex: Integer;   // position in Chunks
    Score: Double;         // BM25, cosine or RRF score, depending on the mode
    KeywordRank: Integer;  // 1-based rank in keyword search, 0 if not found
    VectorRank: Integer;   // 1-based rank in vector search, 0 if not found
  end;

  TSearchHits = array of TSearchHit;

  THybridRetriever = class
  private
    FEmbedder: TEmbedder;
    FChunks: TChunks;
    FKeyword: TBM25Index;
    FVector: TVectorIndex;
    FKeywordWeight: Double;
    FVectorWeight: Double;
    function GetDimensions: Integer;
  public
    { AEmbedder is not owned and must outlive the retriever. }
    constructor Create(AEmbedder: TEmbedder);
    destructor Destroy; override;
    { Embed and index the chunks in both indexes. }
    procedure AddChunks(const AChunks: TChunks);
    function Search(const AQuery: string; ATopK: Integer;
      AMode: TSearchMode = smHybrid): TSearchHits;
    property Chunks: TChunks read FChunks;
    property Dimensions: Integer read GetDimensions;
    { The keyword index, e.g. to call AddStopWords before AddChunks. }
    property KeywordIndex: TBM25Index read FKeyword;
    { Weights for hybrid fusion (default 1 each). }
    property KeywordWeight: Double read FKeywordWeight write FKeywordWeight;
    property VectorWeight: Double read FVectorWeight write FVectorWeight;
  end;

implementation

uses
  Math;

constructor THybridRetriever.Create(AEmbedder: TEmbedder);
begin
  inherited Create;
  FEmbedder := AEmbedder;
  FKeyword := TBM25Index.Create;
  FVector := TVectorIndex.Create;
  FKeywordWeight := 1;
  FVectorWeight := 1;
end;

destructor THybridRetriever.Destroy;
begin
  FVector.Free;
  FKeyword.Free;
  inherited Destroy;
end;

function THybridRetriever.GetDimensions: Integer;
begin
  Result := FVector.Dimensions;
end;

procedure THybridRetriever.AddChunks(const AChunks: TChunks);
var
  Texts: array of string;
  Vectors: TVectors;
  I: Integer;
begin
  SetLength(Texts, Length(AChunks));
  for I := 0 to High(AChunks) do
    Texts[I] := SearchableText(AChunks[I]);

  Vectors := FEmbedder.Embed(Texts);
  if Length(Vectors) <> Length(Texts) then
    raise EPasAIError.CreateFmt('Embedder returned %d vectors for %d texts',
      [Length(Vectors), Length(Texts)]);

  for I := 0 to High(AChunks) do
  begin
    FKeyword.Add(Texts[I]);
    FVector.Add(Vectors[I]);
  end;
  AppendChunks(FChunks, AChunks);
end;

function THybridRetriever.Search(const AQuery: string; ATopK: Integer;
  AMode: TSearchMode): TSearchHits;
var
  Pool: Integer;
  Keyword, Vector, Ranked: TScoredIndices;
  I: Integer;
begin
  { Look deeper than ATopK in each list, so fusion has material to work
    with: a chunk ranked 7th by both methods can deserve a top-3 place. }
  Pool := Max(ATopK * 4, 20);
  Keyword := nil;
  Vector := nil;
  if AMode <> smVector then
    Keyword := FKeyword.Search(AQuery, Pool);
  if AMode <> smKeyword then
    Vector := FVector.Search(FEmbedder.EmbedOne(AQuery), Pool);

  case AMode of
    smKeyword: Ranked := Keyword;
    smVector:  Ranked := Vector;
  else
    Ranked := FuseRRF([Keyword, Vector], [FKeywordWeight, FVectorWeight]);
  end;
  Ranked := TakeTop(Ranked, ATopK);

  SetLength(Result, Length(Ranked));
  for I := 0 to High(Ranked) do
  begin
    Result[I].ChunkIndex := Ranked[I].Index;
    Result[I].Score := Ranked[I].Score;
    Result[I].KeywordRank := RankOf(Keyword, Ranked[I].Index);
    Result[I].VectorRank := RankOf(Vector, Ranked[I].Index);
  end;
end;

end.
