unit PasAI.OpenAI;

(* Provider for the OpenAI Chat Completions API and compatible servers.

  The wire format implemented here is deliberately the common subset:
    POST {BaseURL}/chat/completions
    - complete JSON response, or Server-Sent Events when streaming
    - messages, JSON-schema response format, and function tools
    - bearer authentication (optional for self-hosted compatible servers)

  PasAI does not need a separate provider for every cloud that accepts this
  format. Applications still depend on TLLMProvider, while BaseURL, Model,
  ApiKey and ExtraHeaders select the concrete service.

  SSE is transported through PasAI.Http's line sink. Each "data:" line holds
  one JSON object; the final "data: [DONE]" line marks completion. *)

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Provider, PasAI.Http;

const
  OPENAI_DEFAULT_URL = 'https://api.openai.com/v1';
  OPENAI_DEFAULT_TIMEOUT_MS = 300000;

type
  EOpenAIError = class(EPasAIError);

  TOpenAIClient = class(TLLMProvider)
  private
    FBaseURL: string;
    FApiKey: string;
    FTimeoutMs: Integer;
    FStrictJsonSchema: Boolean;
    FExtraHeaders: THttpHeaders;
    function Endpoint(const APath: string): string;
    function RequestHeaders: THttpHeaders;
    function BuildChatBody(const AMessages: TChatMessages; AStream: Boolean;
      const ASchema: UTF8String; const ATools: TToolSpecs): string;
    function DoChat(const AMessages: TChatMessages;
      const ASchema: UTF8String; const ATools: TToolSpecs): TChatMessage;
  public
    constructor Create(const AModel, AApiKey: string;
      const ABaseURL: string = OPENAI_DEFAULT_URL);

    function Name: string; override;
    function Chat(const AMessages: TChatMessages): string; override;
    function ChatStream(const AMessages: TChatMessages;
      AOnChunk: TTextChunkProc): string; override;
    function ChatJSON(const AMessages: TChatMessages;
      const ASchema: UTF8String): string; override;
    function ChatWithTools(const AMessages: TChatMessages;
      const ATools: TToolSpecs): TChatMessage; override;

    property BaseURL: string read FBaseURL write FBaseURL;
    property ApiKey: string read FApiKey write FApiKey;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    { Some compatible APIs do not support strict JSON Schema. Keep the
      schema in response_format, but disable strict mode for those backends. }
    property StrictJsonSchema: Boolean read FStrictJsonSchema
      write FStrictJsonSchema;
    { Additional headers for compatible services. Authorization is generated
      from ApiKey and should not be duplicated here. }
    property ExtraHeaders: THttpHeaders read FExtraHeaders write FExtraHeaders;
  end;

implementation

uses
  PasAI.Json;

const
  MSG_REQUEST_FAILED =
    'Failed to call the OpenAI-compatible API at %s: %s. ' +
    'Check BaseURL, Model, network access and the API key.';

function TrimSlash(const AURL: string): string;
begin
  Result := AURL;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function StartsWithText(const AText, APrefix: string): Boolean;
begin
  Result := (Length(AText) >= Length(APrefix)) and
    (Copy(AText, 1, Length(APrefix)) = APrefix);
end;

procedure RaiseIfAPIError(AResponse: TJSONObject);
var
  ErrorValue, MessageValue: TJSONValue;
begin
  ErrorValue := JsonFind(AResponse, 'error');
  if ErrorValue = nil then
    Exit;
  if JsonKind(ErrorValue) = jkObject then
  begin
    MessageValue := JsonFind(TJSONObject(ErrorValue), 'message');
    if (MessageValue <> nil) and (JsonKind(MessageValue) = jkString) then
      raise EOpenAIError.Create('OpenAI-compatible API: ' + JsonAsString(MessageValue));
  end;
  raise EOpenAIError.Create('OpenAI-compatible API returned an error: ' +
    JsonToText(ErrorValue));
end;

