unit PasAI.Mock;

{ A fake provider for tests and offline development.

  TMockProvider returns scripted replies in order and records every request
  it receives. This makes two things possible without a running model:

  1. Deterministic tests. Real LLMs answer differently each time, so code
     that reacts to model output (parsers, agent loops, routers) is tested
     against fixed replies instead.
  2. Inspecting prompts. LastMessages shows exactly what would have been
     sent to the model, so prompt-building code can be checked directly.

  A scripted reply is either plain text (AddReply) or a request to run a
  tool (AddToolCall), which lets agent loops be tested step by step. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  SysUtils, PasAI.Types, PasAI.Provider;

type
  TMockProvider = class(TLLMProvider)
  private
    FReplies: TChatMessages;
    FNextReply: Integer;
    FCallCount: Integer;
    FLastMessages: TChatMessages;
    FLastTools: TToolSpecs;
    function NextReply(const AMessages: TChatMessages): TChatMessage;
  public
    constructor Create;

    { Queue a plain text reply. Replies are returned in the order added. }
    procedure AddReply(const AText: string);

    (* Queue a reply in which the model asks to run one tool.
      AArguments is a JSON object as text, e.g. '{"a": 2, "b": 3}'. *)
    procedure AddToolCall(const AToolName, AArguments: string);

    function Name: string; override;

    { Returns the next queued reply. Raises EPasAIError when none are left,
      so a test fails loudly instead of silently getting an empty string. }
    function Chat(const AMessages: TChatMessages): string; override;
    function ChatWithTools(const AMessages: TChatMessages;
      const ATools: TToolSpecs): TChatMessage; override;

    property CallCount: Integer read FCallCount;
    property LastMessages: TChatMessages read FLastMessages;
    property LastTools: TToolSpecs read FLastTools;
  end;

implementation

constructor TMockProvider.Create;
begin
  inherited Create('mock');
end;

procedure TMockProvider.AddReply(const AText: string);
begin
  AddMessage(FReplies, ROLE_ASSISTANT, AText);
end;

procedure TMockProvider.AddToolCall(const AToolName, AArguments: string);
var
  Msg: TChatMessage;
begin
  Msg := ChatMessage(ROLE_ASSISTANT, '');
  SetLength(Msg.ToolCalls, 1);
  Msg.ToolCalls[0].Id := Format('call_%d', [Length(FReplies) + 1]);
  Msg.ToolCalls[0].Name := AToolName;
  Msg.ToolCalls[0].Arguments := AArguments;
  AppendMessage(FReplies, Msg);
end;

function TMockProvider.Name: string;
begin
  Result := 'mock';
end;

function TMockProvider.NextReply(const AMessages: TChatMessages): TChatMessage;
begin
  Inc(FCallCount);
  FLastMessages := Copy(AMessages);   // keep our own copy of the request
  if FNextReply > High(FReplies) then
    raise EPasAIError.CreateFmt(
      'TMockProvider: no reply queued for call #%d', [FCallCount]);
  Result := FReplies[FNextReply];
  Inc(FNextReply);
end;

function TMockProvider.Chat(const AMessages: TChatMessages): string;
begin
  FLastTools := nil;
  Result := NextReply(AMessages).Content;
end;

function TMockProvider.ChatWithTools(const AMessages: TChatMessages;
  const ATools: TToolSpecs): TChatMessage;
begin
  FLastTools := Copy(ATools);
  Result := NextReply(AMessages);
end;

end.
