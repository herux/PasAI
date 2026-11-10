unit PasAI.Json;

{ One JSON API for both compilers.

  Free Pascal ships fpjson, Delphi ships System.JSON. Their classes share
  some names (TJSONObject, TJSONArray) but almost no methods. This unit is
  the only place that knows the difference: every other PasAI unit reads
  and builds JSON through the functions below, and never uses fpjson or
  System.JSON directly.

  Parsing and the object model come from each compiler's own library.
  Writing JSON text (JsonToText, JsonFormat) is implemented here, so the
  output is identical on both compilers and numbers come out as people
  write them: 1234.5 rather than fpjson's 1.2345000000000000E+003, always
  with a dot as decimal separator.

  Ownership follows the libraries: a parsed value belongs to the caller;
  a value added to an object or array belongs to that container. }

{$IFDEF FPC}{$mode delphi}{$ENDIF}{$H+}

interface

uses
  SysUtils, PasAI.Types,
  {$IFDEF FPC}
  fpjson, jsonparser;
  {$ELSE}
  System.JSON;
  {$ENDIF}

type
  {$IFDEF FPC}
  TJSONValue = fpjson.TJSONData;
  TJSONObject = fpjson.TJSONObject;
  TJSONArray = fpjson.TJSONArray;
  {$ELSE}
  TJSONValue = System.JSON.TJSONValue;
  TJSONObject = System.JSON.TJSONObject;
  TJSONArray = System.JSON.TJSONArray;
  {$ENDIF}

  TJsonKind = (jkNull, jkBool, jkNumber, jkString, jkArray, jkObject);

{ Parsing. Both raise EPasAIError on invalid JSON. }
function ParseJson(const AText: string): TJSONValue;
{ Raises EPasAIError if the text is not a JSON object. }
function ParseJsonObject(const AText: string): TJSONObject;

{ Inspecting }
function JsonKind(AValue: TJSONValue): TJsonKind;
{ "object", "array", "string", "number", "boolean" or "null". }
function JsonKindName(AValue: TJSONValue): string;
{ A number with no fractional part. }
function JsonIsInteger(AValue: TJSONValue): Boolean;
{ Member of an object, or nil. }
function JsonFind(AObject: TJSONObject; const AName: string): TJSONValue;
{ Nested member by dotted path, e.g. 'message.content', or nil. }
function JsonFindPath(AValue: TJSONValue; const APath: string): TJSONValue;
{ Elements of an array, or members of an object. 0 for other kinds. }
function JsonCount(AValue: TJSONValue): Integer;
{ Element I of an array, or the value of member I of an object. }
function JsonItem(AValue: TJSONValue; AIndex: Integer): TJSONValue;
{ Name of member I of an object. }
function JsonName(AObject: TJSONObject; AIndex: Integer): string;

{ Reading values }
function JsonAsString(AValue: TJSONValue): string;
function JsonAsFloat(AValue: TJSONValue): Double;
function JsonAsInteger(AValue: TJSONValue): Int64;
function JsonAsBoolean(AValue: TJSONValue): Boolean;

{ Required members: raise EPasAIError when missing or of the wrong kind. }
function JsonGetString(AObject: TJSONObject; const AName: string): string;
function JsonGetFloat(AObject: TJSONObject; const AName: string): Double;
function JsonGetInteger(AObject: TJSONObject; const AName: string): Int64;

{ Optional member: ADefault when missing or not a string. }
function JsonStringOr(AObject: TJSONObject; const AName, ADefault: string): string;

{ Building }
function JsonNewObject: TJSONObject;
function JsonNewArray: TJSONArray;
procedure JsonAddString(AObject: TJSONObject; const AName, AValue: string);
procedure JsonAddInteger(AObject: TJSONObject; const AName: string; AValue: Int64);
procedure JsonAddFloat(AObject: TJSONObject; const AName: string; AValue: Double);
procedure JsonAddBool(AObject: TJSONObject; const AName: string; AValue: Boolean);
{ Adds AValue to AObject, which then owns it. }
procedure JsonAddValue(AObject: TJSONObject; const AName: string; AValue: TJSONValue);
procedure JsonArrayAdd(AArray: TJSONArray; AValue: TJSONValue);
procedure JsonArrayAddString(AArray: TJSONArray; const AValue: string);

