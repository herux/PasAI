unit PasAI.Pg;

{ A thin layer over each compiler's PostgreSQL access: SQLdb (TPQConnection)
  in Free Pascal, FireDAC in Delphi. It loads libpq, runs parameterized
  statements, manages transactions and applies schema migrations. Queries
  come back as TDataSet, the common ancestor of both libraries' datasets.

  Parameters, never string concatenation. Every value goes through a
  numbered parameter (:p1, :p2, ...), sent as a prepared statement. Text
  written by members or by the model can then never change the meaning of
  a query: SQL injection is the database cousin of prompt injection, and
  has the same cure, keeping data and instructions apart.

  libpq. Both libraries load the PostgreSQL client library at runtime and
  look for it without a path, which misses Homebrew, Postgres.app and the
  Windows installer, so LoadLibPq tries the usual locations first. With
  PostgreSQL in Docker, the server runs in the container but the client
  library must still be installed where the program runs:
    macOS:   brew install libpq
    Windows: the PostgreSQL installer (its bin folder holds libpq.dll and
             the DLLs it needs), or set PASAI_LIBPQ to libpq.dll

  Delphi edition. FireDAC's PostgreSQL driver needs an edition that
  includes client/server database access (Enterprise or Architect, or
  Professional with the FireDAC client/server add-on). Without it, the
  FireDAC.Phys.PG unit is missing and this unit does not compile.

  Migrations. db/migrations holds numbered SQL files (001_init.sql, ...).
  Migrate applies, in order, each file not yet listed in schema_migrations,
  each one in its own transaction. A file is split into statements at
  lines ending with ";", so keep one statement per such line ending and do
  not use semicolons at line ends inside function bodies. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types,
  {$IFDEF FPC}
  DB, sqldb, pqconnection;
  {$ELSE}
  Data.DB, FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Param,
  FireDAC.Stan.Def, FireDAC.Stan.Async, FireDAC.Phys, FireDAC.Phys.Intf,
  FireDAC.Phys.PG, FireDAC.Phys.PGDef, FireDAC.DApt, FireDAC.Comp.Client,
  FireDAC.ConsoleUI.Wait;
  {$ENDIF}

type
  EPgError = class(EPasAIError);

  TPgConfig = record
    Host: string;
    Port: Integer;
    Database: string;
    User: string;
    Password: string;
    LibPq: string;   // path to libpq, or '' to search the usual places
  end;

  TPgDatabase = class
  private
    FConfig: TPgConfig;
    {$IFDEF FPC}
    FConnection: TPQConnection;
    FTransaction: TSQLTransaction;
    {$ELSE}
    FConnection: TFDConnection;
    {$ENDIF}
    procedure BindParams(AParams: TParams; const AValues: array of const);
    function NewQuery(const ASQL: string; const AParams: array of const): TDataSet;
    procedure ExecDirect(const ASQL: string);
  public
    constructor Create(const AConfig: TPgConfig);
    destructor Destroy; override;

    procedure StartTransaction;
    procedure Commit;
    procedure Rollback;
    function InTransaction: Boolean;

    { Run a statement that returns no rows. Parameters are bound in order
      to :p1, :p2, ... Pass nil for SQL NULL. }
    procedure Exec(const ASQL: string; const AParams: array of const);

    { Run a query and return it open, positioned on the first row. The
      caller frees it. }
    function Open(const ASQL: string; const AParams: array of const): TDataSet;

    { First column of the first row as text, or '' when there are no rows. }
    function Value(const ASQL: string; const AParams: array of const): string;

    { Apply pending migrations from ADir. Adds one line per applied file to
      ALog (if given). Returns the number applied. }
    function Migrate(const ADir: string; ALog: TStrings = nil): Integer;

    { Versions already applied, oldest first. The caller frees the list. }
    function AppliedMigrations: TStringList;

    property Config: TPgConfig read FConfig;
  end;

{ Read the configuration from environment variables, with defaults that
  match db/docker-compose.yml:
    PASAI_PG_HOST (localhost)   PASAI_PG_PORT (5433)   PASAI_PG_DB (pasai)
    PASAI_PG_USER (pasai)       PASAI_PG_PASSWORD (pasai)
    PASAI_LIBPQ   (searched)
  The password comes from the environment so it is not written in code. }
function PgConfigFromEnv: TPgConfig;

{ Load libpq once. Tries APath if given, then the usual install locations.
  Called automatically by TPgDatabase.Create. }
procedure LoadLibPq(const APath: string);

implementation

{$IFDEF FPC}
uses
  postgres3dyn;
{$ENDIF}

var
  GLibLoaded: Boolean = False;
  {$IFNDEF FPC}
  GDriverLink: TFDPhysPgDriverLink = nil;
  {$ENDIF}

function EnvOr(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function PgConfigFromEnv: TPgConfig;
begin
  Result.Host := EnvOr('PASAI_PG_HOST', 'localhost');
  Result.Port := StrToIntDef(EnvOr('PASAI_PG_PORT', '5433'), 5433);
  Result.Database := EnvOr('PASAI_PG_DB', 'pasai');
  Result.User := EnvOr('PASAI_PG_USER', 'pasai');
  Result.Password := EnvOr('PASAI_PG_PASSWORD', 'pasai');
  Result.LibPq := GetEnvironmentVariable('PASAI_LIBPQ');
end;

{ Candidate locations of libpq, most likely first. }
function LibPqCandidates: TStringList;
{$IFDEF MSWINDOWS}
var
  V: Integer;
{$ENDIF}
begin
  Result := TStringList.Create;
  {$IFDEF MSWINDOWS}
  for V := 18 downto 12 do
    Result.Add(Format('C:\Program Files\PostgreSQL\%d\bin\libpq.dll', [V]));
  {$ENDIF}
  {$IFDEF DARWIN}
  Result.Add('/opt/homebrew/opt/libpq/lib/libpq.dylib');               // Homebrew, Apple Silicon
  Result.Add('/usr/local/opt/libpq/lib/libpq.dylib');                  // Homebrew, Intel
  Result.Add('/Applications/Postgres.app/Contents/Versions/latest/lib/libpq.dylib');
  {$ENDIF}
  {$IFDEF MACOS}
  {$IFNDEF DARWIN}
  Result.Add('/opt/homebrew/opt/libpq/lib/libpq.dylib');
  Result.Add('/usr/local/opt/libpq/lib/libpq.dylib');
  Result.Add('/Applications/Postgres.app/Contents/Versions/latest/lib/libpq.dylib');
  {$ENDIF}
  {$ENDIF}
  {$IFDEF LINUX}
  Result.Add('/usr/lib/x86_64-linux-gnu/libpq.so.5');
  Result.Add('/usr/lib/aarch64-linux-gnu/libpq.so.5');
  Result.Add('/usr/lib64/libpq.so.5');
  {$ENDIF}
end;

procedure LoadLibPq(const APath: string);
var
  Candidates: TStringList;
  Found: string;
  I: Integer;

  {$IFDEF FPC}
  function TryLoad(const APathToTry: string): Boolean;
  begin
    Result := False;
    try
      InitialisePostgres3(APathToTry);
      Result := True;
    except
      on E: EInOutError do
        ;   // not loadable, try the next one
    end;
  end;
  {$ENDIF}

begin
  if GLibLoaded then
    Exit;

  Found := '';
  Candidates := LibPqCandidates;
  try
    if APath <> '' then
    begin
      if not FileExists(APath) then
        raise EPgError.CreateFmt('libpq not found at %s (PASAI_LIBPQ)', [APath]);
      Found := APath;
    end
    else
      for I := 0 to Candidates.Count - 1 do
        if FileExists(Candidates[I]) then
        begin
          Found := Candidates[I];
          Break;
        end;

    {$IFDEF FPC}
    if (Found <> '') and TryLoad(Found) then
    begin
      GLibLoaded := True;
      Exit;
    end;
    { Last resort: the system's own search path. }
    {$IFDEF DARWIN}
    if TryLoad('libpq.dylib') then
    {$ELSE}
    {$IFDEF MSWINDOWS}
    if TryLoad('libpq.dll') then
    {$ELSE}
    if TryLoad('libpq.so.5') then
    {$ENDIF}
    {$ENDIF}
    begin
      GLibLoaded := True;
      Exit;
    end;
    raise EPgError.Create('Cannot find the PostgreSQL client library (libpq). ' +
      'On macOS install it with "brew install libpq"; on Windows install ' +
      'PostgreSQL or set PASAI_LIBPQ to the full path of libpq.dll. Tried: ' +
      Candidates.CommaText);
    {$ELSE}
    { FireDAC loads the library itself when it connects; it only needs to
      know where it is. Empty means FireDAC's own default search. }
    if GDriverLink = nil then
      GDriverLink := TFDPhysPgDriverLink.Create(nil);
    GDriverLink.VendorLib := Found;
    GLibLoaded := True;
    {$ENDIF}
  finally
    Candidates.Free;
  end;
end;

{ TPgDatabase }

constructor TPgDatabase.Create(const AConfig: TPgConfig);
begin
  inherited Create;
  FConfig := AConfig;
  LoadLibPq(AConfig.LibPq);
  {$IFDEF FPC}
  FConnection := TPQConnection.Create(nil);
  FTransaction := TSQLTransaction.Create(nil);
  FConnection.Transaction := FTransaction;
  FTransaction.DataBase := FConnection;
  FConnection.HostName := AConfig.Host;
  FConnection.DatabaseName := AConfig.Database;
  FConnection.UserName := AConfig.User;
  FConnection.Password := AConfig.Password;
  FConnection.Params.Add('port=' + IntToStr(AConfig.Port));
  FConnection.Params.Add('client_encoding=UTF8');
  {$ELSE}
  FConnection := TFDConnection.Create(nil);
  FConnection.DriverName := 'PG';
  FConnection.LoginPrompt := False;
  FConnection.Params.Values['Server'] := AConfig.Host;
  FConnection.Params.Values['Port'] := IntToStr(AConfig.Port);
  FConnection.Params.Values['Database'] := AConfig.Database;
  FConnection.Params.Values['User_Name'] := AConfig.User;
  FConnection.Params.Values['Password'] := AConfig.Password;
  FConnection.Params.Values['CharacterSet'] := 'UTF8';
  { FireDAC rewrites SQL text by default: "!name" and "&name" become macros
    and braces become escape sequences. Plain SQL must stay plain. }
  FConnection.ResourceOptions.MacroCreate := False;
  FConnection.ResourceOptions.MacroExpand := False;
  FConnection.ResourceOptions.EscapeExpand := False;
  {$ENDIF}
  try
    FConnection.Open;
  except
    on E: Exception do
    begin
      {$IFDEF FPC}
      FTransaction.Free;
      FTransaction := nil;
      {$ENDIF}
      FConnection.Free;
      FConnection := nil;
      raise EPgError.CreateFmt('Cannot connect to PostgreSQL at %s:%d as %s: %s. ' +
        'Is the container running? (docker compose -f db/docker-compose.yml up -d)',
        [AConfig.Host, AConfig.Port, AConfig.User, E.Message]);
    end;
  end;
end;

destructor TPgDatabase.Destroy;
begin
  if FConnection <> nil then
  begin
    if InTransaction then
      Rollback;
    FConnection.Close;
  end;
  {$IFDEF FPC}
  FTransaction.Free;
  {$ENDIF}
  FConnection.Free;
  inherited Destroy;
end;

procedure TPgDatabase.StartTransaction;
begin
  {$IFDEF FPC}
  if not FTransaction.Active then
    FTransaction.StartTransaction;
  {$ELSE}
  if not FConnection.InTransaction then
    FConnection.StartTransaction;
  {$ENDIF}
end;

procedure TPgDatabase.Commit;
begin
  {$IFDEF FPC}
  if FTransaction.Active then
    FTransaction.Commit;
  {$ELSE}
  if FConnection.InTransaction then
    FConnection.Commit;
  {$ENDIF}
end;

procedure TPgDatabase.Rollback;
begin
  {$IFDEF FPC}
  if FTransaction.Active then
    FTransaction.Rollback;
  {$ELSE}
  if FConnection.InTransaction then
    FConnection.Rollback;
  {$ENDIF}
end;

function TPgDatabase.InTransaction: Boolean;
begin
  {$IFDEF FPC}
  Result := (FTransaction <> nil) and FTransaction.Active;
  {$ELSE}
  Result := (FConnection <> nil) and FConnection.InTransaction;
  {$ENDIF}
end;

procedure TPgDatabase.BindParams(AParams: TParams; const AValues: array of const);
var
  I: Integer;
  P: TParam;
begin
  for I := 0 to High(AValues) do
  begin
    P := AParams.FindParam('p' + IntToStr(I + 1));
    if P = nil then
      raise EPgError.CreateFmt('Statement has no parameter :p%d', [I + 1]);
    case AValues[I].VType of
      vtInteger:       P.AsInteger := AValues[I].VInteger;
      vtInt64:         P.AsLargeInt := AValues[I].VInt64^;
      vtBoolean:       P.AsBoolean := AValues[I].VBoolean;
      vtExtended:      P.AsFloat := AValues[I].VExtended^;
      vtAnsiString:    P.AsString := string(AnsiString(AValues[I].VAnsiString));
      vtUnicodeString: P.AsString := string(UnicodeString(AValues[I].VUnicodeString));
      vtWideString:    P.AsString := string(WideString(AValues[I].VWideString));
      vtChar:          P.AsString := string(AValues[I].VChar);
      vtWideChar:      P.AsString := string(AValues[I].VWideChar);
      vtString:        P.AsString := string(AValues[I].VString^);
      vtPChar:         P.AsString := string(AValues[I].VPChar);
      vtPointer:
        if AValues[I].VPointer = nil then
        begin
          {$IFDEF FPC}
          { Untyped: PostgreSQL then takes the type of the target column. }
          P.DataType := ftUnknown;
          {$ELSE}
          { FireDAC needs a type even for NULL. Text converts implicitly to
            the column type in PostgreSQL. }
          P.DataType := ftString;
          {$ENDIF}
          P.Clear;
        end
        else
          raise EPgError.Create('Only nil pointers are supported as parameters');
    else
      raise EPgError.CreateFmt('Unsupported parameter type for :p%d', [I + 1]);
    end;
  end;
end;

function TPgDatabase.NewQuery(const ASQL: string; const AParams: array of const): TDataSet;
{$IFDEF FPC}
var
  Q: TSQLQuery;
begin
  Q := TSQLQuery.Create(nil);
  try
    Q.DataBase := FConnection;
    Q.Transaction := FTransaction;
    Q.SQL.Text := ASQL;
    BindParams(Q.Params, AParams);
  except
    Q.Free;
    raise;
  end;
  Result := Q;
end;
{$ELSE}
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConnection;
    Q.SQL.Text := ASQL;
    BindParams(TParams(Q.Params), AParams);
  except
    Q.Free;
    raise;
  end;
  Result := Q;
end;
{$ENDIF}

procedure TPgDatabase.ExecDirect(const ASQL: string);
begin
  StartTransaction;
  {$IFDEF FPC}
  FConnection.ExecuteDirect(ASQL, FTransaction);
  {$ELSE}
  FConnection.ExecSQL(ASQL);
  {$ENDIF}
end;

procedure TPgDatabase.Exec(const ASQL: string; const AParams: array of const);
var
  Q: TDataSet;
begin
  StartTransaction;
  Q := NewQuery(ASQL, AParams);
  try
    {$IFDEF FPC}
    TSQLQuery(Q).ExecSQL;
    {$ELSE}
    TFDQuery(Q).ExecSQL;
    {$ENDIF}
  finally
    Q.Free;
  end;
end;

function TPgDatabase.Open(const ASQL: string; const AParams: array of const): TDataSet;
begin
  StartTransaction;
  Result := NewQuery(ASQL, AParams);
  try
    Result.Open;
  except
    Result.Free;
    raise;
  end;
end;

function TPgDatabase.Value(const ASQL: string; const AParams: array of const): string;
var
  Q: TDataSet;
begin
  Q := Open(ASQL, AParams);
  try
    if Q.EOF then
      Result := ''
    else
      Result := Q.Fields[0].AsString;
  finally
    Q.Free;
  end;
end;

{ Migrations }

function TPgDatabase.AppliedMigrations: TStringList;
var
  Q: TDataSet;
begin
  ExecDirect('CREATE TABLE IF NOT EXISTS schema_migrations (' +
    'version text PRIMARY KEY, ' +
    'applied_at timestamptz NOT NULL DEFAULT now())');
  Commit;
  Result := TStringList.Create;
  try
    Q := Open('SELECT version FROM schema_migrations ORDER BY version', []);
    try
      while not Q.EOF do
      begin
        Result.Add(Q.Fields[0].AsString);
        Q.Next;
      end;
    finally
      Q.Free;
    end;
    Commit;
  except
    Result.Free;
    raise;
  end;
end;

{ Split a migration file into statements: lines ending with ";" end a
  statement, lines starting with "--" are comments. }
function SplitStatements(const AText: string): TStringList;
var
  Lines: TStringList;
  Current, Line: string;
  I: Integer;
begin
  Result := TStringList.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := AText;
    Current := '';
    for I := 0 to Lines.Count - 1 do
    begin
      Line := TrimRight(Lines[I]);
      if (Trim(Line) = '') or (Copy(Trim(Line), 1, 2) = '--') then
        Continue;
      if Current <> '' then
        Current := Current + LineEnding;
      Current := Current + Line;
      if (Line <> '') and (Line[Length(Line)] = ';') then
      begin
        Result.Add(Copy(Current, 1, Length(Current) - 1));
        Current := '';
      end;
    end;
    if Trim(Current) <> '' then
      Result.Add(Current);
  finally
    Lines.Free;
  end;
end;

function TPgDatabase.Migrate(const ADir: string; ALog: TStrings): Integer;
var
  Applied, Files, Statements: TStringList;
  SR: TSearchRec;
  Dir, Version: string;
  I, J: Integer;
begin
  Result := 0;
  Dir := IncludeTrailingPathDelimiter(ADir);
  Applied := AppliedMigrations;
  Files := TStringList.Create;
  try
    if FindFirst(Dir + '*.sql', faAnyFile, SR) = 0 then
    try
      repeat
        Files.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Files.Sort;

    for I := 0 to Files.Count - 1 do
    begin
      Version := ChangeFileExt(Files[I], '');
      if Applied.IndexOf(Version) >= 0 then
        Continue;

      Statements := SplitStatements(LoadTextFileUtf8(Dir + Files[I]));
      try
        try
          StartTransaction;
          for J := 0 to Statements.Count - 1 do
            ExecDirect(Statements[J]);
          Exec('INSERT INTO schema_migrations (version) VALUES (:p1)', [Version]);
          Commit;
        except
          on E: Exception do
          begin
            Rollback;
            raise EPgError.CreateFmt('Migration %s failed: %s', [Files[I], E.Message]);
          end;
        end;
      finally
        Statements.Free;
      end;
      Inc(Result);
      if ALog <> nil then
        ALog.Add('applied ' + Version);
    end;
  finally
    Files.Free;
    Applied.Free;
  end;
end;

initialization

finalization
  {$IFNDEF FPC}
  GDriverLink.Free;
  {$ENDIF}
end.
