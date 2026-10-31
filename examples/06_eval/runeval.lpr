program EvalDemo;   // not "eval" or "runeval": avoids clashing with PasAI.Eval

{ Example 6: evaluating the agent from example 5 across models and prompts.

  Usage:
    ./bin/runeval [options] [model ...]

  Options:
    -n N        runs per case (default 3)
    -t T        temperature, e.g. 0 or 0.7 (default: the model's own)
    -p A,B      prompt variants to compare (default v1); each name refers to
                examples/06_eval/prompts/NAME.txt
    -d FILE     dataset (default examples/06_eval/agent_cases.json)

  Example:
    ./bin/runeval -p v1,v2 qwen2.5:7b-instruct llama3.1

  Prompts are plain text files, so they can be changed without recompiling
  and their history lives in git. $TODAY and $WEEKDAY are expanded.
  Results are printed as a table and saved to results/eval-<time>.csv. }

{$mode delphi}{$H+}
{$codepage utf8}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  Classes, SysUtils,
  PasAI.Types, PasAI.Provider, PasAI.Ollama, PasAI.Tools, PasAI.Agent,
  PasAI.Eval,
  DemoTools;

const
  DEFAULT_DATASET = 'examples/06_eval/agent_cases.json';
  PROMPT_DIR = 'examples/06_eval/prompts/';
  DEFAULT_MODEL = 'qwen2.5:7b-instruct';
  DEFAULT_PROMPT = 'v1';

var
  GTools: TToolRegistry;
  GSystemPrompt: string;   // the variant currently under test

{ The system under test: the same agent setup as example 5, with the
  system prompt of the current variant. }
function AgentTarget(AProvider: TLLMProvider; const AInput: string;
  out AHistory: TChatMessages): string;
begin
  AHistory := nil;
  AddMessage(AHistory, ROLE_SYSTEM, GSystemPrompt);
  AddMessage(AHistory, ROLE_USER, AInput);
  Result := RunAgent(AProvider, GTools, AHistory, 8, nil);
end;

function LoadPrompt(const AName: string): string;
var
  Lines: TStringList;
  FileName: string;
begin
  FileName := PROMPT_DIR + AName + '.txt';
  if not FileExists(FileName) then
    raise Exception.CreateFmt('Prompt file not found: %s', [FileName]);
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(FileName);
    Result := ExpandMacros(Trim(Lines.Text));
  finally
    Lines.Free;
  end;
end;

procedure ShowResult(const R: TEvalResult);
const
  VERDICT: array[Boolean] of string = ('FAIL', 'pass');
begin
  Writeln(Format('  %-12s #%d  %s  %6.1f s',
    [R.CaseId, R.Run, VERDICT[R.Passed], R.DurationMs / 1000]));
  if not R.Passed then
    Writeln('      ', R.Failures);
end;

var
  Models, Prompts: TStringList;
  Cases: TEvalCases;
  Results: TEvalResults;
  Provider: TOllamaClient;
  Repeats, I, J: Integer;
  Temperature: Double;
  Dataset, Arg, CSVFile: string;
begin
  Repeats := 3;
  Temperature := -1;
  Dataset := DEFAULT_DATASET;
  Results := nil;

  Models := TStringList.Create;
  Prompts := TStringList.Create;
  try
    I := 1;
    while I <= ParamCount do
    begin
      Arg := ParamStr(I);
      if (Arg = '-n') and (I < ParamCount) then
      begin
        Inc(I);
        Repeats := StrToInt(ParamStr(I));
      end
      else if (Arg = '-t') and (I < ParamCount) then
      begin
        Inc(I);
        Temperature := StrToFloat(ParamStr(I));
      end
      else if (Arg = '-p') and (I < ParamCount) then
      begin
        Inc(I);
        Prompts.CommaText := ParamStr(I);
      end
      else if (Arg = '-d') and (I < ParamCount) then
      begin
        Inc(I);
        Dataset := ParamStr(I);
      end
      else
        Models.Add(Arg);
      Inc(I);
    end;
    if Models.Count = 0 then
      Models.Add(DEFAULT_MODEL);
    if Prompts.Count = 0 then
      Prompts.Add(DEFAULT_PROMPT);

    try
      Cases := LoadEvalCases(Dataset);
      for J := 0 to Prompts.Count - 1 do
        LoadPrompt(Prompts[J]);   // fail early on a missing prompt file
    except
      on E: Exception do
      begin
        Writeln('Error: ', E.Message);
        Halt(1);
      end;
    end;

    Writeln(Format('Dataset %s: %d cases, %d run(s) each, %d model(s), %d prompt(s)',
      [Dataset, Length(Cases), Repeats, Models.Count, Prompts.Count]));

    GTools := BuildDemoTools;
    try
      for I := 0 to Models.Count - 1 do
      begin
        Provider := TOllamaClient.Create(Models[I]);
        try
          Provider.Temperature := Temperature;
          for J := 0 to Prompts.Count - 1 do
          begin
            GSystemPrompt := LoadPrompt(Prompts[J]);
            Writeln;
            Writeln('=== ', Models[I], ' / ', Prompts[J], ' ===');
            RunEval(Provider, Cases, AgentTarget, Repeats, Prompts[J], Results, ShowResult);
          end;
        finally
          Provider.Free;
        end;
      end;
    finally
      GTools.Free;
    end;

    Writeln;
    PrintEvalSummary(Results);

    ForceDirectories('results');
    CSVFile := 'results/eval-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.csv';
    SaveEvalCSV(Results, CSVFile);
    Writeln;
    Writeln('Saved ', CSVFile);
  finally
    Prompts.Free;
    Models.Free;
  end;
end.
