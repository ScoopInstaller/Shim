#Requires -Version 7

Push-Location $PSScriptRoot

New-Item -ItemType Directory -Force -Path "$PSScriptRoot\dist" | Out-Null
Remove-Item "$PSScriptRoot\dist\*" -Recurse -Force

Write-Host 'Compiling...' -ForegroundColor DarkCyan

dotnet build --configuration Release
Copy-Item -Path "$PSScriptRoot\src\bin\Release\net45\shim.exe" -Destination "$PSScriptRoot\dist" -Force

Write-Host 'Computing checksums...' -ForegroundColor DarkCyan

Get-ChildItem "$PSScriptRoot\dist\*" -Include *.exe | ForEach-Object {
    "$((Get-FileHash -Path $_ -Algorithm SHA256).Hash.ToLower()) *$($_.Name)" | Out-File "$PSScriptRoot\dist\checksum.sha256" -Append -Encoding utf8
    "$((Get-FileHash -Path $_ -Algorithm SHA512).Hash.ToLower()) *$($_.Name)" | Out-File "$PSScriptRoot\dist\checksum.sha512" -Append -Encoding utf8
}

Write-Host 'Packaging...' -ForegroundColor DarkCyan

$version = ([xml](Get-Content "$PSScriptRoot\src\shim.csproj")).Project.PropertyGroup.Version

"$version" | Out-File "$PSScriptRoot\dist\version.txt" -Encoding utf8

Compress-Archive -Path "$PSScriptRoot\dist\*" -DestinationPath "$PSScriptRoot\dist\shim-$version.zip"
"$((Get-FileHash -Path "$PSScriptRoot\dist\shim-$version.zip" -Algorithm SHA256).Hash.ToLower()) *$("shim-$version.zip")" | Out-File "$PSScriptRoot\dist\shim-$version.zip.sha256" -Append -Encoding utf8

Pop-Location
