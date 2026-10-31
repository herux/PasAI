unit PasAI.Guardrails;

{ Guardrails: checks around the model, on the way in and on the way out.

  A prompt asks the model to behave; a guardrail verifies that it did. The
  RAG example showed why both are needed: told to answer in the language of
  the question, the model still answered an Indonesian question in Chinese.

  Input side, before the model sees a message:
  - a fixed list of crisis phrases, checked first, deterministic and
    impossible to talk around;
  - a classifier (structured output) that sorts the message into normal,
    out of scope, regulated advice, crisis, or a request for a human.

  Output side, before the member sees a reply:
  - the reply must be in the same language as the member's message;
  - the reply must not contain forbidden phrases.

  These are layers, and each is imperfect: phrase lists miss rewordings,
  classifiers make mistakes. Used together, and backed by a human handover,
  they make failures rarer and visible. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Provider;

type
  TInputCategory = (icNormal, icOutOfScope, icRegulatedAdvice, icCrisis, icHumanRequest);

  TInputVerdict = record
    Category: TInputCategory;
    Reason: string;
    ByPhrase: Boolean;   // decided by the phrase list, without the classifier
  end;

const
  INPUT_CATEGORY_NAMES: array[TInputCategory] of string =
    ('normal', 'out_of_scope', 'regulated_advice', 'crisis', 'human_request');

  { Phrases separated by "|", matched case-insensitively. Deliberately
    short and high-precision; the classifier covers other wordings. }
  CRISIS_PHRASES =
    'bunuh diri|ingin mati|mau mati|mengakhiri hidup|tidak ingin hidup lagi|' +
    'suicide|kill myself|end my life|want to die';

{ "id", "en", "cjk" (Chinese, Japanese or Korean characters) or "unknown".
  Indonesian and English are told apart by counting their stop words, which
  is crude but reliable for whole sentences. }
function DetectLanguage(const AText: string): string;

{ False, with a reason in AProblem, when the reply is in a different
  language than the question. Short or ambiguous texts pass. }
function CheckReplyLanguage(const AQuestion, AReply: string; out AProblem: string): Boolean;

{ The first phrase of APhrases ("|" separated) found in AText, or ''. }
function FindPhrase(const AText, APhrases: string): string;

{ Classify a member message. AScope describes what the assistant is for,
  e.g. "personal budgeting and saving habits". Crisis phrases are checked
  before the classifier. If the classifier itself fails, the message is
  treated as normal: crisis detection by phrase has already run, and
  blocking every message on a classifier error would make the assistant
  unusable. }
function ClassifyInput(AProvider: TLLMProvider; const AText, AScope: string): TInputVerdict;

implementation

uses
  fpjson, PasAI.BM25, PasAI.Schema, PasAI.Structured;

function CountCJK(const AText: string): Integer;
var
  I: Integer;
  B: Byte;
begin
  { In UTF-8, CJK ideographs, kana and hangul start with lead bytes E3..ED.
    E2 is skipped: it starts common punctuation such as dashes and quotes. }
  Result := 0;
  for I := 1 to Length(AText) do
  begin
    B := Ord(AText[I]);
    if (B >= $E3) and (B <= $ED) then
      Inc(Result);
  end;
end;

function NewWordSet(const AWords: string): TStringList;
var
  Tokens: TTokens;
  I: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Tokens := Tokenize(AWords);
  for I := 0 to High(Tokens) do
    Result.Add(Tokens[I]);
end;

function DetectLanguage(const AText: string): string;
var
  Tokens: TTokens;
  Id, En: TStringList;
  I, IdCount, EnCount: Integer;
begin
  if CountCJK(AText) >= 2 then
    Exit('cjk');

  Id := NewWordSet(STOP_WORDS_ID);
  En := NewWordSet(STOP_WORDS_EN);
  try
    IdCount := 0;
    EnCount := 0;
    Tokens := Tokenize(AText);
    for I := 0 to High(Tokens) do
    begin
      if Id.IndexOf(Tokens[I]) >= 0 then
        Inc(IdCount);
      if En.IndexOf(Tokens[I]) >= 0 then
        Inc(EnCount);
    end;
  finally
    En.Free;
    Id.Free;
  end;

  if IdCount > EnCount then
    Result := 'id'
  else if EnCount > IdCount then
    Result := 'en'
  else
    Result := 'unknown';
end;

function LanguageName(const ACode: string): string;
begin
  if ACode = 'id' then
    Result := 'Indonesian'
  else if ACode = 'en' then
    Result := 'English'
  else if ACode = 'cjk' then
    Result := 'Chinese, Japanese or Korean'
  else
    Result := 'an unknown language';
end;

function CheckReplyLanguage(const AQuestion, AReply: string; out AProblem: string): Boolean;
var
  Q, R: string;
begin
  AProblem := '';
  Q := DetectLanguage(AQuestion);
  R := DetectLanguage(AReply);

  if (R = 'cjk') and (Q <> 'cjk') then
    Result := False
  else if ((Q = 'id') or (Q = 'en')) and ((R = 'id') or (R = 'en')) and (Q <> R) then
    Result := False
  else
    Result := True;

  if not Result then
  begin
    if (Q = 'id') or (Q = 'en') then
      AProblem := Format('the reply must be written in %s, but it was written in %s',
        [LanguageName(Q), LanguageName(R)])
    else
      AProblem := Format('the reply must be in the language of the member''s message, ' +
        'but it was written in %s', [LanguageName(R)]);
  end;
end;

function FindPhrase(const AText, APhrases: string): string;
var
  List: TStringList;
  Lower: string;
  I: Integer;
begin
  Result := '';
  Lower := LowerCase(AText);
  List := TStringList.Create;
  try
    List.Delimiter := '|';
    List.StrictDelimiter := True;
    List.DelimitedText := APhrases;
    for I := 0 to List.Count - 1 do
      if (Trim(List[I]) <> '') and (Pos(LowerCase(Trim(List[I])), Lower) > 0) then
        Exit(Trim(List[I]));
  finally
    List.Free;
  end;
end;

function ClassifyInput(AProvider: TLLMProvider; const AText, AScope: string): TInputVerdict;
var
  Phrase, Category: string;
  Msgs: TChatMessages;
  Obj: TJSONObject;
  C: TInputCategory;
begin
  Result.Category := icNormal;
  Result.Reason := '';
  Result.ByPhrase := False;

  Phrase := FindPhrase(AText, CRISIS_PHRASES);
  if Phrase <> '' then
  begin
    Result.Category := icCrisis;
    Result.Reason := 'crisis phrase "' + Phrase + '"';
    Result.ByPhrase := True;
    Exit;
  end;

  Msgs := nil;
  AddMessage(Msgs, ROLE_SYSTEM,
    'You classify messages sent to a coaching assistant for ' + AScope + '. ' +
    'Choose exactly one category:' + LineEnding +
    '- crisis: mentions self-harm, suicide, being in danger, or a mental health emergency.' + LineEnding +
    '- human_request: asks to talk to a human, a person, or a real coach.' + LineEnding +
    '- regulated_advice: asks which investment, stock, crypto, insurance or loan to choose, ' +
    'or asks for tax or legal advice.' + LineEnding +
    '- out_of_scope: clearly unrelated to ' + AScope + '.' + LineEnding +
    '- normal: anything else, including greetings, small talk, and sharing feelings ' +
    'about money.' + LineEnding +
    'Classify only. Do not answer the message.');
  AddMessage(Msgs, ROLE_USER, AText);

  try
    Obj := ChatStructured(AProvider, Msgs,
      ObjectSchema
        .Enum('category', ['normal', 'out_of_scope', 'regulated_advice', 'crisis', 'human_request'])
        .Str('reason', 'A few words explaining the choice')
        .ToJSON, 2);
  except
    on E: EPasAIError do
    begin
      Result.Reason := 'classifier failed, treated as normal: ' + E.Message;
      Exit;
    end;
  end;

  try
    Category := Obj.Strings['category'];
    Result.Reason := Obj.Strings['reason'];
    for C := Low(TInputCategory) to High(TInputCategory) do
      if INPUT_CATEGORY_NAMES[C] = Category then
        Result.Category := C;
  finally
    Obj.Free;
  end;
end;

end.
