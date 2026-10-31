unit PasAI.Memory;

(* Memory: what lets an assistant know a member across sessions.

  The model remembers nothing between calls (example 2 showed that). Every
  form of memory is therefore text that our code stores and puts back into
  the prompt. Three kinds are used here:

  - Facts: short key/value pairs about the member ("goal" = "save 10 million
    for a laptop by June"), extracted after every turn with structured
    output and stored in a JSON file per member. They go into the system
    prompt of every future session.
  - Session notes: a few sentences summarizing past sessions, written when
    a session ends, so the next session can follow up on commitments.
  - Rolling summary: within a long session, older messages are replaced by
    a summary so the prompt stays small (CompactHistory).

  Data minimization is part of the design: the extraction prompt forbids
  storing account numbers, ID numbers, passwords and health details. What
  is never stored cannot leak.

  File format (data/members/ID.json):
    {"id": "heru", "state": "coaching", "sessions": 3,
     "summary": "...", "facts": {"name": "Heru", "goal": "..."}} *)

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Provider;

type
  TMemberProfile = class
  private
    FId: string;
    FState: string;
    FSummary: string;
    FSessions: Integer;
    FFacts: TStringList;   // name=value, keys in snake_case
    FFileName: string;
  public
    constructor Create(const AId, AFileName: string);
    destructor Destroy; override;
    { Load ADir/AId.json, or return an empty profile if it does not exist. }
    class function Load(const ADir, AId: string): TMemberProfile;
    procedure Save;
    function HasFact(const AKey: string): Boolean;
    { The facts as "- key: value" lines, for a prompt. }
    function FactsAsText: string;
    property Id: string read FId;
    property State: string read FState write FState;
    property Summary: string read FSummary write FSummary;
    property Sessions: Integer read FSessions write FSessions;
    property Facts: TStringList read FFacts;
    property FileName: string read FFileName;
  end;

{ Extract durable facts from one exchange and merge them into AProfile.
  Adds "key=value" to AChanges for every fact that is new or changed.
  Does not save the profile. }
procedure UpdateFacts(AProvider: TLLMProvider; AProfile: TMemberProfile;
  const AMemberText, AAssistantText: string; AChanges: TStrings);

{ Short notes for the coach, merging APrevious with what happened in
  AMessages. Written in English so notes stay consistent across sessions. }
function SummarizeSession(AProvider: TLLMProvider; const AMessages: TChatMessages;
  const APrevious: string): string;

{ When AHistory holds more than AMaxMessages, summarize all but the last
  AKeep messages into ANotes and drop them. Returns True if it compacted. }
function CompactHistory(AProvider: TLLMProvider; var AHistory: TChatMessages;
  var ANotes: string; AMaxMessages, AKeep: Integer): Boolean;

implementation

uses
  fpjson, jsonparser, PasAI.Structured;

const
  FACTS_SCHEMA =
    '{"type": "object", "properties": {"facts": {"type": "array", "items": ' +
    '{"type": "object", "properties": {"key": {"type": "string"}, ' +
    '"value": {"type": "string"}}, "required": ["key", "value"]}}}, ' +
    '"required": ["facts"]}';

  FACTS_PROMPT =
    'You maintain the profile of a member of a personal finance habits ' +
    'coaching service. From the latest exchange, extract durable facts about ' +
    'the member that are worth remembering in future sessions: their name, ' +
    'goals (what, how much, by when), income or spending figures they share, ' +
    'preferences, and commitments they make. ' +
    'Use short snake_case keys, and reuse an existing key when a fact changes. ' +
    'Only record what the member said, never guesses. ' +
    'Never record account numbers, card numbers, ID numbers, passwords, or ' +
    'health information. ' +
    'Return {"facts": []} when there is nothing new.';

{ TMemberProfile }

constructor TMemberProfile.Create(const AId, AFileName: string);
begin
  inherited Create;
  FId := AId;
  FFileName := AFileName;
  FFacts := TStringList.Create;
end;

destructor TMemberProfile.Destroy;
begin
  FFacts.Free;
  inherited Destroy;
end;

function StringField(O: TJSONObject; const AName: string): string;
var
  D: TJSONData;
begin
  D := O.Find(AName);
  if (D <> nil) and (D.JSONType = jtString) then
    Result := D.AsString
  else
    Result := '';
end;

class function TMemberProfile.Load(const ADir, AId: string): TMemberProfile;
var
  FS: TFileStream;
  Root, D: TJSONData;
  Facts: TJSONObject;
  I: Integer;
begin
  Result := TMemberProfile.Create(AId, IncludeTrailingPathDelimiter(ADir) + AId + '.json');
  if not FileExists(Result.FileName) then
    Exit;

  try
    FS := TFileStream.Create(Result.FileName, fmOpenRead or fmShareDenyWrite);
    try
      Root := GetJSON(FS);
    finally
      FS.Free;
    end;
    try
      if Root.JSONType <> jtObject then
        raise EPasAIError.Create('not a JSON object');
      Result.FState := StringField(TJSONObject(Root), 'state');
      Result.FSummary := StringField(TJSONObject(Root), 'summary');
      D := TJSONObject(Root).Find('sessions');
      if (D <> nil) and (D.JSONType = jtNumber) then
        Result.FSessions := D.AsInteger;
      D := TJSONObject(Root).Find('facts');
      if (D <> nil) and (D.JSONType = jtObject) then
      begin
        Facts := TJSONObject(D);
        for I := 0 to Facts.Count - 1 do
          Result.FFacts.Values[Facts.Names[I]] := Facts.Items[I].AsString;
      end;
    finally
      Root.Free;
    end;
  except
    on E: Exception do
    begin
      Result.Free;
      raise EPasAIError.CreateFmt('Cannot read profile %s: %s',
        [IncludeTrailingPathDelimiter(ADir) + AId + '.json', E.Message]);
    end;
  end;
end;

procedure TMemberProfile.Save;
var
  O, Facts: TJSONObject;
  Text: UTF8String;
  FS: TFileStream;
  I: Integer;
begin
  O := TJSONObject.Create;
  try
    O.Add('id', UTF8String(FId));
    O.Add('state', UTF8String(FState));
    O.Add('sessions', FSessions);
    O.Add('summary', UTF8String(FSummary));
    Facts := TJSONObject.Create;
    O.Add('facts', Facts);
    for I := 0 to FFacts.Count - 1 do
      Facts.Add(UTF8String(FFacts.Names[I]), UTF8String(FFacts.ValueFromIndex[I]));
    Text := O.FormatJSON + LineEnding;
  finally
    O.Free;
  end;

  ForceDirectories(ExtractFileDir(FFileName));
  FS := TFileStream.Create(FFileName, fmCreate);
  try
    if Text <> '' then
      FS.WriteBuffer(Text[1], Length(Text));
  finally
    FS.Free;
  end;
end;

function TMemberProfile.HasFact(const AKey: string): Boolean;
begin
  Result := FFacts.IndexOfName(AKey) >= 0;
end;

function TMemberProfile.FactsAsText: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FFacts.Count - 1 do
    Result := Result + '- ' + FFacts.Names[I] + ': ' + FFacts.ValueFromIndex[I] + LineEnding;
end;

{ Facts }

function NormalizeKey(const AKey: string): string;
var
  I: Integer;
begin
  Result := LowerCase(Trim(AKey));
  for I := 1 to Length(Result) do
    if not (Result[I] in ['a'..'z', '0'..'9']) then
      Result[I] := '_';
end;

procedure UpdateFacts(AProvider: TLLMProvider; AProfile: TMemberProfile;
  const AMemberText, AAssistantText: string; AChanges: TStrings);
var
  Msgs: TChatMessages;
  Obj: TJSONObject;
  List, Item: TJSONData;
  Known, Key, Value: string;
  I: Integer;
begin
  Known := AProfile.FactsAsText;
  if Known = '' then
    Known := '(none yet)' + LineEnding;

  Msgs := nil;
  AddMessage(Msgs, ROLE_SYSTEM, FACTS_PROMPT + LineEnding + LineEnding +
    'Facts already known:' + LineEnding + Known);
  AddMessage(Msgs, ROLE_USER,
    'Member said: ' + AMemberText + LineEnding + LineEnding +
    'Coach replied: ' + AAssistantText);

  Obj := ChatStructured(AProvider, Msgs, FACTS_SCHEMA, 2);
  try
    List := Obj.Find('facts');
    if (List = nil) or (List.JSONType <> jtArray) then
      Exit;
    for I := 0 to List.Count - 1 do
    begin
      Item := List.Items[I];
      if Item.JSONType <> jtObject then
        Continue;
      Key := NormalizeKey(TJSONObject(Item).Strings['key']);
      Value := Trim(TJSONObject(Item).Strings['value']);
      if (Key = '') or (Value = '') then
        Continue;
      if AProfile.Facts.Values[Key] <> Value then
      begin
        AProfile.Facts.Values[Key] := Value;
        if AChanges <> nil then
          AChanges.Add(Key + '=' + Value);
      end;
    end;
  finally
    Obj.Free;
  end;
end;

{ Summaries }

function Transcript(const AMessages: TChatMessages): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AMessages) do
    if (AMessages[I].Role = ROLE_USER) or
       ((AMessages[I].Role = ROLE_ASSISTANT) and (AMessages[I].Content <> '')) then
    begin
      if AMessages[I].Role = ROLE_USER then
        Result := Result + 'Member: '
      else
        Result := Result + 'Coach: ';
      Result := Result + AMessages[I].Content + LineEnding;
    end;
