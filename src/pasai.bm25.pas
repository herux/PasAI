unit PasAI.BM25;

{ BM25: the classic keyword ranking function, still used by most search
  engines and a strong partner for vector search.

  For each query term found in a document, BM25 adds:

    idf(term) * tf * (k1 + 1) / (tf + k1 * (1 - b + b * docLength / avgLength))

  - tf  : how often the term occurs in the document (more is better, but
          with diminishing returns controlled by k1)
  - idf : how rare the term is across all documents (rare terms such as an
          error code "E07" count far more than common words)
  - b   : how much long documents are penalized for simply having more words

  Where vectors understand meaning, BM25 matches exact strings: product
  codes, error numbers, names. That is why the two are combined.

  Tokenizing is deliberately simple: lowercase ASCII, split on anything
  that is not a letter or digit, keep tokens of two or more characters.
  Characters above 127 count as letters (UTF-8 bytes in Free Pascal, UTF-16
  characters in Delphi), so words with accented or non-Latin characters
  stay whole. No stemming.

  Stop words are optional. Very common words ("the", "yang") carry little
  meaning, and in a corpus that mixes languages they create false matches:
  an English question then matches every English document through "the"
  and "to". BM25's idf already lowers their weight; removing them stops
  them from producing matches at all. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Search;

const
  { Space separated, lowercase. Pass to TBM25Index.AddStopWords. }
  STOP_WORDS_EN =
    'the an and or of to in on at for with from by as is are was were be been ' +
    'it its this that these those do does did how what when where which who ' +
    'why can could should would will my me you your we our they their if ' +
    'not no there here about into than then so';
  STOP_WORDS_ID =
    'yang dan di ke dari untuk dengan pada dalam apa apakah bagaimana berapa ' +
    'ini itu atau ada bisa saya kamu anda kami kita akan jika kalau tidak ' +
    'juga sudah saat agar oleh sebagai karena tetapi lalu bila mau';

type
  TTokens = array of string;

  TBM25Index = class
  private
    FDocTerms: array of TStringList;   // per document: sorted terms, count in Objects
    FDocLengths: array of Integer;     // tokens per document
    FDocFreq: TStringList;             // sorted terms, number of documents in Objects
    FStopWords: TStringList;           // sorted; empty means no filtering
    FTotalLength: Int64;
    FK1: Double;
    FB: Double;
    function GetCount: Integer;
    function Filter(const ATokens: TTokens): TTokens;
  public
    constructor Create(AK1: Double = 1.2; AB: Double = 0.75);
    destructor Destroy; override;
    { Words to ignore, space separated (see STOP_WORDS_EN, STOP_WORDS_ID).
      Must be called before the first Add, so documents and queries are
      filtered the same way. }
    procedure AddStopWords(const AWords: string);
    { Index a document. Documents are numbered in the order they are added. }
    procedure Add(const AText: string);
    { The ATopK best matching documents; documents with no query term are
      not returned at all. }
    function Search(const AQuery: string; ATopK: Integer): TScoredIndices;
    property Count: Integer read GetCount;
  end;

function Tokenize(const AText: string): TTokens;

implementation

{ A sorted string list used as a term -> count map. Objects holds the
  count, cast to and from PtrInt, which avoids a generics dependency. }
function NewCountList: TStringList;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := True;
  Result.Duplicates := dupIgnore;
  Result.Sorted := True;
end;

procedure Increment(AList: TStringList; const ATerm: string);
var
  I: Integer;
begin
  I := AList.Add(ATerm);   // with dupIgnore, returns the existing index
  AList.Objects[I] := TObject(PtrInt(AList.Objects[I]) + 1);
end;

function CountOf(AList: TStringList; AIndex: Integer): Integer;
begin
  Result := PtrInt(AList.Objects[AIndex]);
end;

function Tokenize(const AText: string): TTokens;
var
  I, N: Integer;
  Token: string;
  Tokens: TTokens;   // nested Flush writes here, not to Result

  procedure Flush;
  begin
    if Length(Token) >= 2 then
    begin
      N := Length(Tokens);
      SetLength(Tokens, N + 1);
      Tokens[N] := LowerCase(Token);
    end;
    Token := '';
  end;

begin
  Tokens := nil;
  Token := '';
  for I := 1 to Length(AText) do
    if IsAsciiAlnum(AText[I]) or (Ord(AText[I]) >= 128) then
      Token := Token + AText[I]
    else
      Flush;
  Flush;
  Result := Tokens;
end;

{ TBM25Index }

constructor TBM25Index.Create(AK1: Double; AB: Double);
begin
  inherited Create;
  FK1 := AK1;
  FB := AB;
  FDocFreq := NewCountList;
  FStopWords := NewCountList;
end;

destructor TBM25Index.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FDocTerms) do
    FDocTerms[I].Free;
  FDocFreq.Free;
  FStopWords.Free;
  inherited Destroy;
