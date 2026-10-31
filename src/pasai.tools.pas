unit PasAI.Tools;

{ A registry of tools the model may call, and the code that runs them.

  The model never executes anything. It only proposes a call: a tool name
  plus arguments as JSON. Execute is the gatekeeper between that proposal
  and real code:

  1. The tool must be registered. Unknown names are rejected.
  2. The arguments are parsed and validated against the tool's schema.
  3. Only then is the Pascal handler run.

  Any failure is returned as text starting with "Error:" instead of raising.
  That text goes back to the model as the tool result, so the model can see
  what went wrong and try again with corrected arguments. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, PasAI.Types;

type
  { A tool implementation: receives validated arguments, returns the result
    as text for the model. Raising an exception is fine; Execute turns it
    into an error result. }
  TToolHandler = function(AArgs: TJSONObject): string;

  TToolRegistry = class
  private
    FSpecs: TToolSpecs;
    FHandlers: array of TToolHandler;
    FSchemas: array of TJSONObject;   // parsed once, used for validation
    function IndexOf(const AName: string): Integer;
  public
    destructor Destroy; override;

    { Register a tool. ASchema is the JSON schema of its arguments, for
      example built with ObjectSchema from PasAI.Schema. Raises if the name
      is taken or the schema is not a JSON object. }
    procedure Add(const AName, ADescription: string; const ASchema: UTF8String;
      AHandler: TToolHandler);

    { The tool descriptions to send to the model. }
    function Specs: TToolSpecs;

    { Validate and run one tool call. Never raises for problems caused by
      the model; returns an "Error: ..." text instead. }
    function Execute(const ACall: TToolCall): string;
  end;

implementation

uses
  jsonparser, PasAI.Structured;

destructor TToolRegistry.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FSchemas) do
    FSchemas[I].Free;
  inherited Destroy;
end;

function TToolRegistry.IndexOf(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FSpecs) do
    if FSpecs[I].Name = AName then
      Exit(I);
  Result := -1;
end;

procedure TToolRegistry.Add(const AName, ADescription: string;
  const ASchema: UTF8String; AHandler: TToolHandler);
var
  D: TJSONData;
  N: Integer;
begin
  if IndexOf(AName) >= 0 then
    raise EPasAIError.CreateFmt('Tool "%s" is already registered', [AName]);

  D := GetJSON(ASchema);
  if D.JSONType <> jtObject then
  begin
    D.Free;
    raise EPasAIError.CreateFmt('Schema of tool "%s" must be a JSON object', [AName]);
  end;

  N := Length(FSpecs);
  SetLength(FSpecs, N + 1);
  SetLength(FHandlers, N + 1);
  SetLength(FSchemas, N + 1);
  FSpecs[N].Name := AName;
  FSpecs[N].Description := ADescription;
  FSpecs[N].ParametersSchema := ASchema;
  FHandlers[N] := AHandler;
  FSchemas[N] := TJSONObject(D);
end;

function TToolRegistry.Specs: TToolSpecs;
begin
  Result := Copy(FSpecs);
end;

function TToolRegistry.Execute(const ACall: TToolCall): string;
var
  Index, I: Integer;
  D: TJSONData;
  Errors: TStringList;
  Names: string;
begin
  Index := IndexOf(ACall.Name);
  if Index < 0 then
  begin
    Names := '';
    for I := 0 to High(FSpecs) do
    begin
      if Names <> '' then
        Names := Names + ', ';
      Names := Names + FSpecs[I].Name;
    end;
    Exit(Format('Error: unknown tool "%s". Available tools: %s', [ACall.Name, Names]));
  end;

  try
    D := GetJSON(UTF8String(ExtractJSONText(ACall.Arguments)));
  except
    on E: Exception do
      Exit('Error: arguments are not valid JSON: ' + E.Message);
  end;

  Errors := TStringList.Create;
  try
    if D.JSONType <> jtObject then
      Errors.Add('arguments must be a JSON object')
    else
      ValidateJSON(D, FSchemas[Index], Errors);

    if Errors.Count > 0 then
      Exit('Error: invalid arguments: ' +
        StringReplace(Trim(Errors.Text), LineEnding, '; ', [rfReplaceAll]));

    try
      Result := FHandlers[Index](TJSONObject(D));
    except
      on E: Exception do
        Result := 'Error: ' + E.Message;
    end;
  finally
    Errors.Free;
    D.Free;
  end;
end;

end.
