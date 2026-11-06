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

Describe 'Zertifikat-Pinning' {
    It 'akzeptiert das Zertifikat mit passendem Thumbprint' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest nicht verfuegbar'; return }
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:Cert } {
            param($Cert)
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Cert.Thumbprint | Should -BeTrue
        }
    }

    It 'ignoriert Gross-/Kleinschreibung, Leerzeichen und Doppelpunkte im Thumbprint' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest nicht verfuegbar'; return }
        $t = $script:Cert.Thumbprint.ToLowerInvariant()
        $spaced = ($t -split '(..)' | Where-Object { $_ }) -join ' '
        $colon = ($t -split '(..)' | Where-Object { $_ }) -join ':'
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:Cert; Spaced = $spaced; Colon = $colon } {
            param($Cert, $Spaced, $Colon)
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Spaced | Should -BeTrue
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Colon | Should -BeTrue
        }
    }

    It 'lehnt ein anderes Zertifikat ab' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest nicht verfuegbar'; return }
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:OtherCert; Thumb = $script:Cert.Thumbprint } {
            param($Cert, $Thumb)
            Test-VeeamCertificateThumbprint -Certificate $Cert -Thumbprint $Thumb | Should -BeFalse
        }
    }

    It 'lehnt bei leerem Thumbprint ab (kein pauschales Akzeptieren)' {
        if (-not $script:CanCreateCert) { Set-ItResult -Skipped -Because 'CertificateRequest nicht verfuegbar'; return }
        InModuleScope VeeamExporter -Parameters @{ Cert = $script:Cert } {
            param($Cert)
            Initialize-VeeamCertificatePinType
            [VeeamExporter.CertificatePin]::Matches($Cert, '') | Should -BeFalse
            [VeeamExporter.CertificatePin]::Matches($null, $Cert.Thumbprint) | Should -BeFalse
        }
    }

    It 'PowerShell 7: HttpClient mit Pinning-Handler' {
        if ($PSVersionTable.PSEdition -ne 'Core') { Set-ItResult -Skipped -Because 'nur PowerShell 7'; return }
        InModuleScope VeeamExporter {
            $ctx = New-VeeamHttpContext -BaseUri 'https://localhost:9419' -CertificateThumbprint 'AB CD EF'
            try {
                $ctx.HttpClient | Should -Not -BeNullOrEmpty
                $ctx.HttpClient.Timeout.TotalSeconds | Should -Be 60
            }
            finally { $ctx.HttpClient.Dispose() }
        }
    }

    It 'Windows PowerShell 5.1: TLS 1.2 und Validation-Callback' {
        if ($PSVersionTable.PSEdition -eq 'Core') { Set-ItResult -Skipped -Because 'nur Windows PowerShell 5.1'; return }
        InModuleScope VeeamExporter {
            $ctx = New-VeeamHttpContext -BaseUri 'https://localhost:9419' -CertificateThumbprint 'AB CD EF'
            $ctx.HttpClient | Should -BeNullOrEmpty
            [System.Net.ServicePointManager]::SecurityProtocol | Should -Be ([System.Net.SecurityProtocolType]::Tls12)
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback | Should -Not -BeNullOrEmpty
            [VeeamExporter.CertificatePin]::PinnedThumbprint | Should -BeExactly 'ABCDEF'
        }
    }
}
