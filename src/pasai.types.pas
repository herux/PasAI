unit PasAI.Types;

{ Core types shared by every PasAI unit.
  This unit intentionally depends on neither HTTP nor JSON, so the upper
  layers (agents, memory, evals) are never tied to a specific provider.
  Where JSON is needed (schemas, tool arguments) it is carried as text. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  ROLE_SYSTEM    = 'system';
  ROLE_USER      = 'user';
  ROLE_ASSISTANT = 'assistant';
  ROLE_TOOL      = 'tool';

type
  { Root of all PasAI exceptions. Catch this to handle any library error. }
  EPasAIError = class(Exception);

  { A request from the model to run one tool. }
  TToolCall = record
    Id: string;          // set by some providers; may be empty
    Name: string;
    Arguments: string;   // a JSON object, as text
  end;

  TToolCalls = array of TToolCall;

  { A single message in a conversation. LLMs are stateless: the entire
    conversation history is sent again on every API call.

    Besides plain text, a message can carry tool traffic:
    - an assistant message may contain ToolCalls (the model asks us to run tools)
    - a ROLE_TOOL message carries a tool's result back, with ToolName set }
  TChatMessage = record
    Role: string;
    Content: string;
    ToolCalls: TToolCalls;
    ToolName: string;
    ToolCallId: string;
  end;

  TChatMessages = array of TChatMessage;

  { What the model is told about a tool: its name, what it does, and the
    JSON schema of its arguments. The description matters a lot: it is the
    only thing the model reads when deciding whether to use the tool. }
  TToolSpec = record
    Name: string;
    Description: string;
    ParametersSchema: UTF8String;
  end;

  TToolSpecs = array of TToolSpec;

  { Callback for text chunks during streaming. Deliberately a plain
    procedure (not "of object") so it is easy to use from console programs.
    An "of object" variant can be added later for GUI applications. }
  TTextChunkProc = procedure(const AText: string);

function ChatMessage(const ARole, AContent: string): TChatMessage;
function ToolResultMessage(const ACall: TToolCall; const AResult: string): TChatMessage;
procedure AddMessage(var AMessages: TChatMessages; const ARole, AContent: string);
procedure AppendMessage(var AMessages: TChatMessages; const AMessage: TChatMessage);

implementation

function ChatMessage(const ARole, AContent: string): TChatMessage;
begin
  { Every field is set explicitly: a function result record is not
    guaranteed to start empty. }
  Result.Role := ARole;
  Result.Content := AContent;
  Result.ToolCalls := nil;
  Result.ToolName := '';
  Result.ToolCallId := '';
end;

function ToolResultMessage(const ACall: TToolCall; const AResult: string): TChatMessage;
begin
  Result := ChatMessage(ROLE_TOOL, AResult);
  Result.ToolName := ACall.Name;
  Result.ToolCallId := ACall.Id;
end;

procedure AppendMessage(var AMessages: TChatMessages; const AMessage: TChatMessage);
var
  N: Integer;
begin
  N := Length(AMessages);
  SetLength(AMessages, N + 1);
  AMessages[N] := AMessage;
end;

procedure AddMessage(var AMessages: TChatMessages; const ARole, AContent: string);
begin
  AppendMessage(AMessages, ChatMessage(ARole, AContent));
end;

end.
