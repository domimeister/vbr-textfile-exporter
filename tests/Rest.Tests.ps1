BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
}

Describe 'Connect-VeeamServer (auth and version probe)' {
    BeforeEach {
        $script:TriedVersions = New-Object System.Collections.Generic.List[string]
    }

    It 'takes the highest revision the server accepts' {
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

    It 'does not try 1.2-rev1 and names VBR 13 as requirement (VBR 12 is not supported)' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            $script:TriedVersions.Add($Headers['x-api-version'])
            if ($Headers['x-api-version'] -ne '1.2-rev1') {
                return New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJson
            }
            return New-HttpResponse -StatusCode 200 -Content $script:TokenJson
        }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*requires Veeam Backup & Replication 13 or later*'
        ($script:TriedVersions -join ',') | Should -BeExactly '1.3-rev2,1.3-rev1,1.3-rev0'
    }

    It 'sends POST /api/oauth2/token as password grant with x-api-version' {
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

    It 'aborts immediately on a wrong password (no further version)' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:InvalidGrantJson }

        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*invalid_grant*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly
    }

    It 'aborts immediately on HTTP <Code>' -TestCases @(@{ Code = 401 }, @{ Code = 403 }, @{ Code = 500 }) {
        param($Code)
        $script:Code = $Code
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode $script:Code -Content '{"message":"version"}' }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw "*HTTP $Code*"
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly
    }

    It 'aborts immediately on HTTP 400 without a version hint' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content '{"errorCode":"BadRequest","message":"Something else"}' }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*Something else*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly
    }

    It 'does not mention the password in the error message' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:InvalidGrantJson }
        $message = $null
        try { $null = Connect-VeeamServer -Credential (New-TestCredential) } catch { $message = $_.Exception.Message }
        $message | Should -Not -BeNullOrEmpty
        $message | Should -Not -Match ([regex]::Escape('S3cret!pw'))
    }

    It 'throws if no version is supported' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJson }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*none of the API versions*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 3 -Exactly
    }

    It 'uses only this version with -ApiVersion' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJson }
        { Connect-VeeamServer -Credential (New-TestCredential) -ApiVersion '1.3-rev0' } | Should -Throw
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter { $Headers['x-api-version'] -eq '1.3-rev0' }
    }

    It 'throws if the token response contains no access_token' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content '{}' }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*access_token*'
    }

    It 'moves on to the next revision on the real VBR 13.1 answer to an unsupported revision' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest {
            $script:TriedVersions.Add($Headers['x-api-version'])
            if ($Headers['x-api-version'] -eq '1.3-rev2') {
                return New-HttpResponse -StatusCode 400 -Content $script:UnsupportedVersionJsonVbr131
            }
            return New-HttpResponse -StatusCode 200 -Content $script:TokenJson
        }
        (Connect-VeeamServer -Credential (New-TestCredential)).ApiVersion | Should -BeExactly '1.3-rev1'
        ($script:TriedVersions -join ',') | Should -BeExactly '1.3-rev2,1.3-rev1'
    }

    It 'stops at once on the real VBR 13.1 answer to wrong credentials (HTTP 401)' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 401 -Content $script:AccessDeniedJsonVbr131 }
        { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*HTTP 401*credentials are invalid*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly
    }

    Context 'HTTP client of a failed logon' {
        BeforeEach {
            # Stands in for the HttpClient of PowerShell 7; counts Dispose().
            $script:Client = [pscustomobject]@{ Disposed = 0 }
            $script:Client | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed++ }
            Mock -ModuleName VeeamExporter New-VeeamHttpContext {
                [pscustomobject]@{ BaseUri = 'https://localhost:9419'; TimeoutSec = 5; HttpClient = $script:Client; ApiVersion = $null; AccessToken = $null; RefreshToken = $null }
            }
        }

        # Content names a variable of TestHelpers.ps1: test cases are built
        # before BeforeAll has loaded it.
        It 'is released when the logon fails (<Case>)' -TestCases @(
            @{ Case = 'HTTP 401'; StatusCode = 401; Content = 'AccessDeniedJsonVbr131'; Message = '*HTTP 401*' }
            @{ Case = 'no supported API version'; StatusCode = 400; Content = 'UnsupportedVersionJson'; Message = '*none of the API versions*' }
            @{ Case = 'no access_token'; StatusCode = 200; Content = $null; Message = '*no access_token*' }
        ) {
            param($Case, $StatusCode, $Content, $Message)
            $body = '{}'
            if ($Content) { $body = Get-Variable -Name $Content -Scope Script -ValueOnly }
            $script:Answer = New-HttpResponse -StatusCode $StatusCode -Content $body
            Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { $script:Answer }
            { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw $Message
            $script:Client.Disposed | Should -Be 1
        }

        It 'is released when the request fails (connection, TLS, timeout)' {
            Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { throw 'The SSL connection could not be established.' }
            { Connect-VeeamServer -Credential (New-TestCredential) } | Should -Throw '*SSL connection*'
            $script:Client.Disposed | Should -Be 1
        }

        It 'stays open in the session after a successful logon' {
            Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content $script:TokenJson }
            $session = Connect-VeeamServer -Credential (New-TestCredential)
            $script:Client.Disposed | Should -Be 0
            [object]::ReferenceEquals($session.HttpClient, $script:Client) | Should -BeTrue
        }
    }
}

