<#
.PARAMETER SavePath
The path of PlayerData.dat
.PARAMETER GamePath
The path of the directory containing Beat Saber.exe
.PARAMETER PlayerNumber
The 0-indexed number of player data to use in PlayerData.dat
#>

#Requires -Version 5

[CmdletBinding()]
param(
    [string]
    $SavePath = '',
    [string]
    $GamePath = '',
    [int]
    $PlayerNumber = 0
)

Set-StrictMode -Version Latest

#region parameter setup
$IsWin = $IsWindows -or $Env:OS -Match 'Windows'

if ($SavePath -eq '') {
    if ($IsWin) {
        $SavePath = "$Env:LOCALAPPDATA\..\LocalLow\Hyperbolic Magnetism\Beat Saber\PlayerData.dat"
    }
    else {
        $SavePath = '~/.steam/steam/steamapps/compatdata/620980/pfx/PlayerData.dat'
    }
}
if (-not (Test-Path $SavePath -PathType Leaf)) {
    Write-Error "Save file not found at $SavePath"
    exit -1
}

if ($GamePath -eq '') {
    if ($IsWin) {
        $GamePath = "${Env:ProgramFiles(x86)}\Steam\steamapps\common\Beat Saber\"
    }
    else {
        $GamePath = '~/.steam/steam/steamapps/common/Beat Saber/'
    }
}
if (-not (Test-Path $GamePath -PathType Container)) {
    Write-Error "Game install not found at $GamePath"
    exit -2
}
$LevelsPath = Join-Path $GamePath 'Beat Saber_Data'
if (-not (Test-Path $LevelsPath -PathType Container)) {
    Write-Error "Game levels not found at $LevelsPath"
    exit -3
}
$PlayerData = (Get-Content $SavePath | ConvertFrom-Json).LocalPlayers
if (-not ($PlayerData.Length -ge $PlayerNumber + 1)) {
    Write-Error 'No players found in the save file'
    exit -3
}
$PlayerData = $PlayerData[$PlayerNumber]
#endregion

#region functions to keep scopes small for memory
Add-Type -AssemblyName 'System.Security.Cryptography.Primitives'
# calculate hash to find level ID in save file
function Load-HashedJson {
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [System.Security.Cryptography.SHA1]
        $Hasher,
        [Parameter(Mandatory=$true, Position=1)]
        [string]
        $Path,
        [Parameter(Position=2)]
        [switch]
        $IsFinal
    )
    $fileRaw = Get-Content $Path -Raw
    $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($fileRaw)
    if ($IsFinal) {
        $Hasher.TransformFinalBlock($fileBytes, 0, $fileBytes.Length) >$null
    }
    else {
        $Hasher.TransformBlock($fileBytes, 0, $fileBytes.Length, $null, 0) >$null
    }
    return ConvertFrom-Json $fileRaw
}
#endregion

# TODO threading, probably C# for PS5.0 compat, with a semaphore
#(Get-CIMInstance -Class 'CIM_Processor').NumberOfLogicalProcessors

$DifficultyRankMap = @(
    'e',
    'N',
    'H',
    'E',
    'E+'
)
$ScoreRankMap = @(
    'E',
    'D',
    'C',
    'B',
    'A',
    'S',
    'SS',
    'SSS'
)

