# PolyADOTool

A small command-line tool for Azure DevOps features that are only accessible through the REST API, not the UI.

- **Windows:** PowerShell version, no dependencies beyond PowerShell 5.1+ / PowerShell Core.
- **macOS / Linux:** Bash version, needs only `bash`, `curl` and `jq` (all preinstalled on macOS; `jq` via `brew install jq` / `apt install jq` on Linux).

Current tool: **`Ado-TestRunTool.ps1`** / **`Ado-TestRunTool.sh`** — delete test runs (including linked test outcomes) and export test run lists. For daily use, see the pre-filled launchers **`Example-Run.ps1`** / **`Example-Run.sh`**. Both versions have the same features and flags (see [Parity](#parity-between-the-powershell-and-bash-versions)).

## Features

### 1. Delete a test run (including linked outcomes)
Azure DevOps has no UI for deleting a test run, and deleted runs clutter reports. This action:

- Resolves the run and shows what will be deleted (name, state, URL).
- Lists all linked test results/outcomes, grouped by outcome (Passed, Failed, ...).
- Asks for confirmation, then deletes the run via the REST API.
- Verifies afterwards that both the run and its results are gone (404), so nothing is left dangling.

### 2. List and export test runs
- Fetches **all** test runs in the project (paged, no 1000-item limit).
- Saves them to a timestamped CSV in the current directory (override with `-OutputPath`).
- CSV columns: id, name, state, outcome, plan, automation flag, dates, total/passed/failed counts, web URL.
- Prints a short preview (10 most recent runs).

### Interaction modes
- **Interactive menu** by default: choose `[1]` delete run (then enter the ID), `[2]` export runs, `[Q]` quit.
- **Non-interactive** for scripting/CI: `-RunId <id>` deletes directly, `-ListRuns` exports directly.

## Usage

### Quick start: `Example-Run.ps1` (recommended for daily use)

If you work on the same project most of the time, open **`Example-Run.ps1`** once, set `$Organization` and `$Project` at the top, and from then on just run:

```powershell
.\Example-Run.ps1                     # interactive menu
.\Example-Run.ps1 -RunId 1234 -Force  # extra arguments are forwarded to the tool
.\Example-Run.ps1 -ListRuns           # e.g. -RunId / -ListRuns / -OutputPath
```

On the first run in a window you are prompted for your PAT with secure (non-echoing) input; it is set as `AZURE_DEVOPS_PAT` for the current session only and never written to disk, so it cannot be committed by accident. Later runs in the same window skip the prompt. To skip the prompt in every window, set `$env:AZURE_DEVOPS_PAT` yourself in your `$PROFILE`.

> If Windows refuses to run scripts ("running scripts is disabled"), run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` once.

### Direct usage

```powershell
# One-time setup: create a PAT with the "Test (read & write)" scope
# https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate
$env:AZURE_DEVOPS_PAT = "<your PAT>"

# Interactive
.\Ado-TestRunTool.ps1 -Organization myorg -Project myproject

# Delete a specific run directly
.\Ado-TestRunTool.ps1 -Organization myorg -Project myproject -RunId 1234 -Force

# Export all runs to CSV directly
.\Ado-TestRunTool.ps1 -Organization myorg -Project myproject -ListRuns -OutputPath C:\temp\runs.csv
```

> The PAT is only read from the environment (`AZURE_DEVOPS_PAT`, fallback `AZDO_PAT`) and is never stored, logged, or written by the script. Each colleague uses their own PAT.

### macOS / Linux: `Ado-TestRunTool.sh` / `Example-Run.sh`

The Bash port is feature-identical to the PowerShell version (same menu, flags, CSV columns, paging and verification). Requirements: `bash` (the macOS default 3.2 works), `curl`, `jq`.

```bash
# One-time setup: create a PAT with the "Test (read & write)" scope
# https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate
export AZURE_DEVOPS_PAT="<your PAT>"

# Interactive
./Ado-TestRunTool.sh -o myorg -p myproject

# Delete a specific run directly
./Ado-TestRunTool.sh -o myorg -p myproject -r 1234 -f

# Export all runs to CSV directly
./Ado-TestRunTool.sh -o myorg -p myproject -l -O /tmp/runs.csv

# Pre-filled launcher (edit Example-Run.sh once, then just run it)
./Example-Run.sh                     # interactive menu; prompts for the PAT if unset
./Example-Run.sh -r 1234 -f          # extra arguments are forwarded to the tool
```

Flags: `-o/-Organization`, `-p/-Project`, `-r/-RunId`, `-l/-ListRuns`, `-O/-OutputPath`, `-f/-Force`, `-w/-WhatIf`, `-h/-Help` (long `--...` forms also work). The PAT is only read from `AZURE_DEVOPS_PAT` (fallback `AZDO_PAT`); `Example-Run.sh` prompts for it with hidden input and exports it for the current shell only — never written to disk.

## Parity between the PowerShell and Bash versions

Yes — functionality is the same: identical interactive menu, identical non-interactive flags (`-RunId`/`-ListRuns`/`-OutputPath`/`-Force`/`-WhatIf`), identical REST calls with API version 7.1, identical paging (pages of 1000), identical CSV columns, identical delete-then-verify-404 behavior, and identical PAT-from-environment-only handling. Only cosmetic platform differences remain: the confirmation prompt is a plain `y/N` (the PowerShell `ShouldProcess` prompt for this high-impact action also defaults to "No"), colors follow the terminal/`NO_COLOR`, and the CSV uses LF line endings instead of CRLF.

## Design choices

- **PAT via environment variable, not parameter.** Keeps tokens out of shell history, process listings, and CI logs, and makes accidental commits of credentials impossible.
- **Run deletion cascades to outcomes; verification instead of per-result deletes.** The documented REST API (7.x) offers Add/Get/List/Update for test results but **no per-result DELETE**. Deleting the run (`DELETE /_apis/test/runs/{runId}`) removes all linked results and attachments server-side. The script therefore deletes the run and then explicitly re-queries the run and results endpoints to confirm 404, proving nothing is left dangling. A single-outcome delete mode was considered and deliberately skipped for this reason.
- **Confirm before destructive action.** Uses PowerShell's `ShouldProcess` (`-Confirm`/`-WhatIf` supported); the confirmation prompt is data-driven and shows the run and its result count. `-Force` opts out for automation.
- **Basic auth with the PAT.** Azure DevOps expects `Authorization: Basic base64(":PAT")`; the token is base64-encoded in memory only.
- **Paging everywhere.** Run lists and per-run results are fetched in pages of 1000, so large projects work correctly.
- **Clear error handling.** 401 (PAT scope/expiry) and 404 (unknown run) produce specific messages instead of raw HTTP errors.
- **API version pinned to 7.1** for stable, documented behavior (`https://dev.azure.com/{org}/{project}/_apis/test/...`).

## References

- [Test Runs - Delete](https://learn.microsoft.com/en-us/rest/api/azure/devops/test/runs/delete?view=azure-devops-rest-7.1)
- [Test Runs - List](https://learn.microsoft.com/en-us/rest/api/azure/devops/test/runs/list?view=azure-devops-rest-7.1)
- [Results (Add/Get/List/Update, no Delete)](https://learn.microsoft.com/en-us/rest/api/azure/devops/test/results?view=azure-devops-rest-7.1)

## Roadmap ideas

- Delete multiple runs in batch (e.g. by date range or pipeline)
- Reset a single test outcome to NotApplicable via the documented Update API
