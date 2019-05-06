Push-Location $psscriptroot

# Prepare
$build = "$PSScriptRoot\build"
$src = "$PSScriptRoot\src"
New-Item -ItemType Directory -Path $build -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$build\*" -Recurse -Force | Out-Null

# Build
Write-Output 'Compiling shim.cs ...'
& "$PSScriptRoot\packages\Microsoft.Net.Compilers\tools\csc.exe" /deterministic /platform:anycpu /nologo /optimize /target:exe /out:"$build\shim.exe" "$src\shim.cs"

# Checksums
Write-Output 'Computing checksums ...'
Get-ChildItem "$build\*" -Include *.exe,*.dll -Recurse | ForEach-Object {
    $checksum = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLower()
    "$checksum *$($_.Name)" | Tee-Object -FilePath "$build\$($_.Name).sha256" -Append
}

Pop-Location
