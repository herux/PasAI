unit PasAI.Tls;

{ Certificate checks for HTTPS in Free Pascal. Delphi does not need this
  unit: System.Net.HttpClient uses the operating system's TLS stack.

  Why it exists. Tested with FPC 3.2.4-rc2 on macOS (FPC issue #42109):
  - FPC loads the system LibreSSL first. That library has no SSL_set1_host,
    and FPC then skips the host name check without any error: a valid
    certificate for ANOTHER host is accepted. Anyone holding a certificate
    for their own domain could pretend to be the API server and read the
    API key.
  - FPC loads no default list of trusted root certificates. The system
    LibreSSL loads one by itself; OpenSSL 3 does not, and then every
    server, valid ones included, is rejected.
  The fix was accepted for FPC's fixes_3_2 branch after 3.2.4. Until every
  supported FPC version has it, this unit closes both gaps. With a fixed
  FPC it does no harm: the host name is then simply checked twice.

  What it does. Using this unit replaces FPC's default TLS socket handler
  with TPasAITlsHandler, for every HTTPS client in the program:
  - after the handshake, the server certificate must name the host we
    connected to (X509_check_host). Fails closed: no certificate, no host
    name or no X509_check_host means no connection.
  - a file of trusted root certificates is loaded from the usual places,
    or from TlsRootsFile.
  Both apply only when certificate verification is on; PasAI.Http always
  switches it on.

  Limitation: host names only. An https:// address written as an IP
  address is refused when verification is on. }

{$mode delphi}{$H+}

interface

uses
  SysUtils, ctypes, dynlibs, ssockets, sslsockets, openssl, opensslsockets;

type
  TPasAITlsHandler = class(TOpenSSLSocketHandler)
  public
    constructor Create; override;
    function Connect: Boolean; override;
  end;

var
  { A PEM file of trusted root certificates. Empty: search the usual
    places (see TlsFindRootsFile). Set before the first HTTPS request. }
  TlsRootsFile: string = '';

{ TlsRootsFile if set, else the first existing file of the usual places,
  else '' (then the TLS library's own default applies). }
function TlsFindRootsFile: string;

{ Load a specific TLS library instead of the one FPC would pick, e.g.
  OpenSSL 3 from Homebrew on macOS:
    TlsUseLibrary('/opt/homebrew/opt/openssl@3/lib/libssl.3.dylib',
                  '/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib');
  Call it before the first HTTPS request: a program loads the library only
  once. Returns False if it could not be loaded or one is already loaded. }
function TlsUseLibrary(const ASSLFile, ACryptoFile: string): Boolean;

{ One line describing the loaded TLS library and the checks in use. }
function TlsLibraryInfo: string;

implementation

const
  ROOTS_CANDIDATES: array[0..3] of string = (
    '/etc/ssl/cert.pem',                    // macOS, Alpine, BSD
    '/etc/ssl/certs/ca-certificates.crt',   // Debian, Ubuntu
    '/etc/pki/tls/certs/ca-bundle.crt',     // Fedora, RHEL
    '/etc/ssl/ca-bundle.pem');              // openSUSE

  X509_CHECK_MATCH = 1;   // X509_check_host: 1 match, 0 no match, < 0 error

type
  { int X509_check_host(X509 *x, const char *name, size_t namelen,
                        unsigned int flags, char **peername)  (libcrypto) }
  TX509CheckHost = function(ACert: PX509; AName: PAnsiChar; ANameLen: csize_t;
    AFlags: cuint; APeerName: PPAnsiChar): cint; cdecl;

function TlsFindRootsFile: string;
var
  I: Integer;
begin
  if TlsRootsFile <> '' then
    Exit(TlsRootsFile);
  for I := Low(ROOTS_CANDIDATES) to High(ROOTS_CANDIDATES) do
    if FileExists(ROOTS_CANDIDATES[I]) then
      Exit(ROOTS_CANDIDATES[I]);
  Result := '';
end;

function TlsUseLibrary(const ASSLFile, ACryptoFile: string): Boolean;
begin
  if IsSSLloaded then
    Exit(False);
  Result := InitSSLInterface(ASSLFile, ACryptoFile);
end;

function TlsLibraryInfo: string;
var
  Roots: string;
begin
  if not InitSSLInterface then
    Exit('no TLS library could be loaded');
  Result := OpenSSLGetVersion(0);
  if GetProcedureAddress(SSLUtilHandle, 'X509_check_host') = nil then
    Result := Result + ', NO X509_check_host: every HTTPS connection will be refused'
  else
    Result := Result + ', host names checked';
  Roots := TlsFindRootsFile;
  if Roots <> '' then
    Result := Result + ', roots from ' + Roots
  else
    Result := Result + ', roots: library default';
end;

{ TPasAITlsHandler }

constructor TPasAITlsHandler.Create;
var
  Roots: string;
begin
  inherited Create;
  Roots := TlsFindRootsFile;
  if Roots <> '' then
    CertificateData.CertCA.FileName := Roots;   // used only when verifying
end;

function TPasAITlsHandler.Connect: Boolean;
var
  CheckHost: TX509CheckHost;
  Cert: PX509;
  Host: AnsiString;
begin
  { Handshake first, including FPC's checks of the certificate chain. }
  Result := inherited Connect;
  if not Result or not VerifyPeerCert then
    Exit;

  Result := False;
  Host := '';
  if Socket is TInetSocket then
    Host := AnsiString(TInetSocket(Socket).Host);
  CheckHost := TX509CheckHost(GetProcedureAddress(SSLUtilHandle, 'X509_check_host'));
  Cert := SslGetPeerCertificate(SSL.SSL);   // a new reference: free it
  try
    if (Host <> '') and Assigned(CheckHost) and (Cert <> nil) then
      Result := CheckHost(Cert, PAnsiChar(Host), Length(Host), 0, nil) = X509_CHECK_MATCH;
  finally
    if Cert <> nil then
      X509Free(Cert);
  end;

  if not Result then
  begin
    SSLLastErrorString := 'Server certificate is not valid for host ' + string(Host);
    Close;   // before a single byte of the request is sent
  end;
end;

initialization
  { opensslsockets, initialized before this unit, registered its own
    handler; this replaces it. }
  TSSLSocketHandler.SetDefaultHandlerClass(TPasAITlsHandler);
end.