function ParseResponse(const AText: string): TJSONObject;
begin
  try
    Result := ParseJsonObject(AText);
  except
    on E: EPasAIError do
      raise EOpenAIError.Create('Unexpected response from OpenAI-compatible API: ' +
        Copy(AText, 1, 200));
  end;
end;

function MessageFromJSON(AMessage: TJSONObject): TChatMessage;
var
  D, CallsValue, Call, Fn, Args: TJSONValue;
  I: Integer;
begin
  Result := ChatMessage(ROLE_ASSISTANT, '');
  D := JsonFind(AMessage, 'content');
  if (D <> nil) and (JsonKind(D) = jkString) then
    Result.Content := JsonAsString(D);

  CallsValue := JsonFind(AMessage, 'tool_calls');
  if (CallsValue = nil) or (JsonKind(CallsValue) <> jkArray) then
    Exit;

  SetLength(Result.ToolCalls, JsonCount(CallsValue));
  for I := 0 to JsonCount(CallsValue) - 1 do
  begin
    Result.ToolCalls[I].Id := '';
    Result.ToolCalls[I].Name := '';
    Result.ToolCalls[I].Arguments := '{}';
    Call := JsonItem(CallsValue, I);
    if JsonKind(Call) <> jkObject then
      Continue;
    Result.ToolCalls[I].Id := JsonStringOr(TJSONObject(Call), 'id', '');
    Fn := JsonFind(TJSONObject(Call), 'function');
    if (Fn = nil) or (JsonKind(Fn) <> jkObject) then
      Continue;
    Result.ToolCalls[I].Name :=
      JsonStringOr(TJSONObject(Fn), 'name', '');
    Args := JsonFind(TJSONObject(Fn), 'arguments');
    if Args <> nil then
      if JsonKind(Args) = jkString then
        Result.ToolCalls[I].Arguments := JsonAsString(Args)
      else
        Result.ToolCalls[I].Arguments := JsonToText(Args);
  end;
end;

function MessageToJSON(const AMessage: TChatMessage): TJSONObject;
var
  Calls: TJSONArray;
  Call, Fn: TJSONObject;
  I: Integer;
begin
  Result := JsonNewObject;
  try
    JsonAddString(Result, 'role', AMessage.Role);
    JsonAddString(Result, 'content', AMessage.Content);

    if Length(AMessage.ToolCalls) > 0 then
    begin
      Calls := JsonNewArray;
      JsonAddValue(Result, 'tool_calls', Calls);
      for I := 0 to High(AMessage.ToolCalls) do
      begin
        Call := JsonNewObject;
        JsonArrayAdd(Calls, Call);
        JsonAddString(Call, 'type', 'function');
        if AMessage.ToolCalls[I].Id <> '' then
          JsonAddString(Call, 'id', AMessage.ToolCalls[I].Id);
        Fn := JsonNewObject;
        JsonAddValue(Call, 'function', Fn);
        JsonAddString(Fn, 'name', AMessage.ToolCalls[I].Name);
        JsonAddString(Fn, 'arguments', AMessage.ToolCalls[I].Arguments);
      end;
    end;

    if AMessage.ToolCallId <> '' then
      JsonAddString(Result, 'tool_call_id', AMessage.ToolCallId);
  except
    Result.Free;
    raise;
  end;
end;

type
  TOpenAIStreamState = class
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

constructor TOpenAIStreamState.Create(AOnChunk: TTextChunkProc);
begin
  inherited Create;
  FOnChunk := AOnChunk;
end;

procedure TOpenAIStreamState.HandleLine(const ALine: string);
var
  Data: string;
  O: TJSONObject;
  Choices, Content, FinishReason: TJSONValue;
  Choice: TJSONValue;
