use clap::{App, Arg};
use hex::ToHex;
use log::{debug, warn};
use serde::Serialize;
use serde_json::Value;
use sha1::{Digest, Sha1};
use std::collections::HashMap;
use std::collections::HashSet;
use std::collections::VecDeque;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::thread;

fn main() {
    let args = App::new("Beat Saber Stats")
        .arg(
            Arg::with_name("save-path")
                .long("save-path")
                .takes_value(true),
        )
        .arg(
            Arg::with_name("game-path")
                .long("game-path")
                .takes_value(true),
        )
        .arg(
            Arg::with_name("player-number")
                .long("player-number")
                .takes_value(true),
        )
        .arg(Arg::with_name("threads").long("threads").takes_value(true))
        // TODO OutFile and OutMode
        .arg(Arg::with_name("v").short("v"))
        .get_matches();

    env_logger::builder()
        .filter_level(if args.is_present("v") {
            log::LevelFilter::Debug
        } else {
            log::LevelFilter::Error
        })
        .init();
    //region parameter setup
    let mut save_path: String = args.value_of("save-path").unwrap_or("").to_owned();
    if save_path.is_empty() {
        if cfg!(windows) {
            save_path = std::env::var("LOCALAPPDATA").unwrap()
                + "\\..\\LocalLow\\Hyperbolic Magnetism\\Beat Saber\\PlayerData.dat";
        } else {
            save_path = "~/.steam/steam/steamapps/compatdata/620980/pfx/PlayerData.dat".to_owned();
        };
    }
    let save_path: &Path = Path::new(&save_path);
    if !save_path.is_file() {
        panic!("Save file not found at {}", save_path.display());
    }
    let mut game_path: String = args.value_of("game-path").unwrap_or("").to_owned();
    if game_path.is_empty() {
        if cfg!(windows) {
            game_path = std::env::var("ProgramFiles(x86)").unwrap()
                + "\\Steam\\steamapps\\common\\Beat Saber\\";
        } else {
            game_path = "~/.steam/steam/steamapps/common/Beat Saber/".to_owned();
        };
    }
    let game_path: &Path = Path::new(&game_path);
    if !game_path.is_dir() {
        panic!("Game install not found at {}", game_path.display());
    }
    let levels_path = game_path.to_path_buf().join("Beat Saber_Data");
    if !levels_path.is_dir() {
        panic!("Game levels not found at {}", levels_path.display())
    }
    let mut threads = args
        .value_of("threads")
        .unwrap_or("0")
        .parse::<usize>()
        .unwrap();
    if threads == 0 {
        threads = num_cpus::get();
    }

    let player_data;
    {
        let _player_data: Value =
            serde_json::from_reader(fs::File::open(save_path).unwrap()).unwrap();
        let _player_data = _player_data["localPlayers"].as_array().unwrap();
        let player_number = args
            .value_of("player-number")
            .unwrap_or("0")
            .parse::<usize>()
            .unwrap();
        if _player_data.len() < player_number + 1 {
            panic!("No players found in the save file");
        }
        player_data = _player_data[player_number].as_object().unwrap().clone();
    }
    //endregion

    //region constants
    let custom_levels_path = levels_path.join("CustomLevels");
    let custom_level_info_files = custom_levels_path
        .read_dir()
        .unwrap()
        .filter_map(|entry| {
            let entry = entry.unwrap();
            if entry.file_type().unwrap().is_dir() && entry.path().join("info.dat").is_file() {
                Some(entry.path().join("info.dat"))
            } else {
                None
            }
        })
        .collect::<VecDeque<_>>();
    let level_stats = Vec::<LevelInfo>::with_capacity(custom_level_info_files.len());
    //endregion

    let level_info_queue = Arc::new(Mutex::new(custom_level_info_files));
    let level_stats_arc = Arc::new(Mutex::new(level_stats));
    let mut thread_handles = Vec::<std::thread::JoinHandle<()>>::with_capacity(threads);
    let player_data = Arc::new(player_data);
    debug!("using threads={}", threads);
    for _i in 0..threads {
        let queue = Arc::clone(&level_info_queue);
        let mut stats = Arc::clone(&level_stats_arc);
        let player_data = Arc::clone(&player_data);
        thread_handles.push(thread::spawn(move || {
            // TODO Builder for thread name
            process_queue(queue, &mut stats, player_data);
        }));
    }
    for t in thread_handles {
        t.join().unwrap();
    }
    // TODO Stopwatch on "Progress:"
    debug!("Progress: finished CustomLevels, starting OST");

    // OST
    let mut level_stats = level_stats_arc.lock().unwrap();
    let processed_level_ids = level_stats
        .iter()
        .map(|li| &li.id)
        .collect::<HashSet<&String>>();
    let unprocessed_scores_by_level_it = player_data["levelsStatsData"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|score| {
            !processed_level_ids.contains(&score["levelId"].as_str().unwrap().to_string())
        });
    let mut unprocessed_scores_by_level =
        HashMap::<String, Vec<&Value>>::with_capacity(unprocessed_scores_by_level_it.size_hint().0);
    for score in unprocessed_scores_by_level_it {
        unprocessed_scores_by_level
            .entry(score["levelId"].as_str().unwrap().to_owned())
            .or_insert_with(|| Vec::<&Value>::with_capacity(1))
            .push(score);
    }
    debug!("Progress: finished OST prep");
    let ost_path = Path::new("ost.csv");
    if ost_path.exists() {
        let mut rdr = csv::Reader::from_path(ost_path).unwrap();
        for result in rdr.records() {
            let record = result.unwrap();
            let level_id = record[46].to_string();
            let scores = unprocessed_scores_by_level.get_mut(&level_id).unwrap();
            let mut diffs = HashMap::new();
            debug!(
                "OST level id={} found num_scores={}",
                level_id,
                scores.len()
            );
            for score in scores
                .iter()
                .filter(|s| s["beatmapCharacteristicName"].as_str().unwrap() == "Standard")
            {
                let diff_idx = score["difficulty"].as_u64().unwrap() as usize;
                let record_idx_diff_offset = 8 * diff_idx + 5;
                let ld = LevelDifficulty {
                    valid: score["validScore"].as_bool().unwrap(),
                    plays: score["playCount"].as_u64().unwrap() as u32,
                    rank: SCORE_RANK_MAP[score["maxRank"].as_u64().unwrap() as usize].to_owned(),
                    combo: if score["fullCombo"].as_bool().unwrap() {
                        "FC".to_owned()
                    } else {
                        score["maxCombo"].as_u64().unwrap().to_string()
                    },
                    score: score["highScore"].as_u64().unwrap() as u32,
                    np10s: Option::None,
                    nps: Some(record[record_idx_diff_offset + 7].parse().unwrap()),
                    notes: Some(record[record_idx_diff_offset + 8].parse().unwrap()),
                };
                debug!(
                    "got OST score for difficulty={}",
                    DIFFICULTY_NAME_MAP[diff_idx]
                );
                diffs.insert(DIFFICULTY_NAME_MAP[diff_idx].to_owned(), ld);
            }
            let chars = HashMap::from([(
                "Standard".to_owned(),
                LevelCharacteristic {
                    difficulties: diffs,
                },
            )]);
            let li = LevelInfo {
                song: record[0].to_string(),
                artist: record[1].to_string(),
                mapper: record[2].to_string(),
                bpm: record[3].parse().unwrap(),
                environment: record[4].to_string(),
                duration: {
                    let mut min_sec_it = record[5].split(':');
                    min_sec_it.next().unwrap().parse::<f64>().unwrap() * 60.0
                        + min_sec_it.next().unwrap().parse::<f64>().unwrap()
                },
                characteristics: chars,
                id: level_id.clone(),
            };
            scores.retain(|s| s["beatmapCharacteristicName"].as_str().unwrap() != "Standard");
            if !scores.is_empty() {
                unprocessed_scores_by_level.remove(&level_id);
            }
            level_stats.push(li);
        }
    } else {
        warn!("No ost.csv found, OST level info will be scores only");
    }
    debug!("Progress: finished OST, starting orphans");

    // get score info for levels not already processed (DLC or deleted custom levels)
    for id_scores in unprocessed_scores_by_level {
        let level_id = id_scores.0;
        let mut chars = HashMap::<String, LevelCharacteristic>::new();
        for score in id_scores.1 {
            let diff_name =
                DIFFICULTY_NAME_MAP[score["difficulty"].as_u64().unwrap() as usize].to_owned();
            let char_name = score["beatmapCharacteristicName"].as_str().unwrap();
            let ld = LevelDifficulty {
                valid: score["validScore"].as_bool().unwrap(),
                plays: score["playCount"].as_u64().unwrap() as u32,
                rank: SCORE_RANK_MAP[score["maxRank"].as_u64().unwrap() as usize].to_owned(),
                combo: if score["fullCombo"].as_bool().unwrap() {
                    "FC".to_owned()
                } else {
                    score["maxCombo"].as_u64().unwrap().to_string()
                },
                score: score["highScore"].as_u64().unwrap() as u32,
                np10s: Option::None,
                nps: Option::None,
                notes: Option::None,
            };
            chars
                .entry(char_name.to_owned())
                .or_insert_with(|| LevelCharacteristic {
                    difficulties: HashMap::<String, LevelDifficulty>::new(),
                })
                .difficulties
                .insert(diff_name, ld);
        }
        let li = LevelInfo {
            song: "".to_owned(),
            artist: "".to_owned(),
            mapper: "".to_owned(),
            bpm: 0.0,
            environment: "".to_owned(),
            duration: 0.0,
            characteristics: chars,
            id: level_id.clone(),
        };
        level_stats.push(li);
    }

    // TODO output enhancements
    //region output
    debug!("Progress: finished orphans, starting output");
    let out_file = Path::new("stats.csv");
    if out_file.exists() {
        fs::remove_file(out_file).unwrap();
    }
    let mut wtr = csv::Writer::from_path(out_file).unwrap();
    wtr.write_record(&[
        "Song",
        "Artist",
        "Mapper",
        "BPM",
        "Environment",
        "~Duration",
        "Characteristic",
        "Difficulty",
        "Notes",
        "~NPS",
        "NP10S",
        "Score",
        "Combo",
        "Rank",
        "Plays",
        "Valid",
        "ID",
    ])
    .unwrap();
    for l in level_stats.iter() {
        for c in &l.characteristics {
            for d in &c.1.difficulties {
                wtr.write_record([
                    &l.song,
                    &l.artist,
                    &l.mapper,
                    &l.bpm.to_string(),
                    &l.environment,
                    &format!(
                        "{:02}:{:02}",
                        (l.duration / 60.0).floor(),
                        (l.duration % 60.0).floor()
                    ),
                    c.0,
                    d.0,
                    &{
                        if let Some(notes) = &d.1.notes {
                            notes.to_string()
                        } else {
                            "".to_owned()
                        }
                    },
                    &{
                        if let Some(nps) = &d.1.nps {
                            nps.to_string()
                        } else {
                            "".to_owned()
                        }
                    },
                    &{
                        if let Some(np10s) = &d.1.np10s {
                            np10s.to_string()
                        } else {
                            "".to_owned()
                        }
                    },
                    &d.1.score.to_string(),
                    &d.1.combo,
                    &d.1.rank,
                    &d.1.plays.to_string(),
                    &d.1.valid.to_string(),
                    &l.id,
                ])
                .unwrap();
            }
        }
    }
    wtr.flush().unwrap();
    //endregion
}

