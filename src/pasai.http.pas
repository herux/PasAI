unit PasAI.Http;

{ Thin HTTP layer: fphttpclient in Free Pascal, System.Net.HttpClient in
  Delphi. The only unit that touches either.

  Two ways to receive a response:
  1. HttpPostJSON          : wait until complete, return the whole body.
  2. HttpPostJSONToStream  : write the body to any TStream AS the data arrives.
     Combined with TLineSinkStream, this is the foundation for NDJSON
     streaming (one JSON object per line), the format Ollama uses.

  Text crosses this unit as string and travels as UTF-8 bytes: request
  bodies are encoded here, and response text is decoded here, one complete
  line at a time, so a character split across two network packets is
  never decoded in halves.

  Delphi note: THTTPClient writes the response into the stream while it
  arrives on Windows. On other platforms the operating system's HTTP
  stack may deliver it in larger pieces; streaming then appears in bursts,
  but the result is the same. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types;

type
  { Called for every complete line, already decoded. }
  TLineEvent = procedure(const ALine: string) of object;

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
    Body: string;
  end;

function HttpPostJSON(const AURL, ABody: string; ATimeoutMs: Integer): THttpResult;

{ Returns the HTTP status code. Any status is accepted (no exception);
  the caller decides what it means. Network errors still raise. }
function HttpPostJSONToStream(const AURL, ABody: string; AOutput: TStream;
  ATimeoutMs: Integer): Integer;

implementation

uses
  {$IFDEF FPC}
  fphttpclient;
  {$ELSE}
  System.Net.HttpClient, System.Net.URLClient;
  {$ENDIF}

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
  OldLen: Integer;
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
  if (Line <> '') and (Ord(Line[Length(Line)]) = 13) then
    SetLength(Line, Length(Line) - 1);
  if Line = '' then
    Exit;
  if Assigned(FOnLine) then
    FOnLine(Utf8BytesToString(Line));
end;

procedure TLineSinkStream.EmitCompleteLines;
var
  I, Start: Integer;
begin
  { Scan bytes, not characters: #10 never occurs inside a UTF-8 sequence. }
  Start := 1;
  for I := 1 to Length(FBuffer) do
    if Ord(FBuffer[I]) = 10 then
    begin
      EmitLine(Copy(FBuffer, Start, I - Start));
      Start := I + 1;
    end;
  if Start > 1 then
    Delete(FBuffer, 1, Start - 1);
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

function HttpPostJSONToStream(const AURL, ABody: string; AOutput: TStream;
  ATimeoutMs: Integer): Integer;
var
  Bytes: RawByteString;
  Body: TMemoryStream;
  {$IFDEF FPC}
  Client: TFPHTTPClient;
  {$ELSE}
  Client: THTTPClient;
  Response: IHTTPResponse;
  {$ENDIF}
begin
  Bytes := StringToUtf8Bytes(ABody);
  Body := TMemoryStream.Create;
  try
    if Bytes <> '' then
      Body.WriteBuffer(Bytes[1], Length(Bytes));
    Body.Position := 0;

    {$IFDEF FPC}
    Client := TFPHTTPClient.Create(nil);
    try
      Client.RequestBody := Body;   // Content-Length is added automatically
      Client.AddHeader('Content-Type', 'application/json');
      Client.IOTimeout := ATimeoutMs;
      { An empty array means every status code is accepted. }
      Client.HTTPMethod('POST', AURL, AOutput, []);
      Result := Client.ResponseStatusCode;
    finally
      Client.RequestBody := nil;
      Client.Free;
    end;
    {$ELSE}
    Client := THTTPClient.Create;
    try
      Client.ContentType := 'application/json';
      Client.ConnectionTimeout := ATimeoutMs;
      Client.ResponseTimeout := ATimeoutMs;
      Response := Client.Post(AURL, Body, AOutput);
      Result := Response.StatusCode;
      Response := nil;   // release before the client that created it
    finally
      Client.Free;
    end;
    {$ENDIF}
  finally
    Body.Free;
  end;
end;

function HttpPostJSON(const AURL, ABody: string; ATimeoutMs: Integer): THttpResult;
var
  Output: TMemoryStream;
  Bytes: RawByteString;
begin
  Output := TMemoryStream.Create;
  try
    Result.StatusCode := HttpPostJSONToStream(AURL, ABody, Output, ATimeoutMs);
    SetLength(Bytes, Output.Size);
    if Output.Size > 0 then
      Move(Output.Memory^, Bytes[1], Output.Size);
    Result.Body := Utf8BytesToString(Bytes);
  finally
    Output.Free;
  end;
end;

end.