{ Writing }
{ A JSON string literal, quoted and escaped. }
function JsonQuote(const S: string): string;
{ Compact JSON text. }
function JsonToText(AValue: TJSONValue): string;
{ Indented JSON text, for files people read. }
function JsonFormat(AValue: TJSONValue): string;
{ Same kind and same JSON text. }
function JsonEquals(A, B: TJSONValue): Boolean;

implementation

uses
  Math;

{ Parsing }

function ParseJson(const AText: string): TJSONValue;
begin
  try
    {$IFDEF FPC}
    Result := GetJSON(UTF8String(AText));
    {$ELSE}
    Result := TJSONObject.ParseJSONValue(AText, True, True);
    {$ENDIF}
  except
    on E: Exception do
      raise EPasAIError.Create('Invalid JSON: ' + E.Message);
  end;
  if Result = nil then
    raise EPasAIError.Create('Invalid JSON: empty input');
end;

function ParseJsonObject(const AText: string): TJSONObject;
var
  V: TJSONValue;
begin
  V := ParseJson(AText);
  if JsonKind(V) <> jkObject then
  begin
    V.Free;
    raise EPasAIError.Create('Expected a JSON object: ' + Copy(AText, 1, 200));
  end;
  Result := TJSONObject(V);
end;

{ Inspecting }

function JsonKind(AValue: TJSONValue): TJsonKind;
begin
  {$IFDEF FPC}
  case AValue.JSONType of
    jtBoolean: Result := jkBool;
    jtNumber:  Result := jkNumber;
    jtString:  Result := jkString;
    jtArray:   Result := jkArray;
    jtObject:  Result := jkObject;
  else
    Result := jkNull;
  end;
  {$ELSE}
  { TJSONNumber descends from TJSONString, so test it first. }
  if AValue is TJSONObject then
    Result := jkObject
  else if AValue is TJSONArray then
    Result := jkArray
  else if AValue is TJSONNumber then
    Result := jkNumber
  else if AValue is TJSONString then
    Result := jkString
  else if AValue is TJSONBool then
    Result := jkBool
  else
    Result := jkNull;
  {$ENDIF}
end;

function JsonKindName(AValue: TJSONValue): string;
const
  NAMES: array[TJsonKind] of string = ('null', 'boolean', 'number', 'string', 'array', 'object');
begin
  Result := NAMES[JsonKind(AValue)];
end;

function JsonIsInteger(AValue: TJSONValue): Boolean;
begin
  Result := (JsonKind(AValue) = jkNumber) and (Frac(JsonAsFloat(AValue)) = 0);
end;

function JsonFind(AObject: TJSONObject; const AName: string): TJSONValue;
begin
  {$IFDEF FPC}
  Result := AObject.Find(AName);
  {$ELSE}
  Result := AObject.GetValue(AName);
  {$ENDIF}
end;

function JsonFindPath(AValue: TJSONValue; const APath: string): TJSONValue;
begin
  {$IFDEF FPC}
  Result := AValue.FindPath(UTF8String(APath));
  {$ELSE}
  Result := AValue.FindValue(APath);
  {$ENDIF}
end;

function JsonCount(AValue: TJSONValue): Integer;
begin
  case JsonKind(AValue) of
    jkArray:  Result := TJSONArray(AValue).Count;
    jkObject: Result := TJSONObject(AValue).Count;
  else
    Result := 0;
  end;
end;

function JsonItem(AValue: TJSONValue; AIndex: Integer): TJSONValue;
begin
  {$IFDEF FPC}
  Result := AValue.Items[AIndex];
  {$ELSE}
  if AValue is TJSONObject then
    Result := TJSONObject(AValue).Pairs[AIndex].JsonValue
  else
    Result := TJSONArray(AValue).Items[AIndex];
  {$ENDIF}
end;

function JsonName(AObject: TJSONObject; AIndex: Integer): string;
begin
  {$IFDEF FPC}
  Result := string(AObject.Names[AIndex]);
  {$ELSE}
  Result := AObject.Pairs[AIndex].JsonString.Value;
  {$ENDIF}
