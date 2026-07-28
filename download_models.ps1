# Speecher installer helper: downloads models and optional CUDA runtime.
# Called from speecher.iss. All output is ASCII, English only.
param(
    [string]$DataDir = "$env:LOCALAPPDATA\Speecher\models",
    [switch]$Small,
    [switch]$Medium,
    [switch]$Large,
    [switch]$Llm,
    [switch]$Cuda
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Get-Catalog {
    $path = Join-Path $PSScriptRoot "models.json"
    if (-not (Test-Path $path)) { throw "models.json not found next to the script" }
    return Get-Content -Raw -Encoding UTF8 $path | ConvertFrom-Json
}

function Save-ModelFile($url, $target, $sha256) {
    $part = "$target.part"
    Write-Host "Downloading $(Split-Path $target -Leaf)"
    Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
    if ($sha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $part).Hash.ToLower()
        if ($actual -ne $sha256.ToLower()) {
            Remove-Item $part -Force
            throw "checksum mismatch for $target"
        }
    }
    Move-Item -Force $part $target
}

function Install-Model($catalog, $key, $kind) {
    $model = $catalog.$key
    if (-not $model) { throw "unknown model $key" }
    $subdir = if ($kind -eq "asr") { "asr" } else { "llm" }
    $dir = Join-Path (Join-Path $DataDir $subdir) $key
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($file in $model.files) {
        $target = Join-Path $dir $file.name
        if ((Test-Path $target) -and ((Get-Item $target).Length -eq $file.size)) {
            Write-Host "Already there: $($file.name)"
            continue
        }
        Save-ModelFile $file.url $target $file.sha256
    }
}

function Install-CudaRuntime {
    # CUDA DLLs live in PyPI wheels; a wheel is a zip archive.
    $target = Join-Path $DataDir "cuda\bin"
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    foreach ($package in @("nvidia-cublas-cu12", "nvidia-cudnn-cu12")) {
        Write-Host "Fetching $package"
        $meta = Invoke-RestMethod -Uri "https://pypi.org/pypi/$package/json" -UseBasicParsing
        $wheel = $meta.urls | Where-Object { $_.filename -like "*win_amd64.whl" } | Select-Object -First 1
        if (-not $wheel) { throw "no windows wheel for $package" }
        $zip = Join-Path $env:TEMP ($wheel.filename -replace "\.whl$", ".zip")
        Invoke-WebRequest -Uri $wheel.url -OutFile $zip -UseBasicParsing
        $unpack = Join-Path $env:TEMP ([System.IO.Path]::GetFileNameWithoutExtension($zip))
        if (Test-Path $unpack) { Remove-Item -Recurse -Force $unpack }
        Expand-Archive -Path $zip -DestinationPath $unpack -Force
        Get-ChildItem -Path $unpack -Recurse -Filter *.dll | ForEach-Object {
            Copy-Item -Force $_.FullName $target
        }
        Remove-Item -Force $zip
        Remove-Item -Recurse -Force $unpack
    }
    Write-Host "CUDA runtime installed to $target"
}

try {
    if ($Cuda) {
        Install-CudaRuntime
    } else {
        $catalog = Get-Catalog
        if ($Small)  { Install-Model $catalog "small" "asr" }
        if ($Medium) { Install-Model $catalog "medium" "asr" }
        if ($Large)  { Install-Model $catalog "large-v3" "asr" }
        if ($Llm)    { Install-Model $catalog "qwen3-4b" "llm" }
    }
    exit 0
} catch {
    Write-Host "FAILED: $_"
    exit 1
}
