unit PasAI.Schema;

{ A small builder for JSON schemas of objects, so they do not have to be
  written by hand as JSON strings (where a missing quote or brace only
  shows up at runtime).

    Schema := ObjectSchema
      .Str('city', 'Name of the city')
      .Enum('unit', ['celsius', 'fahrenheit'], 'Temperature unit')
      .Num('days', 'Number of days to forecast', False)   // optional
      .ToJSON;

  TObjectSchema is a record, and each method returns a modified copy, so
  chaining needs no Free and cannot leak.

  Properties are required unless ARequired is False. Covers the subset
  that PasAI.Structured validates: type, properties, required, enum. }

{$mode delphi}{$H+}

interface

uses
  SysUtils;

type
  TObjectSchema = record
  private
    FProperties: UTF8String;   // "name": {...}, "name2": {...}
    FRequired: UTF8String;     // "name", "name2"
    function WithProperty(const AName: string; const ABody: UTF8String;
      const ADescription: string; ARequired: Boolean): TObjectSchema;
  public
    function Str(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TObjectSchema;
    function Int(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TObjectSchema;
    function Num(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TObjectSchema;
    function Bool(const AName: string; const ADescription: string = '';
      ARequired: Boolean = True): TObjectSchema;
    { A string that must be one of AValues. }
    function Enum(const AName: string; const AValues: array of string;
      const ADescription: string = ''; ARequired: Boolean = True): TObjectSchema;
    function ToJSON: UTF8String;
  end;

{ An object schema with no properties yet. }
function ObjectSchema: TObjectSchema;

implementation

uses
  fpjson;

{ A JSON string literal, quoted and escaped. }
function Quoted(const S: string): UTF8String;
begin
  Result := '"' + StringToJSONString(UTF8String(S)) + '"';
end;

function ObjectSchema: TObjectSchema;
begin
  Result.FProperties := '';
  Result.FRequired := '';
end;

function TObjectSchema.WithProperty(const AName: string; const ABody: UTF8String;
  const ADescription: string; ARequired: Boolean): TObjectSchema;
var
  Prop: UTF8String;
begin
  Result := Self;
  Prop := ABody;
  if ADescription <> '' then
    Prop := Prop + ', "description": ' + Quoted(ADescription);

  if Result.FProperties <> '' then
    Result.FProperties := Result.FProperties + ', ';
  Result.FProperties := Result.FProperties + Quoted(AName) + ': {' + Prop + '}';

  if ARequired then
  begin
    if Result.FRequired <> '' then
      Result.FRequired := Result.FRequired + ', ';
    Result.FRequired := Result.FRequired + Quoted(AName);
  end;
end;

function TObjectSchema.Str(const AName: string; const ADescription: string;
  ARequired: Boolean): TObjectSchema;
begin
  Result := WithProperty(AName, '"type": "string"', ADescription, ARequired);
end;

function TObjectSchema.Int(const AName: string; const ADescription: string;
  ARequired: Boolean): TObjectSchema;
begin
  Result := WithProperty(AName, '"type": "integer"', ADescription, ARequired);
end;

function TObjectSchema.Num(const AName: string; const ADescription: string;
  ARequired: Boolean): TObjectSchema;
begin
  Result := WithProperty(AName, '"type": "number"', ADescription, ARequired);
end;

function TObjectSchema.Bool(const AName: string; const ADescription: string;
  ARequired: Boolean): TObjectSchema;
begin
  Result := WithProperty(AName, '"type": "boolean"', ADescription, ARequired);
end;

function TObjectSchema.Enum(const AName: string; const AValues: array of string;
  const ADescription: string; ARequired: Boolean): TObjectSchema;
var
  List: UTF8String;
  I: Integer;
begin
  List := '';
  for I := 0 to High(AValues) do
  begin
    if List <> '' then
      List := List + ', ';
    List := List + Quoted(AValues[I]);
  end;
  Result := WithProperty(AName, '"type": "string", "enum": [' + List + ']',
    ADescription, ARequired);
end;

function TObjectSchema.ToJSON: UTF8String;
begin
  Result := '{"type": "object", "properties": {' + FProperties + '}';
  if FRequired <> '' then
    Result := Result + ', "required": [' + FRequired + ']';
  Result := Result + '}';
end;

end.
