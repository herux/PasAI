unit PasAI.Structured;

(* Structured output: getting reliable JSON out of a language model.

  A model produces text. Even when asked for JSON, and even with
  constrained decoding, it can still return something unusable: prose
  around the JSON, markdown code fences, a missing field, a value outside
  the allowed set. ChatStructured handles this in three steps:

  1. Extract  - cut the JSON object out of the reply text.
  2. Validate - check it against the JSON schema; collect every problem.
  3. Retry    - if invalid, show the model its own reply plus the list of
                problems and ask again ("retry with feedback").

  Supported JSON Schema subset (enough for most extraction tasks):
    type        "object" "array" "string" "number" "integer" "boolean" "null",
                or an array of these, e.g. ["string", "null"]
    properties  per-property schemas of an object
    required    property names that must be present
    items       schema for every element of an array
    enum        list of allowed values
  Other keywords are ignored. *)

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, PasAI.Types, PasAI.Provider;

type
  EStructuredOutputError = class(EPasAIError);

  { Called after every attempt. AErrors is empty when the reply was valid. }
  TAttemptProc = procedure(AAttempt: Integer; const ARawReply: string;
    AErrors: TStrings);

{ Return the substring from the first opening brace to the last closing
  brace, which removes code fences and any prose around the object.
  Returns the trimmed text unchanged if no braces are found. }
function ExtractJSONText(const AText: string): string;

{ Validate AValue against ASchema and add one human-readable line per
  problem to AErrors. Paths look like $.items[2].name }
procedure ValidateJSON(AValue: TJSONData; ASchema: TJSONObject; AErrors: TStrings);

{ Ask AProvider for a JSON object matching ASchema, validating the reply and
  retrying with feedback up to AMaxAttempts times. Returns the validated
  object, which the caller must free. Raises EStructuredOutputError if no
  attempt produced a valid object. }
function ChatStructured(AProvider: TLLMProvider; const AMessages: TChatMessages;
  const ASchema: UTF8String; AMaxAttempts: Integer = 3;
  AOnAttempt: TAttemptProc = nil): TJSONObject;

implementation

function ExtractJSONText(const AText: string): string;
var
  S: string;
  First, Last: Integer;
begin
  S := Trim(AText);
  First := Pos('{', S);
  Last := LastDelimiter('}', S);
  if (First > 0) and (Last > First) then
    Result := Copy(S, First, Last - First + 1)
  else
    Result := S;
end;

{ Validation }

function JSONTypeName(AValue: TJSONData): string;
begin
  case AValue.JSONType of
    jtObject:  Result := 'object';
    jtArray:   Result := 'array';
    jtString:  Result := 'string';
    jtNumber:  Result := 'number';
    jtBoolean: Result := 'boolean';
    jtNull:    Result := 'null';
  else
    Result := 'unknown';
  end;
end;

function MatchesType(AValue: TJSONData; const AType: string): Boolean;
begin
  if AType = 'integer' then
  begin
    { JSON Schema treats 3.0 as an integer too. }
    Result := (AValue.JSONType = jtNumber) and
      ((TJSONNumber(AValue).NumberType <> ntFloat) or (Frac(AValue.AsFloat) = 0));
  end
  else
    Result := JSONTypeName(AValue) = AType;
end;

{ "type" can be a single name or an array of names. }
function MatchesTypeSpec(AValue: TJSONData; ATypeSpec: TJSONData;
  out ADescription: string): Boolean;
var
  I: Integer;
begin
  if ATypeSpec.JSONType = jtArray then
  begin
    ADescription := '';
    Result := False;
    for I := 0 to ATypeSpec.Count - 1 do
    begin
      if ADescription <> '' then
        ADescription := ADescription + ' or ';
      ADescription := ADescription + ATypeSpec.Items[I].AsString;
      if MatchesType(AValue, ATypeSpec.Items[I].AsString) then
        Result := True;
    end;
  end
  else
  begin
    ADescription := ATypeSpec.AsString;
    Result := MatchesType(AValue, ADescription);
  end;
end;

procedure ValidateAt(AValue: TJSONData; ASchema: TJSONObject;
  const APath: string; AErrors: TStrings);
var
  Spec, Child: TJSONData;
  Props: TJSONObject;
  Required, Allowed: TJSONArray;
  Expected, Name, AllowedList: string;
  I: Integer;
  Found: Boolean;
