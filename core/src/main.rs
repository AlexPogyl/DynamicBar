//! dsh-core — ядро DynamicBar на Rust.
//!
//! Собирает снимок состояния DeepSeek Harness: токены за сегодня, баланс и
//! активность. Это прямая замена сборщику на Node: тот же JSON, но без
//! запуска интерпретатора.
//!
//! ```text
//! dsh-core --json                     # снимок в stdout
//! dsh-core --out ~/dsh.json           # снимок в файл, атомарно
//! dsh-core --no-balance               # без запросов в сеть
//! dsh-core --dsh-home /path/to/.dsh   # другой каталог данных
//! ```

mod agent;
mod frames;
mod net;

use std::fs;
use std::io::Write;
use std::path::PathBuf;

struct Args {
    json: bool,
    out: Option<PathBuf>,
    dsh_home: PathBuf,
    no_balance: bool,
}

fn parse_args() -> Args {
    let mut args = Args {
        json: false,
        out: None,
        dsh_home: PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/".into())).join(".dsh"),
        no_balance: false,
    };
    let mut iter = std::env::args().skip(1);
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--json" => args.json = true,
            "--no-balance" => args.no_balance = true,
            "--out" => {
                if let Some(value) = iter.next() {
                    args.out = Some(PathBuf::from(value));
                }
            }
            "--dsh-home" => {
                if let Some(value) = iter.next() {
                    args.dsh_home = PathBuf::from(value);
                }
            }
            "--version" => {
                println!("dsh-core {}", env!("CARGO_PKG_VERSION"));
                std::process::exit(0);
            }
            "--help" | "-h" => {
                println!("dsh-core --json | --out FILE [--dsh-home DIR] [--no-balance]");
                std::process::exit(0);
            }
            _ => {}
        }
    }
    args
}

fn main() {
    let args = parse_args();
    let snapshot = agent::build(&args.dsh_home, args.no_balance);

    let to_stdout = args.json || args.out.is_none();
    if to_stdout {
        println!("{}", snapshot);
        return;
    }

    let path = args.out.expect("путь к файлу задан");
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    // Пишем через временный файл и переименовываем: читатель никогда не
    // увидит половину JSON.
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    let written = fs::File::create(&tmp).and_then(|mut file| {
        serde_json::to_writer_pretty(&mut file, &snapshot)?;
        file.write_all(b"\n")?;
        Ok(())
    });
    match written {
        Ok(()) => {
            if let Err(error) = fs::rename(&tmp, &path) {
                eprintln!("не удалось записать {}: {error}", path.display());
                std::process::exit(1);
            }
        }
        Err(error) => {
            eprintln!("не удалось записать {}: {error}", path.display());
            std::process::exit(1);
        }
    }
}
