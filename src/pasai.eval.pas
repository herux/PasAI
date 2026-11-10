unit PasAI.Eval;

(* An evaluation harness: measuring an LLM system instead of guessing.

  Change a prompt, a model or a tool description, and the only honest way
  to know whether things got better is to run the same set of cases before
  and after and compare the numbers. This unit does exactly that:

    dataset (JSON file)  ->  run every case N times per model
                         ->  check each run  ->  pass rate table + CSV

  Each case is run several times because LLM output varies between runs.
  A case that passes 2 out of 3 times is a real finding, not noise to hide.

  Checks are deterministic code, not another model judging the answer.
  They are cheap, exact and repeatable, which makes them the right first
  tool; "LLM as judge" is for qualities code cannot check.

  Dataset format:
    {"cases": [
      {"id": "math-chain",
       "input": "What is 1234.5 times 987.6, divided by 3?",
       "checks": [
         {"type": "contains_any", "values": ["406397.4", "406,397.4"]},
         {"type": "not_contains", "values": ["\"name\":"]},
         {"type": "tool_called",  "tool": "calculate", "args": {"op": "divide"}},
         {"type": "tool_not_called", "tool": "refund_order"},
         {"type": "no_tool_calls"}
       ]}
    ]}

  contains_any / not_contains compare case-insensitively (ASCII only).
  tool_called passes if any call in the run used that tool and, when "args"
  is given, has at least those arguments with those values (numbers are
  compared as numbers, so 100 equals 100.0).
  tool_not_called fails if the model asked for that tool at all, even when
  the call was refused: it measures whether the model was fooled, which
  matters even when another layer stopped the action.
  Macros in string values: $TODAY expands to today's date (YYYY-MM-DD),
  $WEEKDAY to today's day of the week in English.

  Results carry a model name and an optional variant label (for example a
  prompt version), so one run can compare models x variants. *)

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Provider;

type
  EEvalError = class(EPasAIError);

  TCheckKind = (ckContainsAny, ckNotContains, ckToolCalled, ckToolNotCalled, ckNoToolCalls);

  TEvalCheck = record
    Kind: TCheckKind;
    Values: array of string;   // contains_any, not_contains
    ToolName: string;          // tool_called, tool_not_called
    ToolArgs: string;          // tool_called: expected arguments as a JSON object, or ''
  end;

  TEvalCase = record
    Id: string;
    Input: string;
    Checks: array of TEvalCheck;
  end;

  TEvalCases = array of TEvalCase;

  TEvalResult = record
    Model: string;
    Variant: string;      // e.g. a prompt version; may be empty
    CaseId: string;
    Run: Integer;
    Passed: Boolean;
    Failures: string;     // reasons, separated by "; "
    Answer: string;
    DurationMs: Int64;
  end;

  TEvalResults = array of TEvalResult;

  { The system under test: given a provider and an input, produce an answer
    and the conversation that led to it. The harness knows nothing about
    tools, prompts or agents; all of that lives in the target. }
  TEvalTarget = function(AProvider: TLLMProvider; const AInput: string;
    out AHistory: TChatMessages): string;

  { Called after every run, for live progress output. }
  TEvalResultProc = procedure(const AResult: TEvalResult);

function LoadEvalCases(const AFileName: string): TEvalCases;

{ Replace $TODAY with today's date as YYYY-MM-DD and $WEEKDAY with the
  English name of the day. }
function ExpandMacros(const S: string): string;

{ Apply every check of ACase to one run. Adds one line per failed check to
  AFailures and returns True when there are none. }
function RunChecks(const ACase: TEvalCase; const AAnswer: string;
  const AHistory: TChatMessages; AFailures: TStrings): Boolean;

{ Run every case ARepeats times against AProvider and append the results to
  AResults, so several models can be collected into one result set.
  AVariant labels these results, e.g. the prompt version under test. }
procedure RunEval(AProvider: TLLMProvider; const ACases: TEvalCases;
  ATarget: TEvalTarget; ARepeats: Integer; const AVariant: string;
  var AResults: TEvalResults; AOnResult: TEvalResultProc = nil);

{ Print a table of pass counts with one row per model (and variant) and
  one column per case, plus totals and timing. }
procedure PrintEvalSummary(const AResults: TEvalResults);

{ Write one row per run, for comparing result sets over time. }
procedure SaveEvalCSV(const AResults: TEvalResults; const AFileName: string);

implementation

uses
  Math, PasAI.Json;

{ Dataset loading }

function RequiredString(O: TJSONObject; const AName, AContext: string): string;
var
  D: TJSONValue;
begin
  D := JsonFind(O, AName);
  if (D = nil) or (JsonKind(D) <> jkString) then
    raise EEvalError.CreateFmt('%s: missing string field "%s"', [AContext, AName]);
  Result := JsonAsString(D);