Describe 'Error body under Windows PowerShell 5.1' {
    # Invoke-WebRequest (5.1) has already read the error response into ErrorDetails,
    # so the response stream is at its end when the exporter gets it.
    It 'rewinds a response stream that has already been read' {
        $text = InModuleScope VeeamExporter -Parameters @{ Json = $script:UnsupportedVersionJsonVbr131 } {
            param($Json)
            $stream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, [System.Text.Encoding]::UTF8.GetBytes($Json))
            $stream.Position = $stream.Length
            Read-VeeamErrorResponseBody -Stream $stream -ErrorDetailsMessage $null
        }
        $text | Should -BeExactly $script:UnsupportedVersionJsonVbr131
    }

    It 'decodes the body as UTF-8' {
        $expected = '{"message":"Repository ' + [char]0x00C4 + 'nderung fehlgeschlagen"}'
        $text = InModuleScope VeeamExporter -Parameters @{ Json = $expected } {
            param($Json)
            $stream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false).GetBytes($Json))
            $stream.Position = $stream.Length
            Read-VeeamErrorResponseBody -Stream $stream -ErrorDetailsMessage 'ignored'
        }
        $text | Should -BeExactly $expected
    }

    It 'falls back to ErrorDetails if the stream gives nothing (<Case>)' -TestCases @(
        @{ Case = 'no stream'; Empty = $false }
        @{ Case = 'empty stream'; Empty = $true }
    ) {
        param($Case, $Empty)
        $text = InModuleScope VeeamExporter -Parameters @{ Empty = $Empty; Json = $script:AccessDeniedJsonVbr131 } {
            param($Empty, $Json)
            $stream = $null
            if ($Empty) { $stream = New-Object -TypeName System.IO.MemoryStream }
            Read-VeeamErrorResponseBody -Stream $stream -ErrorDetailsMessage $Json
        }
        $text | Should -BeExactly $script:AccessDeniedJsonVbr131
    }

    It 'returns an empty string without stream and ErrorDetails' {
        InModuleScope VeeamExporter { Read-VeeamErrorResponseBody -Stream $null -ErrorDetailsMessage $null } | Should -BeExactly ''
    }
}

Describe 'Disconnect-VeeamServer' {
    It 'calls POST /api/oauth2/logout with bearer and x-api-version and clears the tokens' {
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

    It 'only warns if the logout fails' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 500 -Content '{"message":"boom"}' }
        $session = New-TestSession
        { Disconnect-VeeamServer -Session $session -WarningAction SilentlyContinue } | Should -Not -Throw
        $session.AccessToken | Should -BeNullOrEmpty
    }
}

