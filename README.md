# BeatSaberStats
See stats about Beat Saber maps, all in one table! Produces a CSV of all difficulties of a map, including a maximum notes in any 10 seconds (NP10S) that can be a better indicator of peak difficulty than the average NPS.

## Running the Script
The script currently requires one of:
* [PowerShell 6+](https://microsoft.com/PowerShell)
* OR Windows PowerShell 5 with [.NET Framework 4.6+](https://dotnet.microsoft.com/download/dotnet-framework)
  * You can check `$PSVersionTable.CLRVersion`

Assume 0.5-1GB of peak memory usage per thread. Adjust the `-Threads` parameter if you would like, though it caps out at 8.

You may have to run the below command to allow scripts to run:
```powershell
PS> Set-ExecutionPolicy RemoteSigned
```


## About the Data

* OST data was gathered manually and is loaded from `ost.csv` on each run.
  * `~NP10S` is left `null`. I think `~NPS + 1` is a decent estimate based on the custom levels I have.
* Duration is measured as the time between the first and last notes, so it is always ≤ the song duration.
  * Consequently, NPS is always ≥ the NPS reported in the game.
  * However, this avoids the NPS being diluted by long intros or outros, making it a more accurate indicator of difficulty.
* Custom levels are referenced in the player save file by `custom_level_<hash>`, where the hash is the SHA1 of info.dat and all beatmap files concatenated together in the order they appear in the level info file.
  * e.g.
    ```bash
    $ grep .dat info.dat
            "_beatmapFilename": "Normal.dat",
            "_beatmapFilename": "Hard.dat",
    $ cat info.dat Normal.dat Hard.dat | sha1sum
    0b0ad0f34b2d0687a9794bcf5019100fda06971e  -
    ```
  * This is the same method that [SongCore](https://github.com/Kylemc1413/SongCore) uses.
* In a beatmap, the `_time` properties are measured in beats, so use `BPM` from `info.dat` to get real time.

## Contributing

There are some TODOs in the code if you want to add features. If you want to add something beyond the TODOs, open an issue for discussion. You could also contribute to `ost.csv`, or parsing the OST levels programmatically.
