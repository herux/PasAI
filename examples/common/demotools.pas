unit DemoTools;

{ The demo tools shared by the examples: one arithmetic tool and two date
  tools, the things small models most often get wrong when they try to do
  them "in their head".

  Kept in one unit so the agent example and the eval run exercise exactly
  the same tools. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  SysUtils, PasAI.Types, PasAI.Json, PasAI.Schema, PasAI.Tools;

{ A registry with get_current_date, add_days and calculate.
  The caller owns the result. }
function BuildDemoTools: TToolRegistry;

implementation

{ Tool handlers. Arguments arrive already validated against the schema. }

function ToolCurrentDate(AArgs: TJSONObject): string;
begin
  Result := FormatDateTime('yyyy-mm-dd (dddd)', Date, InvariantFormat);
end;

{ Errors meant for the model are raised as EToolError; PasAI.Tools hides
  the text of any other exception. }
function ParseISODate(const S: string): TDateTime;
var
  Y, M, D: Integer;
begin
  if (Length(S) <> 10) or (S[5] <> '-') or (S[8] <> '-') or
     not TryStrToInt(Copy(S, 1, 4), Y) or not TryStrToInt(Copy(S, 6, 2), M) or
     not TryStrToInt(Copy(S, 9, 2), D) then
    raise EToolError.CreateFmt('date "%s" is not in YYYY-MM-DD format', [S]);
  if not TryEncodeDate(Y, M, D, Result) then
    raise EToolError.CreateFmt('"%s" is not a valid date', [S]);
end;

function ToolAddDays(AArgs: TJSONObject): string;
begin
  Result := FormatDateTime('yyyy-mm-dd (dddd)',
    ParseISODate(JsonGetString(AArgs, 'date')) + JsonGetInteger(AArgs, 'days'), InvariantFormat);
end;

function ToolCalculate(AArgs: TJSONObject): string;
var
  A, B: Double;
  Op: string;
begin
  A := JsonGetFloat(AArgs, 'a');
  B := JsonGetFloat(AArgs, 'b');
  Op := JsonGetString(AArgs, 'op');
  if Op = 'add' then
    Result := FloatToStr(A + B, InvariantFormat)
  else if Op = 'subtract' then
    Result := FloatToStr(A - B, InvariantFormat)
  else if Op = 'multiply' then
    Result := FloatToStr(A * B, InvariantFormat)
  else
  begin
    if B = 0 then
      raise EToolError.Create('division by zero');
    Result := FloatToStr(A / B, InvariantFormat);
  end;
end;

function BuildDemoTools: TToolRegistry;
begin
  Result := TToolRegistry.Create;
  Result.Add('get_current_date',
    'Returns today''s date as YYYY-MM-DD together with the day of the week.',
    ObjectSchema.ToJSON, ToolCurrentDate);
  Result.Add('add_days',
    'Adds a number of days (negative to subtract) to a date and returns ' +
    'the resulting date with its day of the week.',
    ObjectSchema
      .Str('date', 'Start date in YYYY-MM-DD format')
      .Int('days', 'Number of days to add; negative to go back')
      .ToJSON,
    ToolAddDays);
  Result.Add('calculate',
    'Performs one arithmetic operation on two numbers.',
    ObjectSchema
      .Num('a', 'First operand')
      .Num('b', 'Second operand')
      .Enum('op', ['add', 'subtract', 'multiply', 'divide'], 'Operation')
      .ToJSON,
    ToolCalculate);
end;

end.
