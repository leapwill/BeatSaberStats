<#
.PARAMETER SavePath
The path of PlayerData.dat
.PARAMETER GamePath
The path of the directory containing Beat Saber.exe
.PARAMETER PlayerNumber
The 0-indexed number of player data to use in PlayerData.dat
.PARAMETER Threads
The number of threads to use for processing levels. Defaults to the number of logical processors on the system but capped at 8 due to sharply diminishing returns.
#>

# TODO get compatibility down to Win10 default of PS5 and .NET Framework 4.0, blocker is System.Security.Cryptography.Primitives

[CmdletBinding()]
param(
    [string]
    $SavePath = '',
    [string]
    $GamePath = '',
    [int]
    $PlayerNumber = 0,
    [ValidateRange(1,8)]
    [AllowNull()]
    [int]
    $Threads
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

if ($Threads = $null) {
    if ($Env:OS -eq 'Windows_NT') {
        $Threads = [Math]::Min((Get-CIMInstance -Class CIM_Processor).NumberOfLogicalProcessors, 8)
    }
    else {
        (Get-Content /proc/cpuinfo | Select-String 'siblings' | Select-Object -First 1) -Match ': +([0-9]+)$' > $null
        $Threads = [Math]::Min([int]$Matches[1], 8)
    }
    $Threads = [Math]::Max($Threads, 1)
}

Add-Type -AssemblyName 'System.Security.Cryptography.Primitives'
Add-Type -AssemblyName 'System.Collections.Concurrent'
#endregion



#region constants
$CustomLevelsPath = Join-Path $LevelsPath 'CustomLevels'
$CustomLevelInfoFiles = Get-ChildItem $CustomLevelsPath -Recurse -Filter 'info.dat'
$LevelStats = New-Object 'System.Collections.Generic.List[object]' -ArgumentList $CustomLevelInfoFiles.Length
$IsVerbose = ($PSCmdlet.MyInvocation.BoundParameters['Verbose'] -ne $null -and $PSCmdlet.MyInvocation.BoundParameters['Verbose'].IsPresent -eq $true)
$IsDebug = ($PSCmdlet.MyInvocation.BoundParameters['Debug'] -ne $null -and $PSCmdlet.MyInvocation.BoundParameters['Debug'].IsPresent -eq $true)
#endregion
# TODO load vanilla levels data (what format?)
# TODO handle zipped CustomWIPLevels

$LevelInfoFilesQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[System.IO.FileInfo]' -ArgumentList (,[System.IO.FileInfo[]]$CustomLevelInfoFiles)
function ForEach-Thread {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true,Position=1)]
        [System.Collections.Concurrent.ConcurrentQueue[System.IO.FileInfo]]
        $Queue,
        [Parameter(Mandatory=$true,Position=2)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$LevelStats
    )

    #region constants but in the runspace
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
    #endregion

    #region functions to keep scopes small for memory
    # calculate hash to find level ID in save file
    function Load-HashedJson {
        [CmdletBinding()]
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

    function Process-SingleLevel {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true,Position=0)]
            [System.IO.FileInfo]
            $levelInfoFile,
            [Parameter(Mandatory=$true,Position=1)]
            [System.Diagnostics.Stopwatch]
            $Stopwatch,
            [Parameter(Mandatory=$true,Position=2)]
            [AllowEmptyCollection()]
            [System.Collections.Generic.List[object]]
            $LevelStats
        )
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
    #endregion

    $Stopwatch = New-Object System.Diagnostics.Stopwatch
    [System.IO.FileInfo]$CurrentFile = $null;
    while ($Queue.TryDequeue([ref]$CurrentFile)) {
        Process-SingleLevel $CurrentFile $Stopwatch $LevelStats -Verbose:($PSCmdlet.MyInvocation.BoundParameters['Verbose'].IsPresent -eq $true) -Debug:($PSCmdlet.MyInvocation.BoundParameters['Debug'].IsPresent -eq $true)
    }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, $Threads)
$pool.Open()
$threadHandles = @{}
Write-Debug "using $Threads threads"
for ($i = 0; $i -lt $Threads; $i++) {
    $poolShell = [PowerShell]::Create()
    $poolShell.RunspacePool = $pool
    $null = $poolShell.AddScript(${Function:ForEach-Thread}.ToString())
    $null = $poolShell.AddParameter('Queue', $LevelInfoFilesQueue)
    $null = $poolShell.AddParameter('LevelStats', $LevelStats)
    $threadHandles[$poolShell] = $poolShell.BeginInvoke()
}

foreach ($shell in $threadHandles.Keys) {
    [System.IAsyncResult]$handle = $threadHandles[$shell]
    $shell.EndInvoke($handle)
    $shell.Dispose()
}

#region output
if (Test-Path 'stats.csv') {
    Remove-Item 'stats.csv'
}
foreach ($lvl in $LevelStats) {
    Export-Csv -InputObject ([pscustomobject]$lvl) -Append -Path 'stats.csv'
}
#endregion
