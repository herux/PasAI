unit PasAI.Types;

{ Core types shared by every PasAI unit.
  This unit intentionally depends on neither HTTP nor JSON, so the upper
  layers (agents, memory, evals) are never tied to a specific provider.
  Where JSON is needed (schemas, tool arguments) it is carried as text.

  It also holds the small compatibility layer between Free Pascal and
  Delphi: in FPC a string holds UTF-8 bytes, in Delphi UTF-16 characters;
  number and date formatting follow the system locale in Delphi (an
  Indonesian Windows writes 1,5 for one and a half); a few names differ.
  Code elsewhere uses these helpers instead of compiler-specific calls. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  Classes, SysUtils;

{$IFNDEF FPC}
type
  PtrInt = NativeInt;

const
  LineEnding = sLineBreak;
{$ENDIF}

const
  ROLE_SYSTEM    = 'system';
  ROLE_USER      = 'user';
  ROLE_ASSISTANT = 'assistant';
  ROLE_TOOL      = 'tool';

type
  { Root of all PasAI exceptions. Catch this to handle any library error. }
  EPasAIError = class(Exception);

  { A request from the model to run one tool. }
  TToolCall = record
    Id: string;          // set by some providers; may be empty
    Name: string;
    Arguments: string;   // a JSON object, as text
  end;

  TToolCalls = array of TToolCall;

  { A single message in a conversation. LLMs are stateless: the entire
    conversation history is sent again on every API call.

    Besides plain text, a message can carry tool traffic:
    - an assistant message may contain ToolCalls (the model asks us to run tools)
    - a ROLE_TOOL message carries a tool's result back, with ToolName set }
  TChatMessage = record
    Role: string;
    Content: string;
    ToolCalls: TToolCalls;
    ToolName: string;
    ToolCallId: string;
  end;

  TChatMessages = array of TChatMessage;

  { What the model is told about a tool: its name, what it does, and the
    JSON schema of its arguments. The description matters a lot: it is the
    only thing the model reads when deciding whether to use the tool. }
  TToolSpec = record
    Name: string;
    Description: string;
    ParametersSchema: UTF8String;
  end;

  TToolSpecs = array of TToolSpec;

  { Callback for text chunks during streaming. Deliberately a plain
    procedure (not "of object") so it is easy to use from console programs.
    An "of object" variant can be added later for GUI applications. }
  TTextChunkProc = procedure(const AText: string);

function ChatMessage(const ARole, AContent: string): TChatMessage;
function ToolResultMessage(const ACall: TToolCall; const AResult: string): TChatMessage;
procedure AddMessage(var AMessages: TChatMessages; const ARole, AContent: string);
procedure AppendMessage(var AMessages: TChatMessages; const AMessage: TChatMessage);

{ Compatibility helpers }

var
  { "." as decimal separator and English day and month names, whatever the
    system locale. Use it for anything a model, a file or a test reads. }
  InvariantFormat: TFormatSettings;

{ Milliseconds from a monotonic clock, for measuring durations. }
function TickMs: UInt64;

{ Read a whole UTF-8 text file (a leading byte order mark is skipped). }
function LoadTextFileUtf8(const AFileName: string): string;

{ Write AText to a file as UTF-8, creating its folder if needed. }
procedure SaveTextFileUtf8(const AFileName, AText: string);

{ Append one line, as UTF-8, creating the file and folder if needed. }
procedure AppendLineUtf8(const AFileName, ALine: string);

{ Convert between a string and the UTF-8 bytes used on the network and in
  files. In FPC these are mostly no-ops; in Delphi they transcode. }
function Utf8BytesToString(const ABytes: RawByteString): string;
function StringToUtf8Bytes(const AText: string): RawByteString;

{ Make console output UTF-8 on Windows. Call first in a program. }
procedure InitConsole;

{ ASCII letter or digit. Avoids set expressions on Char, which Delphi
  warns about because its Char is two bytes wide. }
function IsAsciiAlnum(C: Char): Boolean;

implementation

{$IFDEF MSWINDOWS}
uses
  Windows;
{$ENDIF}

function ChatMessage(const ARole, AContent: string): TChatMessage;
begin
  { Every field is set explicitly: a function result record is not
    guaranteed to start empty. }
  Result.Role := ARole;
  Result.Content := AContent;
  Result.ToolCalls := nil;
  Result.ToolName := '';
  Result.ToolCallId := '';
end;

function ToolResultMessage(const ACall: TToolCall; const AResult: string): TChatMessage;
begin
  Result := ChatMessage(ROLE_TOOL, AResult);
  Result.ToolName := ACall.Name;
  Result.ToolCallId := ACall.Id;
end;

procedure AppendMessage(var AMessages: TChatMessages; const AMessage: TChatMessage);
var
  N: Integer;
begin
  N := Length(AMessages);
  SetLength(AMessages, N + 1);
  AMessages[N] := AMessage;
end;

procedure AddMessage(var AMessages: TChatMessages; const ARole, AContent: string);
begin
  AppendMessage(AMessages, ChatMessage(ARole, AContent));
end;

{ Compatibility helpers }

function TickMs: UInt64;
begin
  {$IFDEF FPC}
  Result := GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

function Utf8BytesToString(const ABytes: RawByteString): string;
{$IFDEF FPC}
var
  R: RawByteString;
begin
  R := ABytes;
  SetCodePage(R, CP_UTF8, False);
  Result := string(R);
end;
{$ELSE}
begin
  Result := UTF8ToString(ABytes);
end;
{$ENDIF}

function StringToUtf8Bytes(const AText: string): RawByteString;
begin
  Result := UTF8Encode(AText);
end;

function LoadTextFileUtf8(const AFileName: string): string;
var
  FS: TFileStream;
  Bytes: RawByteString;
begin
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Bytes, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Bytes[1], FS.Size);
  finally
    FS.Free;
  end;
  { Compare byte values, not characters: in Delphi a character literal is
    two bytes wide and would be compared through a code page. }
  if (Length(Bytes) >= 3) and (Ord(Bytes[1]) = $EF) and (Ord(Bytes[2]) = $BB) and
     (Ord(Bytes[3]) = $BF) then
    Delete(Bytes, 1, 3);
  Result := Utf8BytesToString(Bytes);
end;

procedure SaveTextFileUtf8(const AFileName, AText: string);
var
  FS: TFileStream;
  Bytes: RawByteString;
  Dir: string;
begin
  Dir := ExtractFileDir(ExpandFileName(AFileName));
  if Dir <> '' then
    ForceDirectories(Dir);
  Bytes := StringToUtf8Bytes(AText);
  FS := TFileStream.Create(AFileName, fmCreate);
  try
    if Bytes <> '' then
      FS.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    FS.Free;
  end;
end;

procedure AppendLineUtf8(const AFileName, ALine: string);
var
  FS: TFileStream;
  Bytes: RawByteString;
  Dir: string;
begin
  Dir := ExtractFileDir(ExpandFileName(AFileName));
  if Dir <> '' then
    ForceDirectories(Dir);
  Bytes := StringToUtf8Bytes(ALine + LineEnding);
  if FileExists(AFileName) then
    FS := TFileStream.Create(AFileName, fmOpenReadWrite or fmShareDenyWrite)
  else
    FS := TFileStream.Create(AFileName, fmCreate);
  try
    FS.Seek(0, soEnd);
    FS.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    FS.Free;
  end;
end;

procedure InitConsole;
begin
  {$IFDEF MSWINDOWS}
  SetConsoleOutputCP(CP_UTF8);
  {$IFNDEF FPC}
  SetTextCodePage(Output, CP_UTF8);
  {$ENDIF}
  {$ENDIF}
end;

function IsAsciiAlnum(C: Char): Boolean;
begin
  Result := ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
    ((C >= '0') and (C <= '9'));
end;

initialization
  {$IFDEF FPC}
  InvariantFormat := DefaultFormatSettings;
  InvariantFormat.DecimalSeparator := '.';
  InvariantFormat.ThousandSeparator := ',';
  {$ELSE}
  InvariantFormat := TFormatSettings.Invariant;
  {$ENDIF}
end.
