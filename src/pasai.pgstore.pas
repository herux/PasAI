unit PasAI.PgStore;

{ PostgreSQL implementations of TMemberStore and TAuditSink, on the schema
  in db/migrations/001_init.sql.

  Every public method is one transaction: it commits when it succeeds and
  rolls back when it fails, so a crash halfway through saving a profile
  never leaves facts without their history. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, sqldb, PasAI.Types, PasAI.Memory, PasAI.Storage, PasAI.Tools,
  PasAI.Pg;

type
  TPgMemberStore = class(TMemberStore)
  private
    FDb: TPgDatabase;
  public
    { ADb is not owned. }
    constructor Create(ADb: TPgDatabase);
    function Describe: string; override;
    function LoadProfile(const AMemberId: string): TMemberProfile; override;
    { Upserts the member and its facts. Every fact that is new or changed
      also gets a row in member_fact_events, linked to the current session. }
    procedure SaveProfile(AProfile: TMemberProfile); override;
    procedure StartSession(const AMemberId: string); override;
    procedure EndSession(const ASummary, AState: string); override;
    procedure RecordInputVerdict(const AMemberId, ACategory, AReason: string;
      AByPhrase: Boolean); override;
    procedure RecordTransition(const AMemberId, AFrom, ATo, AReason: string); override;
    procedure RecordBooking(const AMemberId, AReference, AReason, AUrgency: string); override;
  end;

  TPgAuditSink = class(TAuditSink)
  private
    FDb: TPgDatabase;
  public
    { ADb is not owned. }
    constructor Create(ADb: TPgDatabase);
    procedure Log(const AEntry: TAuditEntry); override;
  end;

implementation

{ TPgMemberStore }

constructor TPgMemberStore.Create(ADb: TPgDatabase);
begin
  inherited Create;
  FDb := ADb;
end;

function TPgMemberStore.Describe: string;
begin
  Result := Format('PostgreSQL database %s on %s',
    [FDb.Connection.DatabaseName, FDb.Connection.HostName]);
end;

function TPgMemberStore.LoadProfile(const AMemberId: string): TMemberProfile;
var
  Q: TSQLQuery;
begin
  Result := TMemberProfile.Create(AMemberId, '');
  try
    Q := FDb.Open('SELECT state, session_count, summary FROM members WHERE id = :p1',
      [AMemberId]);
    try
      if not Q.EOF then
      begin
        Result.State := Q.FieldByName('state').AsString;
        Result.Sessions := Q.FieldByName('session_count').AsInteger;
        Result.Summary := Q.FieldByName('summary').AsString;
      end;
    finally
      Q.Free;
    end;

    Q := FDb.Open('SELECT key, value FROM member_facts WHERE member_id = :p1 ORDER BY key',
      [AMemberId]);
    try
      while not Q.EOF do
      begin
        Result.Facts.Values[Q.FieldByName('key').AsString] := Q.FieldByName('value').AsString;
        Q.Next;
      end;
    finally
      Q.Free;
    end;
    FDb.Commit;
  except
    FDb.Rollback;
    Result.Free;
    raise;
  end;
end;

procedure TPgMemberStore.SaveProfile(AProfile: TMemberProfile);
var
  Existing: TStringList;
  Q: TSQLQuery;
  State, Key, Value: string;
  I, Known: Integer;
begin
  State := AProfile.State;
  if State = '' then
    State := 'onboarding';

  Existing := TStringList.Create;
  try
    try
      FDb.StartTransaction;
      FDb.Exec(
        'INSERT INTO members (id, state, session_count, summary) ' +
        'VALUES (:p1, :p2, :p3, :p4) ' +
        'ON CONFLICT (id) DO UPDATE SET state = EXCLUDED.state, ' +
        'session_count = EXCLUDED.session_count, summary = EXCLUDED.summary, ' +
        'updated_at = now()',
        [AProfile.Id, State, AProfile.Sessions, AProfile.Summary]);

      Q := FDb.Open('SELECT key, value FROM member_facts WHERE member_id = :p1',
        [AProfile.Id]);
      try
        while not Q.EOF do
        begin
          Existing.Values[Q.FieldByName('key').AsString] := Q.FieldByName('value').AsString;
          Q.Next;
        end;
      finally
        Q.Free;
      end;

      for I := 0 to AProfile.Facts.Count - 1 do
      begin
        Key := AProfile.Facts.Names[I];
        Value := AProfile.Facts.ValueFromIndex[I];
        Known := Existing.IndexOfName(Key);
        if (Known >= 0) and (Existing.ValueFromIndex[Known] = Value) then
          Continue;

        FDb.Exec(
          'INSERT INTO member_facts (member_id, key, value) VALUES (:p1, :p2, :p3) ' +
          'ON CONFLICT (member_id, key) DO UPDATE SET value = EXCLUDED.value, ' +
          'updated_at = now()',
          [AProfile.Id, Key, Value]);

        if Known >= 0 then
          FDb.Exec(
            'INSERT INTO member_fact_events (member_id, session_id, key, old_value, new_value) ' +
            'VALUES (:p1, NULLIF(:p2, 0), :p3, :p4, :p5)',
            [AProfile.Id, FSessionId, Key, Existing.ValueFromIndex[Known], Value])
        else
          FDb.Exec(
            'INSERT INTO member_fact_events (member_id, session_id, key, old_value, new_value) ' +
            'VALUES (:p1, NULLIF(:p2, 0), :p3, :p4, :p5)',
            [AProfile.Id, FSessionId, Key, nil, Value]);
      end;
      FDb.Commit;
    except
      FDb.Rollback;
      raise;
    end;
  finally
    Existing.Free;
  end;
end;

procedure TPgMemberStore.StartSession(const AMemberId: string);
begin
  try
    FDb.StartTransaction;
    FDb.Exec('INSERT INTO members (id) VALUES (:p1) ON CONFLICT (id) DO NOTHING',
      [AMemberId]);
    FSessionId := StrToInt64(FDb.Value(
      'INSERT INTO sessions (member_id) VALUES (:p1) RETURNING id', [AMemberId]));
    FDb.Commit;
  except
    FDb.Rollback;
    FSessionId := 0;
    raise;
  end;
end;

procedure TPgMemberStore.EndSession(const ASummary, AState: string);
begin
  if FSessionId = 0 then
    Exit;
  try
    FDb.Exec('UPDATE sessions SET ended_at = now(), summary = :p2, state_at_end = :p3 ' +
      'WHERE id = :p1', [FSessionId, ASummary, AState]);
    FDb.Commit;
  except
    FDb.Rollback;
    raise;
  end;
  FSessionId := 0;
end;

procedure TPgMemberStore.RecordInputVerdict(const AMemberId, ACategory, AReason: string;
  AByPhrase: Boolean);
begin
  try
    FDb.Exec('INSERT INTO input_verdicts (member_id, session_id, category, reason, by_phrase) ' +
      'VALUES (:p1, NULLIF(:p2, 0), :p3, :p4, :p5)',
      [AMemberId, FSessionId, ACategory, AReason, AByPhrase]);
    FDb.Commit;
  except
    FDb.Rollback;
    raise;
  end;
end;

procedure TPgMemberStore.RecordTransition(const AMemberId, AFrom, ATo, AReason: string);
begin
  try
    FDb.Exec('INSERT INTO state_transitions (member_id, session_id, from_state, to_state, reason) ' +
      'VALUES (:p1, NULLIF(:p2, 0), :p3, :p4, :p5)',
      [AMemberId, FSessionId, AFrom, ATo, AReason]);
    FDb.Commit;
  except
    FDb.Rollback;
    raise;
  end;
end;

procedure TPgMemberStore.RecordBooking(const AMemberId, AReference, AReason,
  AUrgency: string);
begin
  try
    FDb.Exec('INSERT INTO members (id) VALUES (:p1) ON CONFLICT (id) DO NOTHING', [AMemberId]);
    FDb.Exec('INSERT INTO bookings (reference, member_id, session_id, reason, urgency) ' +
      'VALUES (:p1, :p2, NULLIF(:p3, 0), :p4, :p5)',
      [AReference, AMemberId, FSessionId, AReason, AUrgency]);
    FDb.Commit;
  except
    FDb.Rollback;
    raise;
  end;
end;

{ TPgAuditSink }

constructor TPgAuditSink.Create(ADb: TPgDatabase);
begin
  inherited Create;
  FDb := ADb;
end;

procedure TPgAuditSink.Log(const AEntry: TAuditEntry);
begin
  try
    FDb.Exec('INSERT INTO tool_audit (user_id, tool, arguments, outcome, detail, duration_ms) ' +
      'VALUES (:p1, :p2, :p3, :p4, :p5, :p6)',
      [AEntry.UserId, AEntry.Tool, AEntry.Arguments, AEntry.Outcome, AEntry.Detail,
       AEntry.DurationMs]);
    FDb.Commit;
  except
    FDb.Rollback;
    raise;
  end;
end;

end.
