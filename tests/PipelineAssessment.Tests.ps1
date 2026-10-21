BeforeAll {
    $assessmentPath = (Resolve-Path "$PSScriptRoot/../src/scripts/Invoke-PSRuleWorkbookAssessment.ps1").Path
    function Invoke-TestAssessment {
        param([string]$Scenario, [string]$OutputDirectory)
        # Isolate collector/PSRule/Azure adapters while running the real orchestration and report writer.
        $runner = [powershell]::Create()
        $harness = {
            param($AssessmentPath, $Scenario, $OutputDirectory)
            $previousEnvironment = @{}
            foreach ($name in @('PIPELINE_WORKSPACE', 'BUILD_BUILDID', 'BUILD_ARTIFACTSTAGINGDIRECTORY')) {
                $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            }
            try {
                $env:PIPELINE_WORKSPACE = $OutputDirectory
                $env:BUILD_BUILDID = '42'
                $env:BUILD_ARTIFACTSTAGINGDIRECTORY = $OutputDirectory
                New-Item $OutputDirectory -ItemType Directory -Force | Out-Null
                function Get-Module { [pscustomobject]@{ Version = [version]'2.9.0' } }
                function Import-Module { }
                function Connect-AzDevOps {
                    param($Organization, $OrganizationId, $AccessToken)
                    if ($OrganizationId -ne '11111111-1111-1111-1111-111111111111') { throw 'The organization instance ID was not resolved.' }
                }
                function Export-AzDevOpsOrganizationRuleData {
                    param($OutputPath, $CompletenessReportPath, [switch]$Strict)
                    if ($Scenario -in 'Incomplete', 'PartialNoThrow', 'UnavailableNoThrow') {
                        $status = if ($Scenario -eq 'UnavailableNoThrow') { 'Unavailable' } else { 'Partial' }
                        if ($CompletenessReportPath) { @{ Status = $status } | ConvertTo-Json | Set-Content $CompletenessReportPath }
                        if ($Strict -and $Scenario -eq 'Incomplete') { throw 'Assessment collection is incomplete.' }
                    } elseif ($CompletenessReportPath) { '{"Status":"Complete"}' | Set-Content $CompletenessReportPath }
                    '{}' | Set-Content (Join-Path $OutputPath 'input.json')
                }
                function New-PSRuleOption { }
                function Start-Sleep { }
                function Assert-PSRule {
                    param($ResultVariable, $OutputPath, $InputPath)
                    if (@($InputPath | Where-Object { $_ -match 'collection-status.json' }).Count) { throw 'Collection status entered the target stream.' }
                    $results = @('Pass', 'Fail' | ForEach-Object {
                        [pscustomobject]@{
                            RuleName = 'Test.Rule'; TargetName = 'test-resource'; TargetType = 'Azure.DevOps.Project'
                            Outcome = $_; Info = @{ DisplayName = 'Test rule'; Annotations = @{ severity = 'Critical' } }
                            Field = @{ id = '{"project":"test-project","resourceName":"test-resource"}' }
                        }
                    })
                    if ($Scenario -eq 'Empty') { $results = @() }
                    if ($Scenario -eq 'ExecutionError') { $results[1].Outcome = 'Error' }
                    if ($Scenario -eq 'Skipped') { $results | ForEach-Object { $_.Outcome = 'None' } }
                    Set-Variable -Name $ResultVariable -Scope 1 -Value $results
                    '{}' | Set-Content $OutputPath
                }
                function az {
                    $global:LASTEXITCODE = 0
                    if ($args[0] -eq 'deployment') {
                        return '{"ingestionEndpoint":{"value":"https://example.test"},"ingestionRuleImmutableId":{"value":"dcr-test"},"workspaceId":{"value":"workspace-test"}}'
                    }
                    return 'test-token'
                }
                function Invoke-WebRequest {
                    if ($Scenario -eq 'IngestionFailure') { throw 'Ingestion failed.' }
                }
                function Invoke-RestMethod {
                    param($Uri)
                    if ($Uri -match '/_apis/connectionData$') { return [pscustomobject]@{ instanceId = '11111111-1111-1111-1111-111111111111' } }
                    return '{"tables":[{"rows":[[2,1,1]]}]}' | ConvertFrom-Json
                }
                try {
                    & $AssessmentPath -ModuleManifestPath 'test-module.psd1' -Organization test-org
                    [pscustomobject]@{ Error = $null }
                } catch { [pscustomobject]@{ Error = $_.Exception.Message } }
            } finally {
                foreach ($name in $previousEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name]) }
            }
        }
        try {
            $null = $runner.AddScript($harness.ToString()).AddArgument($assessmentPath).AddArgument($Scenario).AddArgument($OutputDirectory)
            $result = $runner.Invoke()
            [pscustomobject]@{ Error = $result[-1].Error; Messages = $runner.Streams.Information.MessageData -join "`n" }
        } finally { $runner.Dispose() }
    }
}

