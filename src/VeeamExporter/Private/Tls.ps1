# Certificate pinning for the local VBR certificate.
# The check is never switched off globally: when a thumbprint is configured,
# only a certificate with exactly that SHA-1 thumbprint is accepted. Without a
# thumbprint the default .NET validation applies.
# The callbacks are compiled C#, because script block delegates fail on the
# thread pool threads that HttpClient uses in PowerShell 7.

$script:VeeamCertificatePinSource = @'
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
// @@CORE_USINGS@@

namespace VeeamExporter
{
    // @@CORE_TYPES@@

    public static class CertificatePin
    {
        private static string pinnedThumbprint;

        public static string PinnedThumbprint
        {
            get { return pinnedThumbprint; }
        }

        public static string Normalize(string thumbprint)
        {
            if (thumbprint == null) { return null; }
            System.Text.StringBuilder sb = new System.Text.StringBuilder();
            foreach (char c in thumbprint)
            {
                if (Uri.IsHexDigit(c)) { sb.Append(char.ToUpperInvariant(c)); }
            }
            return sb.ToString();
        }

        public static void SetThumbprint(string thumbprint)
        {
            pinnedThumbprint = Normalize(thumbprint);
        }

        public static bool Matches(X509Certificate certificate, string thumbprint)
        {
            string expected = Normalize(thumbprint);
            if (certificate == null || string.IsNullOrEmpty(expected)) { return false; }
            X509Certificate2 cert2 = certificate as X509Certificate2;
            if (cert2 == null) { cert2 = new X509Certificate2(certificate); }
            return string.Equals(cert2.Thumbprint, expected, StringComparison.OrdinalIgnoreCase);
        }

        public static bool Validate(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors)
        {
            return Matches(certificate, pinnedThumbprint);
        }

        public static RemoteCertificateValidationCallback Callback
        {
            get { return new RemoteCertificateValidationCallback(Validate); }
        }
    }
}
'@

# PowerShell 7 only: HttpClientHandler callback, compiled into the same
# assembly as CertificatePin (inserted at the placeholders above).
$script:VeeamCertificatePinCoreUsings = 'using System.Net.Http;'
$script:VeeamCertificatePinCoreTypes = @'
public static class CertificatePinHandler
    {
        public static Func<HttpRequestMessage, X509Certificate2, X509Chain, SslPolicyErrors, bool> Create(string thumbprint)
        {
            string expected = CertificatePin.Normalize(thumbprint);
            return (request, certificate, chain, errors) => CertificatePin.Matches(certificate, expected);
        }
    }
'@

function Initialize-VeeamCertificatePinType {
    [CmdletBinding()]
    param()
    if ('VeeamExporter.CertificatePin' -as [type]) { return }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $source = $script:VeeamCertificatePinSource.Replace('// @@CORE_USINGS@@', $script:VeeamCertificatePinCoreUsings).Replace('// @@CORE_TYPES@@', $script:VeeamCertificatePinCoreTypes)
        Add-Type -TypeDefinition $source -Language CSharp
    }
    else {
        Add-Type -TypeDefinition $script:VeeamCertificatePinSource -Language CSharp
    }
}

function Test-VeeamCertificateThumbprint {
    # Exposed for tests: does the certificate match the thumbprint?
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate]$Certificate,
        [Parameter(Mandatory = $true)][string]$Thumbprint
    )
    Initialize-VeeamCertificatePinType
    return [VeeamExporter.CertificatePin]::Matches($Certificate, $Thumbprint)
}

function Initialize-VeeamTransportSecurity {
    # Windows PowerShell 5.1: TLS 1.2 only, and register the pinning callback
    # on the ServicePointManager. PowerShell 7 uses the HttpClientHandler
    # instead (see New-VeeamHttpContext).
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$CertificateThumbprint
    )
    if ($PSVersionTable.PSEdition -eq 'Core') { return }

    # TLS 1.2 only: SSL 3, TLS 1.0 and 1.1 are not offered (own process only).
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    if ($CertificateThumbprint) {
        Initialize-VeeamCertificatePinType
        [VeeamExporter.CertificatePin]::SetThumbprint($CertificateThumbprint)
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = [VeeamExporter.CertificatePin]::Callback
    }
}

function ConvertTo-VeeamCertificateThumbprint {
    # The 40 hex digits of a SHA-1 thumbprint, upper case. Blanks, colons,
    # hyphens and invisible format characters (U+200E from the certificate
    # dialog) are dropped; anything else, or a length other than 40 (SHA-256),
    # is refused, so no value is pinned that can never match. Same rules as
    # Format-CertificateThumbprint of the installer; a test runs both over the
    # same cases (tests/Deploy.Tests.ps1).
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Thumbprint)
    $hex = New-Object -TypeName System.Text.StringBuilder
    foreach ($c in $Thumbprint.ToCharArray()) {
        if ([char]::GetUnicodeCategory($c) -eq [System.Globalization.UnicodeCategory]::Format) { continue }
        if ([char]::IsWhiteSpace($c) -or $c -eq ':' -or $c -eq '-') { continue }
        if ("$c" -notmatch '^[0-9A-Fa-f]$') {
            throw ("Certificate thumbprint contains '{0}'. Give only the 40 hex digits of the SHA-1 thumbprint (blanks and colons are fine)." -f $c)
        }
        $null = $hex.Append($c)
    }
    if ($hex.Length -ne 40) {
        throw ('Certificate thumbprint has {0} hex digits, expected the 40 of a SHA-1 thumbprint.' -f $hex.Length)
    }
    return $hex.ToString().ToUpperInvariant()
}
