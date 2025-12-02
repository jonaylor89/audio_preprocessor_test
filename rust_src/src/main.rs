mod ffmpeg;
mod processor;

use rayon::prelude::*;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};
use walkdir::WalkDir;

struct Config {
    input_dir: String,
    output_dir: String,
    sample_rate: u32,
    min_duration: f32,
    max_duration: f32,
    threads: usize,
    use_fork: bool,
}

struct Task {
    input_path: PathBuf,
    output_path: PathBuf,
}

fn is_audio_file(path: &Path) -> bool {
    let extensions = ["mp3", "wav", "flac", "m4a", "ogg", "aac", "wma", "opus"];
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| extensions.iter().any(|ext| e.eq_ignore_ascii_case(ext)))
        .unwrap_or(false)
}

fn collect_tasks(input_dir: &str, output_dir: &str) -> Vec<Task> {
    let input_path = Path::new(input_dir);
    let output_path = Path::new(output_dir);

    WalkDir::new(input_dir)
        .into_iter()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_file() && is_audio_file(e.path()))
        .map(|entry| {
            let rel_path = entry.path().strip_prefix(input_path).unwrap();
            let mut out_file = output_path.join(rel_path);
            out_file.set_extension("wav");

            Task {
                input_path: entry.path().to_path_buf(),
                output_path: out_file,
            }
        })
        .collect()
}

fn ensure_output_dirs(tasks: &[Task]) {
    let mut seen = std::collections::HashSet::new();
    for task in tasks {
        if let Some(parent) = task.output_path.parent() {
            if seen.insert(parent.to_path_buf()) {
                let _ = std::fs::create_dir_all(parent);
            }
        }
    }
}

fn process_file_fork(task: &Task, config: &processor::ProcessorConfig) -> Result<(), String> {
    let duration_output = Command::new("ffprobe")
        .args([
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "default=noprint_wrappers=1:nokey=1",
            task.input_path.to_str().unwrap(),
        ])
        .output()
        .map_err(|e| format!("ffprobe failed: {}", e))?;

    let duration: f32 = String::from_utf8_lossy(&duration_output.stdout)
        .trim()
        .parse()
        .unwrap_or(0.0);

    let filter = format!(
        "aresample={}:filter_size=64:cutoff=0.97",
        config.target_sample_rate
    );

    let mut cmd = Command::new("ffmpeg");
    cmd.args(["-y", "-v", "error", "-i", task.input_path.to_str().unwrap()]);

    if duration > config.max_duration_sec {
        cmd.args(["-t", &config.max_duration_sec.to_string()]);
    }

    if duration < config.min_duration_sec {
        let pad_filter = format!("{},apad=whole_dur={}", filter, config.min_duration_sec);
        cmd.args(["-af", &pad_filter]);
    } else {
        cmd.args(["-af", &filter]);
    }

    cmd.args([
        "-ar",
        &config.target_sample_rate.to_string(),
        "-c:a",
        "pcm_f32le",
        task.output_path.to_str().unwrap(),
    ]);

    let status = cmd.status().map_err(|e| format!("ffmpeg failed: {}", e))?;

    if status.success() {
        Ok(())
    } else {
        Err("ffmpeg returned non-zero".to_string())
    }
}

fn main() {
    let args = std::env::args().collect::<Vec<String>>();
    if args.len() < 3 {
        println!(
            "
            Usage: {} <input_dir> <output_dir> [options]

            Options:
              --sample-rate <rate>   Target sample rate (default: 16000)
              --min-duration <sec>   Minimum duration in seconds (default: 3.0)
              --max-duration <sec>   Maximum duration in seconds (default: 5.0)
              --threads <num>        Number of threads (default: auto)
        ",
            args[0]
        );
        return;
    }

    let mut config = Config {
        input_dir: args[1].clone(),
        output_dir: args[2].clone(),
        sample_rate: 16_000,
        min_duration: 3.0,
        max_duration: 5.0,
        threads: 0,
        use_fork: false,
    };

    let mut i = 3;
    while i < args.len() {
        if args[i].eq("--sample-rate") {
            config.sample_rate = args[i + 1]
                .parse()
                .expect("--sample-rate must be an integer");
            i += 1;
        } else if args[i].eq("--min-duration") {
            config.min_duration = args[i + 1].parse().expect("--min-duration must be a float");
            i += 1;
        } else if args[i].eq("--max-duration") {
            config.max_duration = args[i + 1].parse().expect("--max-duration must be a float");
            i += 1;
        } else if args[i].eq("--threads") {
            config.threads = args[i + 1].parse().expect("--threads must be an integer");
            i += 1;
        } else if args[i].eq("--use-fork") {
            config.use_fork = true;
        }

        i += 1;
    }

    println!("Audio Dataset Preprocessor (Rust)");
    println!("Input:  {}", &config.input_dir);
    println!("Output: {}", &config.output_dir);
    println!("Target sample rate: {} Hz", config.sample_rate);
    println!(
        "Duration range: {:.1}s - {:.1}s",
        config.min_duration, config.max_duration
    );
    println!(
        "Mode: {}",
        if config.use_fork {
            "fork (CLI)"
        } else {
            "bindings (native)"
        }
    );

    let processor_config = processor::ProcessorConfig {
        target_sample_rate: config.sample_rate,
        min_duration_sec: config.min_duration,
        max_duration_sec: config.max_duration,
    };

    let tasks = collect_tasks(&config.input_dir, &config.output_dir);
    println!("Found {} audio files", tasks.len());

    if tasks.is_empty() {
        println!("No audio files found.");
        return;
    }

    ensure_output_dirs(&tasks);

    let num_threads = if config.threads > 0 {
        config.threads
    } else {
        std::thread::available_parallelism()
            .map(|p| p.get())
            .unwrap_or(4)
    };

    println!("Processing with {} threads...", num_threads);

    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(num_threads)
        .build()
        .unwrap();

    let processed = AtomicUsize::new(0);
    let failed = AtomicUsize::new(0);

    pool.install(|| {
        tasks.par_iter().for_each(|task| {
            let result = if config.use_fork {
                process_file_fork(task, &processor_config)
            } else {
                processor::process_file(
                    task.input_path.to_str().unwrap(),
                    task.output_path.to_str().unwrap(),
                    &processor_config,
                )
            };

            match result {
                Ok(()) => {
                    processed.fetch_add(1, Ordering::Relaxed);
                    println!("Processed: {}", task.input_path.display());
                }
                Err(e) => {
                    failed.fetch_add(1, Ordering::Relaxed);
                    eprintln!("Failed: {} - {}", task.input_path.display(), e);
                }
            }
        });
    });

    println!(
        "Processing complete! {} succeeded, {} failed",
        processed.load(Ordering::Relaxed),
        failed.load(Ordering::Relaxed)
    );
}
