[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Wait-BeforeExit {
    Write-Host ""
    Read-Host "Press Enter to close"
}

function Stop-WithMessage {
    param([string]$Message)

    Write-Host ""
    Write-Host $Message -ForegroundColor Red
    Wait-BeforeExit
    exit 1
}

function Run-Command {
    param(
        [string]$Program,
        [string[]]$Arguments
    )

    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE."
    }
}

try {
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Kemi Chen Academic Website Publisher" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    $gitInstallDirectory = "C:\Program Files\Git\cmd"
    $ghInstallDirectory = "C:\Program Files\GitHub CLI"

    if (Test-Path -LiteralPath "$gitInstallDirectory\git.exe") {
        $env:PATH = "$gitInstallDirectory;$env:PATH"
    }

    if (Test-Path -LiteralPath "$ghInstallDirectory\gh.exe") {
        $env:PATH = "$ghInstallDirectory;$env:PATH"
    }

    $proxyClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $proxyConnection = $proxyClient.ConnectAsync("127.0.0.1", 7890)
        if ($proxyConnection.Wait(1000) -and $proxyClient.Connected) {
            $proxyUrl = "http://127.0.0.1:7890"
            $env:HTTP_PROXY = $proxyUrl
            $env:HTTPS_PROXY = $proxyUrl
            Write-Host "Local proxy detected: $proxyUrl" -ForegroundColor DarkGray
            Write-Host ""
        }
    }
    catch {
        # Continue without a proxy when Clash is not running.
    }
    finally {
        $proxyClient.Dispose()
    }

    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCommand) {
        Write-Host "Git is not installed." -ForegroundColor Yellow
        Write-Host "Install Git for Windows, restart VS Code, and run this script again:"
        Write-Host "https://git-scm.com/download/win" -ForegroundColor Blue
        Start-Process "https://git-scm.com/download/win"
        Stop-WithMessage "Git is required before publishing."
    }

    $ghCommand = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $ghCommand) {
        Write-Host "GitHub CLI is not installed." -ForegroundColor Yellow
        $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue

        if ($wingetCommand) {
            $answer = Read-Host "Install GitHub CLI now with winget? [Y/n]"
            if ([string]::IsNullOrWhiteSpace($answer) -or $answer -match "^[Yy]") {
                Run-Command "winget" @(
                    "install",
                    "--id", "GitHub.cli",
                    "--exact",
                    "--source", "winget"
                )

                Write-Host ""
                Write-Host "GitHub CLI was installed." -ForegroundColor Green
                Write-Host "Close this window, restart VS Code, and double-click the script again."
                Wait-BeforeExit
                exit 0
            }
        }

        Write-Host "Download GitHub CLI, install it, restart VS Code, and run this script again:"
        Write-Host "https://cli.github.com/" -ForegroundColor Blue
        Start-Process "https://cli.github.com/"
        Stop-WithMessage "GitHub CLI is required before publishing."
    }

    & gh auth status --hostname github.com *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Please sign in to GitHub in the browser window." -ForegroundColor Yellow
        Run-Command "gh" @(
            "auth", "login",
            "--hostname", "github.com",
            "--git-protocol", "https",
            "--web"
        )
    }

    Run-Command "gh" @("auth", "setup-git", "--hostname", "github.com")

    $githubUser = (& gh api user --jq ".login").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($githubUser)) {
        throw "Unable to read the signed-in GitHub username."
    }

    $repositoryName = "$githubUser.github.io"
    $repositoryFullName = "$githubUser/$repositoryName"
    $repositoryUrl = "https://github.com/$repositoryFullName.git"
    $websiteUrl = "https://$repositoryName"

    Write-Host ""
    Write-Host "GitHub account: $githubUser"
    Write-Host "Repository:     $repositoryFullName"

    if (-not (Test-Path -LiteralPath ".git")) {
        Run-Command "git" @("init")
    }

    Run-Command "git" @("branch", "-M", "main")

    $gitUserName = (& git config --get user.name)
    if ([string]::IsNullOrWhiteSpace($gitUserName)) {
        Run-Command "git" @("config", "user.name", $githubUser)
    }

    $gitUserEmail = (& git config --get user.email)
    if ([string]::IsNullOrWhiteSpace($gitUserEmail)) {
        Run-Command "git" @(
            "config",
            "user.email",
            "$githubUser@users.noreply.github.com"
        )
    }

    Run-Command "git" @("add", "--all")

    & git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Run-Command "git" @("commit", "-m", "Update website $timestamp")
        Write-Host "Local changes committed." -ForegroundColor Green
    }
    else {
        Write-Host "No new local changes to commit."
    }

    $originUrl = (& git remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl)) {
        & gh repo view $repositoryFullName *> $null
        if ($LASTEXITCODE -eq 0) {
            Run-Command "git" @("remote", "add", "origin", $repositoryUrl)
        }
        else {
            Run-Command "gh" @(
                "repo", "create", $repositoryFullName,
                "--public",
                "--source", ".",
                "--remote", "origin",
                "--description", "Kemi Chen's academic homepage"
            )
        }
    }
    elseif ($originUrl.Trim() -ne $repositoryUrl) {
        throw "The existing origin remote points to '$originUrl', not '$repositoryUrl'."
    }

    Run-Command "git" @("push", "-u", "origin", "main")
    Write-Host "Website files uploaded successfully." -ForegroundColor Green

    & gh api "repos/$repositoryFullName/pages" *> $null
    if ($LASTEXITCODE -ne 0) {
        $pagesConfig = @{
            build_type = "legacy"
            source = @{
                branch = "main"
                path = "/"
            }
        } | ConvertTo-Json -Compress

        $pagesConfig | & gh api `
            --method POST `
            "repos/$repositoryFullName/pages" `
            --input -

        if ($LASTEXITCODE -eq 0) {
            Write-Host "GitHub Pages enabled." -ForegroundColor Green
        }
        else {
            Write-Host ""
            Write-Host "Files were uploaded, but Pages could not be enabled automatically." -ForegroundColor Yellow
            Write-Host "Open the repository, then choose Settings > Pages > Deploy from a branch > main > / (root)."
        }
    }
    else {
        Write-Host "GitHub Pages is already enabled."
    }

    Write-Host ""
    Write-Host "Repository: https://github.com/$repositoryFullName" -ForegroundColor Blue
    Write-Host "Website:    $websiteUrl" -ForegroundColor Blue
    Write-Host ""
    Write-Host "The first deployment can take several minutes." -ForegroundColor Yellow

    $openAnswer = Read-Host "Open the GitHub repository now? [Y/n]"
    if ([string]::IsNullOrWhiteSpace($openAnswer) -or $openAnswer -match "^[Yy]") {
        Start-Process "https://github.com/$repositoryFullName"
    }

    Wait-BeforeExit
}
catch {
    Stop-WithMessage $_.Exception.Message
}
