unit PasAI.Http;

{ Thin HTTP layer on top of fphttpclient.

  Two ways to receive a response:
  1. HttpPostJSON          : wait until complete, return the whole body.
  2. HttpPostJSONToStream  : write the body to any TStream AS the data arrives.
     Combined with TLineSinkStream, this is the foundation for NDJSON
     streaming (one JSON object per line), the format Ollama uses.

  Delphi note: this is the only unit that touches fphttpclient. When porting
  to Delphi, only this unit needs replacing (see ARCHITECTURE.md). }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

type
  { Called for every complete line. The line is already tagged CP_UTF8. }
  TLineEvent = procedure(const ALine: RawByteString) of object;

  { A TStream that stores nothing: written bytes are split on #10 and each
    complete line is passed straight to OnLine. Any remainder not yet
    terminated by #10 is held until more data arrives (or Flush is called). }
  TLineSinkStream = class(TStream)
  private
    FBuffer: RawByteString;
    FPosition: Int64;
    FOnLine: TLineEvent;
    procedure EmitLine(const ALine: RawByteString);
    procedure EmitCompleteLines;
  public
    constructor Create(AOnLine: TLineEvent);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    { Emit the remaining buffer as the final line. Call after the request completes. }
    procedure Flush;
  end;

  THttpResult = record
    StatusCode: Integer;
    Body: RawByteString;   // tagged CP_UTF8
  end;

function HttpPostJSON(const AURL: string; const ABody: RawByteString;
  ATimeoutMs: Integer): THttpResult;

{ Returns the HTTP status code. Any status is accepted (no exception);
  the caller decides what it means. Network errors still raise. }
function HttpPostJSONToStream(const AURL: string; const ABody: RawByteString;
  AOutput: TStream; ATimeoutMs: Integer): Integer;

implementation

uses
  fphttpclient;

{ TLineSinkStream }

constructor TLineSinkStream.Create(AOnLine: TLineEvent);
begin
  inherited Create;
  FOnLine := AOnLine;
end;

function TLineSinkStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0; // write-only sink
end;

function TLineSinkStream.Write(const Buffer; Count: Longint): Longint;
var
  OldLen: SizeInt;
begin
  if Count > 0 then
  begin
    OldLen := Length(FBuffer);
    SetLength(FBuffer, OldLen + Count);
    Move(Buffer, FBuffer[OldLen + 1], Count);
    Inc(FPosition, Count);
    EmitCompleteLines;
  end;
  Result := Count;
end;

function TLineSinkStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  { This stream only moves forward. Returning the current position is
    enough for TStream.Position and TStream.Size to behave sensibly. }
  Result := FPosition;
end;

procedure TLineSinkStream.EmitLine(const ALine: RawByteString);
var
  Line: RawByteString;
begin
  Line := ALine;
  if (Line <> '') and (Line[Length(Line)] = #13) then
    SetLength(Line, Length(Line) - 1);
  if Line = '' then
    Exit;
  { Bytes from the network are UTF-8. Tag them without converting, so no
    silent codepage conversion happens when passed on to the JSON parser. }
  SetCodePage(Line, CP_UTF8, False);
  if Assigned(FOnLine) then
    FOnLine(Line);
end;

procedure TLineSinkStream.EmitCompleteLines;
var
  P: SizeInt;
  Line: RawByteString;
begin
  P := Pos(#10, FBuffer);
  while P > 0 do
  begin
    Line := Copy(FBuffer, 1, P - 1);
    Delete(FBuffer, 1, P);
    EmitLine(Line);
    P := Pos(#10, FBuffer);
  end;
end;

procedure TLineSinkStream.Flush;
var
  Rest: RawByteString;
begin
  Rest := FBuffer;
  FBuffer := '';
  EmitLine(Rest);
end;

{ HTTP functions }

function HttpPostJSONToStream(const AURL: string; const ABody: RawByteString;
  AOutput: TStream; ATimeoutMs: Integer): Integer;
var
  Client: TFPHTTPClient;
  Body: TMemoryStream;
begin
  Client := TFPHTTPClient.Create(nil);
  Body := TMemoryStream.Create;
  try
    if ABody <> '' then
      Body.WriteBuffer(ABody[1], Length(ABody));
    Body.Position := 0;
    Client.RequestBody := Body;   // Content-Length is added automatically
    Client.AddHeader('Content-Type', 'application/json');
    Client.IOTimeout := ATimeoutMs;
    { An empty array means every status code is accepted (see CheckResponseCode). }
    Client.HTTPMethod('POST', AURL, AOutput, []);
    Result := Client.ResponseStatusCode;
  finally
    Client.RequestBody := nil;
    Body.Free;
    Client.Free;
  end;
end;

function HttpPostJSON(const AURL: string; const ABody: RawByteString;
  ATimeoutMs: Integer): THttpResult;
var
  Output: TMemoryStream;
begin
  Output := TMemoryStream.Create;
  try
    Result.StatusCode := HttpPostJSONToStream(AURL, ABody, Output, ATimeoutMs);
    SetLength(Result.Body, Output.Size);
    if Output.Size > 0 then
      Move(Output.Memory^, Result.Body[1], Output.Size);
    SetCodePage(Result.Body, CP_UTF8, False);
  finally
    Output.Free;
  end;
end;

end.
