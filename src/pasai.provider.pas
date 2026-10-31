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
  protected
    { Returns a copy of AMessages with an instruction to answer in JSON
      matching ASchema, merged into the system message (or added as one). }
    function WithSchemaInstruction(const AMessages: TChatMessages;
      const ASchema: UTF8String): TChatMessages;
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

    { Ask for a reply that is a JSON object conforming to ASchema (a JSON
      Schema document as text). Returns the raw reply text; it is NOT
      validated here. Use ChatStructured in PasAI.Structured for parsing,
      validation and retries.

      The default implementation only describes the schema in the prompt.
      Backends that support constrained decoding (Ollama "format") override
      this to also enforce the schema while the model generates. }
    function ChatJSON(const AMessages: TChatMessages;
      const ASchema: UTF8String): string; virtual;

    { Send the conversation together with the tools the model may use.
      Returns the assistant message: either a final answer in Content, or
      one or more ToolCalls for the caller to execute. Running the tools
      and looping is the job of PasAI.Agent, not of the provider.

      The default implementation supports no tools: with an empty ATools it
      behaves like Chat, otherwise it raises. }
    function ChatWithTools(const AMessages: TChatMessages;
      const ATools: TToolSpecs): TChatMessage; virtual;

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

function TLLMProvider.WithSchemaInstruction(const AMessages: TChatMessages;
  const ASchema: UTF8String): TChatMessages;
var
  Instruction: string;
  I: Integer;
begin
  Instruction :=
    'Respond with a single JSON object that conforms to the JSON schema below. ' +
    'Output only the JSON object: no explanation, no markdown, no code fences.' +
    LineEnding + 'Schema:' + LineEnding + string(ASchema);

  if (Length(AMessages) > 0) and (AMessages[0].Role = ROLE_SYSTEM) then
  begin
    Result := Copy(AMessages);
    Result[0].Content := Result[0].Content + LineEnding + LineEnding + Instruction;
  end
  else
  begin
    SetLength(Result, Length(AMessages) + 1);
    Result[0] := ChatMessage(ROLE_SYSTEM, Instruction);
    for I := 0 to High(AMessages) do
      Result[I + 1] := AMessages[I];
  end;
end;

function TLLMProvider.ChatJSON(const AMessages: TChatMessages;
  const ASchema: UTF8String): string;
begin
  Result := Chat(WithSchemaInstruction(AMessages, ASchema));
end;

function TLLMProvider.ChatWithTools(const AMessages: TChatMessages;
  const ATools: TToolSpecs): TChatMessage;
begin
  if Length(ATools) > 0 then
    raise EPasAIError.CreateFmt('Provider "%s" does not support tool calling', [Name]);
  Result := ChatMessage(ROLE_ASSISTANT, Chat(AMessages));
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
