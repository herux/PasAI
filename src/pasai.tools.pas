unit PasAI.Tools;

{ A registry of tools the model may call, and the code that runs them.

  The model never executes anything. It only proposes a call: a tool name
  plus arguments as JSON. Execute is the gatekeeper between that proposal
  and real code, and checks, in order:

  1. The tool exists.                       (unknown names are refused)
  2. The caller holds its permission.       (authorization by identity)
  3. The arguments match its schema.        (shape, not meaning)
  4. Its call limit is not used up.         (a runaway or abused agent stops)
  5. Its business rules pass, if it has a   (meaning: balance, ownership,
     validator.                              limits)
  6. A human confirmed it, if required.     (decided by code, never the model)
  7. Only then the Pascal handler runs.

  Why validation comes before confirmation: a human should only be asked
  about something that can actually happen. Asking first and refusing
  afterwards wastes the approval and teaches users to click "yes" without
  reading (confirmation fatigue), which weakens the one control a prompt
  injection cannot talk its way past. The validator also returns a summary
  computed by code, and that summary, not the model's raw JSON, is what
  the human approves.

  The validator does not replace the checks in the handler. Between
  validation and execution the human takes time to decide, and the state
  can change meanwhile (another withdrawal, a parallel session): a
  time-of-check to time-of-use gap. The validator serves the user; the
  handler re-checks and stays the guarantee. Simplest is one check routine
  called from both.

  For asynchronous approval (a web or mobile UI), the usual pattern is
  prepare/commit: validation creates a pending action with an id and an
  expiry, and a later commit(id) runs it. The validator here is the
  synchronous first step towards that.

  Every attempt, allowed or not, can be written to an audit log.

  What this does NOT protect against: a tool that is too powerful (one
  "run_sql" tool makes the whole list meaningless), a handler that skips
  its own checks (the schema says "a string", not "an order of this user"),
  or an attacker who controls the machine the agent runs on. Those are
  design and infrastructure questions; see ARCHITECTURE.md.

  Errors go back to the model as text starting with "Error:", so it can
  correct itself. Only EToolError messages are passed on verbatim; any
  other exception becomes a generic message, because raw exception text
  (file paths, SQL, stack details) can leak internals to the model and,
  through it, to the user. The full message goes to the audit log.

  One registry serves one session: Context and the call counters belong to
  that session. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, fpjson, PasAI.Types;

type
  { Raise this from a handler for errors the model should see, such as
    "order not found". Any other exception is reported generically. }
  EToolError = class(EPasAIError);

  TToolRisk = (trRead, trWrite, trCritical);

  { Who is calling. Set once per session on the registry. }
  TToolContext = record
    UserId: string;
    Permissions: string;   // space separated, e.g. 'orders.read refund'
  end;

  TToolOptions = record
    Risk: TToolRisk;
    { Permission the caller must hold, or '' for none. }
    Permission: string;
    { Ask a human before running. Always true for trCritical. }
    RequiresConfirmation: Boolean;
    { Maximum successful calls per session, or 0 for no limit. }
    MaxCalls: Integer;
  end;

  { A tool implementation: receives validated arguments, returns the result
    as text for the model. }
  TToolHandler = function(AArgs: TJSONObject): string;

  { The same, also receiving the caller, for tools that must check which
    data the user may see or change. }
  TContextToolHandler = function(const ACtx: TToolContext; AArgs: TJSONObject): string;

  { Checks business rules before a human is asked. Raise EToolError to
    refuse; the model sees the message. Returns a human-readable summary of
    what the call will do, shown in the confirmation. Must not change any
    state: a refused confirmation has to leave everything as it was. }
  TToolValidator = function(const ACtx: TToolContext; AArgs: TJSONObject): string;

  { Asked before a tool that requires confirmation runs. Return True to
    allow. Without this callback, such tools are always refused.
    ADescription is the validator's summary when the tool has a validator,
    otherwise the tool description. }
  TConfirmFunc = function(const ACtx: TToolContext; const ACall: TToolCall;
    const ADescription: string): Boolean;

  TAuditEntry = record
    Time: TDateTime;
    UserId: string;
    Tool: string;
    Arguments: string;
    Outcome: string;   // 'ok', 'error' or 'denied:<reason>'
    Detail: string;    // result or error text, shortened
    DurationMs: Int64;
  end;

  TAuditProc = procedure(const AEntry: TAuditEntry);

  { Where audit entries are stored: a file, a database table, ... }
  TAuditSink = class
  public
    procedure Log(const AEntry: TAuditEntry); virtual; abstract;
  end;

  { One JSON object per line, appended to a file. }
  TFileAuditSink = class(TAuditSink)
  private
    FFileName: string;
  public
    constructor Create(const AFileName: string);
    procedure Log(const AEntry: TAuditEntry); override;
    property FileName: string read FFileName;
  end;

  TToolRegistry = class
  private
    FSpecs: TToolSpecs;
    FHandlers: array of TToolHandler;
    FContextHandlers: array of TContextToolHandler;
    FValidators: array of TToolValidator;
    FSchemas: array of TJSONObject;   // parsed once, used for validation
    FOptions: array of TToolOptions;
    FCallCounts: array of Integer;
    FContext: TToolContext;
    FOnConfirm: TConfirmFunc;
    FOnAudit: TAuditProc;
    FAuditFileName: string;
    FAuditSink: TAuditSink;
    function IndexOf(const AName: string): Integer;
    function Register(const AName, ADescription: string; const ASchema: UTF8String;
      AHandler: TToolHandler; AContextHandler: TContextToolHandler;
      AValidator: TToolValidator; const AOptions: TToolOptions): Integer;
    procedure Audit(const ACall: TToolCall; const AOutcome, ADetail: string;
      AStart: QWord);
  public
    destructor Destroy; override;

    { Register a read-only tool with no permission or limits. Raises if the
      name is taken or the schema is not a JSON object. }
    procedure Add(const AName, ADescription: string; const ASchema: UTF8String;
      AHandler: TToolHandler);

    { Register a tool with explicit risk, permission and limits. }
    procedure AddTool(const AName, ADescription: string; const ASchema: UTF8String;
      AHandler: TContextToolHandler; const AOptions: TToolOptions); overload;

    { The same, with a validator that runs before confirmation. }
    procedure AddTool(const AName, ADescription: string; const ASchema: UTF8String;
      AHandler: TContextToolHandler; AValidator: TToolValidator;
      const AOptions: TToolOptions); overload;

    { The tools the current caller may use, to send to the model. Tools
      the caller lacks permission for are left out: the model cannot be
      talked into calling what it has never seen. Execute still checks. }
    function Specs: TToolSpecs;

    { Validate and run one tool call. Never raises for problems caused by
      the model; returns an "Error: ..." text instead. }
    function Execute(const ACall: TToolCall): string;

    { Clear the per-session call counters. }
    procedure ResetLimits;

    property Context: TToolContext read FContext write FContext;
    property OnConfirm: TConfirmFunc read FOnConfirm write FOnConfirm;
    { Called for every attempt, e.g. to print a trace. }
    property OnAudit: TAuditProc read FOnAudit write FOnAudit;
    { If set, every attempt is appended to this file as one JSON line. }
    property AuditFileName: string read FAuditFileName write FAuditFileName;
    { If set, every attempt is also passed to this sink. Not owned. If the
      sink fails, the failure is written to standard error and the tool
      result is unaffected (see ARCHITECTURE.md on this trade-off). }
    property AuditSink: TAuditSink read FAuditSink write FAuditSink;
  end;

function ToolOptions(ARisk: TToolRisk; const APermission: string = '';
  ARequiresConfirmation: Boolean = False; AMaxCalls: Integer = 0): TToolOptions;

function ToolContext(const AUserId, APermissions: string): TToolContext;

function HasPermission(const ACtx: TToolContext; const APermission: string): Boolean;

const
  TOOL_RISK_NAMES: array[TToolRisk] of string = ('read', 'write', 'critical');

implementation

uses
  jsonparser, PasAI.Structured;

const
  AUDIT_DETAIL_MAX = 300;

function ToolOptions(ARisk: TToolRisk; const APermission: string;
  ARequiresConfirmation: Boolean; AMaxCalls: Integer): TToolOptions;
begin
  Result.Risk := ARisk;
  Result.Permission := APermission;
  Result.RequiresConfirmation := ARequiresConfirmation or (ARisk = trCritical);
  Result.MaxCalls := AMaxCalls;
end;

function ToolContext(const AUserId, APermissions: string): TToolContext;
begin
  Result.UserId := AUserId;
  Result.Permissions := APermissions;
end;

function HasPermission(const ACtx: TToolContext; const APermission: string): Boolean;
begin
  if APermission = '' then
    Exit(True);
  { Padding with spaces makes "refund" not match "refund_all". }
  Result := Pos(' ' + APermission + ' ', ' ' + ACtx.Permissions + ' ') > 0;
end;

{ TToolRegistry }

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

function TToolRegistry.Register(const AName, ADescription: string;
  const ASchema: UTF8String; AHandler: TToolHandler;
  AContextHandler: TContextToolHandler; AValidator: TToolValidator;
  const AOptions: TToolOptions): Integer;
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
  SetLength(FContextHandlers, N + 1);
  SetLength(FValidators, N + 1);
  SetLength(FSchemas, N + 1);
  SetLength(FOptions, N + 1);
  SetLength(FCallCounts, N + 1);
  FSpecs[N].Name := AName;
  FSpecs[N].Description := ADescription;
  FSpecs[N].ParametersSchema := ASchema;
  FHandlers[N] := AHandler;
  FContextHandlers[N] := AContextHandler;
  FValidators[N] := AValidator;
  FSchemas[N] := TJSONObject(D);
  FOptions[N] := AOptions;
  FCallCounts[N] := 0;
  Result := N;
end;

procedure TToolRegistry.Add(const AName, ADescription: string;
  const ASchema: UTF8String; AHandler: TToolHandler);
begin
  Register(AName, ADescription, ASchema, AHandler, nil, nil, ToolOptions(trRead));
end;

procedure TToolRegistry.AddTool(const AName, ADescription: string;
  const ASchema: UTF8String; AHandler: TContextToolHandler;
  const AOptions: TToolOptions);
begin
  Register(AName, ADescription, ASchema, nil, AHandler, nil, AOptions);
end;

procedure TToolRegistry.AddTool(const AName, ADescription: string;
  const ASchema: UTF8String; AHandler: TContextToolHandler;
  AValidator: TToolValidator; const AOptions: TToolOptions);
begin
  Register(AName, ADescription, ASchema, nil, AHandler, AValidator, AOptions);
end;

function TToolRegistry.Specs: TToolSpecs;
var
  I, N: Integer;
begin
  Result := nil;
  for I := 0 to High(FSpecs) do
    if HasPermission(FContext, FOptions[I].Permission) then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := FSpecs[I];
    end;
end;

procedure TToolRegistry.ResetLimits;
var
  I: Integer;
begin
  for I := 0 to High(FCallCounts) do
    FCallCounts[I] := 0;
end;

procedure WriteAuditLine(const AFileName: string; const AEntry: TAuditEntry);
var
  O: TJSONObject;
  F: TextFile;
begin
  O := TJSONObject.Create;
  try
    O.Add('time', UTF8String(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', AEntry.Time)));
    O.Add('user', UTF8String(AEntry.UserId));
    O.Add('tool', UTF8String(AEntry.Tool));
    O.Add('args', UTF8String(AEntry.Arguments));
    O.Add('outcome', UTF8String(AEntry.Outcome));
    O.Add('detail', UTF8String(AEntry.Detail));
    O.Add('ms', AEntry.DurationMs);
    ForceDirectories(ExtractFileDir(ExpandFileName(AFileName)));
    AssignFile(F, AFileName);
    if FileExists(AFileName) then
      Append(F)
    else
      Rewrite(F);
    try
      Writeln(F, O.AsJSON);
    finally
      CloseFile(F);
    end;
  finally
    O.Free;
  end;
end;

{ TFileAuditSink }

constructor TFileAuditSink.Create(const AFileName: string);
begin
  inherited Create;
  FFileName := AFileName;
end;

procedure TFileAuditSink.Log(const AEntry: TAuditEntry);
begin
  WriteAuditLine(FFileName, AEntry);
end;

procedure TToolRegistry.Audit(const ACall: TToolCall; const AOutcome, ADetail: string;
  AStart: QWord);
var
  E: TAuditEntry;
begin
  if not Assigned(FOnAudit) and (FAuditFileName = '') and (FAuditSink = nil) then
    Exit;
  E.Time := Now;
  E.UserId := FContext.UserId;
  E.Tool := ACall.Name;
  E.Arguments := ACall.Arguments;
  E.Outcome := AOutcome;
  E.Detail := Copy(ADetail, 1, AUDIT_DETAIL_MAX);
  E.DurationMs := GetTickCount64 - AStart;
  if FAuditFileName <> '' then
    WriteAuditLine(FAuditFileName, E);
  if FAuditSink <> nil then
    try
      FAuditSink.Log(E);
    except
      on Ex: Exception do
        Writeln(ErrOutput, 'PasAI: audit sink failed: ', Ex.Message);
    end;
  if Assigned(FOnAudit) then
    FOnAudit(E);
end;

{ "a, b, c": the tools the current caller may use. }
function PermittedNames(ARegistry: TToolRegistry): string;
var
  Specs: TToolSpecs;
  I: Integer;
begin
  Specs := ARegistry.Specs;
  Result := '';
  for I := 0 to High(Specs) do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Specs[I].Name;
  end;
end;

function TToolRegistry.Execute(const ACall: TToolCall): string;
var
  Index: Integer;
  D: TJSONData;
  Errors: TStringList;
  Start: QWord;
  Summary: string;
begin
  Start := GetTickCount64;

  { 1. The tool exists. Unknown and unpermitted tools get the same answer,
       so probing reveals nothing about which tools exist. }
  Index := IndexOf(ACall.Name);
  if Index < 0 then
  begin
    Audit(ACall, 'denied:unknown_tool', '', Start);
    Exit(Format('Error: unknown tool "%s". Available tools: %s',
      [ACall.Name, PermittedNames(Self)]));
  end;

  { 2. Permission }
  if not HasPermission(FContext, FOptions[Index].Permission) then
  begin
    Audit(ACall, 'denied:permission', 'missing ' + FOptions[Index].Permission, Start);
    Exit(Format('Error: unknown tool "%s". Available tools: %s',
      [ACall.Name, PermittedNames(Self)]));
  end;

  { 3. Arguments }
  try
    D := GetJSON(UTF8String(ExtractJSONText(ACall.Arguments)));
  except
    on E: Exception do
    begin
      Audit(ACall, 'denied:invalid_args', E.Message, Start);
      Exit('Error: arguments are not valid JSON: ' + E.Message);
    end;
  end;

  Errors := TStringList.Create;
  try
    if D.JSONType <> jtObject then
      Errors.Add('arguments must be a JSON object')
    else
      ValidateJSON(D, FSchemas[Index], Errors);
    if Errors.Count > 0 then
    begin
      Result := 'Error: invalid arguments: ' +
        StringReplace(Trim(Errors.Text), LineEnding, '; ', [rfReplaceAll]);
      Audit(ACall, 'denied:invalid_args', Result, Start);
      Exit;
    end;

    { 4. Call limit }
    if (FOptions[Index].MaxCalls > 0) and
       (FCallCounts[Index] >= FOptions[Index].MaxCalls) then
    begin
      Audit(ACall, 'denied:rate_limit', '', Start);
      Exit(Format('Error: "%s" may be used at most %d time(s) per session',
        [ACall.Name, FOptions[Index].MaxCalls]));
    end;

    { 5. Business rules, before anyone is asked to approve }
    Summary := FSpecs[Index].Description;
    if Assigned(FValidators[Index]) then
      try
        Summary := FValidators[Index](FContext, TJSONObject(D));
      except
        on E: EToolError do
        begin
          Audit(ACall, 'denied:validation', E.Message, Start);
          Exit('Error: ' + E.Message);
        end;
        on E: Exception do
        begin
          Audit(ACall, 'error', 'validator: ' + E.ClassName + ': ' + E.Message, Start);
          Exit('Error: the tool failed because of an internal problem.');
        end;
      end;

    { 6. Human confirmation }
    if FOptions[Index].RequiresConfirmation then
      if not Assigned(FOnConfirm) or
         not FOnConfirm(FContext, ACall, Summary) then
      begin
        Audit(ACall, 'denied:not_confirmed', '', Start);
        Exit('Error: the user did not approve this action. Do not retry it ' +
          'unless the user asks again.');
      end;

    { 7. Run. The handler re-checks: see the note on time-of-check to
         time-of-use at the top of this unit. }
    try
      if Assigned(FContextHandlers[Index]) then
        Result := FContextHandlers[Index](FContext, TJSONObject(D))
      else
        Result := FHandlers[Index](TJSONObject(D));
      Inc(FCallCounts[Index]);
      Audit(ACall, 'ok', Result, Start);
    except
      on E: EToolError do
      begin
        Result := 'Error: ' + E.Message;
        Audit(ACall, 'error', E.Message, Start);
      end;
      on E: Exception do
      begin
        Result := 'Error: the tool failed because of an internal problem.';
        Audit(ACall, 'error', E.ClassName + ': ' + E.Message, Start);
      end;
    end;
  finally
    Errors.Free;
    D.Free;
  end;
end;

end.
