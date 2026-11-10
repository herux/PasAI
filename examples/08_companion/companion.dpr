program companion;   // Delphi requires this name to match the file name

{ Example 8: an AI coaching companion with memory, a state machine,
  guardrails and a human handover.

  PasCoach is a fictional personal finance habits coach. It is not a
  financial advisor, so recommending specific investments is outside its
  regulated boundary. Every message goes through this pipeline, and each
  step is printed as a line starting with a dot so it can be followed:

    1. input guardrail   crisis phrases, then a classifier
    2. state machine     onboarding -> coaching -> handover
    3. agent             persona + state instructions + remembered facts
                         + session notes, with a booking tool
    4. output guardrail  reply language and forbidden phrases; retry,
                         then a safe fallback
    5. memory            facts extracted and saved after every turn

  Run:   ./bin/companion [-db] [member-id] [model]
         -db stores everything in PostgreSQL (see db/docker-compose.yml)
         instead of files, including fact history, state transitions and
         input verdicts.
  Then:  /profile  show what is remembered    /state  show the state
         /quit     save session notes and exit

  Quit and start again with the same member id: it remembers. Without
  -db, profiles are stored in data/members/ and bookings in
  data/bookings.log. }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  Classes, SysUtils,
  PasAI.Types, PasAI.Provider, PasAI.Ollama, PasAI.Tools, PasAI.Agent,
  PasAI.Guardrails, PasAI.Memory, PasAI.StateMachine,
  PasAI.Storage, PasAI.Pg, PasAI.PgStore,
  CoachTools;

const
  DEFAULT_MEMBER = 'demo';
  DEFAULT_MODEL = 'qwen2.5:7b-instruct';
  MEMBERS_DIR = 'data/members';
  BOOKINGS_FILE = 'data/bookings.log';
  MIGRATIONS_DIR = 'db/migrations';

  SCOPE = 'personal budgeting, saving habits, spending awareness, debt habits, ' +
    'financial goals and the motivation to reach them';

  PERSONA =
    'You are PasCoach, a warm and practical personal finance habits coach. ' +
    'You help members with budgeting, saving habits, spending awareness and ' +
    'financial goals. You are not a licensed financial advisor: never ' +
    'recommend specific investments, stocks, crypto, insurance or loan ' +
    'products, and never give tax or legal advice. Keep replies short, at ' +
    'most 5 sentences, and ask at most one question per reply. Always reply ' +
    'in the same language as the member''s latest message.';

  { Deterministic output check: phrases that would cross the regulated
    boundary. Crude on purpose; the prompt and the input classifier are the
    main defence, this catches what slips through. }
  FORBIDDEN_PHRASES =
    'beli saham|belilah saham|jual saham|buy shares|buy stock|sell your shares|' +
    'invest in bitcoin|beli bitcoin|guaranteed return|pasti untung|dijamin untung';

  STATE_ONBOARDING =
    'Current stage: onboarding. Get to know the member: their name and one ' +
    'concrete financial goal (what, how much, by when). Ask one question at a time.';
  STATE_COACHING =
    'Current stage: coaching. Help the member make progress on their goal with ' +
    'small, concrete actions for the coming week. Before suggesting something ' +
    'new, check on commitments mentioned in the notes.';
  STATE_HANDOVER =
    'Current stage: handover. The member has been referred to a human coach ' +
    'because of a sensitive situation. Do not coach. Be warm and brief, remind ' +
    'them that a human coach will contact them soon, and encourage them to call ' +
    'emergency services (112) if they are in danger.';

  CRISIS_REPLY_ID =
    'Terima kasih sudah mau bercerita. Yang kamu rasakan itu penting, dan kamu ' +
    'tidak harus menghadapinya sendirian. Saya sudah meminta coach manusia ' +
    'untuk segera menghubungimu. Jika kamu merasa dalam bahaya sekarang, ' +
    'segera hubungi layanan darurat 112 atau orang terdekat yang kamu percaya.';
  CRISIS_REPLY_EN =
    'Thank you for telling me. What you are feeling matters, and you do not ' +
    'have to face it alone. I have asked a human coach to contact you soon. ' +
    'If you feel you are in danger right now, please call emergency services ' +
    '(112 in Indonesia) or someone you trust.';

  FALLBACK_ID =
    'Maaf, saya belum bisa memberi jawaban yang tepat untuk itu. Bisa ceritakan ' +
    'lagi dengan kata lain, atau mau saya jadwalkan sesi dengan coach manusia?';
  FALLBACK_EN =
    'Sorry, I could not give a proper answer to that. Could you say it another ' +
    'way, or would you like me to book a session with a human coach?';