begin
  { type: stop here on mismatch, further checks would only add noise }
  Spec := ASchema.Find('type');
  if (Spec <> nil) and not MatchesTypeSpec(AValue, Spec, Expected) then
  begin
    AErrors.Add(Format('%s: expected %s, got %s',
      [APath, Expected, JSONTypeName(AValue)]));
    Exit;
  end;

  { enum: compare by JSON text, so "1" and 1 are different values }
  Spec := ASchema.Find('enum');
  if (Spec <> nil) and (Spec.JSONType = jtArray) then
  begin
    Allowed := TJSONArray(Spec);
    Found := False;
    AllowedList := '';
    for I := 0 to Allowed.Count - 1 do
    begin
      if Allowed.Items[I].AsJSON = AValue.AsJSON then
        Found := True;
      if AllowedList <> '' then
        AllowedList := AllowedList + ', ';
      AllowedList := AllowedList + Allowed.Items[I].AsJSON;
    end;
    if not Found then
      AErrors.Add(Format('%s: value %s is not one of: %s',
        [APath, AValue.AsJSON, AllowedList]));
  end;

  if AValue.JSONType = jtObject then
  begin
    Spec := ASchema.Find('required');
    if (Spec <> nil) and (Spec.JSONType = jtArray) then
    begin
      Required := TJSONArray(Spec);
      for I := 0 to Required.Count - 1 do
        if TJSONObject(AValue).Find(Required.Items[I].AsString) = nil then
          AErrors.Add(Format('%s: missing required property "%s"',
            [APath, Required.Items[I].AsString]));
    end;

    Spec := ASchema.Find('properties');
    if (Spec <> nil) and (Spec.JSONType = jtObject) then
    begin
      Props := TJSONObject(Spec);
      for I := 0 to Props.Count - 1 do
      begin
        Name := Props.Names[I];
        Child := TJSONObject(AValue).Find(Name);
        if (Child <> nil) and (Props.Items[I].JSONType = jtObject) then
          ValidateAt(Child, TJSONObject(Props.Items[I]), APath + '.' + Name, AErrors);
      end;
    end;
  end;

  if AValue.JSONType = jtArray then
  begin
    Spec := ASchema.Find('items');
    if (Spec <> nil) and (Spec.JSONType = jtObject) then
      for I := 0 to AValue.Count - 1 do
        ValidateAt(AValue.Items[I], TJSONObject(Spec),
          Format('%s[%d]', [APath, I]), AErrors);
  end;
end;

procedure ValidateJSON(AValue: TJSONData; ASchema: TJSONObject; AErrors: TStrings);
begin
  ValidateAt(AValue, ASchema, '$', AErrors);
end;

{ Retry loop }

function ParseSchema(const ASchema: UTF8String): TJSONObject;
var
  D: TJSONData;
begin
  try
    D := GetJSON(ASchema);
  except
    on E: Exception do
      raise EStructuredOutputError.Create('Schema is not valid JSON: ' + E.Message);
  end;
  if D.JSONType <> jtObject then
  begin
    D.Free;
    raise EStructuredOutputError.Create('Schema must be a JSON object');
  end;
  Result := TJSONObject(D);
end;

{ Try to turn one reply into a valid object. Returns nil and fills AErrors
  on failure. }
function TryParseReply(const AReply: string; ASchema: TJSONObject;
  AErrors: TStrings): TJSONObject;
var
  D: TJSONData;
begin
  Result := nil;
  try
    D := GetJSON(UTF8String(ExtractJSONText(AReply)));
  except
    on E: Exception do
    begin
      AErrors.Add('reply is not valid JSON: ' + E.Message);
      Exit;
    end;
  end;

  if D.JSONType <> jtObject then
  begin
    AErrors.Add('$: expected a JSON object, got ' + JSONTypeName(D));
    D.Free;
    Exit;
  end;

  ValidateJSON(D, ASchema, AErrors);
  if AErrors.Count > 0 then
    D.Free
  else
    Result := TJSONObject(D);
end;

function FeedbackMessage(AErrors: TStrings): string;
var
  I: Integer;
begin
  Result := 'Your previous reply was not valid:' + LineEnding;
  for I := 0 to AErrors.Count - 1 do
    Result := Result + '- ' + AErrors[I] + LineEnding;
  Result := Result + 'Reply again with only the corrected JSON object.';
end;

function ChatStructured(AProvider: TLLMProvider; const AMessages: TChatMessages;
  const ASchema: UTF8String; AMaxAttempts: Integer;
  AOnAttempt: TAttemptProc): TJSONObject;
var
  Schema: TJSONObject;
  Msgs: TChatMessages;
  Errors: TStringList;
  Reply: string;
  Attempt: Integer;
begin
  Result := nil;
  if AMaxAttempts < 1 then
    AMaxAttempts := 1;

  Schema := ParseSchema(ASchema);
  Errors := TStringList.Create;
  try
    Msgs := Copy(AMessages);
    for Attempt := 1 to AMaxAttempts do
    begin
      Errors.Clear;
      Reply := AProvider.ChatJSON(Msgs, ASchema);
      Result := TryParseReply(Reply, Schema, Errors);

      if Assigned(AOnAttempt) then
        AOnAttempt(Attempt, Reply, Errors);
      if Result <> nil then
        Exit;

      { Show the model what it said and what was wrong with it. }
      AddMessage(Msgs, ROLE_ASSISTANT, Reply);
      AddMessage(Msgs, ROLE_USER, FeedbackMessage(Errors));
    end;

    raise EStructuredOutputError.CreateFmt(
      'No valid reply after %d attempt(s). Last problems: %s',
      [AMaxAttempts, StringReplace(Trim(Errors.Text), LineEnding, '; ', [rfReplaceAll])]);
  finally
    Errors.Free;
    Schema.Free;
  end;
end;

end.
