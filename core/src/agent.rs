//! Снимок состояния агента: токены за сегодня, баланс и активность.
//!
//! Формат совпадает с `scripts/agent/dsh-collector.mjs` и описан в README.
//! Это ядро специально не знает ничего про интерфейс: оно только читает логи
//! и отдаёт JSON.

use chrono::{Local, TimeZone};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::frames;
use crate::net;

const COLLECTOR_VERSION: &str = "2.0.0-rust";

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn start_of_today_ms() -> i64 {
    let now = Local::now();
    let start = now.date_naive().and_hms_opt(0, 0, 0).unwrap();
    Local
        .from_local_datetime(&start)
        .single()
        .map(|dt| dt.timestamp_millis())
        .unwrap_or(now.timestamp_millis())
}

// ------------------------------------------------------------------ события --

#[derive(Deserialize, Default)]
struct RawEvent {
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    time: i64,
    data: Option<RawData>,
}

#[derive(Deserialize, Default)]
struct RawData {
    usage: Option<Usage>,
    source: Option<Source>,
    content: Option<Vec<Block>>,
    name: Option<String>,
    title: Option<String>,
}

#[derive(Deserialize, Default)]
struct Usage {
    #[serde(rename = "inputTokens", default)]
    input: i64,
    #[serde(rename = "outputTokens", default)]
    output: i64,
    #[serde(rename = "cacheReadTokens", default)]
    cache_read: i64,
    #[serde(rename = "cacheWriteTokens", default)]
    cache_write: i64,
}

#[derive(Deserialize, Default)]
struct Source {
    #[serde(default)]
    kind: String,
}

#[derive(Deserialize, Default)]
struct Block {
    #[serde(rename = "type", default)]
    kind: String,
    #[serde(default)]
    text: String,
}

// ------------------------------------------------------------------- сессии --

#[derive(Default, Clone, Serialize, Deserialize)]
struct Tokens {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_write: i64,
}

#[derive(Clone, Serialize, Deserialize)]
struct SessionInfo {
    id: String,
    project: String,
    title: Option<String>,
    task: Option<String>,
    tool: Option<String>,
    last_event_at: i64,
    started_at: Option<i64>,
    open_turns: i32,
    tokens: Tokens,
    had_today: bool,
}

/// Имена каталогов DSH — это путь с дефисами вместо разделителей и
/// восьмеричными группами вида `~0432~` вместо не-ASCII байтов.
fn pretty_project(name: &str) -> String {
    let trimmed = name.trim_matches('-');
    let mut decoded = String::with_capacity(trimmed.len());
    let bytes = trimmed.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'~' {
            if let Some(end) = trimmed[i + 1..].find('~') {
                let octal = &trimmed[i + 1..i + 1 + end];
                if !octal.is_empty() && octal.chars().all(|c| ('0'..='7').contains(&c)) {
                    if let Ok(code) = u32::from_str_radix(octal, 8) {
                        if let Some(ch) = char::from_u32(code) {
                            decoded.push(ch);
                            i += end + 2;
                            continue;
                        }
                    }
                }
            }
        }
        decoded.push(bytes[i] as char);
        i += 1;
    }
    decoded
        .split('-')
        .filter(|part| !part.is_empty())
        .last()
        .unwrap_or(&decoded)
        .to_string()
}

/// Кэш разобранных сессий: файл, который не менялся, можно не читать заново.
/// Активная сессия меняется постоянно, поэтому перечитывается только она.
#[derive(Serialize, Deserialize, Default)]
struct SessionCache {
    day: i64,
    entries: HashMap<String, CachedSession>,
}

#[derive(Serialize, Deserialize, Clone)]
struct CachedSession {
    size: u64,
    mtime: i64,
    /// Позиция после последнего целого кадра: файл только дописывается, так
    /// что разбирать заново нужно лишь хвост.
    offset: usize,
    info: SessionInfo,
}

fn cache_file(dsh_home: &Path) -> PathBuf {
    dsh_home.join("dynamicbar").join("sessions-cache.json")
}

fn read_session_cache(dsh_home: &Path, today_ms: i64) -> SessionCache {
    // Для проверок: полный разбор без кэша.
    if std::env::var("DSH_CORE_NO_CACHE").is_ok() {
        return SessionCache {
            day: today_ms,
            entries: HashMap::new(),
        };
    }
    let cache: SessionCache = fs::read_to_string(cache_file(dsh_home))
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default();
    // Смена суток сбрасывает счётчики: в кэше они привязаны к сегодняшнему дню.
    if cache.day == today_ms {
        cache
    } else {
        SessionCache {
            day: today_ms,
            entries: HashMap::new(),
        }
    }
}

fn write_session_cache(dsh_home: &Path, cache: &SessionCache) {
    let path = cache_file(dsh_home);
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(text) = serde_json::to_string(cache) {
        let _ = fs::write(path, text);
    }
}

