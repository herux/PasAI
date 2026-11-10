program hello;

{ Example 1: calling Ollama two ways, blocking and streaming.

  Run:  ./bin/hello [model-name]
  Default model: qwen2.5:7b-instruct }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils, PasAI.Types, PasAI.Ollama;

procedure PrintChunk(const AText: string);
begin
  Write(AText);
  Flush(Output);   // show it immediately instead of waiting for the buffer to fill
end;

var
  Client: TOllamaClient;
  Msgs: TChatMessages;
  ModelName: string;
begin
  InitConsole;
  ModelName := 'qwen2.5:7b-instruct';
  if ParamCount > 0 then
    ModelName := ParamStr(1);

  Client := TOllamaClient.Create(ModelName);
  try
    try
      Writeln('=== 1. Blocking chat (wait for the full reply) ===');
      Writeln(Client.Ask('In one sentence: what is a large language model?'));
      Writeln;

      Writeln('=== 2. Streaming (text appears piece by piece) ===');
      Msgs := nil;
      AddMessage(Msgs, ROLE_SYSTEM, 'You are a concise assistant.');
      AddMessage(Msgs, ROLE_USER, 'Name 3 strengths of the Pascal language.');
      Client.ChatStream(Msgs, PrintChunk);
      Writeln;
    except
      on E: Exception do
      begin
        Writeln;
        Writeln('Error (', E.ClassName, '): ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Client.Free;
  end;
end.
