BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'Connect-VeeamServer (Auth und Versions-Probe)' {
    BeforeEach {
        $script:TriedVersions = New-Object System.Collections.Generic.List[string]
    }

    It 'nimmt die hoechste Revision, die der Server akzeptiert' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            $script:TriedVersions.Add($Headers['x-api-version'])
            if ($Headers['x-api-version'] -in @('1.3-rev2', '1.3-rev1')) {
                return New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJson
            }
            return New-HttpResponse -StatusCode 200 -Content $script:TokenJson
        } -ParameterFilter { $Path -eq '/api/oauth2/token' }

        $session = Connect-VeeamServer -Credential (New-TestCredential)

        $session.ApiVersion | Should -BeExactly '1.3-rev0'
        $session.AccessToken | Should -BeExactly 'access-123'
        $session.RefreshToken | Should -BeExactly 'refresh-456'
        ($script:TriedVersions -join ',') | Should -BeExactly '1.3-rev2,1.3-rev1,1.3-rev0'
    }

    It 'probiert als letzte Version 1.2-rev1 (VBR 12.3.1)' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            if ($Headers['x-api-version'] -ne '1.2-rev1') {
                return New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJson
            }
            return New-HttpResponse -StatusCode 200 -Content $script:TokenJson
        }
        (Connect-VeeamServer -Credential (New-TestCredential)).ApiVersion | Should -BeExactly '1.2-rev1'
    }

    It 'sendet POST /api/oauth2/token als Password-Grant mit x-api-version' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content $script:TokenJson }

        $null = Connect-VeeamServer -Credential (New-TestCredential) -BaseUri 'https://localhost:9419/'

        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and
            $Path -eq '/api/oauth2/token' -and
            $Context.BaseUri -eq 'https://localhost:9419' -and
            $Headers['x-api-version'] -eq '1.3-rev2' -and
            $FormBody['grant_type'] -eq 'password' -and
            $FormBody['username'] -eq 'veeam-viewer' -and
            $FormBody['password'] -eq 'S3cret!pw'
        }
    }

    It 'bricht bei falschem Passwort sofort ab (keine weitere Version)' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:InvalidGrantJson }

        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*invalid_grant*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly
    }

    It 'bricht bei HTTP <Code> sofort ab' -TestCases @(@{ Code = 401 }, @{ Code = 403 }, @{ Code = 500 }) {
        param($Code)
        $script:Code = $Code
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode $script:Code -Content '{"message":"version"}' }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw "*HTTP $Code*"
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly
    }

    It 'bricht bei HTTP 400 ohne Versionshinweis sofort ab' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content '{"errorCode":"BadRequest","message":"Something else"}' }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*Something else*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly
    }

    It 'nennt das Passwort nicht in der Fehlermeldung' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:InvalidGrantJson }
        $message = $null
        try { $null = Connect-VeeamServer -Credential (New-TestCredential) } catch { $message = $_.Exception.Message }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match ([regex]::Escape('S3cret!pw'))
    }

    It 'wirft, wenn keine Version unterstuetzt wird' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJson }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*none of the API versions*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 4 -Exactly
    }

    It 'nutzt mit -ApiVersion nur diese Version' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJson }
        { Connect-VeeamServer -Credential (New-TestCredential) -ApiVersion '1.2-rev1' } | Should -Throw
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Headers['x-api-version'] -eq '1.2-rev1' }
    }

    It 'wirft, wenn die Token-Antwort kein access_token enthaelt' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content '{}' }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*access_token*'
    }
}

