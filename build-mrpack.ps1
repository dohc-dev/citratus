# ============================================================================
# build-mrpack.ps1 - Script to generate client and server .mrpack archives
# ============================================================================
# This script reads the Modrinth modpack structure and creates two .mrpack
# files (client and server variants) with configurable exclusions.
#
# Requirements:
#   - PowerShell 5.0+
#   - 7z or tar with zip support
#   - build/modrinth.index.json
#   - build/overrides/ (shared configs)
#   - build/client/overrides/ and build/server/overrides/ (variant configs)
#   - build/mods/, build/resourcepacks/, build/shaderpacks/
#
# Configuration:
#   - build-mrpack.toml (optional) for exclude lists per variant
#
# Usage:
#   .\build-mrpack.ps1
# ============================================================================

param()

$ErrorActionPreference = "Stop"

# ============================================================================
# Configuration
# ============================================================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir = Join-Path $ScriptDir "build"
$ConfigFile = Join-Path $ScriptDir "build-mrpack.toml"
$BuildsOutputDir = Join-Path $ScriptDir "builds"
$ModrinthIndex = Join-Path $BuildDir "modrinth.index.json"
$TempBase = [System.IO.Path]::GetTempPath()

# ============================================================================
# Utility Functions
# ============================================================================

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

# ============================================================================
# Phase 0: Check Dependencies & Load Configuration
# ============================================================================

function Test-Dependencies {
    Write-Info "Checking dependencies..."
    
    # Check for 7z or tar
    $has7z = $null -ne (Get-Command 7z -ErrorAction SilentlyContinue)
    $hasTar = $null -ne (Get-Command tar -ErrorAction SilentlyContinue)
    
    if (-not $has7z -and -not $hasTar) {
        Write-Error "Neither '7z' nor 'tar' found. Please install one of these tools."
        exit 1
    }
    
    $zipTool = if ($has7z) { "7z" } else { "tar" }
    Write-Success "Using '$zipTool' for creating archives"
    
    return $zipTool
}

function Test-BuildStructure {
    Write-Info "Checking build structure..."
    
    if (-not (Test-Path $ModrinthIndex)) {
        Write-Error "Missing: $ModrinthIndex"
        exit 1
    }
    
    if (-not (Test-Path (Join-Path $BuildDir "overrides") -PathType Container)) {
        Write-Error "Missing: $(Join-Path $BuildDir 'overrides')"
        exit 1
    }
    
    Write-Success "Build structure is valid"
}

