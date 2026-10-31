unit PasAI.Provider;

{ The abstract base class for every LLM backend.

  Everything above this layer (agents, RAG, memory, evals) talks to a
  TLLMProvider and never to a concrete backend. Swapping Ollama for another
  provider, or for a mock in tests, then requires no changes to that code.

  Why an abstract class and not an interface: Pascal interfaces are
  reference counted, which mixes poorly with manual Free and behaves
  slightly differently between FPC and Delphi. A plain class keeps
  ownership explicit: whoever creates the provider frees it. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, PasAI.Types;

type
  TLLMProvider = class
  private
    FModel: string;
    FTemperature: Double;
  public
    constructor Create(const AModel: string);

    { Short identifier of the backend, e.g. 'ollama'. Useful in logs and
      when comparing providers in evals. }
    function Name: string; virtual; abstract;

    { Send the whole conversation and wait for the complete reply. }
    function Chat(const AMessages: TChatMessages): string; virtual; abstract;

    { Like Chat, but AOnChunk is called for each piece of text as it
      arrives. Returns the complete reply at the end.

      The default implementation calls Chat and delivers the reply as a
      single chunk, so a backend without streaming still works everywhere
      streaming is used. Backends that can stream override this. }
    function ChatStream(const AMessages: TChatMessages;
      AOnChunk: TTextChunkProc): string; virtual;

    { Shortcut: a single question with no history. }
    function Ask(const APrompt: string): string;

    property Model: string read FModel write FModel;
    { A value < 0 means use the backend's default. }
    property Temperature: Double read FTemperature write FTemperature;
  end;

implementation

constructor TLLMProvider.Create(const AModel: string);
begin
  inherited Create;
  FModel := AModel;
  FTemperature := -1;
end;

function TLLMProvider.ChatStream(const AMessages: TChatMessages;
  AOnChunk: TTextChunkProc): string;
begin
  Result := Chat(AMessages);
  if (Result <> '') and Assigned(AOnChunk) then
    AOnChunk(Result);
end;

function TLLMProvider.Ask(const APrompt: string): string;
var
  Msgs: TChatMessages;
begin
  Msgs := nil;
  AddMessage(Msgs, ROLE_USER, APrompt);
  Result := Chat(Msgs);
end;

end.
