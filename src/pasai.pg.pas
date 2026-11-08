unit PasAI.Pg;

{ A thin layer over SQLdb's PostgreSQL connection: loading libpq, running
  parameterized statements, transactions, and schema migrations.

  Parameters, never string concatenation. Every value goes through a
  numbered parameter (:p1, :p2, ...), which SQLdb sends as a prepared
  statement. Text written by members or by the model can then never change
  the meaning of a query: SQL injection is the database cousin of prompt
  injection, and has the same cure, keeping data and instructions apart.

  libpq. SQLdb loads the PostgreSQL client library at runtime. On macOS it
  asks for "libpq.dylib" without a path, which does not find a Homebrew or
  Postgres.app installation, so LoadLibPq tries the usual locations first.
  With PostgreSQL in Docker, the server runs in the container but this
  client library must still be installed on the Mac: brew install libpq.

  Migrations. db/migrations holds numbered SQL files (001_init.sql, ...).
  Migrate applies, in order, each file not yet listed in schema_migrations,
  each one in its own transaction. A file is split into statements at
  lines ending with ";", so keep one statement per such line ending and do
  not use semicolons at line ends inside function bodies. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, sqldb, db, pqconnection, PasAI.Types;

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
    FConnection: TPQConnection;
    FTransaction: TSQLTransaction;
    procedure BindParams(AQuery: TSQLQuery; const AParams: array of const);
    function NewQuery(const ASQL: string; const AParams: array of const): TSQLQuery;
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
    function Open(const ASQL: string; const AParams: array of const): TSQLQuery;

    { First column of the first row as text, or '' when there are no rows. }
    function Value(const ASQL: string; const AParams: array of const): string;

    { Apply pending migrations from ADir. Adds one line per applied file to
      ALog (if given). Returns the number applied. }
    function Migrate(const ADir: string; ALog: TStrings = nil): Integer;

    { Versions already applied, oldest first. }
    function AppliedMigrations: TStringList;

    property Connection: TPQConnection read FConnection;
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

uses
  postgres3dyn;

var
  GLibLoaded: Boolean = False;

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

procedure LoadLibPq(const APath: string);
const
  CANDIDATES: array[0..5] of string = (
    '/opt/homebrew/opt/libpq/lib/libpq.dylib',              // Homebrew, Apple Silicon
    '/usr/local/opt/libpq/lib/libpq.dylib',                 // Homebrew, Intel
    '/Applications/Postgres.app/Contents/Versions/latest/lib/libpq.dylib',
    '/usr/lib/x86_64-linux-gnu/libpq.so.5',                 // Debian, Ubuntu
    '/usr/lib/aarch64-linux-gnu/libpq.so.5',
    '/usr/lib64/libpq.so.5'                                 // Fedora, RHEL
  );
var
  Tried: string;
  I: Integer;

  function TryLoad(const APathToTry: string): Boolean;
  begin
    Result := False;
    if Tried <> '' then
      Tried := Tried + ', ';
    Tried := Tried + APathToTry;
    try
      InitialisePostgres3(APathToTry);
      Result := True;
    except
      on E: EInOutError do
        ;   // not there, try the next one
    end;
  end;

begin
  if GLibLoaded then
    Exit;
  Tried := '';
  if APath <> '' then
  begin
    if not TryLoad(APath) then
      raise EPgError.CreateFmt('Cannot load libpq from %s (PASAI_LIBPQ)', [APath]);
    GLibLoaded := True;
    Exit;
  end;
  for I := 0 to High(CANDIDATES) do
    if FileExists(CANDIDATES[I]) and TryLoad(CANDIDATES[I]) then
    begin
      GLibLoaded := True;
      Exit;
    end;
  { Last resort: the system's own search path. }
  {$IFDEF DARWIN}
  if TryLoad('libpq.dylib') then
  {$ELSE}
  if TryLoad('libpq.so.5') then
  {$ENDIF}
  begin
    GLibLoaded := True;
    Exit;
  end;
  raise EPgError.Create('Cannot find the PostgreSQL client library (libpq). ' +
    'On macOS install it with "brew install libpq", or set PASAI_LIBPQ to its ' +
    'full path. Tried: ' + Tried);
end;

{ TPgDatabase }

constructor TPgDatabase.Create(const AConfig: TPgConfig);
begin
  inherited Create;
  LoadLibPq(AConfig.LibPq);
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
  try
    FConnection.Open;
  except
    on E: Exception do
    begin
      FTransaction.Free;
      FTransaction := nil;
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
  if FTransaction <> nil then
  begin
    if FTransaction.Active then
      FTransaction.Rollback;
    FTransaction.Free;
  end;
  if FConnection <> nil then
  begin
    FConnection.Close;
    FConnection.Free;
  end;
  inherited Destroy;
end;

procedure TPgDatabase.StartTransaction;
begin
  if not FTransaction.Active then
    FTransaction.StartTransaction;
end;

procedure TPgDatabase.Commit;
begin
  if FTransaction.Active then
    FTransaction.Commit;
end;

procedure TPgDatabase.Rollback;
begin
  if FTransaction.Active then
    FTransaction.Rollback;
end;

function TPgDatabase.InTransaction: Boolean;
begin
  Result := FTransaction.Active;
end;

procedure TPgDatabase.BindParams(AQuery: TSQLQuery; const AParams: array of const);
var
  I: Integer;
  P: TParam;
begin
  for I := 0 to High(AParams) do
  begin
    P := AQuery.Params.FindParam('p' + IntToStr(I + 1));
    if P = nil then
      raise EPgError.CreateFmt('Statement has no parameter :p%d', [I + 1]);
    case AParams[I].VType of
      vtInteger:       P.AsInteger := AParams[I].VInteger;
      vtInt64:         P.AsLargeInt := AParams[I].VInt64^;
      vtBoolean:       P.AsBoolean := AParams[I].VBoolean;
      vtExtended:      P.AsFloat := AParams[I].VExtended^;
      vtAnsiString:    P.AsString := AnsiString(AParams[I].VAnsiString);
      vtUnicodeString: P.AsString := string(UnicodeString(AParams[I].VUnicodeString));
      vtChar:          P.AsString := AParams[I].VChar;
      vtString:        P.AsString := string(AParams[I].VString^);
      vtPChar:         P.AsString := string(AParams[I].VPChar);
      vtPointer:
        if AParams[I].VPointer = nil then
        begin
          { Untyped: PostgreSQL then takes the type of the target column, so
            the same nil works for text, bigint and timestamp columns. }
          P.DataType := ftUnknown;
          P.Clear;
        end
        else
          raise EPgError.Create('Only nil pointers are supported as parameters');
    else
      raise EPgError.CreateFmt('Unsupported parameter type for :p%d', [I + 1]);
    end;
  end;
end;

function TPgDatabase.NewQuery(const ASQL: string; const AParams: array of const): TSQLQuery;
begin
  Result := TSQLQuery.Create(nil);
  try
    Result.DataBase := FConnection;
    Result.Transaction := FTransaction;
    Result.SQL.Text := ASQL;
    BindParams(Result, AParams);
  except
    Result.Free;
    raise;
  end;
end;

procedure TPgDatabase.Exec(const ASQL: string; const AParams: array of const);
var
  Q: TSQLQuery;
begin
  StartTransaction;
  Q := NewQuery(ASQL, AParams);
  try
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

function TPgDatabase.Open(const ASQL: string; const AParams: array of const): TSQLQuery;
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
  Q: TSQLQuery;
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

procedure EnsureMigrationTable(ADb: TPgDatabase);
begin
  ADb.StartTransaction;
  ADb.Connection.ExecuteDirect(
    'CREATE TABLE IF NOT EXISTS schema_migrations (' +
    'version text PRIMARY KEY, ' +
    'applied_at timestamptz NOT NULL DEFAULT now())', ADb.FTransaction);
  ADb.Commit;
end;

function TPgDatabase.AppliedMigrations: TStringList;
var
  Q: TSQLQuery;
begin
  EnsureMigrationTable(Self);
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
  Applied, Files, Statements, Script: TStringList;
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

      Script := TStringList.Create;
      try
        Script.LoadFromFile(Dir + Files[I]);
        Statements := SplitStatements(Script.Text);
      finally
        Script.Free;
      end;

      try
        StartTransaction;
        for J := 0 to Statements.Count - 1 do
          FConnection.ExecuteDirect(Statements[J], FTransaction);
        Exec('INSERT INTO schema_migrations (version) VALUES (:p1)', [Version]);
        Commit;
      except
        on E: Exception do
        begin
          Rollback;
          Statements.Free;
          raise EPgError.CreateFmt('Migration %s failed: %s', [Files[I], E.Message]);
        end;
      end;
      Statements.Free;
      Inc(Result);
      if ALog <> nil then
        ALog.Add('applied ' + Version);
    end;
  finally
    Files.Free;
    Applied.Free;
  end;
end;

end.