Describe 'Disconnect-VeeamServer' {
    It 'ruft POST /api/oauth2/logout mit Bearer und x-api-version auf und loescht die Tokens' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 }
        $session = New-TestSession

        Disconnect-VeeamServer -Session $session

        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Path -eq '/api/oauth2/logout' -and
            $Headers['Authorization'] -eq 'Bearer access-123' -and $Headers['x-api-version'] -eq '1.3-rev2'
        }
        $session.AccessToken | Should -BeNullOrEmpty
        $session.RefreshToken | Should -BeNullOrEmpty
    }

    It 'warnt nur, wenn das Logout fehlschlaegt' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 500 -Content '{"message":"boom"}' }
        $session = New-TestSession
        { Disconnect-VeeamServer -Session $session -WarningAction SilentlyContinue } | Should -Not -Throw
        $session.AccessToken | Should -BeNullOrEmpty
    }
}

Describe 'Nur lesen' {
    It 'erlaubt GET auf <Path>' -TestCases @(@{ Path = '/api/v1/jobs/states' }, @{ Path = '/api/v1/serverInfo' }) {
        param($Path)
        InModuleScope VeeamExporter -Parameters @{ Path = $Path } {
            param($Path)
            { Assert-VeeamReadOnlyRequest -Method 'GET' -Path $Path } | Should -Not -Throw
        }
    }

    It 'erlaubt POST nur auf Token und Logout' {
        InModuleScope VeeamExporter {
            { Assert-VeeamReadOnlyRequest -Method 'POST' -Path '/api/oauth2/token' } | Should -Not -Throw
            { Assert-VeeamReadOnlyRequest -Method 'POST' -Path '/api/oauth2/logout' } | Should -Not -Throw
        }
    }

    It 'blockiert <Method> <Path>' -TestCases @(
        @{ Method = 'POST'; Path = '/api/v1/jobs/8e5d1ffc/start' }
        @{ Method = 'POST'; Path = '/api/v1/jobs/8e5d1ffc/stop' }
        @{ Method = 'POST'; Path = '/api/v1/license/install' }
        @{ Method = 'POST'; Path = '/api/oauth2/token/../../v1/jobs/x/start' }
        @{ Method = 'PUT'; Path = '/api/v1/jobs/8e5d1ffc' }
        @{ Method = 'DELETE'; Path = '/api/v1/backupInfrastructure/repositories/1' }
        @{ Method = 'get'; Path = '/api/v1/jobs' }
    ) {
        param($Method, $Path)
        InModuleScope VeeamExporter -Parameters @{ Method = $Method; Path = $Path } {
            param($Method, $Path)
            { Assert-VeeamReadOnlyRequest -Method $Method -Path $Path } | Should -Throw '*read-only*'
        }
    }

    It 'verweigert eine BaseUri ohne https (<BaseUri>), bevor das Passwort gesendet wird' -TestCases @(
        @{ BaseUri = 'http://localhost:9419' }
        @{ BaseUri = 'localhost:9419' }
        @{ BaseUri = '/api' }
    ) {
        param($BaseUri)
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content '{"access_token":"t"}' }
        { Connect-VeeamServer -Credential (New-TestCredential) -BaseUri $BaseUri } | Should -Throw '*https://*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly
    }

    It 'Invoke-VeeamHttpRequest blockiert schreibende Aufrufe vor jedem Netzwerkzugriff' {
        InModuleScope VeeamExporter {
            $ctx = [pscustomobject]@{ BaseUri = 'https://127.0.0.1:1'; TimeoutSec = 1; HttpClient = $null }
            { Invoke-VeeamHttpRequest -Context $ctx -Method POST -Path '/api/v1/jobs/1/start' } | Should -Throw '*read-only*'
            { Invoke-VeeamHttpRequest -Context $ctx -Method DELETE -Path '/api/v1/jobs/1' } | Should -Throw
        }
    }
}