end;

function ParseCheck(K: TJSONObject; const AContext: string): TEvalCheck;
var
  Kind: string;
  D: TJSONValue;
  I: Integer;
begin
  Result.Values := nil;
  Result.ToolName := '';
  Result.ToolArgs := '';
  Kind := RequiredString(K, 'type', AContext);

  if (Kind = 'contains_any') or (Kind = 'not_contains') then
  begin
    if Kind = 'contains_any' then
      Result.Kind := ckContainsAny
    else
      Result.Kind := ckNotContains;
    D := JsonFind(K, 'values');
    if (D = nil) or (JsonKind(D) <> jkArray) or (JsonCount(D) = 0) then
      raise EEvalError.CreateFmt('%s: "%s" needs a non-empty "values" array', [AContext, Kind]);
    SetLength(Result.Values, JsonCount(D));
    for I := 0 to JsonCount(D) - 1 do
      Result.Values[I] := JsonAsString(JsonItem(D, I));
  end
  else if Kind = 'tool_called' then
  begin
    Result.Kind := ckToolCalled;
    Result.ToolName := RequiredString(K, 'tool', AContext);
    D := JsonFind(K, 'args');
    if D <> nil then
    begin
      if JsonKind(D) <> jkObject then
        raise EEvalError.CreateFmt('%s: "args" must be an object', [AContext]);
      Result.ToolArgs := JsonToText(D);
    end;
  end
  else if Kind = 'tool_not_called' then
  begin
    Result.Kind := ckToolNotCalled;
    Result.ToolName := RequiredString(K, 'tool', AContext);
  end
  else if Kind = 'no_tool_calls' then
    Result.Kind := ckNoToolCalls
  else
    raise EEvalError.CreateFmt('%s: unknown check type "%s"', [AContext, Kind]);
end;

function LoadEvalCases(const AFileName: string): TEvalCases;
var
  Root, Cases, Checks, C: TJSONValue;
  I, J: Integer;
  Context: string;
begin
  Result := nil;
  try
    Root := ParseJson(LoadTextFileUtf8(AFileName));
  except
    on E: Exception do
      raise EEvalError.CreateFmt('Cannot read dataset %s: %s', [AFileName, E.Message]);
  end;

  try
    Cases := nil;
    if JsonKind(Root) = jkObject then
      Cases := JsonFind(TJSONObject(Root), 'cases');
    if (Cases = nil) or (JsonKind(Cases) <> jkArray) then
      raise EEvalError.CreateFmt('%s: expected an object with a "cases" array', [AFileName]);

    SetLength(Result, JsonCount(Cases));
    for I := 0 to JsonCount(Cases) - 1 do
    begin
      C := JsonItem(Cases, I);
      if JsonKind(C) <> jkObject then
        raise EEvalError.CreateFmt('%s: case #%d is not an object', [AFileName, I + 1]);
      Context := Format('%s case #%d', [AFileName, I + 1]);
      Result[I].Id := RequiredString(TJSONObject(C), 'id', Context);
      Context := Format('%s case "%s"', [AFileName, Result[I].Id]);
      Result[I].Input := RequiredString(TJSONObject(C), 'input', Context);

      Checks := JsonFind(TJSONObject(C), 'checks');
      if (Checks = nil) or (JsonKind(Checks) <> jkArray) then
        raise EEvalError.CreateFmt('%s: missing "checks" array', [Context]);
      SetLength(Result[I].Checks, JsonCount(Checks));
      for J := 0 to JsonCount(Checks) - 1 do
      begin
        if JsonKind(JsonItem(Checks, J)) <> jkObject then
          raise EEvalError.CreateFmt('%s: check #%d is not an object', [Context, J + 1]);
        Result[I].Checks[J] := ParseCheck(TJSONObject(JsonItem(Checks, J)),
          Format('%s check #%d', [Context, J + 1]));
      end;
    end;
  finally
    Root.Free;
  end;
end;

{ Checks }

function ExpandMacros(const S: string): string;
begin
  Result := StringReplace(S, '$TODAY', FormatDateTime('yyyy-mm-dd', Date, InvariantFormat),
    [rfReplaceAll]);
  Result := StringReplace(Result, '$WEEKDAY', FormatDateTime('dddd', Date, InvariantFormat),
    [rfReplaceAll]);
end;

function ValuesEqual(AExpected, AActual: TJSONValue): Boolean;
begin
  if (JsonKind(AExpected) = jkNumber) and (JsonKind(AActual) = jkNumber) then
    Result := SameValue(JsonAsFloat(AExpected), JsonAsFloat(AActual))
  else if JsonKind(AExpected) = jkString then
    Result := (JsonKind(AActual) = jkString) and
      (JsonAsString(AActual) = ExpandMacros(JsonAsString(AExpected)))
  else
    Result := JsonEquals(AExpected, AActual);
