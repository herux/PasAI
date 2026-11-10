program AgentDemo;   // Delphi requires this name to match the file name

{ Example 5: tool calling and the agent loop.

  Three tools, for the things small models get wrong most often when they
  try to do them "in their head": arithmetic and calendar dates.
  The tools live in examples/common/demotools.pas.

  Part 1 scripts the model with a mock, including an attempt to call a tool
  that was never registered, so every step of the loop is visible.
  Part 2 lets a real model decide which tools to use.

  Run:  ./bin/agentdemo [model-name]
  The model must support tools in Ollama; qwen2.5 and llama3.1 do. }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils,
  PasAI.Types, PasAI.Provider, PasAI.Mock, PasAI.Ollama,
  PasAI.Tools, PasAI.Agent,
  DemoTools;   // get_current_date, add_days, calculate (examples/common)

const
  SYSTEM_PROMPT =
    'You are a helpful assistant. For any arithmetic or date calculation, ' +
    'use the tools instead of calculating yourself. ' +
    'Reply in the language the user writes in.';

procedure LogEvent(AEvent: TAgentEvent; const AText: string);
begin
  case AEvent of
    aeToolCall:   Writeln('  -> call   ', AText);
    aeToolResult: Writeln('  <- result ', AText);
    aeAnswer:     ;   // printed by the caller
  end;
end;

function Ask(AProvider: TLLMProvider; ATools: TToolRegistry;
  const AQuestion: string; out AHistory: TChatMessages): string;
begin
  AHistory := nil;
  AddMessage(AHistory, ROLE_SYSTEM, SYSTEM_PROMPT);
  AddMessage(AHistory, ROLE_USER, AQuestion);
  Result := RunAgent(AProvider, ATools, AHistory, 8, LogEvent);
end;

procedure PrintHistory(const AHistory: TChatMessages);
var
  I, J: Integer;
  Line: string;
begin
  for I := 0 to High(AHistory) do
  begin
    Line := Format('  %-9s ', ['[' + AHistory[I].Role + ']']);
    for J := 0 to High(AHistory[I].ToolCalls) do
      Line := Line + 'calls ' + AHistory[I].ToolCalls[J].Name + ' ' +
        AHistory[I].ToolCalls[J].Arguments + ' ';
    if AHistory[I].ToolName <> '' then
      Line := Line + '(' + AHistory[I].ToolName + ') ';
    Writeln(Line, AHistory[I].Content);
  end;
end;

procedure RunMock(ATools: TToolRegistry);
var
  Mock: TMockProvider;
  History: TChatMessages;
  Answer: string;
begin
  Writeln('=== Part 1: scripted model (mock) ===');
  Mock := TMockProvider.Create;
  try
    Mock.AddToolCall('calculate', '{"a": 12.5, "b": 4, "op": "multiply"}');
    { A tool we never registered: Execute refuses it and tells the model. }
    Mock.AddToolCall('send_email', '{"to": "boss@example.com"}');
    Mock.AddReply('12.5 times 4 is 50. I cannot send emails.');

    { Ask first, print after: Writeln evaluates and writes its arguments
      left to right, so the label would otherwise appear before the log. }
    Answer := Ask(Mock, ATools,
      'What is 12.5 times 4? Then email the result to my boss.', History);
    Writeln('  answer: ', Answer);
    Writeln;
    Writeln('  Full history after the loop:');
    PrintHistory(History);
  finally
    Mock.Free;
  end;
  Writeln;
end;

procedure RunOllama(ATools: TToolRegistry; const AModel: string);
const
  QUESTIONS: array[0..2] of string = (
    'What is 1234.5 multiplied by 987.6, then divided by 3?',
    'Hari apa 100 hari lagi dari hari ini?',
    'Halo! Apa kabar?'
  );
var
  Ollama: TOllamaClient;
  History: TChatMessages;
  Answer: string;
  I: Integer;
begin
  Writeln('=== Part 2: Ollama (', AModel, ') ===');
  Ollama := TOllamaClient.Create(AModel);
  try
    Ollama.Temperature := 0;
    for I := 0 to High(QUESTIONS) do
    begin
      Writeln('> ', QUESTIONS[I]);
      try
        Answer := Ask(Ollama, ATools, QUESTIONS[I], History);
        Writeln('  answer: ', Answer);
      except
        on E: Exception do
          Writeln('  Error: ', E.Message);
      end;
      Writeln;
    end;
  finally
    Ollama.Free;
  end;
end;

var
  Tools: TToolRegistry;
  ModelName: string;
begin
  InitConsole;
  ModelName := 'qwen2.5:7b-instruct';
  if ParamCount > 0 then
    ModelName := ParamStr(1);

  Tools := BuildDemoTools;
  try
    RunMock(Tools);
    RunOllama(Tools, ModelName);
  finally
    Tools.Free;
  end;
end.