var
  Chat: TOllamaClient;
  Tools: TToolRegistry;
  Profile: TMemberProfile;
  Store: TMemberStore;
  Flow: TStateMachine;
  History: TChatMessages;
  SessionNotes: string;

procedure Trace(const AText: string);
begin
  Writeln('  . ', AText);
end;

procedure TraceAgent(AEvent: TAgentEvent; const AText: string);
begin
  case AEvent of
    aeToolCall:   Trace('tool call: ' + AText);
    aeToolResult: Trace('tool result: ' + AText);
    aeAnswer:     ;
  end;
end;

function InEnglish(const AText: string): Boolean;
begin
  Result := DetectLanguage(AText) = 'en';
end;

function BuildSystemPrompt(const ATurnNote: string): string;
var
  Known: string;
begin
  Result := PERSONA + LineEnding + LineEnding + Flow.Instructions;

  Known := Profile.FactsAsText;
  if Known <> '' then
    Result := Result + LineEnding + LineEnding +
      'What you know about this member:' + LineEnding + Known;

  if Trim(Profile.Summary + SessionNotes) <> '' then
    Result := Result + LineEnding + 'Notes from earlier conversations:' + LineEnding +
      Trim(Profile.Summary + ' ' + SessionNotes);

  if ATurnNote <> '' then
    Result := Result + LineEnding + LineEnding + 'For this reply: ' + ATurnNote;
end;

{ Step 4: check the reply, ask for a rewrite up to twice, then fall back. }
function GuardReply(const AMemberText, AReply: string; var AMsgs: TChatMessages): string;
var
  Problem, Phrase: string;
  Attempt: Integer;
begin
  Result := AReply;
  for Attempt := 1 to 3 do
  begin
    Problem := '';
    Phrase := FindPhrase(Result, FORBIDDEN_PHRASES);
    if Phrase <> '' then
      Problem := 'it contains "' + Phrase + '", which is regulated financial advice'
    else
      CheckReplyLanguage(AMemberText, Result, Problem);   // sets Problem on a mismatch

    if Problem = '' then
    begin
      if Attempt > 1 then
        Trace('output guardrail: rewrite accepted');
      Exit;
    end;

    Trace('output guardrail: ' + Problem);
    if Attempt = 3 then
      Break;

    AddMessage(AMsgs, ROLE_ASSISTANT, Result);
    AddMessage(AMsgs, ROLE_USER,
      'Your previous reply broke a rule: ' + Problem + '. Rewrite it so it ' +
      'follows all the rules. Output only the new reply.');
    Result := Chat.Chat(AMsgs);
  end;

  Trace('output guardrail: using the safe fallback');
  if InEnglish(AMemberText) then
    Result := FALLBACK_EN
  else
    Result := FALLBACK_ID;
end;

procedure HandleCrisis(const AText: string);
var
  Reply: string;