end;

{ Reading values }

function JsonAsString(AValue: TJSONValue): string;
begin
  {$IFDEF FPC}
  Result := string(AValue.AsString);
  {$ELSE}
  Result := AValue.Value;
  {$ENDIF}
end;

function JsonAsFloat(AValue: TJSONValue): Double;
begin
  {$IFDEF FPC}
  Result := AValue.AsFloat;
  {$ELSE}
  if AValue is TJSONNumber then
    Result := TJSONNumber(AValue).AsDouble
  else
    Result := StrToFloat(AValue.Value, InvariantFormat);
  {$ENDIF}
end;

function JsonAsInteger(AValue: TJSONValue): Int64;
begin
  {$IFDEF FPC}
  Result := AValue.AsInt64;
  {$ELSE}
  if AValue is TJSONNumber then
    Result := TJSONNumber(AValue).AsInt64
  else
    Result := StrToInt64(AValue.Value);
  {$ENDIF}
end;

function JsonAsBoolean(AValue: TJSONValue): Boolean;
begin
  {$IFDEF FPC}
  Result := AValue.AsBoolean;
  {$ELSE}
  Result := (AValue is TJSONBool) and TJSONBool(AValue).AsBoolean;
  {$ENDIF}
end;

function Required(AObject: TJSONObject; const AName: string; AKind: TJsonKind): TJSONValue;
begin
  Result := JsonFind(AObject, AName);
  if Result = nil then
    raise EPasAIError.CreateFmt('Missing JSON field "%s"', [AName]);
  if JsonKind(Result) <> AKind then
    raise EPasAIError.CreateFmt('JSON field "%s" is a %s', [AName, JsonKindName(Result)]);
end;

function JsonGetString(AObject: TJSONObject; const AName: string): string;
begin
  Result := JsonAsString(Required(AObject, AName, jkString));
end;

function JsonGetFloat(AObject: TJSONObject; const AName: string): Double;
begin
  Result := JsonAsFloat(Required(AObject, AName, jkNumber));
end;

function JsonGetInteger(AObject: TJSONObject; const AName: string): Int64;
begin
  Result := JsonAsInteger(Required(AObject, AName, jkNumber));
end;

function JsonStringOr(AObject: TJSONObject; const AName, ADefault: string): string;
var
  V: TJSONValue;
begin
  V := JsonFind(AObject, AName);
  if (V <> nil) and (JsonKind(V) = jkString) then
    Result := JsonAsString(V)
  else
    Result := ADefault;
end;

{ Building }

function JsonNewObject: TJSONObject;
begin
  Result := TJSONObject.Create;
end;

function JsonNewArray: TJSONArray;
begin
  Result := TJSONArray.Create;
end;

procedure JsonAddString(AObject: TJSONObject; const AName, AValue: string);
begin
  {$IFDEF FPC}
  AObject.Add(UTF8String(AName), UTF8String(AValue));
  {$ELSE}
  AObject.AddPair(AName, AValue);
  {$ENDIF}
end;

procedure JsonAddInteger(AObject: TJSONObject; const AName: string; AValue: Int64);
begin
  {$IFDEF FPC}
  AObject.Add(UTF8String(AName), AValue);
  {$ELSE}
  AObject.AddPair(AName, TJSONNumber.Create(AValue));
  {$ENDIF}
end;

procedure JsonAddFloat(AObject: TJSONObject; const AName: string; AValue: Double);
begin
  {$IFDEF FPC}
  AObject.Add(UTF8String(AName), TJSONFloat(AValue));
  {$ELSE}
  AObject.AddPair(AName, TJSONNumber.Create(AValue));
  {$ENDIF}
end;

procedure JsonAddBool(AObject: TJSONObject; const AName: string; AValue: Boolean);
begin
  {$IFDEF FPC}
  AObject.Add(UTF8String(AName), AValue);
  {$ELSE}
  AObject.AddPair(AName, TJSONBool.Create(AValue));
  {$ENDIF}
end;

procedure JsonAddValue(AObject: TJSONObject; const AName: string; AValue: TJSONValue);
begin
  {$IFDEF FPC}
  AObject.Add(UTF8String(AName), AValue);
  {$ELSE}
  AObject.AddPair(AName, AValue);
  {$ENDIF}