begin
  if FDone or (Trim(ALine) = '') or StartsWithText(ALine, ':') then
    Exit;

  if StartsWithText(ALine, 'data:') then
    Data := Trim(Copy(ALine, 6, Length(ALine)))
  else
    { HTTP error bodies are often formatted JSON, so a line is not guaranteed
      to be a complete SSE event. The caller reports the non-2xx status. }
    Exit;

  if Data = '[DONE]' then
  begin
    FDone := True;
    Exit;
  end;

  O := ParseResponse(Data);
  try
    RaiseIfAPIError(O);
    Choices := JsonFind(O, 'choices');
    if (Choices = nil) or (JsonKind(Choices) <> jkArray) or
      (JsonCount(Choices) = 0) then
      Exit;
    Choice := JsonItem(Choices, 0);
    if JsonKind(Choice) <> jkObject then
      Exit;

    Content := JsonFindPath(Choice, 'delta.content');
    if (Content <> nil) and (JsonKind(Content) = jkString) and
      (JsonAsString(Content) <> '') then
    begin
      FFullText := FFullText + JsonAsString(Content);
      if Assigned(FOnChunk) then
        FOnChunk(JsonAsString(Content));
    end;

    FinishReason := JsonFind(TJSONObject(Choice), 'finish_reason');
    if (FinishReason <> nil) and (JsonKind(FinishReason) = jkString) then
      FDone := True;
  finally
    O.Free;
  end;
end;

constructor TOpenAIClient.Create(const AModel, AApiKey, ABaseURL: string);
begin
  inherited Create(AModel);
  FBaseURL := ABaseURL;
  FApiKey := AApiKey;
  FTimeoutMs := OPENAI_DEFAULT_TIMEOUT_MS;
  FStrictJsonSchema := False;
  FExtraHeaders := nil;
end;

function TOpenAIClient.Name: string;
begin
  Result := 'openai-compatible';
end;

function TOpenAIClient.Endpoint(const APath: string): string;
begin
  Result := TrimSlash(FBaseURL) + APath;
end;

function TOpenAIClient.RequestHeaders: THttpHeaders;
var
  Offset, I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(FExtraHeaders));
  for I := 0 to High(FExtraHeaders) do
    Result[I] := FExtraHeaders[I];

  if FApiKey <> '' then
  begin
    Offset := Length(Result);
    SetLength(Result, Offset + 1);
    Result[Offset].Name := 'Authorization';
    Result[Offset].Value := 'Bearer ' + FApiKey;
  end;
end;

function TOpenAIClient.BuildChatBody(const AMessages: TChatMessages;
  AStream: Boolean; const ASchema: UTF8String;
  const ATools: TToolSpecs): string;
var
  Req, ResponseFormat, JsonSchema, Tool, Fn: TJSONObject;
  Messages, Tools: TJSONArray;
  I: Integer;
begin
  Req := JsonNewObject;
  try
    JsonAddString(Req, 'model', Model);
    JsonAddBool(Req, 'stream', AStream);
    if Temperature >= 0 then
      JsonAddFloat(Req, 'temperature', Temperature);

    Messages := JsonNewArray;
    JsonAddValue(Req, 'messages', Messages);
    for I := 0 to High(AMessages) do
      JsonArrayAdd(Messages, MessageToJSON(AMessages[I]));

    if Length(ATools) > 0 then
    begin
      Tools := JsonNewArray;
      JsonAddValue(Req, 'tools', Tools);
      for I := 0 to High(ATools) do
      begin
        Tool := JsonNewObject;
        JsonArrayAdd(Tools, Tool);
        JsonAddString(Tool, 'type', 'function');
        Fn := JsonNewObject;
        JsonAddValue(Tool, 'function', Fn);
        JsonAddString(Fn, 'name', ATools[I].Name);
        JsonAddString(Fn, 'description', ATools[I].Description);
        JsonAddValue(Fn, 'parameters',
          ParseJson(string(ATools[I].ParametersSchema)));
      end;
    end;

    if ASchema <> '' then
    begin
      ResponseFormat := JsonNewObject;
      JsonAddValue(Req, 'response_format', ResponseFormat);
      JsonAddString(ResponseFormat, 'type', 'json_schema');
      JsonSchema := JsonNewObject;
      JsonAddValue(ResponseFormat, 'json_schema', JsonSchema);
      JsonAddString(JsonSchema, 'name', 'pasai_response');
      JsonAddBool(JsonSchema, 'strict', FStrictJsonSchema);
      JsonAddValue(JsonSchema, 'schema', ParseJson(string(ASchema)));
    end;

    Result := JsonToText(Req);
  finally
    Req.Free;
  end;
