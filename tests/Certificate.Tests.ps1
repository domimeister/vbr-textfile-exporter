BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')

    $script:CanCreateCert = [bool]('System.Security.Cryptography.X509Certificates.CertificateRequest' -as [type])
    if ($script:CanCreateCert) {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $request = New-Object System.Security.Cryptography.X509Certificates.CertificateRequest -ArgumentList 'CN=localhost', $rsa,
            ([System.Security.Cryptography.HashAlgorithmName]::SHA256), ([System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $script:Cert = $request.CreateSelfSigned([System.DateTimeOffset]::UtcNow.AddDays(-1), [System.DateTimeOffset]::UtcNow.AddDays(1))
        $script:OtherCert = $request.CreateSelfSigned([System.DateTimeOffset]::UtcNow.AddDays(-2), [System.DateTimeOffset]::UtcNow.AddDays(2))
    }
}

AfterAll {
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
    }
}

Describe 'Certificate pinning' {
    It 'accepts the certificate with a matching thumbprint' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest not available'; return }
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:Cert } {
            param($Cert)
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Cert.Thumbprint | Should -BeTrue
        }
    }

    It 'ignores case, spaces and colons in the thumbprint' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest not available'; return }
        $t = $script:Cert.Thumbprint.ToLowerInvariant()
        $spaced = ($t -split '(..)' | Where-Object { $_ }) -join ' '
        $colon = ($t -split '(..)' | Where-Object { $_ }) -join ':'
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:Cert; Spaced = $spaced; Colon = $colon } {
            param($Cert, $Spaced, $Colon)
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Spaced | Should -BeTrue
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Colon | Should -BeTrue
        }
    }

    It 'rejects a different certificate' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest not available'; return }
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:OtherCert; Thumb = $script:Cert.Thumbprint } {
            param($Cert, $Thumb)
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Thumb | Should -BeFalse
        }
    }

    It 'rejects an empty thumbprint (no blanket acceptance)' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest not available'; return }
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:Cert } {
            param($Cert)
            Initialize-VeeamCertificatePinType
            [VeeamExporter.CertificatePin]::Matches($Cert, '') | Should -BeFalse
            [VeeamExporter.CertificatePin]::Matches($null, $Cert.Thumbprint) | Should -BeFalse
        }
    }

    It 'PowerShell 7: HttpClient with pinning handler' {
        if ($PSVersionTable.PSEdition -ne 'Core') { Set-ItResult -Skipped -Because 'PowerShell 7 only'; return }
        InModuleScope VeeamExporter {
            $ctx = New-VeeamHttpContext -BaseUri 'https://localhost:9419' -CertificateThumbprint 'ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01'
            try {
                $ctx.HttpClient | Should -Not -BeNullOrEmpty
                $ctx.HttpClient.Timeout.TotalSeconds | Should -Be 60
            }
            finally { $ctx.HttpClient.Dispose() }
        }
    }

    It 'Windows PowerShell 5.1: TLS 1.2 and validation callback' {
        if ($PSVersionTable.PSEdition -eq 'Core') { Set-ItResult -Skipped -Because 'Windows PowerShell 5.1 only'; return }
        InModuleScope VeeamExporter {
            $ctx = New-VeeamHttpContext -BaseUri 'https://localhost:9419' -CertificateThumbprint 'ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01'
            $ctx.HttpClient | Should -BeNullOrEmpty
            [System.Net.ServicePointManager]::SecurityProtocol | Should -Be ([System.Net.SecurityProtocolType]::Tls12)
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback | Should -Not -BeNullOrEmpty
            [VeeamExporter.CertificatePin]::PinnedThumbprint | Should -BeExactly 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'
        }
    }

    It 'refuses <Case> as thumbprint before anything is sent' -TestCases @(
        @{ Case = 'a label from certutil'; In = 'Cert Hash(sha1): ab cd ef 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef 01'; Message = "*contains 'r'*" }
        @{ Case = 'a SHA-256 fingerprint'; In = ('3F2A' * 16); Message = '*64 hex digits*' }
        @{ Case = 'a short value'; In = 'AB CD EF'; Message = '*6 hex digits*' }
    ) {
        param($Case, $In, $Message)
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content $script:TokenJson }
        { Connect-VeeamServer -Credential (New-TestCredential) -CertificateThumbprint $In } | Should -Throw $Message
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly
    }
}
