# BeatSaberStats
See stats about Beat Saber maps, all in one table! Produces a CSV of all difficulties of a map, including a maximum notes in any 10 seconds (NP10S) that can be a better indicator of peak difficulty than the average NPS.

## About the Data

* Duration is measured as the time between the first and last notes, so it is always ≤ the song duration.
  * Consequently, NPS is always ≥ the NPS reported in the game.
  * However, this avoids the NPS being diluted by long intros or outros, making it a more accurate indicator of difficulty.
* Custom levels are referenced in the player save file by `custom_level_<hash>`, where the hash is the SHA1 of info.dat and all beatmap files concatenated together in the order they appear in the level info file.
  * e.g.
    ```
    $ grep .dat info.dat
            "_beatmapFilename": "Normal.dat",
            "_beatmapFilename": "Hard.dat",
    $ cat info.dat Normal.dat Hard.dat | sha1sum
    0b0ad0f34b2d0687a9794bcf5019100fda06971e  -
    ```
* In a beatmap, the `_time` properties are measured in beats, so use BPM from info.dat to get real time.

## Contributing

There are some TODOs in the code if you want to add features. If you want to add something beyond the TODOs, open an issue for discussion.