end;

{ True when every key of AExpected is present in AActual with an equal value.
  Extra keys in AActual are allowed. }
function ArgsMatch(const AActual, AExpected: string): Boolean;
var
  Act, Exp, V: TJSONValue;
  I: Integer;
begin
  if Trim(AExpected) = '' then
    Exit(True);
  Act := nil;
  Exp := nil;
  try
    try
      Act := ParseJson(AActual);
    except
      Exit(False);
    end;
    Exp := ParseJson(AExpected);
    if (JsonKind(Act) <> jkObject) or (JsonKind(Exp) <> jkObject) then
      Exit(False);
    for I := 0 to JsonCount(Exp) - 1 do
    begin
      V := JsonFind(TJSONObject(Act), JsonName(TJSONObject(Exp), I));
      if (V = nil) or not ValuesEqual(JsonItem(Exp, I), V) then
        Exit(False);
    end;
    Result := True;
  finally
    Act.Free;
    Exp.Free;
  end;
end;

function CollectToolCalls(const AHistory: TChatMessages): TToolCalls;
var
  I, J, N: Integer;
begin
  Result := nil;
  for I := 0 to High(AHistory) do
    for J := 0 to High(AHistory[I].ToolCalls) do
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := AHistory[I].ToolCalls[J];
    end;
end;

function DescribeCalls(const ACalls: TToolCalls): string;
var
  I: Integer;
begin
  if Length(ACalls) = 0 then
    Exit('none');
  Result := '';
  for I := 0 to High(ACalls) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + ACalls[I].Name + ' ' + ACalls[I].Arguments;
  end;
end;

function QuotedList(const AValues: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AValues) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + '"' + AValues[I] + '"';
  end;
end;

function RunChecks(const ACase: TEvalCase; const AAnswer: string;
  const AHistory: TChatMessages; AFailures: TStrings): Boolean;
var
  Calls: TToolCalls;
  Answer, Needle: string;
  I, J, Before: Integer;
  Found: Boolean;
  Check: TEvalCheck;
begin
  Before := AFailures.Count;
  Calls := CollectToolCalls(AHistory);
  Answer := LowerCase(AAnswer);

  for I := 0 to High(ACase.Checks) do
  begin
    Check := ACase.Checks[I];
    case Check.Kind of
      ckContainsAny:
        begin
          Found := False;
          for J := 0 to High(Check.Values) do
            if Pos(LowerCase(ExpandMacros(Check.Values[J])), Answer) > 0 then
              Found := True;
          if not Found then
            AFailures.Add('answer contains none of: ' + QuotedList(Check.Values));
        end;

      ckNotContains:
        for J := 0 to High(Check.Values) do
        begin
          Needle := LowerCase(ExpandMacros(Check.Values[J]));
          if Pos(Needle, Answer) > 0 then
            AFailures.Add('answer contains forbidden text "' + Check.Values[J] + '"');
        end;

      ckToolCalled:
        begin
          Found := False;
          for J := 0 to High(Calls) do
            if (Calls[J].Name = Check.ToolName) and
               ArgsMatch(Calls[J].Arguments, Check.ToolArgs) then
              Found := True;
          if not Found then
            if Check.ToolArgs <> '' then
              AFailures.Add(Format('expected a call to %s with %s; calls made: %s',
                [Check.ToolName, ExpandMacros(Check.ToolArgs), DescribeCalls(Calls)]))
            else
              AFailures.Add(Format('expected a call to %s; calls made: %s',
                [Check.ToolName, DescribeCalls(Calls)]));
        end;

      ckToolNotCalled:
        for J := 0 to High(Calls) do
          if Calls[J].Name = Check.ToolName then
          begin
            AFailures.Add(Format('expected no call to %s; called with %s',
              [Check.ToolName, Calls[J].Arguments]));
            Break;
          end;

      ckNoToolCalls:
        if Length(Calls) > 0 then
          AFailures.Add('expected no tool calls; calls made: ' + DescribeCalls(Calls));
    end;
  end;

  Result := AFailures.Count = Before;
end;

{ Running }

