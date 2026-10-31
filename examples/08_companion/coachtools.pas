unit CoachTools;

{ The human handover: booking a session with a human coach.

  BookCoach is called in two ways. The companion program calls it directly
  when the input guardrail detects a crisis or an explicit request for a
  human: those decisions are too important to leave to the model. The model
  can also call it as the tool book_human_coach, for situations the code
  cannot recognize by itself, such as a debt problem that needs more than
  habit coaching.

  Bookings are appended to data/bookings.log. In a real service this is
  where the booking system or the coach on duty would be notified. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, fpjson, PasAI.Schema, PasAI.Tools;

const
  BOOKINGS_FILE = 'data/bookings.log';

var
  { The member the tool books for; set by the program before chatting. }
  CurrentMemberId: string;

{ Record a booking and return a message describing it. AUrgency is
  "normal" or "urgent". }
function BookCoach(const AMemberId, AReason, AUrgency: string): string;

function BuildCoachTools: TToolRegistry;

implementation

function BookCoach(const AMemberId, AReason, AUrgency: string): string;
var
  F: TextFile;
  Reference, When: string;
begin
  Reference := 'BK-' + FormatDateTime('mmddhhnnss', Now);
  ForceDirectories(ExtractFileDir(BOOKINGS_FILE));
  AssignFile(F, BOOKINGS_FILE);
  if FileExists(BOOKINGS_FILE) then
    Append(F)
  else
    Rewrite(F);
  try
    Writeln(F, FormatDateTime('yyyy-mm-dd hh:nn:ss', Now), #9, Reference, #9,
      AMemberId, #9, AUrgency, #9, AReason);
  finally
    CloseFile(F);
  end;

  if AUrgency = 'urgent' then
    When := 'within 1 hour'
  else
    When := 'within 24 hours';
  Result := Format('Booked %s: a human coach will contact the member %s.',
    [Reference, When]);
end;

function ToolBookCoach(AArgs: TJSONObject): string;
begin
  Result := BookCoach(CurrentMemberId, AArgs.Strings['reason'], AArgs.Strings['urgency']);
end;

function BuildCoachTools: TToolRegistry;
begin
  Result := TToolRegistry.Create;
  Result.Add('book_human_coach',
    'Books a session with a human coach. Use it when the member asks to talk ' +
    'to a person, or when their situation needs more than habit coaching, ' +
    'for example serious debt problems or legal or tax questions.',
    ObjectSchema
      .Str('reason', 'Why a human coach is needed, in one sentence')
      .Enum('urgency', ['normal', 'urgent'], 'urgent only if the member may be at risk')
      .ToJSON,
    ToolBookCoach);
end;

end.
