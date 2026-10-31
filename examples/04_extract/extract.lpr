program extract;

{ Example 4: structured output - turning free text into a Pascal record.

  Part 1 uses a mock whose first reply is deliberately broken, to show the
  validate-and-retry loop deterministically.
  Part 2 runs real sentences, in Indonesian and English, through Ollama.

  Run:  ./bin/extract [model-name] }

{$mode delphi}{$H+}
{$codepage utf8}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  Classes, SysUtils, fpjson,
  PasAI.Types, PasAI.Provider, PasAI.Mock, PasAI.Ollama, PasAI.Structured;

const
  { The contract between our code and the model. "day" uses an enum so
    the answer can be checked mechanically instead of trusted. }
  MEETING_SCHEMA =
    '{"type": "object",' +
    ' "properties": {' +
    '   "person": {"type": "string"},' +
    '   "day":    {"type": "string", "enum": ["monday", "tuesday", "wednesday",' +
    '              "thursday", "friday", "saturday", "sunday", "unknown"]},' +
    '   "time":   {"type": "string"},' +
    '   "topic":  {"type": "string"}' +
    ' },' +
    ' "required": ["person", "day", "time", "topic"]}';

  SYSTEM_PROMPT =
    'Extract the meeting described in the user''s message. ' +
    'Write "day" in lowercase English, or "unknown" if no day is given. ' +
    'Write "time" in 24-hour HH:MM format, or "unknown". ' +
    'Write "topic" as a short English phrase.';

type
  TMeeting = record
    Person: string;
    Day: string;
    Time: string;
    Topic: string;
  end;

{ The JSON has already been validated, so every field is present and has
  the right type. }
function MeetingFromJSON(AObj: TJSONObject): TMeeting;
begin
  Result.Person := AObj.Strings['person'];
  Result.Day := AObj.Strings['day'];
  Result.Time := AObj.Strings['time'];
  Result.Topic := AObj.Strings['topic'];
end;

procedure LogAttempt(AAttempt: Integer; const ARawReply: string; AErrors: TStrings);
var
  I: Integer;
begin
  if AErrors.Count = 0 then
    Writeln('  attempt ', AAttempt, ': valid')
  else
  begin
    Writeln('  attempt ', AAttempt, ': INVALID, raw reply was:');
    Writeln('    ', StringReplace(ARawReply, LineEnding, ' ', [rfReplaceAll]));
    for I := 0 to AErrors.Count - 1 do
      Writeln('    - ', AErrors[I]);
  end;
end;

function ExtractMeeting(AProvider: TLLMProvider; const AText: string): TMeeting;
var
  Msgs: TChatMessages;
  Obj: TJSONObject;
begin
  Msgs := nil;
  AddMessage(Msgs, ROLE_SYSTEM, SYSTEM_PROMPT);
  AddMessage(Msgs, ROLE_USER, AText);
  Obj := ChatStructured(AProvider, Msgs, MEETING_SCHEMA, 3, LogAttempt);
  try
    Result := MeetingFromJSON(Obj);
  finally
    Obj.Free;
  end;
end;

procedure PrintMeeting(const M: TMeeting);
begin
  Writeln('  person: ', M.Person);
  Writeln('  day   : ', M.Day);
  Writeln('  time  : ', M.Time);
  Writeln('  topic : ', M.Topic);
end;

procedure RunMock;
var
  Mock: TMockProvider;
  I: Integer;
begin
  Writeln('=== Part 1: mock, first reply broken on purpose ===');
  Mock := TMockProvider.Create;
  try
    { Typical small-model mistakes: code fences, a non-English day that
      is not in the enum, a missing field. }
    Mock.AddReply('```json' + LineEnding +
      '{"person": "Budi", "day": "selasa", "time": "15:00"}' + LineEnding + '```');
    Mock.AddReply('{"person": "Budi", "day": "tuesday", "time": "15:00", "topic": "budget"}');

    PrintMeeting(ExtractMeeting(Mock, 'Rapat dengan Budi Selasa depan jam 3 sore soal anggaran.'));

    Writeln;
    Writeln('  Messages sent on the retry (what the model was told):');
    for I := 0 to High(Mock.LastMessages) do
      Writeln('    [', Mock.LastMessages[I].Role, '] ',
        StringReplace(Mock.LastMessages[I].Content, LineEnding, ' | ', [rfReplaceAll]));
  finally
    Mock.Free;
  end;
  Writeln;
end;

procedure RunOllama(const AModel: string);
const
  SENTENCES: array[0..3] of string = (
    'Rapat dengan Budi Selasa depan jam 3 sore soal anggaran.',
    'Can we meet Friday at 10am, Sarah? I want to go over the hiring plan.',
    'Ingatkan saya ngobrol sama Pak Andi hari Kamis jam 09.30 tentang server baru.',
    'Lunch with Maria sometime next week to talk about the conference.'
  );
var
  Ollama: TOllamaClient;
  I: Integer;
begin
  Writeln('=== Part 2: Ollama (', AModel, ') ===');
  Ollama := TOllamaClient.Create(AModel);
  try
    Ollama.Temperature := 0;   // extraction wants consistency, not creativity
    for I := 0 to High(SENTENCES) do
    begin
      Writeln('> ', SENTENCES[I]);
      try
        PrintMeeting(ExtractMeeting(Ollama, SENTENCES[I]));
      except
        on E: Exception do
          Writeln('  Error: ', E.Message);
      end;
      Writeln;
    end;
  finally
    Ollama.Free;
  end;
end;

var
  ModelName: string;
begin
  ModelName := 'qwen2.5:7b-instruct';
  if ParamCount > 0 then
    ModelName := ParamStr(1);

  RunMock;
  RunOllama(ModelName);
end.
