if(!$env:APPVEYOR_REPO_TAG) {
    return
}

Write-Output 'Generating release notes ...'
#region GitHub release notes
$previousRelease = (Invoke-RestMethod -Uri "https://api.github.com/repos/$env:APPVEYOR_REPO_NAME/releases/latest?access_token=$env:GITHUB_ACCESS_TOKEN" -Verbose)
Write-Host "Previous Release: $($previousRelease.name) ($($previousRelease.target_commitish))"
$compare = (Invoke-RestMethod -Uri "https://api.github.com/repos/$env:APPVEYOR_REPO_NAME/compare/$($previousRelease.target_commitish)...$env:APPVEYOR_REPO_COMMIT`?access_token=$env:GITHUB_ACCESS_TOKEN" -Verbose)
$releaseNotes = "## Release Notes`n#### Version [$env:APPVEYOR_REPO_TAG_NAME](https://github.com/$env:APPVEYOR_REPO_NAME/tree/$env:APPVEYOR_REPO_TAG_NAME)`n"

if($null -ne $compare.commits -and $compare.commits.Length -gt 0) {
    $releaseNotes += "`nCommit | Description`n--- | ---`n"
    $contributions = @{}
    $compare.commits | Sort-Object -Property @{Expression={$_.commit.author.date};} -Descending | ForEach-Object {
        $commitMessage = $_.commit.message.Replace("`r`n"," ").Replace("`n"," ");
        if ($commitMessage.ToLower().StartsWith('merge') -or
            $commitMessage.ToLower().StartsWith('merging') -or
            $commitMessage.ToLower().StartsWith('private')) {
                continue
        }
        $releaseNotes += "[``$($_.sha.Substring(0, 7))``](https://github.com/$env:APPVEYOR_REPO_NAME/tree/$($_.sha)) | $commitMessage`n"
        $contributions.$($_.author.login)++
    }
    $releaseNotes += "`nContributor | Commits`n--- | ---`n"
    $contributions.GetEnumerator() | Sort-Object -Property @{Expression={$_.Value}} -Descending | ForEach-Object {
        $releaseNotes += "@$($_.Name) | $($_.Value)`n"
    }
} else {
    $releaseNotes += "There are no new items for this release."
}

$env:GITHUB_RELEASE_NOTES = $releaseNotes
Write-Output $releaseNotes
#endregion
