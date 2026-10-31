unit PasAI.Chunk;

{ Chunking: cutting documents into pieces small enough to retrieve and to
  fit into a prompt.

  Too large, and a chunk mixes several topics, so it matches many queries
  weakly and wastes prompt space. Too small, and it loses the context that
  makes it understandable. Splitting on paragraph boundaries and packing
  paragraphs up to a size limit keeps related sentences together.

  Each chunk also keeps the document's title (its first "# " heading). The
  title is indexed together with the text: a chunk that only says "Charge
  for 70 minutes" is much easier to find when it carries "Battery" too. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

type
  TChunk = record
    Source: string;   // file name or other origin
    Title: string;    // document title, repeated for every chunk
    Index: Integer;   // position within its document, from 0
    Text: string;
  end;

  TChunks = array of TChunk;

{ Split AText into chunks of at most AMaxChars characters (bytes of UTF-8),
  breaking at paragraphs, or at spaces inside an overlong paragraph. }
function ChunkText(const AText, ASource: string; AMaxChars: Integer = 800): TChunks;

{ Read a UTF-8 text file and chunk it, with the file name as source. }
function ChunkFile(const AFileName: string; AMaxChars: Integer = 800): TChunks;

{ Chunk every file in ADir matching AMask (e.g. '*.md'), in file name
  order, so results are the same on every run. }
function ChunkFolder(const ADir, AMask: string; AMaxChars: Integer = 800): TChunks;

{ "source#index", e.g. "baterai.md#1": a readable id for logs and reports. }
function ChunkId(const AChunk: TChunk): string;

procedure AppendChunks(var ATarget: TChunks; const AMore: TChunks);

{ The text to index for a chunk: its title followed by its text. }
function SearchableText(const AChunk: TChunk): string;

implementation

type
  TStringArray = array of string;

procedure AddString(var A: TStringArray; const S: string);
var
  N: Integer;
begin
  N := Length(A);
  SetLength(A, N + 1);
  A[N] := S;
end;

{ Paragraphs are separated by blank lines. }
function SplitParagraphs(const AText: string): TStringArray;
var
  Lines: TStringList;
  Para: string;
  I: Integer;
begin
  Result := nil;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Para := '';
    for I := 0 to Lines.Count - 1 do
      if Trim(Lines[I]) = '' then
      begin
        if Para <> '' then
          AddString(Result, Para);
        Para := '';
      end
      else if Para = '' then
        Para := TrimRight(Lines[I])
      else
        Para := Para + #10 + TrimRight(Lines[I]);
    if Para <> '' then
      AddString(Result, Para);
  finally
    Lines.Free;
  end;
end;

{ Break a paragraph longer than AMaxChars at spaces. }
function SplitLong(const AText: string; AMaxChars: Integer): TStringArray;
var
  Rest: string;
  Cut: Integer;
begin
  Result := nil;
  Rest := AText;
  while Length(Rest) > AMaxChars do
  begin
    Cut := AMaxChars;
    while (Cut > 0) and not (Rest[Cut] in [' ', #10]) do
      Dec(Cut);
    if Cut = 0 then
      Cut := AMaxChars;   // no space at all: cut hard
    AddString(Result, Trim(Copy(Rest, 1, Cut)));
    Delete(Rest, 1, Cut);
  end;
  if Trim(Rest) <> '' then
    AddString(Result, Trim(Rest));
end;

function ChunkText(const AText, ASource: string; AMaxChars: Integer): TChunks;
var
  Paras, Pieces: TStringArray;
  Title, Current: string;
  I, J: Integer;
  Chunks: TChunks;   // nested Flush writes here, not to Result

  procedure Flush;
  var
    N: Integer;
  begin
    if Current = '' then
      Exit;
    N := Length(Chunks);
    SetLength(Chunks, N + 1);
    Chunks[N].Source := ASource;
    Chunks[N].Title := Title;
    Chunks[N].Index := N;
    Chunks[N].Text := Current;
    Current := '';
  end;

  procedure AddPiece(const APiece: string);
  begin
    if Current = '' then
      Current := APiece
    else if Length(Current) + 2 + Length(APiece) <= AMaxChars then
      Current := Current + #10#10 + APiece
    else
    begin
      Flush;
      Current := APiece;
    end;
  end;

begin
  Chunks := nil;
  if AMaxChars < 50 then
    AMaxChars := 50;
  Paras := SplitParagraphs(AText);

  Title := ASource;
  if (Length(Paras) > 0) and (Copy(Paras[0], 1, 2) = '# ') then
    Title := Trim(Copy(Paras[0], 3, Length(Paras[0])));

  Current := '';
  for I := 0 to High(Paras) do
    if Length(Paras[I]) > AMaxChars then
    begin
      Pieces := SplitLong(Paras[I], AMaxChars);
      for J := 0 to High(Pieces) do
        AddPiece(Pieces[J]);
    end
    else
      AddPiece(Paras[I]);
  Flush;
  Result := Chunks;
end;

function ChunkFile(const AFileName: string; AMaxChars: Integer): TChunks;
var
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(AFileName);
    Result := ChunkText(Lines.Text, ExtractFileName(AFileName), AMaxChars);
  finally
    Lines.Free;
  end;
end;

function ChunkFolder(const ADir, AMask: string; AMaxChars: Integer): TChunks;
var
  SR: TSearchRec;
  Files: TStringList;
  Dir: string;
  I: Integer;
begin
  Result := nil;
  Dir := IncludeTrailingPathDelimiter(ADir);
  Files := TStringList.Create;
  try
    if FindFirst(Dir + AMask, faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
          Files.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Files.Sort;
    for I := 0 to Files.Count - 1 do
      AppendChunks(Result, ChunkFile(Dir + Files[I], AMaxChars));
  finally
    Files.Free;
  end;
end;

function ChunkId(const AChunk: TChunk): string;
begin
  Result := AChunk.Source + '#' + IntToStr(AChunk.Index);
end;

procedure AppendChunks(var ATarget: TChunks; const AMore: TChunks);
var
  I, N: Integer;
begin
  N := Length(ATarget);
  SetLength(ATarget, N + Length(AMore));
  for I := 0 to High(AMore) do
    ATarget[N + I] := AMore[I];
end;

function SearchableText(const AChunk: TChunk): string;
begin
  Result := AChunk.Title + #10 + AChunk.Text;
end;

end.
