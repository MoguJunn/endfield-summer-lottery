param(
  [string]$SupabaseCliPath = ''
)

$ErrorActionPreference = 'Stop'
$LotteryRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $LotteryRoot
$SupabaseExe = $SupabaseCliPath
if (-not $SupabaseExe) {
  $SupabaseExe = Join-Path $WorkspaceRoot '_tools\supabase-cli\supabase.exe'
}

if (-not (Test-Path -LiteralPath $SupabaseExe)) {
  throw 'Supabase CLI not found. Run npm run local:e2e once, or pass -SupabaseCliPath.'
}

$env:DO_NOT_TRACK = '1'
Push-Location $LotteryRoot
try {
  & $SupabaseExe test db
  if ($LASTEXITCODE -ne 0) {
    throw "Supabase database tests failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
