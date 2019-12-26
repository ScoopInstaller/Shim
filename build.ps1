Push-Location $psscriptroot

# Prepare
$build = "$PSScriptRoot\build"
$src = "$PSScriptRoot\src"
New-Item -ItemType Directory -Path $build -ErrorAction SilentlyContinue | Out-Null
Remove-Item "$build\*" -Recurse -Force | Out-Null

cmd.exe /c "call `"C:\Program Files (x86)\Microsoft Visual Studio\2017\Community\VC\Auxiliary\Build\vcvars64.bat`" && set > %temp%\vcvars.txt"

Get-Content "$env:temp\vcvars.txt" | Foreach-Object {
  if ($_ -match "^(.*?)=(.*)$") {
    Set-Content "env:\$($matches[1])" $matches[2]
  }
}

# Build
Write-Output 'Compiling shim.c ...'
& cmd /c cl.exe /O1 /Fe"$build\shim.exe" "$src\shim.c" '2>&1'

if($LastExitCode -ne 0) { $host.SetShouldExit($LastExitCode )  }

# Checksums
Write-Output 'Computing checksums ...'
Get-ChildItem "$build\*" -Include *.exe,*.dll -Recurse | ForEach-Object {
    $checksum = (Get-FileHash -Path $_.FullName -Algorithm SHA256).Hash.ToLower()
    "$checksum *$($_.Name)" | Tee-Object -FilePath "$build\$($_.Name).sha256" -Append
}

Pop-Location