end;

function SummarizeSession(AProvider: TLLMProvider; const AMessages: TChatMessages;
  const APrevious: string): string;
var
  Msgs: TChatMessages;
  Previous: string;
begin
  Previous := Trim(APrevious);
  if Previous = '' then
    Previous := '(none)';
  Msgs := nil;
  AddMessage(Msgs, ROLE_SYSTEM,
    'You write notes for a personal finance habits coach. Combine the previous ' +
    'notes with the new conversation into at most 5 sentences: the member''s ' +
    'situation, progress, commitments they made, and open questions to follow up. ' +
    'Write in English. Output only the notes.');
  AddMessage(Msgs, ROLE_USER,
    'Previous notes:' + LineEnding + Previous + LineEnding + LineEnding +
    'New conversation:' + LineEnding + Transcript(AMessages));
  Result := Trim(AProvider.Chat(Msgs));
end;

function CompactHistory(AProvider: TLLMProvider; var AHistory: TChatMessages;
  var ANotes: string; AMaxMessages, AKeep: Integer): Boolean;
var
  Old: TChatMessages;
  Cut: Integer;
begin
  Result := Length(AHistory) > AMaxMessages;
  if not Result then
    Exit;
  Cut := Length(AHistory) - AKeep;
  Old := Copy(AHistory, 0, Cut);
  ANotes := SummarizeSession(AProvider, Old, ANotes);
  AHistory := Copy(AHistory, Cut, AKeep);
end;

end.
