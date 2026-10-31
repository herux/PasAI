unit PasAI.Types;

{ Core types shared by every PasAI unit.
  This unit intentionally depends on neither HTTP nor JSON, so the upper
  layers (agents, memory, evals) are never tied to a specific provider. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

const
  ROLE_SYSTEM    = 'system';
  ROLE_USER      = 'user';
  ROLE_ASSISTANT = 'assistant';

type
  { Root of all PasAI exceptions. Catch this to handle any library error. }
  EPasAIError = class(Exception);

  { A single message in a conversation. LLMs are stateless: the entire
    conversation history is sent again on every API call. }
  TChatMessage = record
    Role: string;
    Content: string;
  end;

  TChatMessages = array of TChatMessage;

  { Callback for text chunks during streaming. Deliberately a plain
    procedure (not "of object") so it is easy to use from console programs.
    An "of object" variant can be added later for GUI applications. }
  TTextChunkProc = procedure(const AText: string);

function ChatMessage(const ARole, AContent: string): TChatMessage;
procedure AddMessage(var AMessages: TChatMessages; const ARole, AContent: string);

implementation

function ChatMessage(const ARole, AContent: string): TChatMessage;
begin
  Result.Role := ARole;
  Result.Content := AContent;
end;

procedure AddMessage(var AMessages: TChatMessages; const ARole, AContent: string);
var
  N: Integer;
begin
  N := Length(AMessages);
  SetLength(AMessages, N + 1);
  AMessages[N] := ChatMessage(ARole, AContent);
end;

end.
