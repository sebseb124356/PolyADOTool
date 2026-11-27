<#
.SYNOPSIS
    Example launcher for Ado-TestRunTool.ps1 with your own organization and project.

.DESCRIPTION
    If you usually work on the same project, edit the $Organization and $Project
    variables below once (replace 'myorg' and 'myproject'), then just run this
    file whenever you need the tool - it starts Ado-TestRunTool.ps1 with those
    values, so you never have to retype them.

    The PAT is never stored in this file. If AZURE_DEVOPS_PAT is not already set
    in the session, you are prompted for it with secure (non-echoing) input and
    it is set as an environment variable for the current session only. It is
    never written to disk, so it cannot be committed by accident, and it
    disappears when the window closes. Later runs in the same window reuse the
    variable and skip the prompt. To skip the prompt in every window, set
    $env:AZURE_DEVOPS_PAT yourself in your $PROFILE.

    Any extra arguments are forwarded to the tool, for example:

      .\Example-Run.ps1                      # interactive menu
      .\Example-Run.ps1 -RunId 1234 -Force   # delete run 1234 directly
      .\Example-Run.ps1 -ListRuns            # export all runs to CSV

    The PAT needs the "Test (read & write)" scope:
    https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate
#>

$Organization = 'myorg'
$Project      = 'myproject'

if (-not $env:AZURE_DEVOPS_PAT) {
    $securePat = Read-Host -AsSecureString 'Enter your Azure DevOps PAT (scope: Test read & write)'
    $env:AZURE_DEVOPS_PAT = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePat))
    $securePat.Dispose()
}

& (Join-Path $PSScriptRoot 'Ado-TestRunTool.ps1') -Organization $Organization -Project $Project @args
