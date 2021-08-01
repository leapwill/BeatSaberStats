<#
.PARAMETER SavePath
The path of PlayerData.dat
.PARAMETER GamePath
The path of the directory containing Beat Saber.exe
.PARAMETER PlayerNumber
The 0-indexed number of player data to use in PlayerData.dat
#>

# TODO get down to 5, blocker is System.Security.Cryptography.Primitives
#Requires -Version 6

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
$IsWin = $Env:OS -Match 'Windows'

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
    exit -4
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

# TODO threading, probably C# for PS5.0 compat. with a semaphore? free mem check (0.5GB per thread)? currently ~1.5s and 100-600MB per song
#(Get-CIMInstance -Class CIM_Processor).NumberOfLogicalProcessors

$DifficultyRankMap = @(
    'Y',
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
# for each directory with info.dat (song)
foreach ($levelInfoFile in $CustomLevelInfoFiles) {
    Write-Verbose "processing $($levelInfoFile.Directory.Name)"
    $Stopwatch.Restart()

    $hasher = [System.Security.Cryptography.SHA1]::Create()

    $levelInfoSrc = Load-HashedJson $hasher $levelInfoFile.FullName

    # TODO custom dependencies (e.g. Chroma): $difficultyInfo._requirements and $levelInfoSrc._suggestions
    $levelInfo = [ordered]@{
        'Song' = $levelInfoSrc._songName;
        'Artist' = $levelInfoSrc._songAuthorName;
        'Mapper' = $levelInfoSrc._levelAuthorName;
        'BPM' = $levelInfoSrc._beatsPerMinute;
        'Environment' = $levelInfoSrc._environmentName;
        '~Duration' = [double]0;
    }
    # setup object to be the same every level
    foreach ($prefix in $DifficultyRankMap) {
        $levelInfo["$prefix Valid"] = $levelInfo["$prefix Plays"] = $levelInfo["$prefix Rank"] = $levelInfo["$prefix Combo"] = $levelInfo["$prefix Score"] = $levelInfo["$prefix NP10S"] = $levelInfo["$prefix ~NPS"] = $levelInfo["$prefix Notes"] = ''
    }
    Write-Debug "info done at `t$($Stopwatch.ElapsedMilliseconds)"

    # for each characteristic (e.g. standard, one-hand, 90deg, lawless, etc.)
    for ($characteristicIdx = 0; $characteristicIdx -lt $levelInfoSrc._difficultyBeatmapSets.Length; $characteristicIdx++) {
        $characteristicBeatmapSet = $levelInfoSrc._difficultyBeatmapSets[$characteristicIdx]
        # for each difficulty level on the characteristic
        for ($difficultyIdx = 0; $difficultyIdx -lt $characteristicBeatmapSet._difficultyBeatmaps.Length; $difficultyIdx++) {
            $difficultyInfo = $characteristicBeatmapSet._difficultyBeatmaps[$difficultyIdx]
            $isFinalHashedFile = ($difficultyIdx -eq $characteristicBeatmapSet._difficultyBeatmaps.Length - 1) -and ($characteristicIdx -eq $levelInfoSrc._difficultyBeatmapSets.Length - 1)
            $beatmapNotes = (Load-HashedJson $hasher (Join-Path $levelInfoFile.DirectoryName $difficultyInfo._beatmapFilename) $isFinalHashedFile)._notes
            # TODO one-hand/90/360/lightshow _difficultyBeatmapSets
            if ($characteristicBeatmapSet._beatmapCharacteristicName -eq 'Standard' -or $levelInfoSrc._difficultyBeatmapSets.Length -eq 1) {
                $prefix = $DifficultyRankMap[[Math]::Floor($difficultyInfo._difficultyRank / 2)]

                # read beatmap and calc stats
                $levelInfo["$prefix Notes"] = $beatmapNotes.Length
                # TODO for real NPS, song length comes from reading _songFilename. need ffmpeg?
                # note._time is floating-point beats
                $firstNoteTime = $beatmapNotes[0]._time
                $lastNoteTime = $beatmapNotes[$beatmapNotes.Length - 1]._time
                $notesDurationSeconds = ($lastNoteTime - $firstNoteTime) / $levelInfo['BPM'] * 60
                $levelInfo["$prefix ~NPS"] = [Math]::Round($beatmapNotes.Length / $notesDurationSeconds, 2)
                $levelInfo['~Duration'] = [Math]::Max($levelInfo['~Duration'], $notesDurationSeconds)

                # highest 10-second NPS
                # TODO use 2 indexes to look at original array instead of a new one?
                [double]$highestSoFar = 0
                $notes = New-Object 'System.Collections.Generic.List[double]'
                [double]$tenSecondsInBeats = $levelInfo['BPM'] / 6
                foreach ($note in $beatmapNotes) {
                    $notes.Add($note._time)
                    $notes.RemoveAll({param($t) $t -lt $note._time - $tenSecondsInBeats}) >$null
                    $notesNps = $notes.Count
                    if ($notesNps -gt $highestSoFar) {
                        $highestSoFar = $notesNps
                    }
                }
                $levelInfo["$prefix NP10S"] = [Math]::Round($highestSoFar / 10, 2)


            }
        }
    }
    Write-Debug "difficulties done at $($Stopwatch.ElapsedMilliseconds)"
    # format song duration as longest of all difficulties
    $levelInfo['~Duration'] = [string][Math]::Floor($levelInfo['~Duration'] / 60) + ':' + [Math]::Floor($levelInfo['~Duration'] % 60)

    # read save file for scores and stuff
    $hashStr = [System.BitConverter]::ToString($hasher.Hash) -Replace '-',''
    $levelId = "custom_level_$hashStr"
    $levelInfo['ID'] = $levelId
    # sort because something put lowercase hashes in my save file (SongCore uses uppercase)
    # TODO sort by valid, then score
    $scores = $PlayerData.levelsStatsData | Where-Object {$_.levelId -iLike $levelId -and $_.beatmapCharacteristicName -eq 'Standard'} | Sort-Object -Property levelId -CaseSensitive
    foreach ($score in $scores) {
        $prefix = $DifficultyRankMap[[Math]::Floor($score.difficulty)]
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

#region output
# TODO use -Append to avoid storing all in memory until the end?
Remove-Item 'stats.csv'
foreach ($lvl in $LevelStats) {
    Export-Csv -InputObject ([pscustomobject]$lvl) -Append -Path 'stats.csv'
}
#endregion