const DIFFICULTY_NAME_MAP: [&str; 5] = ["Easy", "Normal", "Hard", "Expert", "Expert+"];
const SCORE_RANK_MAP: [&str; 8] = ["E", "D", "C", "B", "A", "S", "SS", "SSS"];

fn process_queue(
    queue: Arc<Mutex<VecDeque<PathBuf>>>,
    level_stats: &mut Arc<Mutex<Vec<LevelInfo>>>,
    player_data: Arc<serde_json::Map<String, Value>>,
) {
    loop {
        let current_file;
        {
            let mut locked_queue = queue.lock().unwrap();
            current_file = locked_queue.pop_front();
        }
        match current_file {
            Some(cf) => process_single_song(cf, level_stats, &player_data),
            None => return,
        }
    }
}

fn process_single_song(
    level_info_file: PathBuf,
    level_stats: &mut Arc<Mutex<Vec<LevelInfo>>>,
    player_data: &Arc<serde_json::Map<String, Value>>,
) {
    debug!("processing song_info={}", level_info_file.display());
    let mut hasher = Sha1::new();
    let level_info_src = load_and_hash_json(&mut hasher, &level_info_file);
    let mut level_info = LevelInfo {
        song: level_info_src["_songName"].as_str().unwrap().to_owned(),
        artist: level_info_src["_songAuthorName"]
            .as_str()
            .unwrap()
            .to_owned(),
        mapper: level_info_src["_levelAuthorName"]
            .as_str()
            .unwrap()
            .to_owned(),
        bpm: level_info_src["_beatsPerMinute"].as_f64().unwrap(),
        environment: level_info_src["_environmentName"]
            .as_str()
            .unwrap()
            .to_owned(),
        duration: 0.0,
        characteristics: HashMap::new(),
        id: "".to_owned(),
    };
    let ten_seconds_in_beats = level_info.bpm / 6.0;
    let characteristics = level_info_src["_difficultyBeatmapSets"].as_array().unwrap();
    // for each characteristic (e.g. standard, one-hand, 90deg, lawless, etc.)
    for characteristic_beatmap_set in characteristics {
        let difficulties = characteristic_beatmap_set["_difficultyBeatmaps"]
            .as_array()
            .unwrap();
        // for each difficulty level on the characteristic
        for difficulty_info in difficulties {
            debug!(
                "Processing song_info={} char={} diff={}",
                level_info_file.display(),
                characteristic_beatmap_set["_beatmapCharacteristicName"]
                    .as_str()
                    .unwrap(),
                DIFFICULTY_NAME_MAP
                    [(difficulty_info["_difficultyRank"].as_u64().unwrap() / 2) as usize]
            );
            let difficulty_file = load_and_hash_json(
                &mut hasher,
                &level_info_file
                    .parent()
                    .unwrap()
                    .join(difficulty_info["_beatmapFilename"].as_str().unwrap()),
            );
            let mut difficulty_ver_str = difficulty_file["version"]
                .as_str()
                .unwrap_or("2.0.0")
                .chars();
            let beatmap_notes: Vec<Note>;
            match difficulty_ver_str.next().unwrap() {
                '3' => {
                    // TODO safety if these properties don't exist, this could almost certainly be rewritten better
                    let color_notes = difficulty_file["colorNotes"].as_array().unwrap();
                    let bomb_notes = difficulty_file["bombNotes"].as_array().unwrap();
                    let burst_notes = difficulty_file["burstSliders"].as_array().unwrap();
                    let slider_notes = difficulty_file["sliders"].as_array().unwrap();
                    let mut all_notes: Vec<Note> = Vec::with_capacity(
                        color_notes.len()
                            + bomb_notes.len()
                            + burst_notes.len()
                            + 2 * slider_notes.len(),
                    );

                    all_notes.extend(color_notes.iter().map(|n| Note {
                        beat: n["b"].as_f64().unwrap(),
                    }));
                    all_notes.extend(bomb_notes.iter().map(|n| Note {
                        beat: n["b"].as_f64().unwrap(),
                    }));
                    all_notes.extend(burst_notes.iter().map(|n| Note {
                        beat: n["b"].as_f64().unwrap(),
                    }));
                    all_notes.extend(slider_notes.iter().flat_map(|n| {
                        vec![
                            Note {
                                beat: n["b"].as_f64().unwrap(),
                            },
                            Note {
                                beat: n["tb"].as_f64().unwrap(),
                            },
                        ]
                    }));
                    all_notes.sort_by(|a, b| a.beat.partial_cmp(&b.beat).unwrap());
                    beatmap_notes = all_notes;
                }
                '2' => match difficulty_ver_str.nth(1).unwrap() {
                    '6' => {
                        let color_notes = difficulty_file["_notes"].as_array().unwrap();
                        let slider_notes = difficulty_file["_sliders"].as_array().unwrap();
                        let mut all_notes =
                            Vec::with_capacity(color_notes.len() + 2 * slider_notes.len());
                        all_notes.extend(color_notes.iter().map(|n| Note {
                            beat: n["b"].as_f64().unwrap(),
                        }));
                        all_notes.extend(slider_notes.iter().flat_map(|n| {
                            vec![
                                Note {
                                    beat: n["b"].as_f64().unwrap(),
                                },
                                Note {
                                    beat: n["tb"].as_f64().unwrap(),
                                },
                            ]
                        }));
                        all_notes.sort_by(|a, b| a.beat.partial_cmp(&b.beat).unwrap());
                        beatmap_notes = all_notes;
                    }
                    _ => {
                        beatmap_notes = difficulty_file["_notes"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .map(|n| Note {
                                beat: n["_time"].as_f64().unwrap(),
                            })
                            .collect();
                    }
                },
                _ => panic!("Unrecognized difficulty file schema version"),
            }
            let mut ld = LevelDifficulty {
                valid: false,
                plays: 0,
                rank: "".to_owned(),
                combo: "".to_owned(),
                score: 0,
                np10s: Option::None,
                nps: Option::None,
                notes: Option::None,
            };
            if !beatmap_notes.is_empty() {
                let first_note_time = beatmap_notes[0].beat;
                let last_note_time = beatmap_notes.last().unwrap().beat;
                let notes_duration_seconds =
                    (last_note_time - first_note_time) / level_info.bpm * 60.0;
                level_info.duration = level_info.duration.max(notes_duration_seconds);
                ld.nps = Some(beatmap_notes.len() as f64 / notes_duration_seconds);
                ld.notes = Some(beatmap_notes.len() as u32);

                // highest 10-second NPS
                {
                    let mut highest_so_far = 0.0;
                    let mut start_idx = 0;
                    let mut end_idx = 0;
                    while end_idx < beatmap_notes.len() - 1 {
                        let limit = beatmap_notes[start_idx].beat + ten_seconds_in_beats;
                        while end_idx <= beatmap_notes.len() - 2
                            && beatmap_notes[end_idx + 1].beat <= limit
                        {
                            end_idx += 1;
                        }
                        let notes_nps = (end_idx - start_idx + 1) as f64;
                        if notes_nps > highest_so_far {
                            highest_so_far = notes_nps;
                        }
                        start_idx += 1;
                    }
                    ld.np10s = Some((highest_so_far * 10.0).round() / 100.0);
                }
            }
            let characteristic_name = characteristic_beatmap_set["_beatmapCharacteristicName"]
                .as_str()
                .unwrap();
            if !level_info.characteristics.contains_key(characteristic_name) {
                // TODO change to or_insert_with
                level_info.characteristics.insert(
                    characteristic_name.to_owned(),
                    LevelCharacteristic {
                        difficulties: HashMap::new(),
                    },
                );
            }
            let difficulty_name = DIFFICULTY_NAME_MAP
                [(difficulty_info["_difficultyRank"].as_u64().unwrap() / 2) as usize];
            let old_diff = level_info
                .characteristics
                .get_mut(characteristic_name)
                .unwrap()
                .difficulties
                .insert(difficulty_name.to_owned(), ld);
            assert!(old_diff.is_none());
        }
    }
    level_info.id = "custom_level_".to_owned() + &(hasher.finalize().encode_hex_upper::<String>());
    let all_level_scores = player_data["levelsStatsData"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|l| l["levelId"].as_str().unwrap() == level_info.id);
    for score in all_level_scores {
        let characteristic_name = score["beatmapCharacteristicName"].as_str().unwrap();
        let difficulty_name = DIFFICULTY_NAME_MAP[score["difficulty"].as_u64().unwrap() as usize];
        if !level_info.characteristics.contains_key(characteristic_name) {
            debug!(
                "Skipping score processing for id={} char={} diff={}",
                level_info.id, characteristic_name, difficulty_name
            );
            continue;
        }
        let ld = level_info
            .characteristics
            .get_mut(characteristic_name)
            .unwrap()
            .difficulties
            .get_mut(difficulty_name);
        let mut ld = ld.unwrap();
        ld.valid = score["validScore"].as_bool().unwrap();
        ld.plays = score["playCount"].as_u64().unwrap() as u32;
        ld.rank = SCORE_RANK_MAP[score["maxRank"].as_u64().unwrap() as usize].to_owned();
        ld.combo = if score["fullCombo"].as_bool().unwrap() {
            "FC".to_owned()
        } else {
            score["maxCombo"].as_u64().unwrap().to_string()
        };
        ld.score = score["highScore"].as_u64().unwrap() as u32;
    }

    level_stats.lock().unwrap().push(level_info);
}

fn load_and_hash_json(hasher: &mut Sha1, path: &Path) -> Value {
    let mut bytes = Vec::new();
    let mut f = fs::File::open(path).unwrap();
    f.read_to_end(&mut bytes).unwrap();
    hasher.update(&bytes);
    serde_json::from_slice(&bytes[..]).unwrap()
}

#[derive(Serialize)]
struct LevelInfo {
    song: String,
    artist: String,
    mapper: String,
    bpm: f64,
    environment: String,
    duration: f64, // seconds
    characteristics: HashMap<String, LevelCharacteristic>,
    id: String,
}

#[derive(Serialize)]
struct LevelCharacteristic {
    difficulties: HashMap<String, LevelDifficulty>,
}

#[derive(Serialize)]
struct LevelDifficulty {
    valid: bool,
    plays: u32,
    rank: String,
    combo: String,
    score: u32,
    np10s: Option<f64>,
    nps: Option<f64>,
    notes: Option<u32>,
}

struct Note {
    beat: f64,
}
