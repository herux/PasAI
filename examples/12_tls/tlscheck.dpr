program tlscheck;

{ Example 12: does HTTPS reject the certificates it should reject?

  Sends a small request through PasAI.Http to test hosts of badssl.com and
  compares what happened with what should happen:

    badssl.com              valid certificate          must connect
    api.anthropic.com       a real API host            must connect
    expired.                expired certificate        must be rejected
    self-signed.            nobody vouches for it      must be rejected
    untrusted-root.         unknown root authority     must be rejected
    wrong.host.             valid, but for another     must be rejected
                            host name

  Run this before sending an API key from a new machine or compiler.
  Any HTTP status counts as "connected": these hosts do not expect our
  request, only the TLS handshake matters.

  Run:  ./bin/tlscheck [-openssl]
        -openssl  (Free Pascal, macOS) use OpenSSL 3 from Homebrew instead
                  of the system LibreSSL

  A badssl.com host sometimes times out; a timeout is not a certificate
  check. Run again if a result looks odd. }

{$IFDEF FPC}{$mode delphi}{$codepage utf8}{$ENDIF}{$H+}
{$IFNDEF FPC}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}
  SysUtils, PasAI.Types, PasAI.Http{$IFDEF FPC}, PasAI.Tls{$ENDIF};

type
  TCase = record
    URL: string;
    MustConnect: Boolean;
  end;

const
  CASES: array[0..5] of TCase = (
    (URL: 'https://badssl.com/';                MustConnect: True),
    (URL: 'https://api.anthropic.com/';         MustConnect: True),
    (URL: 'https://expired.badssl.com/';        MustConnect: False),
    (URL: 'https://self-signed.badssl.com/';    MustConnect: False),
    (URL: 'https://untrusted-root.badssl.com/'; MustConnect: False),
    (URL: 'https://wrong.host.badssl.com/';     MustConnect: False));

  TIMEOUT_MS = 15000;
  {$IFDEF FPC}
  HOMEBREW_SSL    = '/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib';
  HOMEBREW_CRYPTO = '/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib';
  {$ENDIF}

function Connects(const AURL: string; out ADetail: string): Boolean;
begin
  try
    ADetail := Format('HTTP %d', [HttpPostJSON(AURL, '{}', TIMEOUT_MS).StatusCode]);
    Result := True;
  except
    on E: Exception do
    begin
      ADetail := E.ClassName + ': ' + E.Message;
      Result := False;
    end;
  end;
end;

var
  I, Failed: Integer;
  Connected: Boolean;
  Detail, Verdict: string;
begin
  InitConsole;
  {$IFDEF FPC}
  if (ParamCount > 0) and (ParamStr(1) = '-openssl') then
    if not TlsUseLibrary(HOMEBREW_SSL, HOMEBREW_CRYPTO) then
    begin
      Writeln('Could not load ', HOMEBREW_SSL);
      Halt(2);
    end;
  Writeln('TLS: ', TlsLibraryInfo);
  {$ELSE}
  Writeln('TLS: the operating system''s (Delphi THTTPClient)');
  {$ENDIF}
  Writeln;

  Failed := 0;
  for I := 0 to High(CASES) do
  begin
    Connected := Connects(CASES[I].URL, Detail);
    if Connected = CASES[I].MustConnect then
      Verdict := 'PASS'
    else
    begin
      Verdict := 'FAIL';
      Inc(Failed);
    end;
    if Connected then
      Writeln(Format('%s  %-36s connected  (%s)', [Verdict, CASES[I].URL, Detail]))
    else
    begin
      Writeln(Format('%s  %-36s rejected', [Verdict, CASES[I].URL]));
      Writeln('      ', Detail);
    end;
  end;

  Writeln;
  if Failed = 0 then
    Writeln('All checks passed.')
  else
  begin
    Writeln(Failed, ' check(s) failed. Do not send API keys from this program.');
    ExitCode := 1;
  end;
end.
