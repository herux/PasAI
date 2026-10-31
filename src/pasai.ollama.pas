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

{$mode delphi}{$H+}

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
      const AFormat: UTF8String; const ATools: TToolSpecs): RawByteString;
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
  Math, fpjson, jsonparser, PasAI.Http;

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

{ Parse a JSON object given as text; an empty text becomes an empty object. }
function JSONObjectFromText(const AText: string): TJSONData;
begin
  if Trim(AText) = '' then
    Result := TJSONObject.Create
  else
    Result := GetJSON(UTF8String(AText));
end;

{ Convert Ollama's "message" object into a TChatMessage. }
function MessageFromJSON(AMsg: TJSONObject): TChatMessage;
var
  D, Fn, Args, Id: TJSONData;
  Calls: TJSONArray;
  I: Integer;
begin
  Result := ChatMessage(ROLE_ASSISTANT, '');

  D := AMsg.Find('content');
  if (D <> nil) and not D.IsNull then
    Result.Content := D.AsString;

  D := AMsg.Find('tool_calls');
  if (D = nil) or (D.JSONType <> jtArray) then
    Exit;

  Calls := TJSONArray(D);
  SetLength(Result.ToolCalls, Calls.Count);
  for I := 0 to Calls.Count - 1 do
  begin
    Result.ToolCalls[I].Id := '';
    Result.ToolCalls[I].Name := '';
    Result.ToolCalls[I].Arguments := '{}';
    if Calls.Items[I].JSONType <> jtObject then
      Continue;

    Id := TJSONObject(Calls.Items[I]).Find('id');
    if (Id <> nil) and (Id.JSONType = jtString) then
      Result.ToolCalls[I].Id := Id.AsString;

    Fn := TJSONObject(Calls.Items[I]).Find('function');
    if (Fn = nil) or (Fn.JSONType <> jtObject) then
      Continue;

    D := TJSONObject(Fn).Find('name');
    if D <> nil then
      Result.ToolCalls[I].Name := D.AsString;

    { Ollama sends an object; accept a string too, as OpenAI-style servers do. }
    Args := TJSONObject(Fn).Find('arguments');
    if Args <> nil then
      if Args.JSONType = jtString then
        Result.ToolCalls[I].Arguments := Args.AsString
      else
        Result.ToolCalls[I].Arguments := Args.AsJSON;
  end;
end;

{ Convert a TChatMessage into Ollama's message JSON. }
function MessageToJSON(const AMsg: TChatMessage): TJSONObject;
var
  Calls: TJSONArray;
  Call, Fn: TJSONObject;
  I: Integer;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('role', UTF8String(AMsg.Role));
    Result.Add('content', UTF8String(AMsg.Content));

    if Length(AMsg.ToolCalls) > 0 then
    begin
      Calls := TJSONArray.Create;
      Result.Add('tool_calls', Calls);
      for I := 0 to High(AMsg.ToolCalls) do
      begin
        Call := TJSONObject.Create;
        Calls.Add(Call);
        if AMsg.ToolCalls[I].Id <> '' then
          Call.Add('id', UTF8String(AMsg.ToolCalls[I].Id));
        Fn := TJSONObject.Create;
        Call.Add('function', Fn);
        Fn.Add('name', UTF8String(AMsg.ToolCalls[I].Name));
        Fn.Add('arguments', JSONObjectFromText(AMsg.ToolCalls[I].Arguments));
      end;
    end;

    if AMsg.ToolName <> '' then
      Result.Add('tool_name', UTF8String(AMsg.ToolName));
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
  AStream: Boolean; const AFormat: UTF8String; const ATools: TToolSpecs): RawByteString;
var
  Req, Opts, Tool, Fn: TJSONObject;
  Arr: TJSONArray;
  I: Integer;
begin
  Req := TJSONObject.Create;
  try
    Req.Add('model', UTF8String(Model));
    Req.Add('stream', AStream);
    if AFormat <> '' then
      Req.Add('format', GetJSON(AFormat));   // the schema as a JSON object, not a string

    Arr := TJSONArray.Create;
    Req.Add('messages', Arr);           // Req now owns Arr
    for I := 0 to High(AMessages) do
      Arr.Add(MessageToJSON(AMessages[I]));

    if Length(ATools) > 0 then
    begin
      Arr := TJSONArray.Create;
      Req.Add('tools', Arr);
      for I := 0 to High(ATools) do
      begin
        Tool := TJSONObject.Create;
        Arr.Add(Tool);
        Tool.Add('type', UTF8String('function'));   // cast avoids an ambiguous overload
        Fn := TJSONObject.Create;
        Tool.Add('function', Fn);
        Fn.Add('name', UTF8String(ATools[I].Name));
        Fn.Add('description', UTF8String(ATools[I].Description));
        Fn.Add('parameters', GetJSON(ATools[I].ParametersSchema));
      end;
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

function TOllamaClient.DoChat(const AMessages: TChatMessages;
  const AFormat: UTF8String; const ATools: TToolSpecs): TChatMessage;
var
  Body: RawByteString;
  R: THttpResult;
  O: TJSONObject;
  D: TJSONData;
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

  O := ParseObject(R.Body);
  try
    RaiseIfOllamaError(O);
    if R.StatusCode <> 200 then
      raise EOllamaError.CreateFmt('Ollama returned HTTP %d', [R.StatusCode]);
    D := O.Find('message');
    if (D = nil) or (D.JSONType <> jtObject) then
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
  Body: RawByteString;
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
  Body: RawByteString;
  R: THttpResult;
  D, Row: TJSONData;
  URL: string;
  I, J: Integer;
begin
  Req := TJSONObject.Create;
  try
    Req.Add('model', UTF8String(Model));
    Input := TJSONArray.Create;
    Req.Add('input', Input);
    for I := AFrom to AFrom + ACount - 1 do
      Input.Add(UTF8String(ATexts[I]));
    Body := Req.AsJSON;
  finally
    Req.Free;
  end;

  URL := FBaseURL;
  while (URL <> '') and (URL[Length(URL)] = '/') do
    SetLength(URL, Length(URL) - 1);
  try
    R := HttpPostJSON(URL + '/api/embed', Body, FTimeoutMs);
  except
    on E: Exception do
      raise EOllamaError.CreateFmt(MSG_REQUEST_FAILED, [FBaseURL, E.Message]);
  end;

  O := ParseObject(R.Body);
  try
    RaiseIfOllamaError(O);
    if R.StatusCode <> 200 then
      raise EOllamaError.CreateFmt('Ollama returned HTTP %d', [R.StatusCode]);
    D := O.Find('embeddings');
    if (D = nil) or (D.JSONType <> jtArray) then
      raise EOllamaError.Create('Ollama response has no embeddings');

    SetLength(Result, D.Count);
    for I := 0 to D.Count - 1 do
    begin
      Row := D.Items[I];
      if Row.JSONType <> jtArray then
        raise EOllamaError.Create('Embedding is not an array');
      SetLength(Result[I], Row.Count);
      for J := 0 to Row.Count - 1 do
        Result[I][J] := Row.Items[J].AsFloat;
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
