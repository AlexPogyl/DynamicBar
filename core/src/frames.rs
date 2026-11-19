//! Разбор логов сессий DeepSeek Harness.
//!
//! Лог — это поток отдельных zstd-кадров (по кадру на запись). Ни один
//! декодер «из коробки» не читает кадры после первого, поэтому границы
//! считаются вручную по RFC 8878, а каждый кадр разжимается отдельно.

use ruzstd::decoding::StreamingDecoder;
use std::io::{Cursor, Read};

const ZSTD_MAGIC: u32 = 0xFD2F_B528;

/// Длина кадра по его заголовку и блокам. `None` — кадр недописан или битый;
/// тогда остаток файла игнорируется: следующая запись допишет его целиком.
fn frame_length(buf: &[u8], start: usize) -> Option<usize> {
    let mut pos = start;
    let need = |pos: usize, n: usize| pos + n <= buf.len();

    if !need(pos, 4) {
        return None;
    }
    let magic = u32::from_le_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]);

    // Пропускаемые кадры (skippable frames) — у них своя длина.
    if (0x184D_2A50..=0x184D_2A5F).contains(&magic) {
        if !need(pos, 8) {
            return None;
        }
        let size = u32::from_le_bytes([buf[pos + 4], buf[pos + 5], buf[pos + 6], buf[pos + 7]]) as usize;
        return Some(8 + size);
    }
    if magic != ZSTD_MAGIC {
        return None;
    }

    pos += 4;
    if !need(pos, 1) {
        return None;
    }
    let descriptor = buf[pos];
    pos += 1;

    let content_size_flag = descriptor >> 6;
    let single_segment = (descriptor >> 5) & 1 == 1;
    let has_checksum = (descriptor >> 2) & 1 == 1;
    let dict_flag = descriptor & 3;

    if !single_segment {
        pos += 1; // Window_Descriptor
    }
    pos += [0, 1, 2, 4][dict_flag as usize];
    if content_size_flag == 0 {
        if single_segment {
            pos += 1;
        }
    } else {
        pos += [0, 2, 4, 8][content_size_flag as usize];
    }

    loop {
        if !need(pos, 3) {
            return None;
        }
        let header = (buf[pos] as u32) | ((buf[pos + 1] as u32) << 8) | ((buf[pos + 2] as u32) << 16);
        pos += 3;
        let last_block = header & 1 == 1;
        let block_type = (header >> 1) & 3;
        let block_size = (header >> 3) as usize;
        pos += if block_type == 1 { 1 } else { block_size };
        if last_block {
            break;
        }
    }
    if has_checksum {
        pos += 4;
    }
    if pos > buf.len() {
        return None;
    }
    Some(pos - start)
}

/// Разжимает все кадры файла, начиная с `start`. Возвращает текст и позицию
/// после последнего **целого** кадра: следующий вызов может продолжить с неё,
/// не перечитывая весь лог.
pub fn decode_from(buf: &[u8], start: usize) -> (String, usize) {
    let mut out = String::new();
    let mut pos = start;
    while pos + 4 <= buf.len() {
        let magic = u32::from_le_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]]);
        // Не кадр — дальше искать нечего (обычно это недописанный хвост).
        if magic != ZSTD_MAGIC && !(0x184D_2A50..=0x184D_2A5F).contains(&magic) {
            break;
        }
        let Some(len) = frame_length(buf, pos) else { break };
        let frame = &buf[pos..pos + len];
        pos += len;
        if magic != ZSTD_MAGIC {
            continue; // skippable
        }
        let mut decoder = match StreamingDecoder::new(Cursor::new(frame)) {
            Ok(decoder) => decoder,
            Err(_) => continue,
        };
        let mut text = String::new();
        if decoder.read_to_string(&mut text).is_ok() {
            out.push_str(&text);
        }
    }
    (out, pos)
}

/// Разжимает файл целиком.
pub fn decode_all(buf: &[u8]) -> String {
    decode_from(buf, 0).0
}