end;

procedure JsonArrayAdd(AArray: TJSONArray; AValue: TJSONValue);
begin
  {$IFDEF FPC}
  AArray.Add(AValue);
  {$ELSE}
  AArray.AddElement(AValue);
  {$ENDIF}
end;

procedure JsonArrayAddString(AArray: TJSONArray; const AValue: string);
begin
  {$IFDEF FPC}
  AArray.Add(UTF8String(AValue));
  {$ELSE}
  AArray.Add(AValue);
  {$ENDIF}
end;

{ Writing }

function JsonQuote(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '"';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    case Ord(C) of
      $22: Result := Result + '\"';
      $5C: Result := Result + '\\';
      $0A: Result := Result + '\n';
      $0D: Result := Result + '\r';
      $09: Result := Result + '\t';
      $08: Result := Result + '\b';
      $0C: Result := Result + '\f';
      0..7, $0B, $0E..$1F:
        Result := Result + '\u' + IntToHex(Ord(C), 4);
    else
      { Everything else as is: non-ASCII text stays readable, and becomes
        UTF-8 bytes at the network or file boundary. }
      Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

function NumberText(AValue: TJSONValue): string;
var
  F: Double;
begin
  F := JsonAsFloat(AValue);
  if (Frac(F) = 0) and (Abs(F) < 9.0E15) then
    Result := IntToStr(Round(F))
  else
    Result := FloatToStr(F, InvariantFormat);
end;

procedure WriteValue(AValue: TJSONValue; AIndent: Integer; APretty: Boolean;
  var AOut: string);
var
  I: Integer;
  Pad, PadInner: string;
begin
  if APretty then
  begin
    Pad := StringOfChar(' ', AIndent * 2);
    PadInner := StringOfChar(' ', (AIndent + 1) * 2);
  end
  else
  begin
    Pad := '';
    PadInner := '';
  end;

  case JsonKind(AValue) of
    jkNull:   AOut := AOut + 'null';
    jkBool:   if JsonAsBoolean(AValue) then AOut := AOut + 'true' else AOut := AOut + 'false';
    jkNumber: AOut := AOut + NumberText(AValue);
    jkString: AOut := AOut + JsonQuote(JsonAsString(AValue));
    jkArray:
      begin
        if JsonCount(AValue) = 0 then
        begin
          AOut := AOut + '[]';
          Exit;
        end;
        AOut := AOut + '[';
        for I := 0 to JsonCount(AValue) - 1 do
        begin
          if I > 0 then
            AOut := AOut + ',';
          if APretty then
            AOut := AOut + LineEnding + PadInner;
          WriteValue(JsonItem(AValue, I), AIndent + 1, APretty, AOut);
        end;
        if APretty then
          AOut := AOut + LineEnding + Pad;
        AOut := AOut + ']';
      end;
    jkObject:
      begin
        if JsonCount(AValue) = 0 then
        begin
          AOut := AOut + '{}';
          Exit;
        end;
        AOut := AOut + '{';
        for I := 0 to JsonCount(AValue) - 1 do
        begin
          if I > 0 then
            AOut := AOut + ',';
          if APretty then
            AOut := AOut + LineEnding + PadInner;
          AOut := AOut + JsonQuote(JsonName(TJSONObject(AValue), I));
          if APretty then
            AOut := AOut + ': '
          else
            AOut := AOut + ':';
          WriteValue(JsonItem(AValue, I), AIndent + 1, APretty, AOut);
        end;
        if APretty then
          AOut := AOut + LineEnding + Pad;
        AOut := AOut + '}';
      end;
  end;
end;

function JsonToText(AValue: TJSONValue): string;
begin
  Result := '';
  WriteValue(AValue, 0, False, Result);
end;

function JsonFormat(AValue: TJSONValue): string;
begin
  Result := '';
  WriteValue(AValue, 0, True, Result);
end;

function JsonEquals(A, B: TJSONValue): Boolean;
begin
  Result := (JsonKind(A) = JsonKind(B)) and (JsonToText(A) = JsonToText(B));
end;

end.
