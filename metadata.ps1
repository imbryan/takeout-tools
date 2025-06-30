param(
    [Parameter(Mandatory=$true)]
    [string]$TargetPath
)

$resolvedPath = Resolve-Path -Path $TargetPath

$mediaExtensions = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath "ext.txt")

$files = Get-ChildItem -Path $resolvedPath -Force -File

$doneDir = Join-Path -Path $resolvedPath -ChildPath 'done'
$failedDir = Join-Path -Path $resolvedPath -ChildPath 'failed'

# Step 1: Load all JSON files into a hashtable keyed by media filename
$jsonDataMap = @{}

foreach ($jsonFile in $files | Where-Object { $_.Extension.ToLower() -ieq '.json' }) {
    $jsonBase = $jsonFile.BaseName # File name without extension
    $suppPattern = '\.s[a-z\-]{0,22}$'
    $indexPattern = '\(\d+\)(?=\.|$)'
    $extPattern = '(?:' + (($mediaExtensions | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
    $malformedExtPattern = '\.(?!' + (($mediaExtensions | ForEach-Object { [regex]::Escape($_) }) -join '|') + '$)[a-z0-9]{0,5}$'

    # Extract index e.g. "(1)" if exists
    $jsonFileIndex = '' 
    if ($jsonBase -match $indexPattern) {
        $jsonFileIndex = $matches[0]
    }

    # Extract media extension if exists
    $expectedMediaExt = ''
    if ($jsonBase -match $extPattern) {
        $expectedMediaExt = $matches[0]
    }

    Write-Host "jsonBase $jsonBase"

    # Remove index, then ".supplemental-metadata", then malformed extensions, then media file extension
    $jsonBaseClean = $jsonBase -replace $indexPattern, '' -replace $suppPattern, '' -replace $malformedExtPattern, '' -replace $extPattern, ''

    # Look for this expected media file
    $match = $files | Where-Object {
        $mediaExtensions -contains $_.Extension.ToLower() -and
        $_.BaseName.StartsWith($jsonBaseClean) -and
        (
            ($jsonFileIndex -ne '' -and $_.BaseName.EndsWith($jsonFileIndex)) -or
            ($jsonFileIndex -eq '' -and $_.BaseName -notmatch $indexPattern)
        ) -and 
        (
            -not $expectedMediaExt -or
            $_.Extension.ToLower() -eq $expectedMediaExt.ToLower()
        )
    } | Sort-Object {
        # Prefer exact matches
        if ($_.BaseName -eq "$jsonBaseClean$jsonFileIndex") { 0 } else { 1 }
    } | Select-Object -First 1

    # Add to Data Map
    if ($match) {
        Write-Host "Matched JSON '$($jsonFile.Name)' to media '$($match.Name)'"

        $jsonDataMap[$match.Name] = @{
            Content = (Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json)
            Name = $jsonFile.Name
            Path = $jsonFile.FullName
            Used = $false
            Failed = $false
        }

        ##### Debug #####
        # Write-Host "BaseName $jsonBaseClean$jsonFileIndex Extension $expectedMediaExt"
        ##### End Debug #####
    } else {
        Write-Host "No media match for: $($jsonFile.Name)"

        ##### Debug #####
        Write-Host "Expected BaseName like $jsonBaseClean$jsonFileIndex"
        if ($expectedMediaExt) {
            Write-Host "Expected extension $expectedMediaExt"
        }
        ##### End Debug #####
    }
}

# Step 2: Process each media file
$mediaFiles = $files | Where-Object { $mediaExtensions -contains $_.Extension.ToLower() }
$total = $mediaFiles.Count
$index = 0
foreach ($mediaFile in $mediaFiles) {
    $index++
    Write-Host "[$index / $total] Processing: $($mediaFile.Name)"

    $jsonKey = $mediaFile.Name

    # Fallback for -edited variants
    if (-not $jsonDataMap.ContainsKey($jsonKey) -and $mediaFile.Name -like '*-edited*') {
        $jsonKey = $mediaFile.Name -replace '-edited', ''
        Write-Host "Attempting to use original JSON metadata for edited file: $($mediaFile.Name)"
    }

    # Fallback for asymmetric indexed variants
    if (-not $jsonDataMap.ContainsKey($jsonKey) -and $mediaFile.Name -match $indexPattern) {
        $jsonKey = $mediaFile.Name -replace $indexPattern, ''
        Write-Host "Attempting to use non-indexed JSON metadata for indexed file: $($mediaFile.Name)"
    }

    # Still no metadata
    if (-not $jsonDataMap.ContainsKey($jsonKey)) {
        Write-Host "No JSON metadata found for file: $($mediaFile.Name)"
        continue
    }

    $jsonContent = $jsonDataMap[$jsonKey].Content
    $args = @()

    # Date
    if ($jsonContent.photoTakenTime -and $jsonContent.photoTakenTime.timestamp) {
        $epoch = [int]$jsonContent.photoTakenTime.timestamp
        $dtUtc = [System.DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime
        $dateTaken = $dtUtc.ToString('yyyy:MM:dd HH:mm:ss')

        $args += "-DateTimeOriginal=$dateTaken"
        $args += "-CreateDate=$dateTaken"
        $args += "-ModifyDate=$dateTaken"

        if ($mediaFile.Extension.ToLower() -in @('.mp4', '.mov', '.3gp')) {
            $args += "-QuickTime:CreateDate=$dateTaken"
            $args += "-QuickTime:ModifyDate=$dateTaken"
            $args += "-TrackCreateDate=$dateTaken"
            $args += "-TrackModifyDate=$dateTaken"
            $args += "-MediaCreateDate=$dateTaken"
        }
    }

    # Description
    if ($jsonContent.description) {
        $desc = $jsonContent.description -replace '"', '\"'

        $args += "-Description=$desc"
        $args += "-XMP:Description=$desc"
        $args += "-QuickTime:Description=$desc"
        $args += "-Comment=$desc"
        $args += "-ImageDescription=$desc"
        $args += "-Caption-Abstract=$desc"
        $args += "-XPComment=$desc"
    }

    # GPS Coords
    if ($jsonContent.geoData) {
        $lat = $jsonContent.geoData.latitude
        $lng = $jsonContent.geoData.longitude
        if (($lat -ne $null) -and ($lng -ne $null)) {
            $latRef = if ($lat -ge 0) { 'N' } else { 'S' }
            $lngRef = if ($lng -ge 0) { 'E' } else { 'W' }

            $args += "-GPSLatitude=$lat"
            $args += "-GPSLongitude=$lng"
            $args += "-GPSLatitudeRef=$latRef"
            $args += "-GPSLongitudeRef=$lngRef"
        }
    }

    # Device Name
    if ($jsonContent.cameraMake -or $jsonContent.cameraModel) {
        $device = ''
        if ($jsonContent.cameraMake) { $device += $jsonContent.cameraMake }
        if ($jsonContent.cameraModel) { $device += ' ' + $jsonContent.cameraModel }
        $device = $device.Trim()
        if ($device -ne '') {
            $args += "-Make=$device"
            $args += "-Model=$device"
        }
    }

    # Exiftool
    if ($args.Count -gt 0) {
        $exiftoolArgs = $args + "-overwrite_original", $mediaFile.FullName

        Write-Host "Running exiftool with arguments:"
        Write-Host ($exiftoolArgs -join ' ')

        $exifResult = & exiftool @exiftoolArgs 2>&1

        ##### DEBUG #####
        Write-Host "Exiftool command args:"
        $exiftoolArgs | ForEach-Object { "'$_'" }
        ##### ENDDEBUG #####

        if ($LASTEXITCODE -eq 0) {
            # Flag JSON as used
            $jsonDataMap[$jsonKey].Used = $true

            # Move media to "/done"
            if (-not (Test-Path $doneDir)) {
                New-Item -ItemType Directory -Path $doneDir | Out-Null
            }
            $mediaDest = Join-Path -Path $doneDir -ChildPath $mediaFile.Name
            Move-Item -Path $mediaFile.FullName -Destination $mediaDest -Force
        } else {
            Write-Warning "Exiftool failed for $($mediaFile.Name): $exifResult"

            # Flag JSON as failed
            $jsonDataMap[$jsonKey].Failed = $true

            # Move media file to "/failed"
            if (-not (Test-Path $failedDir)) {
                New-Item -ItemType Directory -Path $failedDir | Out-Null
            }
            $mediaDest = Join-Path -Path $failedDir -ChildPath $mediaFile.Name
            Move-Item -Path $mediaFile.FullName -Destination $mediaDest -Force
        }
    }
    else {
        Write-Host "No metadata to write for file: $($mediaFile.Name)"
    }
}

# Step 3: Delete or move JSON files after processing
foreach ($entry in $jsonDataMap.GetEnumerator()) {
    if ($entry.Value.Failed) {
        $jsonDest = Join-Path -Path $failedDir -ChildPath $entry.Value.Name
        Move-Item -Path $entry.Value.Path -Destination $jsonDest -Force
    }
    elseif ($entry.Value.Used -and (Test-Path $entry.Value.Path)) {
        Remove-Item $entry.Value.Path -Force
        Write-Host "Deleted: $($entry.Value.Name)"
    }
}