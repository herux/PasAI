program providers;

{ Example 3: one piece of code, any provider.

  Summarize below is written against TLLMProvider only. It runs unchanged
  against a mock (instant, deterministic, no model needed) and against
  Ollama. The mock also lets us inspect the exact prompt that was built.

  Run:  ./bin/providers [model-name] }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils, PasAI.Types, PasAI.Provider, PasAI.Mock, PasAI.Ollama;

const
  ARTICLE =
    'Free Pascal is a mature, open-source compiler for the Pascal and ' +
    'Object Pascal languages. It targets many platforms, including Linux, ' +
    'macOS, Windows and embedded systems, and is the compiler behind the ' +
    'Lazarus IDE. Its syntax is largely compatible with Delphi.';

{ Application code: knows nothing about which backend it talks to. }
function Summarize(AProvider: TLLMProvider; const AText: string;
  AOnChunk: TTextChunkProc): string;
var
  Msgs: TChatMessages;
begin
  Msgs := nil;
  AddMessage(Msgs, ROLE_SYSTEM,
    'Summarize the user''s text in exactly one short sentence.');
  AddMessage(Msgs, ROLE_USER, AText);
  Result := AProvider.ChatStream(Msgs, AOnChunk);
end;

procedure PrintChunk(const AText: string);
begin
  Write(AText);
  Flush(Output);
end;

procedure PrintMessages(const AMessages: TChatMessages);
var
  I: Integer;
begin
  for I := 0 to High(AMessages) do
    Writeln('  [', AMessages[I].Role, '] ', AMessages[I].Content);
end;

procedure RunWith(AProvider: TLLMProvider);
begin
  Writeln('--- provider: ', AProvider.Name, ' (model: ', AProvider.Model, ') ---');
  try
    Summarize(AProvider, ARTICLE, PrintChunk);
    Writeln;
  except
    on E: Exception do
      Writeln('Error: ', E.Message);
  end;
  Writeln;
end;

var
  Mock: TMockProvider;
  Ollama: TOllamaClient;
  ModelName: string;
begin
  InitConsole;
  ModelName := 'qwen2.5:7b-instruct';
  if ParamCount > 0 then
    ModelName := ParamStr(1);

  Mock := TMockProvider.Create;
  Ollama := TOllamaClient.Create(ModelName);
  try
    { 1. The mock: fixed reply, delivered as a single chunk by the
         default ChatStream implementation in TLLMProvider. }
    Mock.AddReply('Free Pascal is a cross-platform, Delphi-compatible Pascal compiler.');
    RunWith(Mock);

    Writeln('What the mock received (the prompt Summarize built):');
    PrintMessages(Mock.LastMessages);
    Writeln;

    { 2. Calling the mock again with nothing queued fails loudly. }
    RunWith(Mock);

    { 3. The same function against a real model, streamed. }
    RunWith(Ollama);
  finally
    Ollama.Free;
    Mock.Free;
  end;
end.
