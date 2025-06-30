param(
    [Parameter(Mandatory=$true)]
    [string]$TargetPath
)

$resolvedPath = Resolve-Path -Path $TargetPath

$mediaExtensions = Get-Content -Path (Join-Path -Path $PSScriptRoot -ChildPath "ext.txt")

$files = Get-ChildItem -Path $resolvedPath -Force -File

foreach ($file in $files | Where-Object { $mediaExtensions -contains $_.Extension.ToLower() }) {
    $trueExt = & exiftool -s -s -s -FileTypeExtension $file.FullName

    if (-not ($trueExt -ieq $file.Extension.TrimStart('.'))) {
        # Extract index patterns like "file(1).png"
        $indexPattern = '\(\d+\)$'
        $mediaFileIndex = ''
        if ($file.BaseName -match $indexPattern) {
            $mediaFileIndex = $matches[0]
        }
        $mediaBaseNameClean = $file.BaseName -replace $indexPattern, ''

        # Preserve fake extension like "file_PNG.jpg"
        $oldExtClean = "_" + $file.Extension.TrimStart('.')

        # Assemble new name
        $newName = "$mediaBaseNameClean$oldExtClean$mediaFileIndex.$trueExt"
        $newPath = Join-Path -Path $file.DirectoryName -ChildPath $newName

        # Rename if target doesn't exist
        if (-not (Test-Path $newPath)) {
            Rename-Item -Path $file.FullName -NewName $newName
            Write-Host "Renamed: $($file.Name) -> $newName"

            # Match JSON
            $jsonMatch = $files | Where-Object {
                $_.BaseName -like "$mediaBaseNameClean*" -and
                (
                    ($mediaFileIndex -ne '' -and $_.BaseName.EndsWith($mediaFileIndex)) -or
                    ($mediaFileIndex -eq '' -and $_.BaseName -notmatch $indexPattern)
                )
            } | Sort-Object {
                # Prefer match with extension and index
                if ($_.BaseName -like "$mediaBaseNameClean$($file.Extension)*$mediaFileIndex") { 0 } else { 1 }
            } | Select-Object -First 1

            # Rename JSON
            $oldExtEscaped = [regex]::Escape($file.Extension)
            if ($jsonMatch -and ($jsonMatch.BaseName -match $oldExtEscaped)) {
                $newJsonBaseName = $jsonMatch.BaseName -replace $oldExtEscaped, "$oldExtClean.$trueExt"
                $newJsonName = "$newJsonBaseName$($jsonMatch.Extension)"
                $newJsonPath = Join-Path -Path $jsonMatch.DirectoryName -ChildPath $newJsonName

                if (-not (Test-Path $newJsonPath)) {
                    Rename-Item -Path $jsonMatch.FullName -NewName $newJsonName
                    Write-Host "Renamed JSON: $($jsonMatch.Name) -> $newJsonName"
                } else {
                    Write-Warning "Skipped JSON rename: $($jsonMatch.Name) (target already exists)"
                }
            }
        } else {
            Write-Warning "Skipped: $($file.Name) (target already exists)"
        }
    } else {
        Write-Warning "Skipped: $($file.Name) (genuine $($file.Extension.TrimStart('.')) file)"
    }
}