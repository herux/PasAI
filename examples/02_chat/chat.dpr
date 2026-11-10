program chat;

{ Example 2: interactive chat with history.

  Key concept: the model remembers NOTHING. Conversation "memory" is just
  the TChatMessages array we send again on every turn. Try /reset and then
  ask about something discussed earlier.

  Run:  ./bin/chat [model-name] }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils, PasAI.Types, PasAI.Ollama;

procedure PrintChunk(const AText: string);
begin
  Write(AText);
  Flush(Output);
end;

var
  Client: TOllamaClient;
  History: TChatMessages;
  Line, Reply, ModelName: string;
begin
  InitConsole;
  ModelName := 'qwen2.5:7b-instruct';
  if ParamCount > 0 then
    ModelName := ParamStr(1);

  Client := TOllamaClient.Create(ModelName);
  try
    History := nil;
    // AddMessage(History, ROLE_SYSTEM,
    //   'You are a friendly assistant. Keep answers short. ' +
    //   'Reply in the same language the user writes in.');
    AddMessage(History, ROLE_SYSTEM,
      'You are Qwen, a model made by Alibaba Cloud, running inside a chat client ' +
      'built by Heru using Free Pascal. Keep answers short. ' +
      'Always reply only in the language the user writes in.');

    Writeln('Chatting with ', ModelName, '.');
    Writeln('Commands: /reset (clear history), /history (message count), /quit');

    while True do
    begin
      Write('> ');
      Flush(Output);
      if EOF(Input) then
        Break;
      Readln(Line);
      Line := Trim(Line);

      if Line = '' then
        Continue;
      if Line = '/quit' then
        Break;
      if Line = '/reset' then
      begin
        SetLength(History, 1);   // keep only the system prompt
        Writeln('(history cleared)');
        Continue;
      end;
      if Line = '/history' then
      begin
        Writeln('(', Length(History), ' messages sent on every turn)');
        Continue;
      end;

      AddMessage(History, ROLE_USER, Line);
      try
        Reply := Client.ChatStream(History, PrintChunk);
        Writeln;
        AddMessage(History, ROLE_ASSISTANT, Reply);
      except
        on E: Exception do
        begin
          Writeln;
          Writeln('Error: ', E.Message);
          SetLength(History, Length(History) - 1);  // drop the user message that failed
        end;
      end;
    end;
  finally
    Client.Free;
  end;
end.
