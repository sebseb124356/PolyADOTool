#!/usr/bin/env bash
#
# SYNOPSIS
#     Example launcher for Ado-TestRunTool.sh with your own organization and project.
#
# DESCRIPTION
#     If you usually work on the same project, edit the ORGANIZATION and PROJECT
#     variables below once (replace 'myorg' and 'myproject'), then just run this
#     file whenever you need the tool - it starts Ado-TestRunTool.sh with those
#     values, so you never have to retype them.
#
#     The PAT is never stored in this file. If AZURE_DEVOPS_PAT is not already set
#     in the session, you are prompted for it with hidden (non-echoing) input and
#     it is exported for the current shell only. It is never written to disk, so it
#     cannot be committed by accident, and it disappears when the terminal closes.
#     Later runs in the same terminal reuse the variable and skip the prompt. To
#     skip the prompt in every terminal, export AZURE_DEVOPS_PAT in your ~/.bashrc
#     or ~/.zshrc.
#
#     Any extra arguments are forwarded to the tool, for example:
#
#       ./Example-Run.sh                    # interactive menu
#       ./Example-Run.sh -r 1234 -f         # delete run 1234 directly
#       ./Example-Run.sh -l                 # export all runs to CSV
#
#     The PAT needs the "Test (read & write)" scope:
#     https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate

ORGANIZATION='myorg'
PROJECT='myproject'

if [[ -z "${AZURE_DEVOPS_PAT:-}" ]]; then
    read -rs -p "Enter your Azure DevOps PAT (scope: Test read & write): " pat
    echo ""
    export AZURE_DEVOPS_PAT="$pat"
    unset pat
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/Ado-TestRunTool.sh" -o "$ORGANIZATION" -p "$PROJECT" "$@"