Describe 'Read-only' {
    It 'allows GET on <Path>' -TestCases @(@{ Path = '/api/v1/jobs/states' }, @{ Path = '/api/v1/sessions' }) {
        param($Path)
        InModuleScope VeeamExporter -Parameters @{ Path = $Path } {
            param($Path)
            { Assert-VeeamReadOnlyRequest -Method 'GET' -Path $Path } | Should -Not -Throw
        }
    }

    It 'allows POST only on token and logout' {
        InModuleScope VeeamExporter {
            { Assert-VeeamReadOnlyRequest -Method 'POST' -Path '/api/oauth2/token' } | Should -Not -Throw
            { Assert-VeeamReadOnlyRequest -Method 'POST' -Path '/api/oauth2/logout' } | Should -Not -Throw
        }
    }

    It 'blocks <Method> <Path>' -TestCases @(
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

    It 'refuses a BaseUri without https (<BaseUri>) before the password is sent' -TestCases @(
        @{ BaseUri = 'http://localhost:9419' }
        @{ BaseUri = 'localhost:9419' }
        @{ BaseUri = '/api' }
    ) {
        param($BaseUri)
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content '{"access_token":"t"}' }
        { Connect-VeeamServer -Credential (New-TestCredential) -BaseUri $BaseUri } | Should -Throw '*https://*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly
    }

    It 'refuses -TimeoutSec <Value> before the password is sent' -TestCases @(@{ Value = 0 }, @{ Value = -5 }, @{ Value = 601 }) {
        param($Value)
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content '{"access_token":"t"}' }
        { Connect-VeeamServer -Credential (New-TestCredential) -TimeoutSec $Value } | Should -Throw '*TimeoutSec*'
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 0 -Exactly
    }

    It 'Invoke-VeeamHttpRequest blocks writing calls before any network access' {
        InModuleScope VeeamExporter {
            $ctx = [pscustomobject]@{ BaseUri = 'https://127.0.0.1:1'; TimeoutSec = 1; HttpClient = $null }
            { Invoke-VeeamHttpRequest -Context $ctx -Method POST -Path '/api/v1/jobs/1/start' } | Should -Throw '*read-only*'
            { Invoke-VeeamHttpRequest -Context $ctx -Method DELETE -Path '/api/v1/jobs/1' } | Should -Throw
        }
    }
}

Describe 'GET and paging' {
    BeforeAll {
        $script:AllJobs = @(1..450 | ForEach-Object {
                [pscustomobject]@{ id = "id-$_"; name = ('Job {0:D3}' -f $_); type = 'VSphereBackup'; status = 'Inactive'; lastResult = 'Success'; objectsCount = 1 }
            })
    }

    It 'reads all pages via skip/limit up to pagination.total' {
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

    It 'sets x-api-version and bearer token in every GET' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 200 -Content (Get-FixtureText -Name 'jobs-states.json') }
        $null = Get-VeeamJobMetric -Session (New-TestSession)
        Should -Invoke -ModuleName VeeamExporter Invoke-VeeamHttpRequest -Times 1 -Exactly -ParameterFilter {
            $Headers['x-api-version'] -eq '1.3-rev2' -and $Headers['Authorization'] -eq 'Bearer access-123'
        }
    }

    It 'keeps reading without pagination.total until a page is not full' {
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

    It 'keeps its own query parameters when paging' {
        InModuleScope VeeamExporter {
            Mock Invoke-VeeamRestGet { [pscustomobject]@{ data = @(); pagination = [pscustomobject]@{ total = 0 } } }
            $null = Get-VeeamPagedItem -Session ([pscustomobject]@{}) -Path '/api/v1/sessions' -Query ([ordered]@{ typeFilter = 'BackupJob' })
            Should -Invoke Invoke-VeeamRestGet -Times 1 -Exactly -ParameterFilter {
                $Query['typeFilter'] -eq 'BackupJob' -and $Query['skip'] -eq 0 -and $Query['limit'] -eq 200
            }
        }
    }

    It 'throws on HTTP errors with status and error text' {
        Mock -ModuleName VeeamExporter Invoke-VeeamHttpRequest { New-HttpResponse -StatusCode 403 -Content '{"errorCode":"AccessDenied","message":"Access is denied."}' }
        { Get-VeeamJobMetric -Session (New-TestSession) } | Should -Throw '*HTTP 403*AccessDenied*'
    }

    It 'builds the query with URL encoding' {
        InModuleScope VeeamExporter {
            ConvertTo-VeeamQueryString -Query ([ordered]@{ typeFilter = 'BackupJob,ReplicaJob'; createdAfterFilter = '2024-01-10T00:00:00+01:00'; skip = 0 }) |
                Should -BeExactly 'typeFilter=BackupJob%2CReplicaJob&createdAfterFilter=2024-01-10T00%3A00%3A00%2B01%3A00&skip=0'
        }
    }
}
