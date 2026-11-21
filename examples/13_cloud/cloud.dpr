program cloud;

{ Example 13: use a cloud or self-hosted OpenAI-compatible Chat Completions
  API through the same TLLMProvider interface used by the Ollama examples.

  Required:
    PASAI_CLOUD_API_KEY   API key; leave unset for a local server without auth
  Optional:
    PASAI_CLOUD_MODEL     defaults to gpt-4o-mini
    PASAI_CLOUD_BASE_URL  defaults to https://api.openai.com/v1

  Run: ./bin/cloud }

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
end;

var
  Client: TOpenAIClient;
  ApiKey, Model, BaseURL: string;
  Messages: TChatMessages;
begin
  InitConsole;

  ApiKey := GetEnvironmentVariable('PASAI_CLOUD_API_KEY');
  Model := EnvOrDefault('PASAI_CLOUD_MODEL', 'gpt-4o-mini');
  BaseURL := EnvOrDefault('PASAI_CLOUD_BASE_URL', OPENAI_DEFAULT_URL);

  Client := TOpenAIClient.Create(Model, ApiKey, BaseURL);
  try
    Writeln('Provider: ', Client.Name);
    Writeln('Model: ', Client.Model);
    Writeln('Endpoint: ', BaseURL);
    Writeln;
    Messages := nil;
    AddMessage(Messages, ROLE_USER,
      'Explain why a provider abstraction is useful in one short paragraph.');
    Client.ChatStream(Messages, PrintChunk);
    Writeln;
  finally
    Client.Free;
  end;
end.
