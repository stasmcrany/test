Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$RunnerSha='4afc951e5c499118a90e1ccb2b841f3dbda89ab5ce725c03f68ebdc44d5c8f13'
$RunnerPattern='D4X_SCIENTIFIC_EXECUTE_V1*.ps1'

$secure=$null
$bstr=[IntPtr]::Zero
$plain=$null
try{
    $f=Get-ChildItem -LiteralPath "$HOME\Downloads" -Filter $RunnerPattern -File |
        Where-Object { (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant() -eq $RunnerSha } |
        Select-Object -First 1
    if(-not $f){throw 'D4X_SCIENTIFIC_EXECUTE_V1_FILE_NOT_FOUND_OR_HASH_MISMATCH'}

    $secure=Read-Host 'Paste OpenAI API key (input hidden)' -AsSecureString
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)

    if([string]::IsNullOrWhiteSpace($plain)){throw 'OPENAI_API_KEY_EMPTY'}
    if($plain -match "[`r`n`0]"){throw 'OPENAI_API_KEY_INVALID_CHARS'}
    if($plain.Length -lt 20){throw 'OPENAI_API_KEY_TOO_SHORT'}

    $env:OPENAI_API_KEY=$plain
    $env:D4X_SCIENTIFIC_RUNNER_SHA256=$RunnerSha

    Write-Output 'D4X_LOCAL_KEY_INJECTION=PASS_VALUE_NOT_PRINTED'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $f.FullName -PreflightOnly
    if($LASTEXITCODE -ne 0){throw "D4X_SCI_PREFLIGHT_EXIT::$LASTEXITCODE"}
}
finally{
    Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:D4X_SCIENTIFIC_RUNNER_SHA256 -ErrorAction SilentlyContinue
    if($bstr -ne [IntPtr]::Zero){
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $plain=$null
    $secure=$null
}