end;

function TOpenAIClient.DoChat(const AMessages: TChatMessages;
  const ASchema: UTF8String; const ATools: TToolSpecs): TChatMessage;
var
  Body: string;
  R: THttpResult;
  O: TJSONObject;
  Choices, Choice, Message: TJSONValue;
begin
  Body := BuildChatBody(AMessages, False, ASchema, ATools);
  try
    R := HttpPostJSONWithHeaders(
      Endpoint('/chat/completions'), Body, RequestHeaders, FTimeoutMs);
  except
    on E: EOpenAIError do
      raise;
    on E: Exception do
      raise EOpenAIError.CreateFmt(MSG_REQUEST_FAILED, [FBaseURL, E.Message]);
  end;

  O := ParseResponse(R.Body);
  try
    RaiseIfAPIError(O);
    if R.StatusCode <> 200 then
      raise EOpenAIError.CreateFmt(
        'OpenAI-compatible API returned HTTP %d', [R.StatusCode]);
    Choices := JsonFind(O, 'choices');
    if (Choices = nil) or (JsonKind(Choices) <> jkArray) or
      (JsonCount(Choices) = 0) then
      raise EOpenAIError.Create('OpenAI-compatible response has no choices');
    Choice := JsonItem(Choices, 0);
    if JsonKind(Choice) <> jkObject then
      raise EOpenAIError.Create('OpenAI-compatible choice is not an object');
    Message := JsonFind(TJSONObject(Choice), 'message');
    if (Message = nil) or (JsonKind(Message) <> jkObject) then
      raise EOpenAIError.Create('OpenAI-compatible response has no message');
    Result := MessageFromJSON(TJSONObject(Message));
  finally
    O.Free;
  end;
end;

function TOpenAIClient.Chat(const AMessages: TChatMessages): string;
begin
  Result := DoChat(AMessages, '', nil).Content;
end;

function TOpenAIClient.ChatJSON(const AMessages: TChatMessages;
  const ASchema: UTF8String): string;
begin
  Result := DoChat(
    WithSchemaInstruction(AMessages, ASchema), ASchema, nil).Content;
end;

function TOpenAIClient.ChatWithTools(const AMessages: TChatMessages;
  const ATools: TToolSpecs): TChatMessage;
begin
  Result := DoChat(AMessages, '', ATools);
end;

function TOpenAIClient.ChatStream(const AMessages: TChatMessages;
  AOnChunk: TTextChunkProc): string;
var
  Body: string;
  State: TOpenAIStreamState;
  Sink: TLineSinkStream;
  Status: Integer;
begin
  Body := BuildChatBody(AMessages, True, '', nil);
  State := TOpenAIStreamState.Create(AOnChunk);
  Sink := TLineSinkStream.Create(State.HandleLine);
  try
    try
      Status := HttpPostJSONToStreamWithHeaders(
        Endpoint('/chat/completions'), Body, Sink, RequestHeaders, FTimeoutMs);
    except
      on E: EOpenAIError do
        raise;
      on E: Exception do
        raise EOpenAIError.CreateFmt(MSG_REQUEST_FAILED, [FBaseURL, E.Message]);
    end;
    Sink.Flush;
    if Status <> 200 then
      raise EOpenAIError.CreateFmt(
        'OpenAI-compatible API returned HTTP %d', [Status]);
    if not State.Done then
      raise EOpenAIError.Create('OpenAI-compatible stream ended before completion');
    Result := State.FullText;
  finally
    Sink.Free;
    State.Free;
  end;
end;

end.