fn session_files(root: &Path) -> Vec<(PathBuf, String, String, i64)> {
    let mut out = Vec::new();
    let Ok(projects) = fs::read_dir(root) else { return out };
    for project in projects.flatten() {
        let project_path = project.path();
        if !project_path.is_dir() {
            continue;
        }
        let project_name = pretty_project(&project.file_name().to_string_lossy());
        let Ok(sessions) = fs::read_dir(&project_path) else { continue };
        for session in sessions.flatten() {
            let dir = session.path();
            if !dir.is_dir() {
                continue;
            }
            let file = dir.join("session.v4.jsonl.zstd");
            let Ok(meta) = fs::metadata(&file) else { continue };
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            out.push((
                file,
                session.file_name().to_string_lossy().to_string(),
                project_name.clone(),
                mtime,
            ));
        }
    }
    out
}

fn read_session(
    path: &Path,
    id: &str,
    project: &str,
    today_ms: i64,
    resume: Option<&CachedSession>,
) -> Option<(SessionInfo, usize)> {
    let data = fs::read(path).ok()?;

    let (mut info, start) = match resume {
        Some(cached) if cached.size <= data.len() as u64 => (cached.info.clone(), cached.offset.min(data.len())),
        _ => (
            SessionInfo {
                id: id.to_string(),
                project: project.to_string(),
                title: None,
                task: None,
                tool: None,
                last_event_at: 0,
                started_at: None,
                open_turns: 0,
                tokens: Tokens::default(),
                had_today: false,
            },
            0,
        ),
    };

    let (text, consumed) = frames::decode_from(&data, start);
    if text.is_empty() && start == 0 {
        return None;
    }

    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        // Быстрый отбор: полный разбор каждой строки — самая дорогая часть.
        // Большинство событий (step/start, tool/result, delivery-accepted)
        // для снимка не нужны, поэтому сначала смотрим только на тип.
        let Some(kind) = quick_kind(line) else { continue };
        if !matches!(
            kind,
            "turn/start" | "turn/end" | "session/title" | "user/message" | "tool/call" | "assistant/message"
        ) {
            continue;
        }
        let Ok(event) = serde_json::from_str::<RawEvent>(line) else { continue };
        if event.time > info.last_event_at {
            info.last_event_at = event.time;
        }
        let data = event.data.unwrap_or_default();
        match event.kind.as_str() {
            "turn/start" => {
                info.open_turns += 1;
                if info.started_at.is_none() {
                    info.started_at = Some(event.time);
                }
            }
            "turn/end" => info.open_turns = (info.open_turns - 1).max(0),
            "session/title" => {
                if let Some(title) = data.title {
                    if !title.trim().is_empty() {
                        info.title = Some(title.trim().to_string());
                    }
                }
            }
            "user/message" => {
                // Только настоящие реплики человека: time-context и прочий
                // служебный шум задачу не описывают.
                let is_user = data
                    .source
                    .as_ref()
                    .map(|s| s.kind == "user")
                    .unwrap_or(false);
                if is_user {
                    let text = data
                        .content
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|b| b.kind == "text")
                        .map(|b| b.text.trim().to_string())
                        .filter(|t| !t.is_empty())
                        .collect::<Vec<_>>()
                        .join(" ");
                    if !text.is_empty() {
                        info.task = Some(text);
                    }
                }
            }
            "tool/call" => {
                if let Some(name) = data.name {
                    info.tool = Some(name);
                }
            }
            "assistant/message" => {
                if let Some(usage) = data.usage {
                    if event.time >= today_ms {
                        info.had_today = true;
                        info.tokens.input += usage.input;
                        info.tokens.output += usage.output;
                        info.tokens.cache_read += usage.cache_read;
                        info.tokens.cache_write += usage.cache_write;
                    }
                }
            }
            _ => {}
        }
    }

    Some((info, consumed))
}

/// Тип события без полного разбора JSON: `{"type":"…"`.
fn quick_kind(line: &str) -> Option<&str> {
    let start = line.find("\"type\":\"")? + 8;
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(&rest[..end])
}

fn dsh_running() -> bool {
    let Ok(output) = Command::new("/bin/ps").arg("-axo").arg("command").output() else {
        return false;
    };
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines().any(|line| {
        let line = line.trim();
        line.contains("dsh web") || (line.contains("/dsh") && line.ends_with(" web"))
    })
}

fn status_of(info: &SessionInfo, running: bool, now: i64) -> &'static str {
    if !running {
        return "off";
    }
    let age = now - info.last_event_at;
    if info.open_turns > 0 {
        if age < 90_000 {
            "working"
        } else {
            "waiting"
        }
    } else if age < 120_000 {
        "working"
    } else {
        "idle"
    }
}

