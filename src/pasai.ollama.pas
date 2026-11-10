unit PasAI.Ollama;

(* Client for Ollama (https://ollama.com), a local LLM server.

  Endpoint used:
    POST /api/chat   body: {"model", "messages", "stream", "format", "tools", "options"}

  Non-streaming : a single JSON object {"message":{"role","content"}, "done":true, ...}
  Streaming     : NDJSON, one object per line, each carrying a chunk of
                  "message.content"; the last object has "done": true.
  Errors        : {"error": "message"} (e.g. the model has not been pulled).

  Tool calling:
    request  "tools": [{"type":"function","function":{"name","description","parameters"}}]
    response "message": {"role":"assistant","content":"",
                         "tool_calls":[{"function":{"name":"x","arguments":{...}}}]}
    result   a message {"role":"tool","content":"...","tool_name":"x"}
  Unlike OpenAI, Ollama sends "arguments" as a JSON object, not as a string.

  Embeddings:
    POST /api/embed   body: {"model", "input": ["text", ...]}
    response          {"embeddings": [[0.01, -0.2, ...], ...]}

  Note: this header uses parenthesis-star comment delimiters because the JSON
  examples contain braces, which would end a brace comment early. *)

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Provider, PasAI.Embed;

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
    { AFormat: a JSON schema as text, or empty for free-form text. }
    function BuildChatBody(const AMessages: TChatMessages; AStream: Boolean;
      const AFormat: UTF8String; const ATools: TToolSpecs): string;
    function DoChat(const AMessages: TChatMessages; const AFormat: UTF8String;
      const ATools: TToolSpecs): TChatMessage;
  public
    constructor Create(const AModel: string; const ABaseURL: string = OLLAMA_DEFAULT_URL);

    function Name: string; override;
    function Chat(const AMessages: TChatMessages): string; override;
    { Ollama streams NDJSON, so this overrides the single-chunk default. }
    function ChatStream(const AMessages: TChatMessages; AOnChunk: TTextChunkProc): string; override;
    { Sends the schema both in the prompt and as Ollama's "format" field.
      With "format", Ollama constrains decoding so the model can only emit
      tokens that keep the output valid against the schema. }
    function ChatJSON(const AMessages: TChatMessages; const ASchema: UTF8String): string; override;
    { Native tool calling through the "tools" field. }
    function ChatWithTools(const AMessages: TChatMessages;
      const ATools: TToolSpecs): TChatMessage; override;

    property BaseURL: string read FBaseURL write FBaseURL;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
  end;

  { Embeddings through Ollama's /api/embed, e.g. with bge-m3, which is
    multilingual and works well for Indonesian. Texts are sent in batches. }
  TOllamaEmbedder = class(TEmbedder)
  private
    FBaseURL: string;
    FTimeoutMs: Integer;
    FBatchSize: Integer;
    function EmbedBatch(const ATexts: array of string; AFrom, ACount: Integer): TVectors;
  public
    constructor Create(const AModel: string; const ABaseURL: string = OLLAMA_DEFAULT_URL);
    function Name: string; override;
    function Embed(const ATexts: array of string): TVectors; override;
    property BaseURL: string read FBaseURL write FBaseURL;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    { Texts per request. Larger batches are faster but use more memory. }
    property BatchSize: Integer read FBatchSize write FBatchSize;
  end;

implementation

uses
  Math, PasAI.Json, PasAI.Http;

const
  MSG_REQUEST_FAILED =
    'Failed to call Ollama at %s: %s. ' +
    'Make sure Ollama is running (open the app or run "ollama serve").';

{ Helpers }

function TrimSlash(const AURL: string): string;
begin
  Result := AURL;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function ParseResponse(const AText: string): TJSONObject;
begin
  try
    Result := ParseJsonObject(AText);
  except
    on E: EPasAIError do
      raise EOllamaError.Create('Unexpected response from Ollama: ' + Copy(AText, 1, 200));
  end;
end;

procedure RaiseIfOllamaError(O: TJSONObject);
var
  E: TJSONValue;
begin
  E := JsonFind(O, 'error');
  if E <> nil then
    raise EOllamaError.Create('Ollama: ' + JsonAsString(E));
end;

{ Convert Ollama's "message" object into a TChatMessage. }
function MessageFromJSON(AMsg: TJSONObject): TChatMessage;
var
  D, Call, Fn, Args, Id: TJSONValue;
  I: Integer;
begin
  Result := ChatMessage(ROLE_ASSISTANT, '');

  D := JsonFind(AMsg, 'content');
  if (D <> nil) and (JsonKind(D) = jkString) then
    Result.Content := JsonAsString(D);

  D := JsonFind(AMsg, 'tool_calls');
  if (D = nil) or (JsonKind(D) <> jkArray) then
    Exit;

  SetLength(Result.ToolCalls, JsonCount(D));
  for I := 0 to JsonCount(D) - 1 do
  begin
    Result.ToolCalls[I].Id := '';
    Result.ToolCalls[I].Name := '';
    Result.ToolCalls[I].Arguments := '{}';
    Call := JsonItem(D, I);
    if JsonKind(Call) <> jkObject then
      Continue;

    Id := JsonFind(TJSONObject(Call), 'id');
    if (Id <> nil) and (JsonKind(Id) = jkString) then
      Result.ToolCalls[I].Id := JsonAsString(Id);

    Fn := JsonFind(TJSONObject(Call), 'function');
    if (Fn = nil) or (JsonKind(Fn) <> jkObject) then
      Continue;
    Result.ToolCalls[I].Name := JsonStringOr(TJSONObject(Fn), 'name', '');

    { Ollama sends an object; accept a string too, as OpenAI-style servers do. }
    Args := JsonFind(TJSONObject(Fn), 'arguments');
    if Args <> nil then
      if JsonKind(Args) = jkString then
        Result.ToolCalls[I].Arguments := JsonAsString(Args)
      else
        Result.ToolCalls[I].Arguments := JsonToText(Args);
  end;
end;

{ Arguments are stored as text; Ollama wants them as an object. }
function ArgumentsValue(const AText: string): TJSONValue;
begin
  if Trim(AText) = '' then
    Result := JsonNewObject
  else
    Result := ParseJson(AText);
end;

function MessageToJSON(const AMsg: TChatMessage): TJSONObject;
var
  Calls: TJSONArray;
  Call, Fn: TJSONObject;
  I: Integer;
begin
  Result := JsonNewObject;
  try
    JsonAddString(Result, 'role', AMsg.Role);
    JsonAddString(Result, 'content', AMsg.Content);

    if Length(AMsg.ToolCalls) > 0 then
    begin
      Calls := JsonNewArray;
      JsonAddValue(Result, 'tool_calls', Calls);
      for I := 0 to High(AMsg.ToolCalls) do
      begin
        Call := JsonNewObject;
        JsonArrayAdd(Calls, Call);
        if AMsg.ToolCalls[I].Id <> '' then
          JsonAddString(Call, 'id', AMsg.ToolCalls[I].Id);
        Fn := JsonNewObject;
        JsonAddValue(Call, 'function', Fn);
        JsonAddString(Fn, 'name', AMsg.ToolCalls[I].Name);
        JsonAddValue(Fn, 'arguments', ArgumentsValue(AMsg.ToolCalls[I].Arguments));
      end;
    end;

    if AMsg.ToolName <> '' then
      JsonAddString(Result, 'tool_name', AMsg.ToolName);
  except
    Result.Free;
    raise;
  end;
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
    procedure HandleLine(const ALine: string);
    property FullText: string read FFullText;
    property Done: Boolean read FDone;
  end;

constructor TOllamaStreamState.Create(AOnChunk: TTextChunkProc);
begin
  inherited Create;
  FOnChunk := AOnChunk;
end;

procedure TOllamaStreamState.HandleLine(const ALine: string);
var
  O: TJSONObject;
  D: TJSONValue;
  Piece: string;
begin
  { Each line is a complete JSON object, so multi-byte characters are never
    cut in half, even when network packets are split arbitrarily. }
  O := ParseResponse(ALine);
  try
    RaiseIfOllamaError(O);
    D := JsonFindPath(O, 'message.content');
    if (D <> nil) and (JsonKind(D) = jkString) then
    begin
      Piece := JsonAsString(D);
      if Piece <> '' then
      begin
        FFullText := FFullText + Piece;
        if Assigned(FOnChunk) then
          FOnChunk(Piece);
      end;
    end;
    D := JsonFind(O, 'done');
    if (D <> nil) and (JsonKind(D) = jkBool) and JsonAsBoolean(D) then
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
  Result := TrimSlash(FBaseURL) + APath;
end;

function TOllamaClient.BuildChatBody(const AMessages: TChatMessages;
  AStream: Boolean; const AFormat: UTF8String; const ATools: TToolSpecs): string;
var
  Req, Opts, Tool, Fn: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Req := JsonNewObject;
  try
    JsonAddString(Req, 'model', Model);
    JsonAddBool(Req, 'stream', AStream);
    if AFormat <> '' then
      JsonAddValue(Req, 'format', ParseJson(string(AFormat)));   // an object, not a string

    Arr := JsonNewArray;
    JsonAddValue(Req, 'messages', Arr);
    for I := 0 to High(AMessages) do
      JsonArrayAdd(Arr, MessageToJSON(AMessages[I]));

    if Length(ATools) > 0 then
    begin
      Arr := JsonNewArray;
      JsonAddValue(Req, 'tools', Arr);
      for I := 0 to High(ATools) do
      begin
        Tool := JsonNewObject;
        JsonArrayAdd(Arr, Tool);
        JsonAddString(Tool, 'type', 'function');
        Fn := JsonNewObject;
        JsonAddValue(Tool, 'function', Fn);
        JsonAddString(Fn, 'name', ATools[I].Name);
        JsonAddString(Fn, 'description', ATools[I].Description);
        JsonAddValue(Fn, 'parameters', ParseJson(string(ATools[I].ParametersSchema)));
      end;
    end;

    if Temperature >= 0 then
    begin
      Opts := JsonNewObject;
      JsonAddValue(Req, 'options', Opts);
      JsonAddFloat(Opts, 'temperature', Temperature);
    end;

    Result := JsonToText(Req);
  finally
    Req.Free;
  end;
end;

function TOllamaClient.DoChat(const AMessages: TChatMessages;
  const AFormat: UTF8String; const ATools: TToolSpecs): TChatMessage;
var
  Body: string;
  R: THttpResult;
  O: TJSONObject;
  D: TJSONValue;
begin
  { Built outside the try below, so an invalid schema is reported as such
    and not as a connection problem. }
  Body := BuildChatBody(AMessages, False, AFormat, ATools);
  try
    R := HttpPostJSON(Endpoint('/api/chat'), Body, FTimeoutMs);
  except
    on E: Exception do
      raise EOllamaError.CreateFmt(MSG_REQUEST_FAILED, [FBaseURL, E.Message]);
  end;

  O := ParseResponse(R.Body);
  try
    RaiseIfOllamaError(O);
    if R.StatusCode <> 200 then
      raise EOllamaError.CreateFmt('Ollama returned HTTP %d', [R.StatusCode]);
    D := JsonFind(O, 'message');
    if (D = nil) or (JsonKind(D) <> jkObject) then
      raise EOllamaError.Create('Ollama response has no message');
    Result := MessageFromJSON(TJSONObject(D));
  finally
    O.Free;
  end;
end;

function TOllamaClient.Chat(const AMessages: TChatMessages): string;
begin
  Result := DoChat(AMessages, '', nil).Content;
end;

function TOllamaClient.ChatJSON(const AMessages: TChatMessages;
  const ASchema: UTF8String): string;
begin
  Result := DoChat(WithSchemaInstruction(AMessages, ASchema), ASchema, nil).Content;
end;

function TOllamaClient.ChatWithTools(const AMessages: TChatMessages;
  const ATools: TToolSpecs): TChatMessage;
begin
  Result := DoChat(AMessages, '', ATools);
end;

function TOllamaClient.ChatStream(const AMessages: TChatMessages;
  AOnChunk: TTextChunkProc): string;
var
  State: TOllamaStreamState;
  Sink: TLineSinkStream;
  Status: Integer;
  Body: string;
begin
  Body := BuildChatBody(AMessages, True, '', nil);
  State := TOllamaStreamState.Create(AOnChunk);
  Sink := TLineSinkStream.Create(State.HandleLine);
  try
    try
      Status := HttpPostJSONToStream(Endpoint('/api/chat'), Body, Sink, FTimeoutMs);
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

{ TOllamaEmbedder }

constructor TOllamaEmbedder.Create(const AModel: string; const ABaseURL: string);
begin
  inherited Create(AModel);
  FBaseURL := ABaseURL;
  FTimeoutMs := OLLAMA_DEFAULT_TIMEOUT_MS;
  FBatchSize := 32;
end;

function TOllamaEmbedder.Name: string;
begin
  Result := 'ollama';
end;

function TOllamaEmbedder.EmbedBatch(const ATexts: array of string;
  AFrom, ACount: Integer): TVectors;
var
  Req, O: TJSONObject;
  Input: TJSONArray;
  Body: string;
  R: THttpResult;
  D, Row: TJSONValue;
  I, J: Integer;
begin
  Req := JsonNewObject;
  try
    JsonAddString(Req, 'model', Model);
    Input := JsonNewArray;
    JsonAddValue(Req, 'input', Input);
    for I := AFrom to AFrom + ACount - 1 do
      JsonArrayAddString(Input, ATexts[I]);
    Body := JsonToText(Req);
  finally
    Req.Free;
  end;

  try
    R := HttpPostJSON(TrimSlash(FBaseURL) + '/api/embed', Body, FTimeoutMs);
  except
    on E: Exception do
      raise EOllamaError.CreateFmt(MSG_REQUEST_FAILED, [FBaseURL, E.Message]);
  end;

  O := ParseResponse(R.Body);
  try
    RaiseIfOllamaError(O);
    if R.StatusCode <> 200 then
      raise EOllamaError.CreateFmt('Ollama returned HTTP %d', [R.StatusCode]);
    D := JsonFind(O, 'embeddings');
    if (D = nil) or (JsonKind(D) <> jkArray) then
      raise EOllamaError.Create('Ollama response has no embeddings');

    SetLength(Result, JsonCount(D));
    for I := 0 to JsonCount(D) - 1 do
    begin
      Row := JsonItem(D, I);
      if JsonKind(Row) <> jkArray then
        raise EOllamaError.Create('Embedding is not an array');
      SetLength(Result[I], JsonCount(Row));
      for J := 0 to JsonCount(Row) - 1 do
        Result[I][J] := JsonAsFloat(JsonItem(Row, J));
    end;
  finally
    O.Free;
  end;
end;

function TOllamaEmbedder.Embed(const ATexts: array of string): TVectors;
var
  Batch: TVectors;
  From, Count, I: Integer;
begin
  SetLength(Result, Length(ATexts));
  From := 0;
  while From < Length(ATexts) do
  begin
    Count := Min(Max(FBatchSize, 1), Length(ATexts) - From);
    Batch := EmbedBatch(ATexts, From, Count);
    if Length(Batch) <> Count then
      raise EOllamaError.CreateFmt('Ollama returned %d embeddings for %d texts',
        [Length(Batch), Count]);
    for I := 0 to Count - 1 do
      Result[From + I] := Batch[I];
    Inc(From, Count);
  end;
end;

end.