begin
  Trace(BookCoach(Profile.Id, 'crisis signal in conversation', 'urgent'));
  if (Flow.Current <> 'handover') and Flow.CanTransitionTo('handover') then
  begin
    Store.RecordTransition(Profile.Id, Flow.Current, 'handover', 'crisis signal');
    Flow.TransitionTo('handover');
    Trace('state: -> handover');
  end;
  Profile.State := Flow.Current;
  Store.SaveProfile(Profile);
  if InEnglish(AText) then
    Reply := CRISIS_REPLY_EN
  else
    Reply := CRISIS_REPLY_ID;
  Writeln(Reply);
  AddMessage(History, ROLE_USER, AText);
  AddMessage(History, ROLE_ASSISTANT, Reply);
  { Crisis details are deliberately not passed to fact extraction. }
end;

procedure HandleTurn(const AText: string);
var
  Verdict: TInputVerdict;
  TurnNote, Reply: string;
  Msgs: TChatMessages;
  Changes: TStringList;
  I: Integer;
begin
  { 1. Input guardrail }
  Verdict := ClassifyInput(Chat, AText, SCOPE);
  Trace(Format('input: %s (%s)', [INPUT_CATEGORY_NAMES[Verdict.Category], Verdict.Reason]));
  Store.RecordInputVerdict(Profile.Id, INPUT_CATEGORY_NAMES[Verdict.Category],
    Verdict.Reason, Verdict.ByPhrase);

  TurnNote := '';
  case Verdict.Category of
    icCrisis:
      begin
        HandleCrisis(AText);
        Exit;
      end;
    icHumanRequest:
      begin
        Trace(BookCoach(Profile.Id, 'member asked for a human coach', 'normal'));
        TurnNote := 'A human coach has just been booked at the member''s request. ' +
          'Confirm this, and offer to keep working together until then.';
      end;
    icRegulatedAdvice:
      TurnNote := 'The member asked for regulated financial advice. Do not give it: ' +
        'explain briefly that you cannot recommend specific products, investments, ' +
        'tax or legal steps, suggest a licensed advisor, then help with the habits ' +
        'side of their question.';
    icOutOfScope:
      TurnNote := 'The message is outside what you coach on. Say so kindly in one ' +
        'sentence and steer back to their financial goal.';
  end;

  { 2 and 3. State instructions, memory, and the agent }
  Msgs := nil;
  AddMessage(Msgs, ROLE_SYSTEM, BuildSystemPrompt(TurnNote));
  for I := 0 to High(History) do
    AppendMessage(Msgs, History[I]);
  AddMessage(Msgs, ROLE_USER, AText);
  Reply := RunAgent(Chat, Tools, Msgs, 6, TraceAgent);

  { 4. Output guardrail }
  Reply := GuardReply(AText, Reply, Msgs);
  Writeln(Reply);
  AddMessage(History, ROLE_USER, AText);
  AddMessage(History, ROLE_ASSISTANT, Reply);

  { 5. Memory, and the state transitions that depend on it }
  if Flow.Current <> 'handover' then
  begin
    Changes := TStringList.Create;
    try
      try
        UpdateFacts(Chat, Profile, AText, Reply, Changes);
        for I := 0 to Changes.Count - 1 do
          Trace('memory: ' + Changes[I]);
      except
        on E: EPasAIError do
          Trace('memory: extraction failed: ' + E.Message);
      end;
    finally
      Changes.Free;
    end;

    if (Flow.Current = 'onboarding') and Profile.HasFact('goal') then
    begin
      Store.RecordTransition(Profile.Id, 'onboarding', 'coaching', 'goal known');
      Flow.TransitionTo('coaching');
      Trace('state: onboarding -> coaching (a goal is known)');
    end;
  end;

  Profile.State := Flow.Current;
  Store.SaveProfile(Profile);

  if CompactHistory(Chat, History, SessionNotes, 16, 8) then
    Trace('memory: older messages summarized into session notes');
end;

procedure EndSession;
begin
  if Length(History) > 0 then
  begin
    Writeln('(writing session notes...)');
    Profile.Summary := SummarizeSession(Chat, History,
      Trim(Profile.Summary + ' ' + SessionNotes));
  end;
  Profile.State := Flow.Current;
  Store.SaveProfile(Profile);
  Store.EndSession(Profile.Summary, Flow.Current);
  Writeln('Saved to ', Store.Describe);
