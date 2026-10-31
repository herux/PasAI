unit PasAI.Ollama;

(* Client for Ollama (https://ollama.com), a local LLM server.

  Endpoint used:
    POST /api/chat   body: {"model", "messages", "stream", "options"}

  Non-streaming : a single JSON object {"message":{"role","content"}, "done":true, ...}
  Streaming     : NDJSON, one object per line, each carrying a chunk of
                  "message.content"; the last object has "done": true.
  Errors        : {"error": "message"} (e.g. the model has not been pulled).

  Note: this header uses parenthesis-star comment delimiters because the JSON
  examples contain braces, which would end a brace comment early. *)

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Provider;

const
  OLLAMA_DEFAULT_URL = 'http://localhost:11434';
  OLLAMA_DEFAULT_TIMEOUT_MS = 300000; // local models can be slow on first load

type
  EOllamaError = class(EPasAIError);

  TOllamaClient = class(TLLMProvider)
  private
    FBaseURL: string;
    FTimeoutMs: Integer;
    function Endpoint(const APath: string): string;
    function BuildChatBody(const AMessages: TChatMessages; AStream: Boolean): RawByteString;
  public
    constructor Create(const AModel: string; const ABaseURL: string = OLLAMA_DEFAULT_URL);

    function Name: string; override;
    function Chat(const AMessages: TChatMessages): string; override;
    { Ollama streams NDJSON, so this overrides the single-chunk default. }
    function ChatStream(const AMessages: TChatMessages; AOnChunk: TTextChunkProc): string; override;

    property BaseURL: string read FBaseURL write FBaseURL;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
  end;

implementation

uses
  fpjson, jsonparser, PasAI.Http;

const
  MSG_REQUEST_FAILED =
    'Failed to call Ollama at %s: %s. ' +
    'Make sure Ollama is running (open the app or run "ollama serve").';

{ JSON helpers }

function ParseObject(const AText: UTF8String): TJSONObject;
var
  D: TJSONData;
begin
  D := GetJSON(AText);
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise EOllamaError.Create('Response is not a JSON object: ' + Copy(AText, 1, 200));
  end;
  Result := TJSONObject(D);
end;

procedure RaiseIfOllamaError(O: TJSONObject);
var
  E: TJSONData;
begin
  E := O.Find('error');
  if E <> nil then
    raise EOllamaError.Create('Ollama: ' + E.AsString);
end;

{ TOllamaStreamState: collects the streaming result line by line. }

type
  TOllamaStreamState = class
  private
    FOnChunk: TTextChunkProc;
    FFullText: string;
    FDone: Boolean;
  public
    constructor Create(AOnChunk: TTextChunkProc);
    procedure HandleLine(const ALine: RawByteString);
    property FullText: string read FFullText;
    property Done: Boolean read FDone;
  end;

constructor TOllamaStreamState.Create(AOnChunk: TTextChunkProc);
begin
  inherited Create;
  FOnChunk := AOnChunk;
end;

procedure TOllamaStreamState.HandleLine(const ALine: RawByteString);
var
  O: TJSONObject;
  D: TJSONData;
  Piece: string;
begin
  { Each line is a complete JSON object, so multi-byte UTF-8 characters are
    never cut in half, even when network packets are split arbitrarily. }
  O := ParseObject(ALine);
  try
    RaiseIfOllamaError(O);
    D := O.FindPath('message.content');
    if (D <> nil) and not D.IsNull then
    begin
      Piece := D.AsString;
      if Piece <> '' then
      begin
        FFullText := FFullText + Piece;
        if Assigned(FOnChunk) then
          FOnChunk(Piece);
      end;
    end;
    D := O.Find('done');
    if (D <> nil) and (D.JSONType = jtBoolean) and D.AsBoolean then
      FDone := True;
  finally
    O.Free;
  end;
end;

{ TOllamaClient }

constructor TOllamaClient.Create(const AModel: string; const ABaseURL: string);
begin
  inherited Create(AModel);
  FBaseURL := ABaseURL;
  FTimeoutMs := OLLAMA_DEFAULT_TIMEOUT_MS;
end;

function TOllamaClient.Name: string;
begin
  Result := 'ollama';
end;

function TOllamaClient.Endpoint(const APath: string): string;
begin
  Result := FBaseURL;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  Result := Result + APath;
end;

function TOllamaClient.BuildChatBody(const AMessages: TChatMessages;
  AStream: Boolean): RawByteString;
var
  Req, M, Opts: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Req := TJSONObject.Create;
  try
    Req.Add('model', UTF8String(Model));
    Req.Add('stream', AStream);

    Arr := TJSONArray.Create;
    Req.Add('messages', Arr);           // Req now owns Arr
    for I := 0 to High(AMessages) do
    begin
      M := TJSONObject.Create;
      Arr.Add(M);                       // Arr now owns M
      M.Add('role', UTF8String(AMessages[I].Role));
      M.Add('content', UTF8String(AMessages[I].Content));
    end;

    if Temperature >= 0 then
    begin
      Opts := TJSONObject.Create;
      Req.Add('options', Opts);
      Opts.Add('temperature', TJSONFloat(Temperature));
    end;

    Result := Req.AsJSON;
  finally
    Req.Free;
  end;
end;

function TOllamaClient.Chat(const AMessages: TChatMessages): string;
var
  R: THttpResult;
  O: TJSONObject;
  D: TJSONData;
begin
  try
    R := HttpPostJSON(Endpoint('/api/chat'), BuildChatBody(AMessages, False), FTimeoutMs);
  except
    on E: Exception do
      raise EOllamaError.CreateFmt(MSG_REQUEST_FAILED, [FBaseURL, E.Message]);
  end;

  O := ParseObject(R.Body);
  try
    RaiseIfOllamaError(O);
    if R.StatusCode <> 200 then
      raise EOllamaError.CreateFmt('Ollama returned HTTP %d', [R.StatusCode]);
    D := O.FindPath('message.content');
    if D = nil then
      raise EOllamaError.Create('Ollama response has no message.content');
    Result := D.AsString;
  finally
    O.Free;
  end;
end;

function TOllamaClient.ChatStream(const AMessages: TChatMessages;
  AOnChunk: TTextChunkProc): string;
var
  State: TOllamaStreamState;
  Sink: TLineSinkStream;
  Status: Integer;
begin
  State := TOllamaStreamState.Create(AOnChunk);
  Sink := TLineSinkStream.Create(State.HandleLine);
  try
    try
      Status := HttpPostJSONToStream(Endpoint('/api/chat'),
        BuildChatBody(AMessages, True), Sink, FTimeoutMs);
    except
      on E: EPasAIError do
        raise;   // error reported by Ollama itself (e.g. unknown model): pass it on unchanged
      on E: Exception do
        raise EOllamaError.CreateFmt(MSG_REQUEST_FAILED, [FBaseURL, E.Message]);
    end;

    Sink.Flush;  // final line without #10 (usually an error object)
    if Status <> 200 then
      raise EOllamaError.CreateFmt('Ollama returned HTTP %d', [Status]);
    if not State.Done then
      raise EOllamaError.Create('Stream ended before completion');

    Result := State.FullText;
  finally
    Sink.Free;
    State.Free;
  end;
end;

end.
