<#
.PARAMETER SavePath
The path of PlayerData.dat
.PARAMETER GamePath
The path of the directory containing Beat Saber.exe
.PARAMETER PlayerNumber
The 0-indexed number of player data to use in PlayerData.dat
#>

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

#(Get-CIMInstance -Class 'CIM_Processor').NumberOfLogicalProcessors

$DifficultyRankMap = @{
    1 = 'Y';
    3 = 'N';
    5 = 'H';
    7 = 'E';
    9 = 'E+'
}
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
Add-Type -AssemblyName 'System.Security.Cryptography.Primitives'
foreach ($levelInfoFile in $CustomLevelInfoFiles) {
    $levelInfoSrc = ConvertFrom-Json (Get-Content $levelInfoFile.FullName -Raw)
    $levelInfo = @{
        'Song' = $levelInfoSrc._songName;
        'Artist' = $levelInfoSrc._songAuthorName;
        'Mapper' = $levelInfoSrc._levelAuthorName;
        'BPM' = $levelInfoSrc._beatsPerMinute;
        'Envrionment' = $levelInfoSrc._environmentName;
    }
    <# setup object to be the same every level
    foreach ($prefix in $DifficultyRankMap.Values) {
        $levelInfo["$prefix Valid"] = $levelInfo["$prefix Plays"] = $levelInfo["$prefix Rank"] = $levelInfo["$prefix Combo"] = $levelInfo["$prefix Score"] = $levelInfo["$prefix NP10S"] = $levelInfo["$prefix ~Duration"] = $levelInfo["$prefix ~NPS"] = $levelInfo["$prefix Notes"] = ''
    }#>

    $bytesToHash = New-Object 'System.Collections.Generic.List[byte]'
    # TODO use C# HashAlgorithm#TransformBlock to read files in chunks for less memory?
    $bytesToHash.AddRange([byte[]](Get-Content $levelInfoFile.FullName -AsByteStream 3>$null))

    # TODO one-hand/90/360/lightshow _difficultyBeatmapSets
    $standardMaps = ($levelInfoSrc._difficultyBeatmapSets | Where-Object { $_._beatmapCharacteristicName -eq 'Standard' })._difficultyBeatmaps
    foreach ($difficultyInfo in $standardMaps) {
        $prefix = $DifficultyRankMap[$difficultyInfo._difficultyRank]
        $bytesToHash.AddRange([byte[]](Get-Content (Join-Path $levelInfoFile.DirectoryName $difficultyInfo._beatmapFilename) -AsByteStream 3>$null))

        # read beatmap and calc stats
        $beatmapNotes = (Get-Content (Join-Path $levelInfoFile.DirectoryName $difficultyInfo._beatmapFilename) -Raw | ConvertFrom-Json)._notes
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

    # calculate hash to find level ID in save file
    [System.Security.Cryptography.HashAlgorithm]$hash = [System.Security.Cryptography.SHA1]::Create()
    $hash.ComputeHash($bytesToHash) >$null
    $hashStr = [System.BitConverter]::ToString($hash.Hash) -Replace '-',''
    $levelId = "custom_level_$hashStr"
    $levelInfo['ID'] = $levelId
    $scores = $PlayerData.levelsStatsData | Where-Object {$_.levelId -iLike $levelId -and $_.beatmapCharacteristicName -eq 'Standard'}
    foreach ($score in $scores) {
        $prefix = $DifficultyRankMap[$score.difficulty]
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

    $LevelStats.Add($levelInfo)
    Write-Host "processed $levelId"
}

Export-Csv $LevelStats -Path 'stats.csv'
