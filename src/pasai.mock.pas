unit PasAI.Mock;

{ A fake provider for tests and offline development.

  TMockProvider returns scripted replies in order and records every request
  it receives. This makes two things possible without a running model:

  1. Deterministic tests. Real LLMs answer differently each time, so code
     that reacts to model output (parsers, agent loops, routers) is tested
     against fixed replies instead.
  2. Inspecting prompts. LastMessages shows exactly what would have been
     sent to the model, so prompt-building code can be checked directly. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, PasAI.Types, PasAI.Provider;

type
  TMockProvider = class(TLLMProvider)
  private
    FReplies: array of string;
    FNextReply: Integer;
    FCallCount: Integer;
    FLastMessages: TChatMessages;
  public
    constructor Create;

    { Queue a reply. Replies are returned in the order they were added. }
    procedure AddReply(const AText: string);

    function Name: string; override;

    { Returns the next queued reply. Raises EPasAIError when none are left,
      so a test fails loudly instead of silently getting an empty string. }
    function Chat(const AMessages: TChatMessages): string; override;

    property CallCount: Integer read FCallCount;
    property LastMessages: TChatMessages read FLastMessages;
  end;

implementation

constructor TMockProvider.Create;
begin
  inherited Create('mock');
end;

procedure TMockProvider.AddReply(const AText: string);
var
  N: Integer;
begin
  N := Length(FReplies);
  SetLength(FReplies, N + 1);
  FReplies[N] := AText;
end;

function TMockProvider.Name: string;
begin
  Result := 'mock';
end;

function TMockProvider.Chat(const AMessages: TChatMessages): string;
begin
  Inc(FCallCount);
  FLastMessages := Copy(AMessages);   // keep our own copy of the request
  if FNextReply > High(FReplies) then
    raise EPasAIError.CreateFmt(
      'TMockProvider: no reply queued for call #%d', [FCallCount]);
  Result := FReplies[FNextReply];
  Inc(FNextReply);
end;

end.