end;

procedure TBM25Index.AddStopWords(const AWords: string);
var
  Words: TTokens;
  I: Integer;
begin
  if Count > 0 then
    raise Exception.Create('AddStopWords must be called before documents are added');
  Words := Tokenize(AWords);
  for I := 0 to High(Words) do
    FStopWords.Add(Words[I]);
end;

function TBM25Index.Filter(const ATokens: TTokens): TTokens;
var
  I, N: Integer;
begin
  if FStopWords.Count = 0 then
    Exit(ATokens);
  Result := nil;
  for I := 0 to High(ATokens) do
    if FStopWords.IndexOf(ATokens[I]) < 0 then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := ATokens[I];
    end;
end;

function TBM25Index.GetCount: Integer;
begin
  Result := Length(FDocTerms);
end;

procedure TBM25Index.Add(const AText: string);
var
  Tokens: TTokens;
  Terms: TStringList;
  I, N: Integer;
begin
  Tokens := Filter(Tokenize(AText));
  Terms := NewCountList;
  for I := 0 to High(Tokens) do
    Increment(Terms, Tokens[I]);
  { Each distinct term counts once towards document frequency. }
  for I := 0 to Terms.Count - 1 do
    Increment(FDocFreq, Terms[I]);

  N := Length(FDocTerms);
  SetLength(FDocTerms, N + 1);
  SetLength(FDocLengths, N + 1);
  FDocTerms[N] := Terms;
  FDocLengths[N] := Length(Tokens);
  Inc(FTotalLength, Length(Tokens));
end;

function TBM25Index.Search(const AQuery: string; ATopK: Integer): TScoredIndices;
var
  QueryTerms: TStringList;
  Tokens: TTokens;
  Scores: array of Double;
  AvgLength, Idf, Tf: Double;
  I, D, T, DocCount, DocFreq, N: Integer;
begin
  Result := nil;
  DocCount := Count;
  if DocCount = 0 then
    Exit;
  AvgLength := FTotalLength / DocCount;
  if AvgLength = 0 then
    AvgLength := 1;

  SetLength(Scores, DocCount);
  for D := 0 to DocCount - 1 do
    Scores[D] := 0;

  QueryTerms := NewCountList;   // also removes repeated query terms
  try
    Tokens := Filter(Tokenize(AQuery));
    for I := 0 to High(Tokens) do
      Increment(QueryTerms, Tokens[I]);

    for I := 0 to QueryTerms.Count - 1 do
    begin
      T := FDocFreq.IndexOf(QueryTerms[I]);
      if T < 0 then
        Continue;   // term appears in no document
      DocFreq := CountOf(FDocFreq, T);
      Idf := Ln(1 + (DocCount - DocFreq + 0.5) / (DocFreq + 0.5));

      for D := 0 to DocCount - 1 do
      begin
        T := FDocTerms[D].IndexOf(QueryTerms[I]);
        if T < 0 then
          Continue;
        Tf := CountOf(FDocTerms[D], T);
        Scores[D] := Scores[D] + Idf * Tf * (FK1 + 1) /
          (Tf + FK1 * (1 - FB + FB * FDocLengths[D] / AvgLength));
      end;
    end;
  finally
    QueryTerms.Free;
  end;

  for D := 0 to DocCount - 1 do
    if Scores[D] > 0 then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N].Index := D;
      Result[N].Score := Scores[D];
    end;
  SortByScore(Result);
  Result := TakeTop(Result, ATopK);
end;

end.
