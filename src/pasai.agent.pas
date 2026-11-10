unit PasAI.Agent;

{ The agent loop.

  An "agent" is less magical than it sounds. It is this loop:

    repeat
      ask the model, offering it the tools
      if the model answered in text: done
      otherwise run every tool it asked for, append the results
    until done or too many steps

  The model decides which tool to call and with what arguments; our code
  decides whether that is allowed (PasAI.Tools) and does the actual work.
  The step limit is a safety net: a confused model can otherwise keep
  calling tools forever. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  SysUtils, PasAI.Types, PasAI.Provider, PasAI.Tools;

type
  EAgentError = class(EPasAIError);

  TAgentEvent = (aeToolCall, aeToolResult, aeAnswer);

  { Called as the loop progresses, for logging or showing progress. }
  TAgentEventProc = procedure(AEvent: TAgentEvent; const AText: string);

{ Run the loop until the model gives a final text answer, and return it.
  AMessages is updated in place with every assistant message and tool
  result, so the caller can continue the conversation afterwards.
  AMaxSteps counts model calls. }
function RunAgent(AProvider: TLLMProvider; ATools: TToolRegistry;
  var AMessages: TChatMessages; AMaxSteps: Integer = 8;
  AOnEvent: TAgentEventProc = nil): string;

implementation

function RunAgent(AProvider: TLLMProvider; ATools: TToolRegistry;
  var AMessages: TChatMessages; AMaxSteps: Integer;
  AOnEvent: TAgentEventProc): string;
var
  Specs: TToolSpecs;
  Reply: TChatMessage;
  Output: string;
  Step, I: Integer;
begin
  Specs := ATools.Specs;
  for Step := 1 to AMaxSteps do
  begin
    Reply := AProvider.ChatWithTools(AMessages, Specs);
    { The assistant message goes into the history even when it only holds
      tool calls: the model must see its own request next to the results. }
    AppendMessage(AMessages, Reply);

    if Length(Reply.ToolCalls) = 0 then
    begin
      if Assigned(AOnEvent) then
        AOnEvent(aeAnswer, Reply.Content);
      Exit(Reply.Content);
    end;

    for I := 0 to High(Reply.ToolCalls) do
    begin
      if Assigned(AOnEvent) then
        AOnEvent(aeToolCall, Reply.ToolCalls[I].Name + ' ' + Reply.ToolCalls[I].Arguments);
      Output := ATools.Execute(Reply.ToolCalls[I]);
      if Assigned(AOnEvent) then
        AOnEvent(aeToolResult, Output);
      AppendMessage(AMessages, ToolResultMessage(Reply.ToolCalls[I], Output));
    end;
  end;

  raise EAgentError.CreateFmt('No final answer after %d steps', [AMaxSteps]);
end;

end.
