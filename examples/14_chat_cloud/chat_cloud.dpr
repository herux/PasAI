program chat_cloud;

{ Example 14: interactive chat with history through a cloud or self-hosted
  OpenAI-compatible Chat Completions API.

  Conversation memory is the TChatMessages history sent again on every turn.
  Use /reset to discard it and start a fresh conversation.

  Required:
    PASAI_CLOUD_API_KEY   API key; leave unset for a local server without auth
  Optional:
    PASAI_CLOUD_MODEL     defaults to gpt-4o-mini
    PASAI_CLOUD_BASE_URL  defaults to https://api.openai.com/v1

  Run: ./bin/chat_cloud [model-name] }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils,
  PasAI.Types, PasAI.OpenAI;

function EnvOrDefault(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

procedure PrintChunk(const AText: string);
begin
  Write(AText);
  Flush(Output);
end;

var
  Client: TOpenAIClient;
  History: TChatMessages;
  ApiKey, Model, BaseURL, Line, Reply: string;
begin
  InitConsole;

  ApiKey := GetEnvironmentVariable('PASAI_CLOUD_API_KEY');
  Model := EnvOrDefault('PASAI_CLOUD_MODEL', 'gpt-4o-mini');
  BaseURL := EnvOrDefault('PASAI_CLOUD_BASE_URL', OPENAI_DEFAULT_URL);
  if ParamCount > 0 then
    Model := ParamStr(1);

  Client := TOpenAIClient.Create(Model, ApiKey, BaseURL);
  try
    History := nil;
    AddMessage(History, ROLE_SYSTEM,
      'You are a helpful assistant running inside a chat client built with PasAI. ' +
      'Keep answers concise. Always reply in the language the user writes in.');

    Writeln('Chatting with ', Client.Model, ' through ', Client.Name, '.');
    Writeln('Endpoint: ', Client.BaseURL);
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
        SetLength(History, 1);
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
          SetLength(History, Length(History) - 1);
        end;
      end;
    end;
  finally
    Client.Free;
  end;
end.