# TODO load vanilla levels data (what format?)
# TODO handle zipped CustomWIPLevels
$CustomLevelsPath = Join-Path $LevelsPath 'CustomLevels'
$CustomLevelInfoFiles = Get-ChildItem $CustomLevelsPath -Recurse -Filter 'info.dat'
$LevelStats = New-Object 'System.Collections.Generic.List[object]' -ArgumentList $CustomLevelInfoFiles.Length
$Stopwatch = New-Object System.Diagnostics.Stopwatch
foreach ($levelInfoFile in $CustomLevelInfoFiles) {
    Write-Verbose "processing $($levelInfoFile.Directory.Name)"
    $Stopwatch.Restart()

    $hasher = [System.Security.Cryptography.SHA1]::Create()

    $levelInfoSrc = Load-HashedJson $hasher $levelInfoFile.FullName

    $levelInfo = [ordered]@{
        'Song' = $levelInfoSrc._songName;
        'Artist' = $levelInfoSrc._songAuthorName;
        'Mapper' = $levelInfoSrc._levelAuthorName;
        'BPM' = $levelInfoSrc._beatsPerMinute;
        'Envrionment' = $levelInfoSrc._environmentName;
    }
    # setup object to be the same every level
    foreach ($prefix in $DifficultyRankMap) {
        $levelInfo["$prefix Valid"] = $levelInfo["$prefix Plays"] = $levelInfo["$prefix Rank"] = $levelInfo["$prefix Combo"] = $levelInfo["$prefix Score"] = $levelInfo["$prefix NP10S"] = $levelInfo["$prefix ~Duration"] = $levelInfo["$prefix ~NPS"] = $levelInfo["$prefix Notes"] = ''
    }

    # TODO one-hand/90/360/lightshow _difficultyBeatmapSets
    $standardMaps = ($levelInfoSrc._difficultyBeatmapSets | Where-Object { $_._beatmapCharacteristicName -eq 'Standard' })
    if ($standardMaps -eq $null -or $standardMaps.Length -eq 0) {
        Write-Information "No Standard beatmaps found, skipping $($levelInfoFile.Directory.Name)"
        continue
    }
    else {
        $standardMaps = $standardMaps._difficultyBeatmaps
    }
    Write-Debug "info done at `t$($Stopwatch.ElapsedMilliseconds)"
    foreach ($difficultyInfo in $standardMaps) {
        $prefix = $DifficultyRankMap[[Math]::Floor($difficultyInfo._difficultyRank / 2)]

        # read beatmap and calc stats
        $beatmapNotes = (Load-HashedJson $hasher (Join-Path $levelInfoFile.DirectoryName $difficultyInfo._beatmapFilename) $($difficultyInfo -eq $standardMaps[$standardMaps.Length - 1]))._notes
        $levelInfo["$prefix Notes"] = $beatmapNotes.Length
        # TODO for real NPS, song length comes from reading _songFilename. need ffmpeg?
        $firstNoteTime = $beatmapNotes[0]._time
        $lastNoteTime = $beatmapNotes[$beatmapNotes.Length - 1]._time
        $notesDuration = $lastNoteTime - $firstNoteTime
        $levelInfo["$prefix ~NPS"] = [Math]::Round($beatmapNotes.Length / $notesDuration, 2)
        $levelInfo["$prefix ~Duration"] = [string][Math]::Floor($notesDuration / 60) + ':' + [Math]::Floor($notesDuration % 60)

        # highest 10-second NPS
        # TODO use 2 indexes to look at original array instead of a new one?
        [double]$highestSoFar = 0
        $notes = New-Object 'System.Collections.Generic.List[float]'
        foreach ($note in $beatmapNotes) {
            $notes.Add($note._time)
            $notes.RemoveAll({param($t) $t -lt $note._time - 10}) >$null
            $notesNps = $notes.Count
            if ($notesNps -gt $highestSoFar) {
                $highestSoFar = $notesNps
            }
        }
        $levelInfo["$prefix NP10S"] = [Math]::Round($highestSoFar / 10, 2)

        

    }
    Write-Debug "difficulties done at $($Stopwatch.ElapsedMilliseconds)"

    # read save file for scores and stuff
    $hashStr = [System.BitConverter]::ToString($hasher.Hash) -Replace '-',''
    $levelId = "custom_level_$hashStr"
    $levelInfo['ID'] = $levelId
    $scores = $PlayerData.levelsStatsData | Where-Object {$_.levelId -iLike $levelId -and $_.beatmapCharacteristicName -eq 'Standard'}
    foreach ($score in $scores) {
        $prefix = $DifficultyRankMap[[Math]::Floor($score.difficulty / 2)]
        $levelInfo["$prefix Score"] = $score.highScore
        if ($score.fullCombo) {
            $levelInfo["$prefix Combo"] = 'FC'
        }
        else {
            $levelInfo["$prefix Combo"] = $score.maxCombo
        }
        $levelInfo["$prefix Rank"] = $ScoreRankMap[$score.maxRank]
        $levelInfo["$prefix Plays"] = $score.playCount
        $levelInfo["$prefix Valid"] = $score.validScore
    }
    Write-Debug "scores done at `t$($Stopwatch.ElapsedMilliseconds)"

    $LevelStats.Add($levelInfo)
    Write-Verbose "processed $levelId"
}

# TODO use -Append to avoid storing all in memory until the end?
Remove-Item 'stats.csv'
foreach ($lvl in $LevelStats) {
    Export-Csv -InputObject ([pscustomobject]$lvl) -Append -Path 'stats.csv'
}
