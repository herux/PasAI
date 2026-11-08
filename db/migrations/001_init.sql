-- PasAI data model: the coaching companion and the tool audit trail.
--
-- Design notes
-- - members holds the current state; everything that happens over time is
--   in append-only event tables (fact changes, state transitions, input
--   verdicts, tool audit). Current state answers "where is this member
--   now", events answer "how did they get here" and feed reports.
-- - No conversation transcripts are stored. Facts and session summaries are
--   what the companion needs; raw messages would add risk without adding
--   capability (data minimization).
-- - CHECK constraints mirror the values the application uses, so a bug in
--   the code cannot write a state or category that does not exist.
-- - One statement per line ending with a semicolon: see PasAI.Pg.Migrate.

CREATE TABLE members (
  id            text PRIMARY KEY,
  state         text NOT NULL DEFAULT 'onboarding'
                CHECK (state IN ('onboarding', 'coaching', 'handover')),
  session_count integer NOT NULL DEFAULT 0,
  summary       text NOT NULL DEFAULT '',
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
  id           bigserial PRIMARY KEY,
  member_id    text NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  started_at   timestamptz NOT NULL DEFAULT now(),
  ended_at     timestamptz,
  summary      text,
  state_at_end text
);

CREATE INDEX sessions_member_idx ON sessions (member_id, started_at DESC);

-- Current facts: one row per member and key.
CREATE TABLE member_facts (
  member_id  text NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  key        text NOT NULL,
  value      text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (member_id, key)
);

-- Insight capture: every change of a fact, with the session it came from.
CREATE TABLE member_fact_events (
  id         bigserial PRIMARY KEY,
  member_id  text NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  session_id bigint REFERENCES sessions(id) ON DELETE SET NULL,
  key        text NOT NULL,
  old_value  text,
  new_value  text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX member_fact_events_member_idx ON member_fact_events (member_id, created_at);

-- Progress tracking: how members move through the coaching flow.
CREATE TABLE state_transitions (
  id         bigserial PRIMARY KEY,
  member_id  text NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  session_id bigint REFERENCES sessions(id) ON DELETE SET NULL,
  from_state text NOT NULL,
  to_state   text NOT NULL,
  reason     text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Routing log: the input guardrail's decision for every message, without
-- the message itself. The share of non-normal verdicts over time is the
-- production signal for over-flagging.
CREATE TABLE input_verdicts (
  id         bigserial PRIMARY KEY,
  member_id  text NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  session_id bigint REFERENCES sessions(id) ON DELETE SET NULL,
  category   text NOT NULL
             CHECK (category IN ('normal', 'out_of_scope', 'regulated_advice', 'crisis', 'human_request')),
  reason     text NOT NULL DEFAULT '',
  by_phrase  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX input_verdicts_time_idx ON input_verdicts (created_at);

-- Human handover.
CREATE TABLE bookings (
  id         bigserial PRIMARY KEY,
  reference  text NOT NULL UNIQUE,
  member_id  text NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  session_id bigint REFERENCES sessions(id) ON DELETE SET NULL,
  reason     text NOT NULL,
  urgency    text NOT NULL CHECK (urgency IN ('normal', 'urgent')),
  status     text NOT NULL DEFAULT 'requested'
             CHECK (status IN ('requested', 'confirmed', 'done', 'cancelled')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX bookings_open_idx ON bookings (status, urgency, created_at);

-- Every tool call attempt, allowed or refused. Not tied to members: tools
-- also run for staff and other users. arguments is text, not jsonb, because
-- the model can send invalid JSON and the audit must never fail to record.
CREATE TABLE tool_audit (
  id          bigserial PRIMARY KEY,
  created_at  timestamptz NOT NULL DEFAULT now(),
  user_id     text NOT NULL,
  tool        text NOT NULL,
  arguments   text NOT NULL DEFAULT '',
  outcome     text NOT NULL,
  detail      text NOT NULL DEFAULT '',
  duration_ms integer NOT NULL DEFAULT 0
);

CREATE INDEX tool_audit_time_idx ON tool_audit (created_at);

CREATE INDEX tool_audit_user_idx ON tool_audit (user_id, created_at);