Describe 'GET und Paging' {
    BeforeAll {
        $script:AllJobs = @(1..450 | ForEach-Object {
                [pscustomobject]@{ id = "id-$_"; name = ('Job {0:D3}' -f $_); type = 'VSphereBackup'; status = 'Inactive'; lastResult = 'Success'; objectsCount = 1 }
            })
    }

    It 'liest alle Seiten ueber skip/limit bis pagination.total' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            $skip = [int]$Query['skip']
            $limit = [int]$Query['limit']
            $end = [math]::Min($skip + $limit, $script:AllJobs.Count) - 1
            $page = @()
            if ($skip -le $end) { $page = @($script:AllJobs[$skip..$end]) }
            $body = [pscustomobject]@{
                data       = $page
                pagination = [pscustomobject]@{ total = $script:AllJobs.Count; count = $page.Count; skip = $skip; limit = $limit }
            }
            New-HttpResponse -StatusCode 200 -Content ($body | ConvertTo-Json -Depth 5)
        }

        $metrics = Get-VeeamJobMetric -Session (New-TestSession)

        ($metrics | Where-Object Name -EQ 'veeam_job_info').Samples.Count | Should -Be 450
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 3 -Exactly
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq '/api/v1/jobs/states' -and $Query['skip'] -eq 0 -and $Query['limit'] -eq 200
        }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq '/api/v1/jobs/states' -and $Query['skip'] -eq 200 -and $Query['limit'] -eq 200
        }
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Path -eq '/api/v1/jobs/states' -and $Query['skip'] -eq 400 -and $Query['limit'] -eq 200
        }
    }

    It 'setzt x-api-version und Bearer-Token in jedem GET' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content (Get-FixtureText -Name 'jobs-states.json') }
        $null = Get-VeeamJobMetric -Session (New-TestSession)
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Headers['x-api-version'] -eq '1.3-rev2' -and $Headers['Authorization'] -eq 'Bearer access-123'
        }
    }

    It 'liest ohne pagination.total weiter, bis eine Seite nicht voll ist' {
        InModuleScope VeeamExporter {
            Mock Invoke-VeeamRestGet {
                $skip = [int]$Query['skip']
                $items = @('a', 'b', 'c', 'd', 'e')
                $end = [math]::Min($skip + 2, $items.Count) - 1
                $page = @()
                if ($skip -le $end) { $page = @($items[$skip..$end]) }
                [pscustomobject]@{ data = $page }
            }
            $result = @(Get-VeeamPagedItem -Session ([pscustomobject]@{}) -Path '/api/v1/x' -PageSize 2)
            ($result -join '') | Should -BeExactly 'abcde'
            Should -Invoke Invoke-VeeamRestGet -Times 3 -Exactly
        }
    }

    It 'behaelt eigene Query-Parameter beim Paging' {
        InModuleScope VeeamExporter {
            Mock Invoke-VeeamRestGet { [pscustomobject]@{ data = @(); pagination = [pscustomobject]@{ total = 0 } } }
            $null = Get-VeeamPagedItem -Session ([pscustomobject]@{}) -Path '/api/v1/sessions' -Query ([ordered]@{ typeFilter = 'BackupJob' })
            Should -Invoke Invoke-VeeamRestGet -Times 1 -Exactly -ParameterFilter {
                $Query['typeFilter'] -eq 'BackupJob' -and $Query['skip'] -eq 0 -and $Query['limit'] -eq 200
            }
        }
    }

    It 'wirft bei HTTP-Fehlern mit Status und Fehlertext' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 403 -Content '{"errorCode":"AccessDenied","message":"Access is denied."}' }
        { Get-VeeamJobMetric -Session (New-TestSession) } | Should -Throw '*HTTP 403*AccessDenied*'
    }

    It 'baut die Query mit URL-Encoding' {
        InModuleScope VeeamExporter {
            ConvertTo-VeeamQueryString -Query ([ordered]@{ typeFilter = 'BackupJob,ReplicaJob'; createdAfterFilter = '2024-01-10T00:00:00+01:00'; skip = 0 }) |
                Should -BeExactly 'typeFilter=BackupJob%2CReplicaJob&createdAfterFilter=2024-01-10T00%3A00%3A00%2B01%3A00&skip=0'
        }
    }
}