/// Собирает снимок целиком. Ошибки не прерывают работу: чего не удалось
/// прочитать, того просто не будет в JSON, а причина попадёт в warnings.
pub fn build(dsh_home: &Path, no_balance: bool) -> Value {
    let started = now_ms();
    let today_ms = start_of_today_ms();
    let now = now_ms();
    let mut warnings: Vec<String> = Vec::new();

    let files = session_files(&dsh_home.join("sessions"));
    let mut relevant: Vec<&(PathBuf, String, String, i64)> =
        files.iter().filter(|f| f.3 >= today_ms).collect();
    // Живые сессии последних 30 минут нужны для списка, даже если начаты вчера.
    let recent: Vec<&(PathBuf, String, String, i64)> =
        files.iter().filter(|f| f.3 >= now - 30 * 60_000).collect();

    let mut cache = read_session_cache(dsh_home, today_ms);
    let mut cache_changed = false;
    let mut by_id: HashMap<String, SessionInfo> = HashMap::new();
    for entry in relevant.drain(..).chain(recent.into_iter()) {
        if by_id.contains_key(&entry.1) {
            continue;
        }
        let key = entry.0.to_string_lossy().to_string();
        let meta = fs::metadata(&entry.0).ok();
        let size = meta.as_ref().map(|m| m.len()).unwrap_or(0);
        let mtime = entry.3;

        let cached = cache.entries.get(&key).cloned();
        if let Some(cached) = &cached {
            if cached.size == size && cached.mtime == mtime && cached.info.had_today {
                by_id.insert(entry.1.clone(), cached.info.clone());
                continue;
            }
        }

        // Хвост файла дописывается между запусками: продолжаем с последнего
        // целого кадра, а не разбираем мегабайты заново.
        if let Some((info, offset)) =
            read_session(&entry.0, &entry.1, &entry.2, today_ms, cached.as_ref())
        {
            cache.entries.insert(
                key,
                CachedSession {
                    size,
                    mtime,
                    offset,
                    info: info.clone(),
                },
            );
            cache_changed = true;
            by_id.insert(entry.1.clone(), info);
        }
    }
    if cache_changed {
        write_session_cache(dsh_home, &cache);
    }

    let running = dsh_running();
    let mut today = Tokens::default();
    let mut sessions_today = 0;
    for info in by_id.values() {
        if info.had_today {
            sessions_today += 1;
            today.input += info.tokens.input;
            today.output += info.tokens.output;
            today.cache_read += info.tokens.cache_read;
            today.cache_write += info.tokens.cache_write;
        }
    }

    let mut active: Vec<&SessionInfo> = by_id
        .values()
        .filter(|info| now - info.last_event_at < 30 * 60_000)
        .collect();
    active.sort_by_key(|info| -info.last_event_at);

    let statuses: Vec<&str> = active
        .iter()
        .map(|info| status_of(info, running, now))
        .collect();
    let global_status = if !running {
        "off"
    } else if statuses.contains(&"working") {
        "working"
    } else if statuses.contains(&"waiting") {
        "waiting"
    } else {
        "idle"
    };

    let sessions_json: Vec<Value> = active
        .iter()
        .take(8)
        .map(|info| {
            json!({
                "id": info.id,
                "project": info.project,
                "title": info.title,
                "task": info.task.as_ref().map(|t| t.chars().take(240).collect::<String>()),
                "tool": info.tool,
                "startedAt": info.started_at,
                "lastEventAt": info.last_event_at,
                "status": status_of(info, running, now),
            })
        })
        .collect();

    let date_string = Local::now().format("%Y-%m-%d").to_string();
    let today_json = json!({
        "date": date_string,
        "input": today.input,
        "output": today.output,
        "cacheRead": today.cache_read,
        "cacheWrite": today.cache_write,
        "billable": today.input + today.output,
        "total": today.input + today.output + today.cache_read + today.cache_write,
        "sessions": sessions_today,
    });

    let balance_json = if no_balance {
        empty_balance()
    } else {
        net::balance_snapshot(dsh_home, &mut warnings)
    };

    json!({
        "schemaVersion": 1,
        "updatedAt": now,
        "collector": {
            "version": COLLECTOR_VERSION,
            "tookMs": now_ms() - started,
            "warnings": warnings,
        },
        "agent": {
            "dshRunning": running,
            "status": global_status,
            "sessions": sessions_json,
        },
        "today": today_json,
        "balance": balance_json,
    })
}

fn empty_balance() -> Value {
    json!({
        "available": null,
        "at": null,
        "wallets": [],
        "rub": null,
        "walletRub": {},
        "rates": {},
        "ratesAt": null,
        "ratesDate": null,
        "ratesSource": null,
        "converted": {},
    })
}
