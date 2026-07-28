param(
  [ValidateSet('Start', 'Draw', 'Reset', 'Stop', 'Status')]
  [string]$Action = 'Start',
  [string]$MainSiteRoot = '',
  [string]$SupabaseCliPath = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$LotteryRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $LotteryRoot
$MainRoot = $MainSiteRoot
if (-not $MainRoot) {
  $MainRoot = Join-Path $WorkspaceRoot '_tmp\summer-lottery-main'
}
$RuntimeRoot = Join-Path $LotteryRoot '.local-e2e'
$SupabaseExe = $SupabaseCliPath
if (-not $SupabaseExe) {
  $SupabaseExe = Join-Path $WorkspaceRoot '_tools\supabase-cli\supabase.exe'
}
$SupabaseVersion = '2.109.1'
$SupabaseZipHash = 'd0d270692cf78b8aa56545461f02cdf929ce9bb94e95e5e66404fd0e7d2c0c16'
$SupabaseZipUrl = "https://github.com/supabase/cli/releases/download/v$SupabaseVersion/supabase_${SupabaseVersion}_windows_amd64.zip"
$RuntimeBaseline = Join-Path $LotteryRoot 'supabase\migrations\000_local_main_baseline.sql'
$LocalAuthBaseline = Join-Path $LotteryRoot 'scripts\fixtures\000_local_main_auth.sql'
$StatePath = Join-Path $RuntimeRoot 'state.json'
$MainPidPath = Join-Path $RuntimeRoot 'main.pid'
$LotteryPidPath = Join-Path $RuntimeRoot 'lottery.pid'
$ProjectId = 'open-lottery'
$DatabaseContainer = "supabase_db_$ProjectId"

$TestEmail = 'demo-participant@example.local'
$TestPassword = 'OpenLotteryDemo2026!'
$ContactOperatorEmail = 'demo-contact-operator@example.local'
$ContactOperatorPassword = 'OpenLotteryContactOperator2026!'
$GatewaySecret = 'local-e2e-backend-secret-please-never-use-in-production-000'
$MainSessionSecret = 'local-e2e-main-session-secret-please-never-use-in-production-00'
$LotterySessionSecret = 'local-e2e-lottery-session-secret-never-use-in-production-000'
$DrawSeed = 'local-e2e-private-draw-seed-please-never-use-in-production-000'
$ContactEncryptionKey = 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY'

function Write-Step([string]$Message) {
  Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Ensure-SupabaseCli {
  $env:DO_NOT_TRACK = '1'
  if (Test-Path -LiteralPath $SupabaseExe) {
    return
  }
  Write-Step "Download and verify Supabase CLI v$SupabaseVersion"
  $ToolRoot = Split-Path -Parent $SupabaseExe
  Ensure-Directory $ToolRoot
  $ZipPath = Join-Path $ToolRoot "supabase_${SupabaseVersion}_windows_amd64.zip"
  Invoke-WebRequest -Uri $SupabaseZipUrl -OutFile $ZipPath
  $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
  if ($ActualHash -ne $SupabaseZipHash) {
    Remove-Item -LiteralPath $ZipPath -Force
    throw "Supabase CLI checksum mismatch: $ActualHash"
  }
  Expand-Archive -LiteralPath $ZipPath -DestinationPath $ToolRoot -Force
}

function Invoke-Supabase([string[]]$Arguments, [switch]$AllowFailure) {
  Push-Location $LotteryRoot
  try {
    & $SupabaseExe @Arguments
    $ExitCode = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($ExitCode -ne 0 -and -not $AllowFailure) {
    throw "Supabase CLI failed: $($Arguments -join ' ')"
  }
}

function Get-SupabaseStatus {
  $PreviousErrorPreference = $ErrorActionPreference
  Push-Location $LotteryRoot
  try {
    $ErrorActionPreference = 'Continue'
    $Raw = & $SupabaseExe status -o json 2>$null
    $ExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $PreviousErrorPreference
    Pop-Location
  }
  if ($ExitCode -ne 0 -or -not $Raw) {
    throw 'Local Supabase is not running. Run npm run local:e2e first.'
  }
  return ($Raw | ConvertFrom-Json)
}

function Stop-TrackedProcess([string]$PidPath) {
  if (-not (Test-Path -LiteralPath $PidPath)) {
    return
  }
  $TrackedPid = [int](Get-Content -LiteralPath $PidPath -Raw)
  Stop-Process -Id $TrackedPid -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Stop-WebApps {
  Stop-TrackedProcess $MainPidPath
  Stop-TrackedProcess $LotteryPidPath
  $Listeners = Get-NetTCPConnection -LocalPort 5173,5175 -State Listen -ErrorAction SilentlyContinue
  if ($Listeners) {
    $ListenerPids = $Listeners | Select-Object -ExpandProperty OwningProcess -Unique
    Stop-Process -Id $ListenerPids -Force -ErrorAction SilentlyContinue
  }
}

function Wait-Http([string]$Url, [int]$TimeoutSeconds = 90) {
  $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    try {
      $Response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 5
      if ($Response.StatusCode -ge 200 -and $Response.StatusCode -lt 500) {
        return
      }
    } catch {
      Start-Sleep -Milliseconds 700
    }
  } while ((Get-Date) -lt $Deadline)
  throw "Timed out waiting for local service: $Url"
}

function Ensure-FontStubs {
  $FontFiles = @(
    (Join-Path $MainRoot 'src\generated\fonts\harmony\sc-medium\result.css'),
    (Join-Path $MainRoot 'src\generated\fonts\harmony\sc-bold\result.css')
  )
  foreach ($FontFile in $FontFiles) {
    Ensure-Directory (Split-Path -Parent $FontFile)
    if (-not (Test-Path -LiteralPath $FontFile)) {
      Set-Content -LiteralPath $FontFile -Value '/* Local E2E font fallback: use system fonts. */' -Encoding UTF8
    }
  }
}

function Set-LocalEnvironment($Status) {
  $ApiUrl = [string]$Status.API_URL
  $AnonKey = [string]$Status.ANON_KEY
  $ServiceRoleKey = [string]$Status.SERVICE_ROLE_KEY
  $env:SUPABASE_URL = $ApiUrl
  $env:VITE_SUPABASE_URL = $ApiUrl
  $env:SUPABASE_PUBLISHABLE_KEY = $AnonKey
  $env:VITE_SUPABASE_PUBLISHABLE_KEY = $AnonKey
  $env:SUPABASE_SECRET_KEY = $ServiceRoleKey
  $env:VITE_APP_URL = 'http://localhost:5173'
  $env:VITE_SUMMER_LOTTERY_URL = 'http://localhost:5175'
  $env:LOTTERY_PROVIDER = 'main-site'
  $env:LOTTERY_CAMPAIGN_ID = 'community-lottery'
  $env:LOTTERY_SITE_URL = 'http://localhost:5175'
  $env:MAIN_SITE_URL = 'http://localhost:5173'
  $env:LOTTERY_SSO_AUDIENCE = 'open-lottery'
  $env:LOTTERY_CONTACT_FORMAT = 'text'
  $env:LOTTERY_NOTIFICATION_REQUIRED = 'true'
  $env:LOTTERY_NOTIFICATION_VALUE = 'demo-notifications'
  $env:LOTTERY_BACKEND_SECRET = $GatewaySecret
  $env:LOTTERY_CONTACT_ENCRYPTION_ACTIVE_KEY_ID = 'local-e2e'
  $env:LOTTERY_CONTACT_ENCRYPTION_KEYS_JSON = "{`"local-e2e`":`"$ContactEncryptionKey`"}"
  $env:APP_SESSION_SECRET = $MainSessionSecret
  $env:OAUTH_STATE_SECRET = $MainSessionSecret
  $env:AUTH_SECURITY_HASH_SECRET = $MainSessionSecret
  $env:MAIL_ABUSE_HASH_SECRET = $MainSessionSecret
  $env:APP_SESSION_COOKIE_NAME = 'eg_session'
  $env:APP_REFRESH_COOKIE_NAME = 'eg_refresh'
  $env:APP_SESSION_COMPAT_JWT_ENABLED = 'false'
  $env:AUTH_CAPTCHA_MODE = 'enforce'
  $env:AUTH_CAPTCHA_PROVIDER = 'turnstile'
  $env:AUTH_CAPTCHA_REQUIRED_ACTIONS = 'lottery_enter'
  $env:VITE_AUTH_CAPTCHA_MODE = 'enforce'
  $env:VITE_AUTH_CAPTCHA_PROVIDER = 'turnstile'
  $env:VITE_AUTH_CAPTCHA_REQUIRED_ACTIONS = 'lottery_enter'
  $env:VITE_AUTH_CAPTCHA_REGION_STRATEGY = 'pow'
  $env:AUTH_MAIL_ACTIONS_ENABLED = 'false'
  $env:VITE_AUTH_OAUTH_GITHUB_ENABLED = 'false'
  $env:VITE_AUTH_OAUTH_LINUXDO_ENABLED = 'false'
  $env:VITE_AUTH_OAUTH_QQ_ENABLED = 'false'
  $env:LOTTERY_SESSION_SECRET = $LotterySessionSecret
  $env:LOTTERY_SESSION_TTL_SECONDS = '604800'
  $env:LOTTERY_DRAW_SEED = $DrawSeed
}

function Seed-TestUser($Status) {
  $Headers = @{
    apikey = [string]$Status.SERVICE_ROLE_KEY
    Authorization = "Bearer $($Status.SERVICE_ROLE_KEY)"
    'Content-Type' = 'application/json'
  }
  $LocalUsers = @(
    @{
      email = $TestEmail
      password = $TestPassword
      email_confirm = $true
      user_metadata = @{ username = 'Demo Participant' }
    },
    @{
      email = $ContactOperatorEmail
      password = $ContactOperatorPassword
      email_confirm = $true
      user_metadata = @{ username = 'Demo Contact Operator' }
    }
  )
  foreach ($LocalUser in $LocalUsers) {
    $Body = $LocalUser | ConvertTo-Json -Depth 4
    try {
      Invoke-RestMethod -Method Post -Uri "$($Status.API_URL)/auth/v1/admin/users" -Headers $Headers -Body $Body | Out-Null
    } catch {
      if ($_.Exception.Response.StatusCode.value__ -ne 422) {
        throw
      }
    }
  }
  $Sql = @"
UPDATE public.profiles
SET role = 'super_admin'
WHERE email = '$TestEmail';

INSERT INTO public.summer_lottery_operator_grants (
  campaign_id,
  user_id,
  capability,
  granted_by
)
SELECT
  'community-lottery',
  operator.id,
  capability,
  grantor.id
FROM public.profiles AS operator
CROSS JOIN public.profiles AS grantor
CROSS JOIN (VALUES ('contact_read'), ('contact_purge')) AS capability_list(capability)
WHERE operator.email = '$ContactOperatorEmail'
  AND grantor.email = '$TestEmail'
ON CONFLICT (campaign_id, user_id, capability) DO NOTHING;
"@
  docker exec $DatabaseContainer psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c $Sql | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to grant the local test user super-admin operator access.'
  }
}

function Start-WebApps($Status) {
  Stop-WebApps
  Ensure-FontStubs
  Set-LocalEnvironment $Status
  $MainOut = Join-Path $RuntimeRoot 'main.out.log'
  $MainErr = Join-Path $RuntimeRoot 'main.err.log'
  $LotteryOut = Join-Path $RuntimeRoot 'lottery.out.log'
  $LotteryErr = Join-Path $RuntimeRoot 'lottery.err.log'
  $env:VITE_AUTH_CAPTCHA_MODE = 'off'
  $MainProcess = Start-Process -FilePath 'npm.cmd' -ArgumentList @('exec', 'vite', '--', '--port', '5173', '--strictPort') -WorkingDirectory $MainRoot -RedirectStandardOutput $MainOut -RedirectStandardError $MainErr -PassThru
  Set-Content -LiteralPath $MainPidPath -Value $MainProcess.Id -Encoding ascii
  Remove-Item Env:LOTTERY_DRAW_SEED -ErrorAction SilentlyContinue
  $env:VITE_AUTH_CAPTCHA_MODE = 'enforce'
  $LotteryProcess = Start-Process -FilePath 'npm.cmd' -ArgumentList @('exec', 'vite', '--', '--port', '5175', '--strictPort') -WorkingDirectory $LotteryRoot -RedirectStandardOutput $LotteryOut -RedirectStandardError $LotteryErr -PassThru
  Set-Content -LiteralPath $LotteryPidPath -Value $LotteryProcess.Id -Encoding ascii
  Wait-Http 'http://localhost:5173/'
  Wait-Http 'http://localhost:5175/'
}

function Invoke-MainOperatorAction($Status, [string]$Operation) {
  $LoginHeaders = @{
    apikey = [string]$Status.ANON_KEY
    'Content-Type' = 'application/json'
  }
  $LoginBody = @{
    email = $TestEmail
    password = $TestPassword
  } | ConvertTo-Json
  $Login = Invoke-RestMethod -Method Post -Uri "$($Status.API_URL)/auth/v1/token?grant_type=password" -Headers $LoginHeaders -Body $LoginBody
  if (-not $Login.access_token) {
    throw 'Could not obtain the local short-lived operator identity.'
  }
  $Headers = @{
    Authorization = "Bearer $($Login.access_token)"
    Origin = 'http://localhost:5173'
    'Content-Type' = 'application/json'
  }
  $Body = @{
    action = $Operation
    campaignId = 'community-lottery'
    confirmation = "$($Operation.ToUpperInvariant()) community-lottery"
  } | ConvertTo-Json
  Invoke-RestMethod -Method Post -Uri 'http://localhost:5173/api/admin-summer-lottery-operations' -Headers $Headers -Body $Body | Out-Null
}

function Prepare-Campaign($Status) {
  Invoke-MainOperatorAction $Status 'prepare'
}

function Start-LocalE2E {
  Ensure-Directory $RuntimeRoot
  Ensure-SupabaseCli
  if (-not (Test-Path -LiteralPath $LocalAuthBaseline)) {
    throw "Local auth baseline not found: $LocalAuthBaseline"
  }
  Copy-Item -LiteralPath $LocalAuthBaseline -Destination $RuntimeBaseline -Force
  try {
    Write-Step 'Start local Supabase'
    Invoke-Supabase @('start')
    Write-Step 'Reset local database and apply all migrations'
    Invoke-Supabase @('db', 'reset', '--yes')
  } finally {
    Remove-Item -LiteralPath $RuntimeBaseline -Force -ErrorAction SilentlyContinue
  }
  $Status = Get-SupabaseStatus
  Seed-TestUser $Status
  Write-Step 'Start main site and lottery site'
  Start-WebApps $Status
  Prepare-Campaign $Status
  @{
    apiUrl = $Status.API_URL
    anonKey = $Status.ANON_KEY
    serviceRoleKey = $Status.SERVICE_ROLE_KEY
    email = $TestEmail
    password = $TestPassword
    contactOperatorEmail = $ContactOperatorEmail
    contactOperatorPassword = $ContactOperatorPassword
    mainUrl = 'http://localhost:5173/'
    lotteryUrl = 'http://localhost:5175/'
  } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
  Start-Process 'http://localhost:5175/'
  Write-Host "`nLocal full-flow environment is ready." -ForegroundColor Green
  Write-Host "Lottery: http://localhost:5175/"
  Write-Host "Main:    http://localhost:5173/"
  Write-Host "Email:   $TestEmail"
  Write-Host "Password:$TestPassword"
  Write-Host "After entering, run npm run local:e2e:draw to close and draw immediately."
}

function Draw-LocalCampaign {
  Ensure-SupabaseCli
  $Status = Get-SupabaseStatus
  Set-LocalEnvironment $Status
  $Genesis = 1692803367
  $Round = [math]::Floor(([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $Genesis) / 3) - 2
  if ($Round -le 0) {
    throw 'Could not calculate a valid drand Quicknet round.'
  }
  $Sql = "UPDATE public.summer_lottery_campaigns SET closes_at = NOW() - INTERVAL '2 seconds', draws_at = NOW() - INTERVAL '1 second', public_randomness_round = $Round WHERE id = 'community-lottery';"
  docker exec $DatabaseContainer psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c $Sql | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to update the local campaign timeline.'
  }
  Invoke-MainOperatorAction $Status 'draw'
  Write-Host "Local draw completed with drand Quicknet round $Round. Refresh the results page to verify." -ForegroundColor Green
  Start-Process 'http://localhost:5175/#results'
}

function Stop-LocalE2E([switch]$KeepDatabase) {
  Stop-WebApps
  if (-not $KeepDatabase) {
    Ensure-SupabaseCli
    Invoke-Supabase @('stop', '--no-backup') -AllowFailure
  }
  Write-Host 'Local full-flow environment stopped.' -ForegroundColor Green
}

Ensure-Directory $RuntimeRoot
switch ($Action) {
  'Start' { Start-LocalE2E }
  'Draw' { Draw-LocalCampaign }
  'Reset' { Stop-LocalE2E; Start-LocalE2E }
  'Stop' { Stop-LocalE2E }
  'Status' {
    $Status = Get-SupabaseStatus
    Write-Host "Supabase: $($Status.API_URL)"
    Write-Host 'Main:     http://localhost:5173/'
    Write-Host 'Lottery:  http://localhost:5175/'
  }
}