function JoinLines(AList: TStrings; const ASeparator: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AList.Count - 1 do
  begin
    if I > 0 then
      Result := Result + ASeparator;
    Result := Result + AList[I];
  end;
end;

procedure RunEval(AProvider: TLLMProvider; const ACases: TEvalCases;
  ATarget: TEvalTarget; ARepeats: Integer; const AVariant: string;
  var AResults: TEvalResults; AOnResult: TEvalResultProc);
var
  I, R, N: Integer;
  History: TChatMessages;
  Failures: TStringList;
  Res: TEvalResult;
  Start: UInt64;
begin
  Failures := TStringList.Create;
  try
    for I := 0 to High(ACases) do
      for R := 1 to ARepeats do
      begin
        Failures.Clear;
        History := nil;
        Res.Model := AProvider.Model;
        Res.Variant := AVariant;
        Res.CaseId := ACases[I].Id;
        Res.Run := R;
        Res.Answer := '';
        Start := TickMs;
        try
          Res.Answer := ATarget(AProvider, ACases[I].Input, History);
          Res.Passed := RunChecks(ACases[I], Res.Answer, History, Failures);
        except
          on E: Exception do
          begin
            Failures.Add('error: ' + E.Message);
            Res.Passed := False;
          end;
        end;
        Res.DurationMs := TickMs - Start;
        Res.Failures := JoinLines(Failures, '; ');

        N := Length(AResults);
        SetLength(AResults, N + 1);
        AResults[N] := Res;
        if Assigned(AOnResult) then
          AOnResult(Res);
      end;
  finally
    Failures.Free;
  end;
end;

{ Reporting }

{ The row a result belongs to in the summary table. }
function RowKey(const R: TEvalResult): string;
begin
  if R.Variant = '' then
    Result := R.Model
  else
    Result := R.Model + ' / ' + R.Variant;
end;

procedure AddUnique(AList: TStrings; const S: string);
begin
  if AList.IndexOf(S) < 0 then
    AList.Add(S);
end;

procedure PrintEvalSummary(const AResults: TEvalResults);
const
  MODEL_WIDTH = 32;
  CELL_WIDTH = 13;
var
  Models, Cases: TStringList;
  M, C, I, Passed, Total, AllPassed, AllTotal: Integer;
  TotalMs: Int64;
  Line: string;
begin
  Models := TStringList.Create;
  Cases := TStringList.Create;
  try
    for I := 0 to High(AResults) do
    begin
      AddUnique(Models, RowKey(AResults[I]));
      AddUnique(Cases, AResults[I].CaseId);
    end;

    Line := Format('%-*s', [MODEL_WIDTH, 'model']);
    for C := 0 to Cases.Count - 1 do
      Line := Line + Format('%-*s', [CELL_WIDTH, Copy(Cases[C], 1, CELL_WIDTH - 1)]);
    Writeln(Line, 'total   avg time');

    for M := 0 to Models.Count - 1 do
    begin
      Line := Format('%-*s', [MODEL_WIDTH, Copy(Models[M], 1, MODEL_WIDTH - 1)]);
      AllPassed := 0;
      AllTotal := 0;
      TotalMs := 0;
      for C := 0 to Cases.Count - 1 do
      begin
        Passed := 0;
        Total := 0;
        for I := 0 to High(AResults) do
          if (RowKey(AResults[I]) = Models[M]) and (AResults[I].CaseId = Cases[C]) then
          begin
            Inc(Total);
            if AResults[I].Passed then
              Inc(Passed);
            Inc(TotalMs, AResults[I].DurationMs);
          end;
        Inc(AllPassed, Passed);
        Inc(AllTotal, Total);
        Line := Line + Format('%-*s', [CELL_WIDTH, Format('%d/%d', [Passed, Total])]);
      end;
      if AllTotal > 0 then
        Line := Line + Format('%3d%%    %.1f s',
          [Round(100 * AllPassed / AllTotal), TotalMs / AllTotal / 1000]);
      Writeln(Line);
    end;
  finally
    Cases.Free;
    Models.Free;
  end;
end;

function CSVField(const S: string): string;
begin
  Result := '"' + StringReplace(S, '"', '""', [rfReplaceAll]) + '"';
end;

procedure SaveEvalCSV(const AResults: TEvalResults; const AFileName: string);
var
  Lines: TStringList;
  I: Integer;
begin
  Lines := TStringList.Create;
  try
    Lines.Add('model,variant,case,run,passed,duration_ms,failures,answer');
    for I := 0 to High(AResults) do
      Lines.Add(Format('%s,%s,%s,%d,%s,%d,%s,%s', [
        CSVField(AResults[I].Model),
        CSVField(AResults[I].Variant),
        CSVField(AResults[I].CaseId),
        AResults[I].Run,
        BoolToStr(AResults[I].Passed, 'true', 'false'),
        AResults[I].DurationMs,
        CSVField(AResults[I].Failures),
        CSVField(AResults[I].Answer)]));
    SaveTextFileUtf8(AFileName, Lines.Text);
  finally
    Lines.Free;
  end;
end;

end.
