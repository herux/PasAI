unit PasAI.Storage;

{ Where the companion keeps what it knows, behind one interface.

  TMemberStore is what the application talks to. TFileMemberStore keeps the
  original behaviour (one JSON file per member, a bookings log) and needs
  nothing installed. TPgMemberStore in PasAI.PgStore writes the same data
  to PostgreSQL, plus the events a file store cannot usefully keep: fact
  history, state transitions, input verdicts. Swapping one for the other
  does not change the application code.

  A store tracks the current session: StartSession opens it, the Record*
  methods attach to it, EndSession closes it. }

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types, PasAI.Memory;

type
  TMemberStore = class
  protected
    FSessionId: Int64;
  public
    { Where the data goes, for messages such as "Saved to ...". }
    function Describe: string; virtual; abstract;

    { The member's profile, or an empty one for a new member. The caller
      frees it. }
    function LoadProfile(const AMemberId: string): TMemberProfile; virtual; abstract;
    procedure SaveProfile(AProfile: TMemberProfile); virtual; abstract;

    procedure StartSession(const AMemberId: string); virtual;
    procedure EndSession(const ASummary, AState: string); virtual;

    procedure RecordInputVerdict(const AMemberId, ACategory, AReason: string;
      AByPhrase: Boolean); virtual;
    procedure RecordTransition(const AMemberId, AFrom, ATo, AReason: string); virtual;
    procedure RecordBooking(const AMemberId, AReference, AReason, AUrgency: string);
      virtual; abstract;

    { 0 when no session is open, or when the store has no session ids. }
    property SessionId: Int64 read FSessionId;
  end;

  TFileMemberStore = class(TMemberStore)
  private
    FDir: string;
    FBookingsFile: string;
  public
    constructor Create(const ADir, ABookingsFile: string);
    function Describe: string; override;
    function LoadProfile(const AMemberId: string): TMemberProfile; override;
    procedure SaveProfile(AProfile: TMemberProfile); override;
    procedure RecordBooking(const AMemberId, AReference, AReason, AUrgency: string); override;
  end;

implementation

{ TMemberStore: the default implementations keep nothing. }

procedure TMemberStore.StartSession(const AMemberId: string);
begin
  FSessionId := 0;
end;

procedure TMemberStore.EndSession(const ASummary, AState: string);
begin
  FSessionId := 0;
end;

procedure TMemberStore.RecordInputVerdict(const AMemberId, ACategory, AReason: string;
  AByPhrase: Boolean);
begin
end;

procedure TMemberStore.RecordTransition(const AMemberId, AFrom, ATo, AReason: string);
begin
end;

{ TFileMemberStore }

constructor TFileMemberStore.Create(const ADir, ABookingsFile: string);
begin
  inherited Create;
  FDir := ADir;
  FBookingsFile := ABookingsFile;
end;

function TFileMemberStore.Describe: string;
begin
  Result := 'files in ' + FDir;
end;

function TFileMemberStore.LoadProfile(const AMemberId: string): TMemberProfile;
begin
  Result := TMemberProfile.Load(FDir, AMemberId);
end;

procedure TFileMemberStore.SaveProfile(AProfile: TMemberProfile);
begin
  AProfile.Save;
end;

procedure TFileMemberStore.RecordBooking(const AMemberId, AReference, AReason,
  AUrgency: string);
var
  F: TextFile;
begin
  ForceDirectories(ExtractFileDir(ExpandFileName(FBookingsFile)));
  AssignFile(F, FBookingsFile);
  if FileExists(FBookingsFile) then
    Append(F)
  else
    Rewrite(F);
  try
    Writeln(F, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), #9, AReference, #9,
      AMemberId, #9, AUrgency, #9, AReason);
  finally
    CloseFile(F);
  end;
end;

end.
