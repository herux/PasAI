unit PasAI.StateMachine;

{ A small state machine for conversation flow.

  Each state carries instructions that are added to the system prompt, and
  only explicitly allowed transitions can happen. The point is that the
  conversation flow is decided by code, not by the model: the model is told
  how to behave in the current state, but it cannot move the conversation
  into a state the design does not allow. That makes the flow predictable
  and auditable, which matters in regulated settings. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils, PasAI.Types;

type
  TStateMachine = class
  private
    FNames: TStringList;
    FInstructions: array of string;
    FTransitions: TStringList;   // "from>to"
    FCurrent: string;
    procedure SetCurrent(const AName: string);
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddState(const AName, AInstructions: string);
    procedure AllowTransition(const AFrom, ATo: string);
    function HasState(const AName: string): Boolean;
    function CanTransitionTo(const ATo: string): Boolean;
    { Raises if the transition is not allowed. Moving to the current state
      is always allowed and does nothing. }
    procedure TransitionTo(const ATo: string);
    { Instructions of the current state. }
    function Instructions: string;
    { Setting Current directly is for restoring a saved state; it must name
      a known state but ignores the transition rules. }
    property Current: string read FCurrent write SetCurrent;
  end;

implementation

constructor TStateMachine.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  FTransitions := TStringList.Create;
  FTransitions.Sorted := True;
  FTransitions.Duplicates := dupIgnore;
end;

destructor TStateMachine.Destroy;
begin
  FTransitions.Free;
  FNames.Free;
  inherited Destroy;
end;

procedure TStateMachine.AddState(const AName, AInstructions: string);
var
  N: Integer;
begin
  if HasState(AName) then
    raise EPasAIError.CreateFmt('State "%s" already exists', [AName]);
  FNames.Add(AName);
  N := Length(FInstructions);
  SetLength(FInstructions, N + 1);
  FInstructions[N] := AInstructions;
  if FCurrent = '' then
    FCurrent := AName;   // the first state added is the initial state
end;

procedure TStateMachine.AllowTransition(const AFrom, ATo: string);
begin
  if not HasState(AFrom) or not HasState(ATo) then
    raise EPasAIError.CreateFmt('Unknown state in transition %s -> %s', [AFrom, ATo]);
  FTransitions.Add(AFrom + '>' + ATo);
end;

function TStateMachine.HasState(const AName: string): Boolean;
begin
  Result := FNames.IndexOf(AName) >= 0;
end;

function TStateMachine.CanTransitionTo(const ATo: string): Boolean;
begin
  Result := (ATo = FCurrent) or (FTransitions.IndexOf(FCurrent + '>' + ATo) >= 0);
end;

procedure TStateMachine.TransitionTo(const ATo: string);
begin
  if not CanTransitionTo(ATo) then
    raise EPasAIError.CreateFmt('Transition %s -> %s is not allowed', [FCurrent, ATo]);
  FCurrent := ATo;
end;

procedure TStateMachine.SetCurrent(const AName: string);
begin
  if not HasState(AName) then
    raise EPasAIError.CreateFmt('Unknown state "%s"', [AName]);
  FCurrent := AName;
end;

function TStateMachine.Instructions: string;
var
  I: Integer;
begin
  I := FNames.IndexOf(FCurrent);
  if I < 0 then
    Result := ''
  else
    Result := FInstructions[I];
end;

end.