function Parse-TomlArray {
    param(
        [string]$ConfigFile,
        [string]$Section,
        [string]$Key
    )
    
    if (-not (Test-Path $ConfigFile)) {
        return @()
    }
    
    $lines = Get-Content $ConfigFile
    $inSection = $false
    $arrayContent = ""
    $inArray = $false
    
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        
        # Check if we found the section
        if ($trimmed -eq "[$Section]") {
            $inSection = $true
            continue
        }
        
        # If we're in the wrong section, skip
        if (-not $inSection) {
            continue
        }
        
        # If we hit another section, stop
        if ($inSection -and $trimmed.StartsWith("[") -and $trimmed -ne "[$Section]") {
            break
        }
        
        # Skip comments
        if ($trimmed.StartsWith("#")) {
            continue
        }
        
        # Check if this line has our key
        if ($trimmed.StartsWith("$Key =")) {
            $inArray = $true
            # Extract from this line to end of array
            $arrayContent = $trimmed.Substring("$Key =".Length).Trim()
            
            # If array is complete on one line, extract and return
            if ($arrayContent.EndsWith("]")) {
                $arrayContent = $arrayContent.Substring(1, $arrayContent.Length - 2)
                $items = [regex]::Matches($arrayContent, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
                return @($items)
            }
            
            # Otherwise continue collecting lines for multiline array
            $arrayContent = $arrayContent.Substring(1) # Remove opening [
            continue
        }
        
        # If we're collecting array lines
        if ($inArray) {
            $arrayContent += " " + $trimmed
            if ($trimmed.EndsWith("]")) {
                # Array is complete
                $arrayContent = $arrayContent.Substring(0, $arrayContent.Length - 1).TrimEnd() # Remove closing ]
                $items = [regex]::Matches($arrayContent, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
                return @($items)
            }
        }
    }
    
    return @()
}

function Load-Config {
    Write-Info "Loading configuration..."
    
    $script:ClientExclude = @()
    $script:ServerExclude = @()
    
    if (-not (Test-Path $ConfigFile)) {
        Write-Warning "Config file not found: $ConfigFile"
        Write-Info "Using default (no exclusions)"
        return
    }
    
    Write-Info "Parsing exclusion lists from $ConfigFile"
    
    # Parse arrays
    $script:ClientExclude = Parse-TomlArray $ConfigFile "client" "exclude"
    $script:ServerExclude = Parse-TomlArray $ConfigFile "server" "exclude"
    
    Write-Info "Client exclusions: $($script:ClientExclude.Count) items"
    Write-Info "Server exclusions: $($script:ServerExclude.Count) items"
}

# ============================================================================
# Phase 1: Initialize & Read Manifest
# ============================================================================

function Read-Manifest {
    Write-Info "Reading modrinth.index.json..."
    
    try {
        $manifest = Get-Content $ModrinthIndex | ConvertFrom-Json
        $script:ModpackName = $manifest.name
        $script:VersionId = $manifest.versionId
        
        Write-Success "Modpack: $($script:ModpackName)"
        Write-Success "Version: $($script:VersionId)"
    }
    catch {
        Write-Error "Failed to parse modrinth.index.json: $_"
        exit 1
    }
}

function Prompt-Customization {
    Write-Info "Customization prompts..."
    
    # Prompt for version ID
    $userVersion = Read-Host "Version ID [$($script:VersionId)]"
    if ($userVersion) {
        $script:VersionId = $userVersion
    }
    
    # Prompt for modpack name
    $userName = Read-Host "Modpack name [$($script:ModpackName)]"
    if ($userName) {
        $script:ModpackName = $userName
    }
    
    # Build output file names
    $script:ClientMrpack = "$($script:ModpackName)-$($script:VersionId)-client.mrpack"
    $script:ServerMrpack = "$($script:ModpackName)-$($script:VersionId)-server.mrpack"
    
    Write-Success "Output files:"
    Write-Success "  Client: $($script:ClientMrpack)"
    Write-Success "  Server: $($script:ServerMrpack)"
}

# ============================================================================
# Phase 2: Helper functions for file operations
# ============================================================================

function Copy-Overrides {
    param(
        [string]$SourceDir,
        [string]$DestDir,
        [string]$Variant
    )
    
    if (-not (Test-Path $SourceDir -PathType Container)) {
        Write-Warning "Source directory not found: $SourceDir (skipping)"
        return
    }
    
    Write-Info "Copying overrides to $Variant`: $SourceDir"
    
    # Ensure destination exists
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }
    
    # Use Copy-Item for PowerShell-native directory copy
    Get-ChildItem -Path $SourceDir -Force | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $DestDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Apply-Exclusions {
    param(
        [string]$WorkDir,
        [string]$Variant,
        [array]$ExcludeList
    )
    
    if ($ExcludeList.Count -eq 0) {
        return
    }
    
    Write-Info "Applying exclusions for $Variant ($($ExcludeList.Count) items)"
    
    foreach ($excludePattern in $ExcludeList) {
        $excludePattern = $excludePattern.Trim()
        
        if ([string]::IsNullOrEmpty($excludePattern)) {
            continue
        }
        
        # Convert forward slashes to backslashes for Windows paths
        $excludePattern = $excludePattern -replace '/', '\'
        
        # Find all matching items using Get-ChildItem recursively
        $matchedItems = @()
        
        if ($excludePattern -match '[\*\?]') {
            # Wildcard pattern - recursively search and filter by relative path
            $matchedItems = Get-ChildItem -Path "$WorkDir" -Recurse -Force -ErrorAction SilentlyContinue | 
                Where-Object {
                    $relativePath = $_.FullName -replace [regex]::Escape("$WorkDir\"), ""
                    $relativePath -like $excludePattern
                }
        }
        else {
            # Exact path match
            $fullPath = Join-Path $WorkDir $excludePattern
            if (Test-Path $fullPath) {
                $matchedItems = @(Get-Item -Path $fullPath -Force -ErrorAction SilentlyContinue)
            }
        }
        
        if ($matchedItems.Count -gt 0) {
            foreach ($item in $matchedItems) {
                Write-Info "  Excluding: $($item.FullName -replace [regex]::Escape($WorkDir), '' -replace '^\\', '')"
                Remove-Item -Recurse -Force $item.FullName -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Warning "  Exclude pattern matched nothing: $excludePattern"
        }
    }
}

function Copy-ContentDirs {
    param(
        [string]$WorkDir,
        [string]$Variant
    )
    
    $dirs = @("mods", "resourcepacks", "shaderpacks")
    
    foreach ($dir in $dirs) {
        $sourcePath = Join-Path $BuildDir $dir
        if (Test-Path $sourcePath -PathType Container) {
            Write-Info "Copying $dir/ to $Variant"
            $destPath = Join-Path $WorkDir $dir
            Copy-Item -Path $sourcePath -Destination $destPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Create-MrpackArchive {
    param(
        [string]$WorkDir,
        [string]$OutputFile,
        [string]$Variant
    )
    
    Write-Info "Creating $Variant .mrpack archive..."
    
    # Create proper .mrpack structure: modrinth.index.json at root, everything else in overrides/
    $mrpackDir = Join-Path $TempBase "mrpack_structure_$($Variant)_$(Get-Random)"
    New-Item -ItemType Directory -Path $mrpackDir | Out-Null
    
    try {
        # Copy modrinth.index.json to root of .mrpack
        Copy-Item $ModrinthIndex -Destination (Join-Path $mrpackDir "modrinth.index.json") -Force
        
        # Move everything from WorkDir into overrides/ subdirectory
        $overridesDir = Join-Path $mrpackDir "overrides"
        New-Item -ItemType Directory -Path $overridesDir | Out-Null
        
        Get-ChildItem -Path $WorkDir -Force | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination $overridesDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        # Create the .mrpack archive using 7z (faster compression)
        $outputPath = Join-Path $BuildsOutputDir $OutputFile
        $sevenZip = "7z"
        
        # Try to use 7z for compression
        try {
            & $sevenZip a -tzip -mx5 "$outputPath" "$mrpackDir\*" -r | Out-Null
        }
        catch {
            Write-Warning "7z not found, falling back to Compress-Archive"
            Compress-Archive -Path "$mrpackDir\*" -DestinationPath $outputPath -Force -CompressionLevel Optimal
        }
        
        if (Test-Path $outputPath) {
            $size = (Get-Item $outputPath).Length / 1MB
            Write-Success "$Variant archive created: $outputPath ($([Math]::Round($size, 2)) MB)"
            return $outputPath
        }
        else {
            Write-Error "Failed to create $Variant archive at $outputPath"
            return $null
        }
    }
    catch {
        Write-Error "Archive creation failed: $_"
        return $null
    }
    finally {
        # Cleanup structure directory
        if (Test-Path $mrpackDir) {
            Remove-Item -Recurse -Force $mrpackDir -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# Phase 3: Build Client & Server Variants
# ============================================================================

function Build-Variant {
    param(
        [string]$Variant,
        [string]$OutputFile,
        [array]$ExcludeList
    )
    
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Building $Variant variant" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    
    # Create temporary working directory
    $tempDir = Join-Path $TempBase "mrpack_${Variant}_$(Get-Random)"
    Write-Info "Using temporary directory: $tempDir"
    
    if (Test-Path $tempDir) {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    
    try {
        # Step 1: Copy shared overrides
        Copy-Overrides -SourceDir (Join-Path $BuildDir "overrides") -DestDir $tempDir -Variant $Variant
        
        # Step 2: Copy variant-specific overrides
        $variantDir = Join-Path $BuildDir $Variant "overrides"
        if (Test-Path $variantDir -PathType Container) {
            Write-Info "Applying $Variant-specific overrides from $variantDir"
            Copy-Overrides -SourceDir $variantDir -DestDir $tempDir -Variant $Variant
        }
        
        # Step 3: Copy content directories
        Copy-ContentDirs -WorkDir $tempDir -Variant $Variant
        
        # Step 4: Apply exclusions AFTER all content is copied
        Apply-Exclusions -WorkDir $tempDir -Variant $Variant -ExcludeList $ExcludeList
        
        # Step 5: Create the .mrpack archive
        Create-MrpackArchive -WorkDir $tempDir -OutputFile $OutputFile -Variant $Variant
        
        Write-Success "$Variant build complete"
    }
    finally {
        # Cleanup
        if (Test-Path $tempDir) {
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
        }
    }
}

# ============================================================================
# Phase 4: Main Execution
# ============================================================================

function Main {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║       Modrinth Modpack (.mrpack) Builder                   ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    
    # Phase 0: Check & Load
    Test-BuildStructure
    Load-Config
    
    # Phase 1: Initialize
    Read-Manifest
    Prompt-Customization
    
    # Create output directory
    if (-not (Test-Path $BuildsOutputDir)) {
        New-Item -ItemType Directory -Path $BuildsOutputDir | Out-Null
    }
    Write-Info "Output directory: $BuildsOutputDir"
    
    # Phase 2-3: Build variants
    Build-Variant -Variant "client" -OutputFile $script:ClientMrpack -ExcludeList $script:ClientExclude
    Build-Variant -Variant "server" -OutputFile $script:ServerMrpack -ExcludeList $script:ServerExclude
    
    # Summary
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║                    BUILD COMPLETE ✓                        ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host ""
    Write-Success "Archives created in: $BuildsOutputDir"
    Write-Success "  - $($script:ClientMrpack)"
    Write-Success "  - $($script:ServerMrpack)"
    Write-Host ""
}

# Run main function
Main
