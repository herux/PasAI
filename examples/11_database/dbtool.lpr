program DbTool;

{ Example 11: the database behind the companion.

  Commands:
    ./bin/dbtool migrate         apply pending migrations from db/migrations
    ./bin/dbtool status          applied migrations and row counts
    ./bin/dbtool report          what the event tables say about the service
    ./bin/dbtool member ID       one member: facts, fact history, sessions

  The report is the reason the schema keeps events and not only current
  state. "How many members reached coaching", "how often does the input
  guardrail flag messages", "which tool calls were refused" are questions
  that only append-only history can answer.

  Connection settings come from the environment (see PasAI.Pg); the
  defaults match db/docker-compose.yml. Start the database with:
    docker compose -f db/docker-compose.yml up -d }

{$mode delphi}{$H+}
{$codepage utf8}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  Classes, SysUtils, sqldb, PasAI.Pg;

const
  MIGRATIONS_DIR = 'db/migrations';

var
  Db: TPgDatabase;

{ Print every row of a query as aligned columns. }
procedure PrintQuery(const ATitle, ASQL: string; const AParams: array of const);
var
  Q: TSQLQuery;
  Widths: array of Integer;
  Line: string;
  I, Rows: Integer;
begin
  Writeln;
  Writeln(ATitle);
  Q := Db.Open(ASQL, AParams);
  try
    SetLength(Widths, Q.FieldCount);
    for I := 0 to Q.FieldCount - 1 do
    begin
      Widths[I] := Length(Q.Fields[I].FieldName) + 2;
      if Widths[I] < 12 then
        Widths[I] := 12;
    end;
    { Widen columns to fit the first rows. }
    Rows := 0;
    while (not Q.EOF) and (Rows < 50) do
    begin
      for I := 0 to Q.FieldCount - 1 do
        if Length(Q.Fields[I].AsString) + 2 > Widths[I] then
          Widths[I] := Length(Q.Fields[I].AsString) + 2;
      Q.Next;
      Inc(Rows);
    end;
    for I := 0 to High(Widths) do
      if Widths[I] > 60 then
        Widths[I] := 60;

    Line := '  ';
    for I := 0 to Q.FieldCount - 1 do
      Line := Line + Format('%-*s', [Widths[I], Q.Fields[I].FieldName]);
    Writeln(Line);

    Q.First;
    Rows := 0;
    while not Q.EOF do
    begin
      Line := '  ';
      for I := 0 to Q.FieldCount - 1 do
        Line := Line + Format('%-*s', [Widths[I], Copy(Q.Fields[I].AsString, 1, Widths[I] - 2)]);
      Writeln(Line);
      Q.Next;
      Inc(Rows);
    end;
    if Rows = 0 then
      Writeln('  (no rows)');
  finally
    Q.Free;
  end;
  Db.Commit;
end;

procedure DoMigrate;
var
  Log: TStringList;
  I, Count: Integer;
begin
  Log := TStringList.Create;
  try
    Count := Db.Migrate(MIGRATIONS_DIR, Log);
    for I := 0 to Log.Count - 1 do
      Writeln(Log[I]);
    Writeln(Format('%d migration(s) applied', [Count]));
  finally
    Log.Free;
  end;
end;

procedure DoStatus;
var
  Applied: TStringList;
begin
  Applied := Db.AppliedMigrations;
  try
    Writeln('Applied migrations: ', Applied.CommaText);
  finally
    Applied.Free;
  end;
  PrintQuery('Rows per table',
    'SELECT ''members'' AS table_name, count(*) AS rows FROM members ' +
    'UNION ALL SELECT ''sessions'', count(*) FROM sessions ' +
    'UNION ALL SELECT ''member_facts'', count(*) FROM member_facts ' +
    'UNION ALL SELECT ''member_fact_events'', count(*) FROM member_fact_events ' +
    'UNION ALL SELECT ''state_transitions'', count(*) FROM state_transitions ' +
    'UNION ALL SELECT ''input_verdicts'', count(*) FROM input_verdicts ' +
    'UNION ALL SELECT ''bookings'', count(*) FROM bookings ' +
    'UNION ALL SELECT ''tool_audit'', count(*) FROM tool_audit', []);
end;

procedure DoReport;
begin
  PrintQuery('Members per stage',
    'SELECT state, count(*) AS members FROM members GROUP BY state ORDER BY state', []);

  PrintQuery('Input guardrail verdicts, last 30 days (the over-flagging signal)',
    'SELECT category, count(*) AS messages, ' +
    'round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS percent, ' +
    'sum(CASE WHEN by_phrase THEN 1 ELSE 0 END) AS by_phrase ' +
    'FROM input_verdicts WHERE created_at > now() - interval ''30 days'' ' +
    'GROUP BY category ORDER BY messages DESC', []);

  PrintQuery('Stage transitions',
    'SELECT from_state, to_state, reason, count(*) AS times ' +
    'FROM state_transitions GROUP BY from_state, to_state, reason ORDER BY times DESC', []);

  PrintQuery('Open bookings',
    'SELECT reference, member_id, urgency, reason, ' +
    'to_char(created_at, ''YYYY-MM-DD HH24:MI'') AS created ' +
    'FROM bookings WHERE status = ''requested'' ' +
    'ORDER BY (urgency = ''urgent'') DESC, created_at', []);

  PrintQuery('Most recorded facts',
    'SELECT key, count(*) AS members FROM member_facts GROUP BY key ' +
    'ORDER BY members DESC, key LIMIT 10', []);

  PrintQuery('Tool calls by outcome',
    'SELECT tool, outcome, count(*) AS calls, round(avg(duration_ms)) AS avg_ms ' +
    'FROM tool_audit GROUP BY tool, outcome ORDER BY tool, calls DESC', []);
end;

procedure DoMember(const AId: string);
begin
  PrintQuery('Member', 'SELECT id, state, session_count, ' +
    'to_char(created_at, ''YYYY-MM-DD'') AS since, summary FROM members WHERE id = :p1', [AId]);
  PrintQuery('Facts', 'SELECT key, value, to_char(updated_at, ''YYYY-MM-DD HH24:MI'') AS updated ' +
    'FROM member_facts WHERE member_id = :p1 ORDER BY key', [AId]);
  PrintQuery('Fact history', 'SELECT to_char(created_at, ''YYYY-MM-DD HH24:MI'') AS at, ' +
    'session_id AS session, key, coalesce(old_value, ''-'') AS old_value, new_value ' +
    'FROM member_fact_events WHERE member_id = :p1 ORDER BY created_at, id', [AId]);
  PrintQuery('Sessions', 'SELECT id, to_char(started_at, ''YYYY-MM-DD HH24:MI'') AS started, ' +
    'to_char(ended_at, ''HH24:MI'') AS ended, state_at_end AS stage ' +
    'FROM sessions WHERE member_id = :p1 ORDER BY started_at', [AId]);
end;

procedure Usage;
begin
  Writeln('Usage: dbtool migrate | status | report | member ID');
end;

var
  Command: string;
begin
  if ParamCount < 1 then
  begin
    Usage;
    Halt(1);
  end;
  Command := ParamStr(1);

  Db := nil;
  try
    try
      Db := TPgDatabase.Create(PgConfigFromEnv);
      if Command = 'migrate' then
        DoMigrate
      else if Command = 'status' then
        DoStatus
      else if Command = 'report' then
        DoReport
      else if (Command = 'member') and (ParamCount >= 2) then
        DoMember(ParamStr(2))
      else
      begin
        Usage;
        ExitCode := 1;
      end;
    except
      on E: Exception do
      begin
        Writeln('Error: ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Db.Free;
  end;
end.
