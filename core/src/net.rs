//! Сеть: баланс DeepSeek и курс ЦБ.
//!
//! Запросы редкие (баланс — раз в 5 минут, курс — раз в 12 часов), поэтому
//! вместо тяжёлого TLS-стека используется системный `curl`: он есть на любом
//! Mac и умеет всё, что нужно. Ключ в кэш и в снимок не попадает.

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::agent::now_ms;

const BALANCE_TTL_MS: i64 = 5 * 60_000;
const RATES_TTL_MS: i64 = 12 * 60 * 60_000;

fn curl(url: &str, bearer: Option<&str>) -> Option<String> {
    let mut command = Command::new("/usr/bin/curl");
    command.args(["-s", "-L", "--max-time", "8", url]);
    if let Some(token) = bearer {
        command.args(["-H", &format!("Authorization: Bearer {token}")]);
    }
    let output = command.output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).to_string())
}

fn api_key(dsh_home: &Path) -> Option<String> {
    if let Ok(value) = std::env::var("DEEPSEEK_API_KEY") {
        if !value.trim().is_empty() {
            return Some(value.trim().to_string());
        }
    }
    let text = fs::read_to_string(dsh_home.join(".credentials.yaml")).ok()?;
    for line in text.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("DEEPSEEK_API_KEY:") {
            let value = rest.trim().trim_matches('"').trim_matches('\'').trim();
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn fetch_balance(key: &str) -> Option<Value> {
    let body = curl("https://api.deepseek.com/user/balance", Some(key))?;
    let parsed: Value = serde_json::from_str(&body).ok()?;
    let wallets: Vec<Value> = parsed
        .get("balance_infos")?
        .as_array()?
        .iter()
        .map(|wallet| {
            let number = |field: &str| {
                wallet
                    .get(field)
                    .and_then(|v| v.as_str())
                    .and_then(|v| v.parse::<f64>().ok())
                    .unwrap_or(0.0)
            };
            json!({
                "currency": wallet.get("currency").and_then(|v| v.as_str()).unwrap_or(""),
                "total": number("total_balance"),
                "granted": number("granted_balance"),
                "toppedUp": number("topped_up_balance"),
            })
        })
        .collect();
    Some(json!({
        "available": parsed.get("is_available").and_then(|v| v.as_bool()).unwrap_or(false),
        "at": now_ms(),
        "wallets": wallets,
    }))
}

fn fetch_rates() -> Option<Value> {
    let xml = curl("https://www.cbr.ru/scripts/XML_daily.asp", None)?;

    let mut rates = serde_json::Map::new();
    let mut date = None;
    if let Some(start) = xml.find("Date=\"") {
        let rest = &xml[start + 6..];
        if let Some(end) = rest.find('"') {
            date = Some(rest[..end].to_string());
        }
    }

    // Ответ приходит в windows-1251, но нужные поля — ASCII, поэтому
    // достаточно строкового поиска по тегам.
    let mut cursor = 0usize;
    while let Some(code_start) = xml[cursor..].find("<CharCode>") {
        let code_start = cursor + code_start + "<CharCode>".len();
        let Some(code_end) = xml[code_start..].find("</CharCode>") else { break };
        let code = &xml[code_start..code_start + code_end];

        let Some(nominal_at) = xml[code_start..].find("<Nominal>") else { break };
        let nominal_start = code_start + nominal_at + "<Nominal>".len();
        let Some(nominal_end) = xml[nominal_start..].find("</Nominal>") else { break };
        let nominal: f64 = xml[nominal_start..nominal_start + nominal_end]
            .trim()
            .parse()
            .unwrap_or(1.0);

        let Some(value_at) = xml[nominal_start..].find("<Value>") else { break };
        let value_start = nominal_start + value_at + "<Value>".len();
        let Some(value_end) = xml[value_start..].find("</Value>") else { break };
        let raw = xml[value_start..value_start + value_end].replace(',', ".");

        if let Ok(value) = raw.trim().parse::<f64>() {
            if nominal > 0.0 && value > 0.0 {
                rates.insert(code.to_string(), json!(value / nominal));
            }
        }
        cursor = value_start + value_end;
    }

    if rates.is_empty() {
        return None;
    }
    Some(json!({
        "at": now_ms(),
        "source": "ЦБ РФ",
        "date": date,
        "rates": Value::Object(rates),
    }))
}

fn cache_path(dsh_home: &Path) -> PathBuf {
    dsh_home.join("dynamicbar").join("cache.json")
}

fn read_cache(path: &Path) -> Value {
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_else(|| json!({}))
}

fn write_cache(path: &Path, cache: &Value) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(text) = serde_json::to_string(cache) {
        let _ = fs::write(path, text);
    }
}

fn cached(path: &Path, key: &str, ttl: i64, load: impl FnOnce() -> Option<Value>) -> Option<Value> {
    let mut cache = read_cache(path);
    let entry = cache.get(key).cloned();
    let age = entry
        .as_ref()
        .and_then(|e| e.get("at"))
        .and_then(|v| v.as_i64())
        .map(|at| now_ms() - at);

    if let Some(age) = age {
        if age < ttl {
            return entry.and_then(|e| e.get("value").cloned());
        }
    }

    match load() {
        Some(value) => {
            if let Some(map) = cache.as_object_mut() {
                map.insert(key.to_string(), json!({ "at": now_ms(), "value": value }));
            }
            write_cache(path, &cache);
            Some(value)
        }
        // Свежее не получилось — показываем прошлый снимок, он лучше пустоты.
        None => entry.and_then(|e| e.get("value").cloned()),
    }
}

fn round(value: f64, digits: i32) -> f64 {
    let factor = 10f64.powi(digits);
    (value * factor).round() / factor
}

/// Баланс с пересчётом: рубли по курсу ЦБ, остальные валюты — из рублей.
pub fn balance_snapshot(dsh_home: &Path, warnings: &mut Vec<String>) -> Value {
    let path = cache_path(dsh_home);

    let balance = if let Some(key) = api_key(dsh_home) {
        cached(&path, "balance", BALANCE_TTL_MS, || fetch_balance(&key))
    } else {
        warnings.push("нет ключа DEEPSEEK_API_KEY".to_string());
        None
    };
    let rates = cached(&path, "rates", RATES_TTL_MS, fetch_rates);

    let Some(balance) = balance else {
        return json!({
            "available": null, "at": null, "wallets": [], "rub": null, "walletRub": {},
            "rates": rates.as_ref().and_then(|r| r.get("rates")).cloned().unwrap_or_else(|| json!({})),
            "ratesAt": rates.as_ref().and_then(|r| r.get("at")).cloned().unwrap_or(Value::Null),
            "ratesDate": rates.as_ref().and_then(|r| r.get("date")).cloned().unwrap_or(Value::Null),
            "ratesSource": rates.as_ref().and_then(|r| r.get("source")).cloned().unwrap_or(Value::Null),
            "converted": {},
        });
    };

    let wallets = balance
        .get("wallets")
        .and_then(|w| w.as_array())
        .cloned()
        .unwrap_or_default();
    let rate_map = rates
        .as_ref()
        .and_then(|r| r.get("rates"))
        .and_then(|r| r.as_object())
        .cloned()
        .unwrap_or_default();

    let mut wallet_rub = serde_json::Map::new();
    let mut sum = 0.0f64;
    let mut known = rates.is_some();
    for wallet in &wallets {
        let currency = wallet.get("currency").and_then(|v| v.as_str()).unwrap_or("");
        let total = wallet.get("total").and_then(|v| v.as_f64()).unwrap_or(0.0);
        match rate_map.get(currency).and_then(|v| v.as_f64()) {
            Some(rate) => {
                let value = total * rate;
                wallet_rub.insert(currency.to_string(), json!(round(value, 2)));
                sum += value;
            }
            None => {
                if total > 0.0 {
                    known = false;
                }
            }
        }
    }

    let rub = if known && !wallets.is_empty() {
        Some(round(sum, 2))
    } else {
        None
    };

    let mut converted = serde_json::Map::new();
    if let Some(rub_value) = rub {
        for code in ["CNY", "USD", "EUR"] {
            if let Some(rate) = rate_map.get(code).and_then(|v| v.as_f64()) {
                if rate > 0.0 {
                    converted.insert(code.to_string(), json!(round(rub_value / rate, 2)));
                }
            }
        }
    }

    json!({
        "available": balance.get("available").cloned().unwrap_or(Value::Null),
        "at": balance.get("at").cloned().unwrap_or(Value::Null),
        "wallets": wallets,
        "rub": rub,
        "walletRub": Value::Object(wallet_rub),
        "rates": Value::Object(rate_map),
        "ratesAt": rates.as_ref().and_then(|r| r.get("at")).cloned().unwrap_or(Value::Null),
        "ratesDate": rates.as_ref().and_then(|r| r.get("date")).cloned().unwrap_or(Value::Null),
        "ratesSource": rates.as_ref().and_then(|r| r.get("source")).cloned().unwrap_or(Value::Null),
        "converted": Value::Object(converted),
    })
}