end;

var
  MemberId, ModelName, Line: string;
  UseDb: Boolean;
  Db: TPgDatabase;
  AuditSink: TPgAuditSink;
  Applied: TStringList;
  Positional, I: Integer;
begin
  InitConsole;
  MemberId := DEFAULT_MEMBER;
  ModelName := DEFAULT_MODEL;
  UseDb := False;
  Positional := 0;
  for I := 1 to ParamCount do
    if ParamStr(I) = '-db' then
      UseDb := True
    else
    begin
      Inc(Positional);
      if Positional = 1 then
        MemberId := ParamStr(I)
      else if Positional = 2 then
        ModelName := ParamStr(I);
    end;
  CurrentMemberId := MemberId;

  Chat := TOllamaClient.Create(ModelName);
  Tools := BuildCoachTools;
  Flow := TStateMachine.Create;
  Profile := nil;
  Store := nil;
  Db := nil;
  AuditSink := nil;
  try
    try
      Chat.Temperature := 0.3;

      if UseDb then
      begin
        Db := TPgDatabase.Create(PgConfigFromEnv);
        Applied := TStringList.Create;
        try
          Db.Migrate(MIGRATIONS_DIR, Applied);
          for I := 0 to Applied.Count - 1 do
            Writeln('database: ', Applied[I]);
        finally
          Applied.Free;
        end;
        Store := TPgMemberStore.Create(Db);
        AuditSink := TPgAuditSink.Create(Db);
        Tools.AuditSink := AuditSink;
      end
      else
        Store := TFileMemberStore.Create(MEMBERS_DIR, BOOKINGS_FILE);
      BookingStore := Store;
      Tools.Context := ToolContext(MemberId, '');

      Flow.AddState('onboarding', STATE_ONBOARDING);
      Flow.AddState('coaching', STATE_COACHING);
      Flow.AddState('handover', STATE_HANDOVER);
      Flow.AllowTransition('onboarding', 'coaching');
      Flow.AllowTransition('onboarding', 'handover');
      Flow.AllowTransition('coaching', 'handover');

      Profile := Store.LoadProfile(MemberId);
      Store.StartSession(MemberId);
      Profile.Sessions := Profile.Sessions + 1;
      if Profile.State <> '' then
        Flow.Current := Profile.State;

      Writeln(Format('PasCoach (%s), member "%s", session %d, stage %s',
        [ModelName, MemberId, Profile.Sessions, Flow.Current]));
      Writeln('Storage: ', Store.Describe);
      if Profile.Facts.Count > 0 then
        Writeln(Format('Remembering %d fact(s) from earlier sessions. /profile shows them.',
          [Profile.Facts.Count]));
      Writeln('Type a message, or /profile, /state, /quit.');

      History := nil;
      SessionNotes := '';
      while True do
      begin
        Writeln;
        Write('> ');
        Flush(Output);
        if EOF(Input) then
          Break;
        Readln(Line);
        Line := Trim(Line);
        if Line = '' then
          Continue;
        if Line = '/quit' then
          Break;
        if Line = '/state' then
        begin
          Writeln('stage: ', Flow.Current);
          Continue;
        end;
        if Line = '/profile' then
        begin
          if Profile.Facts.Count = 0 then
            Writeln('(no facts yet)')
          else
            Write(Profile.FactsAsText);
          if Profile.Summary <> '' then
            Writeln('notes: ', Profile.Summary);
          Continue;
        end;

        try
          HandleTurn(Line);
        except
          on E: Exception do
            Writeln('Error: ', E.Message);
        end;
      end;

      EndSession;
    except
      on E: Exception do
      begin
        Writeln('Error: ', E.Message);
        ExitCode := 1;
      end;
    end;
  finally
    Profile.Free;
    Flow.Free;
    Tools.Free;
    AuditSink.Free;
    Store.Free;
    Db.Free;
    Chat.Free;
  end;
end.