Describe 'Assessment report integration' {
    It 'validates the completeness report independently for <Scenario>' -ForEach @(@{ Scenario = 'PartialNoThrow' }, @{ Scenario = 'UnavailableNoThrow' }) {
        $output = "$TestDrive/$Scenario"
        $assessment = Invoke-TestAssessment $Scenario $output
        $assessment.Error | Should -Match 'collection is incomplete'
        Test-Path "$output/psrule-results.sarif" | Should -BeFalse
        Test-Path "$output/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'PSRuleReportReady'
    }

    It 'does not publish an assessment containing only skipped controls' {
        $output = "$TestDrive/skipped"
        $assessment = Invoke-TestAssessment Skipped $output
        $assessment.Error | Should -Match 'zero evaluated rule results'
        Test-Path "$output/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'PSRuleReportReady'
    }

    It 'retains completeness evidence and prevents evaluation and publication after incomplete collection' {
        $output = "$TestDrive/incomplete"
        $assessment = Invoke-TestAssessment Incomplete $output
        $assessment.Error | Should -Match 'collection is incomplete'
        (Get-Content "$output/collection-status.json" -Raw | ConvertFrom-Json).Status | Should -Be Partial
        Test-Path "$output/psrule-results.sarif" | Should -BeFalse
        Test-Path "$output/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'PSRuleReportReady'
    }

    It 'retains the HTML, Markdown, and SARIF and announces report readiness before ingestion fails' {
        $output = "$TestDrive/ingestion-failure"
        $assessment = Invoke-TestAssessment IngestionFailure $output
        $assessment.Error | Should -Be 'Ingestion failed.'
        Test-Path "$output/psrule-dashboard.html" | Should -BeTrue
        Test-Path "$output/psrule-summary.md" | Should -BeTrue
        Test-Path "$output/psrule-results.sarif" | Should -BeTrue
        $assessment.Messages | Should -Match '##vso\[task.uploadsummary\]'
        $assessment.Messages | Should -Match '##vso\[task.setvariable variable=PSRuleReportReady\]true'
    }

    It 'keeps rule violations as findings and verifies workbook publishing' {
        $assessment = Invoke-TestAssessment Success "$TestDrive/success"
        $assessment.Error | Should -BeNullOrEmpty
        $assessment.Messages | Should -Match 'total=2, failed=1, passed=1'
    }

    It 'does not publish a dashboard for zero evaluated results' {
        $output = "$TestDrive/empty"
        $assessment = Invoke-TestAssessment Empty $output
        $assessment.Error | Should -Match 'zero rule results'
        Test-Path "$output/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'PSRuleReportReady'
    }

    It 'does not publish a success-looking dashboard when rule execution fails' {
        $output = "$TestDrive/execution-error"
        $assessment = Invoke-TestAssessment ExecutionError $output
        $assessment.Error | Should -Match 'rule execution errors'
        Test-Path "$output/psrule-dashboard.html" | Should -BeFalse
        $assessment.Messages | Should -Not -Match 'task.uploadsummary'
    }
}
