#!/usr/bin/env node
// dsh-collector — собирает снимок состояния агента DeepSeek Harness.
//
//   node dsh-collector.mjs --json
//   node dsh-collector.mjs --out ~/.dsh/dynamicbar/dsh.json
//
// Что внутри снимка: токены за сегодня, баланс DeepSeek, курсы ЦБ и активные
// сессии агента. Ничего не пишет в сеть, кроме двух запросов: баланс
// (api.deepseek.com, раз в 5 минут) и курсы (cbr.ru, раз в сутки).
//
// Ключ API берётся из переменной DEEPSEEK_API_KEY или из refs в
// ~/.dsh/.credentials.yaml. В снимок он не попадает никогда.
//
// Схема снимка описана в README, раздел «Вкладка «Агент»».

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';

const VERSION = '1.0.0';

// ---------------------------------------------------------------- аргументы --

const argv = process.argv.slice(2);
function arg(name, fallback = null) {
  const i = argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const value = argv[i + 1];
  return value && !value.startsWith('--') ? value : true;
}
function flag(name) { return argv.includes(`--${name}`); }

const dsHome = arg('dsh-home') || process.env.DSH_HOME || path.join(os.homedir(), '.dsh');
const cachePath = path.join(dsHome, 'dynamicbar', 'cache.json');
const defaultOut = path.join(dsHome, 'dynamicbar', 'dsh.json');
const outPath = arg('out') === true ? defaultOut : arg('out');
const toStdout = flag('json') || !outPath;
const skipBalance = flag('no-balance');
const warnings = [];

// -------------------------------------------------------------- утилиты ------

const now = Date.now();

function safeReaddir(dir) {
  try { return fs.readdirSync(dir, { withFileTypes: true }); } catch { return []; }
}

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

function round(value, digits = 2) {
  if (!Number.isFinite(value)) return null;
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

// ------------------------------------------------------------- zstd ---------

// Сессия — это поток отдельных zstd-кадров (по кадру на запись). Ни
// zstdDecompressSync, ни потоковый API Node не читают кадры после первого:
// оба молча возвращают содержимое только первого кадра. Поэтому границы
// кадров считаются вручную по формату RFC 8878 и каждый кадр разжимается
// отдельно.
function decodeZstd(buf) {
  const chunks = [];
  let pos = 0;

  const need = (n) => pos + n <= buf.length;

  while (need(4)) {
    const magic = buf.readUInt32LE(pos);

    // Пропускаемые кадры (skippable frames).
    if (magic >= 0x184d2a50 && magic <= 0x184d2a5f) {
      if (!need(8)) break;
      const size = buf.readUInt32LE(pos + 4);
      pos += 8 + size;
      continue;
    }
    if (magic !== 0xfd2fb528) break;

    const start = pos;
    pos += 4;
    if (!need(1)) break;

    const descriptor = buf[pos++];
    const contentSizeFlag = descriptor >> 6;
    const singleSegment = (descriptor >> 5) & 1;
    const hasChecksum = (descriptor >> 2) & 1;
    const dictFlag = descriptor & 3;

    if (!singleSegment) pos += 1;                 // Window_Descriptor
    pos += [0, 1, 2, 4][dictFlag];                // Dictionary_ID
    if (contentSizeFlag === 0) {
      if (singleSegment) pos += 1;
    } else {
      pos += [0, 2, 4, 8][contentSizeFlag];       // Frame_Content_Size
    }

    let complete = false;
    while (need(3)) {
      const header = buf.readUIntLE(pos, 3);
      pos += 3;
      const lastBlock = header & 1;
      const blockType = (header >> 1) & 3;
      const blockSize = header >> 3;
      pos += blockType === 1 ? 1 : blockSize;     // RLE занимает 1 байт
      if (lastBlock) { complete = true; break; }
    }
    if (!complete) break;
    if (hasChecksum) pos += 4;

    const frame = buf.subarray(start, Math.min(pos, buf.length));
    try {
      chunks.push(zlib.zstdDecompressSync(frame));
    } catch {
      // Недописанный или повреждённый кадр — пропускаем, остальное читаем.
    }
  }

  return Buffer.concat(chunks).toString('utf8');
}

// ---------------------------------------------------------- сессии ----------

function prettyProject(dirName) {
  // Имена каталогов DSH — это путь, где разделители заменены на дефис,
  // а не-ASCII байты записаны восьмеричными группами вида ~0432~.
  let name = dirName.replace(/^--/, '').replace(/--$/, '');
  name = name.replace(/~([0-7]{3,4})~/g, (_, oct) => String.fromCharCode(parseInt(oct, 8)));
  const parts = name.split('-').filter(Boolean);
  return parts.length ? parts[parts.length - 1] : name;
}

function collectSessionFiles(root) {
  const files = [];
  for (const project of safeReaddir(root)) {
    if (!project.isDirectory()) continue;
    const projectDir = path.join(root, project.name);
    for (const session of safeReaddir(projectDir)) {
      if (!session.isDirectory()) continue;
      const file = path.join(projectDir, session.name, 'session.v4.jsonl.zstd');
      try {
        const stat = fs.statSync(file);
        files.push({
          file,
          id: session.name,
          project: prettyProject(project.name),
          mtime: stat.mtimeMs,
          size: stat.size,
        });
      } catch { /* сессии без лога пропускаем */ }
    }
  }
  return files;
}

const startOfToday = new Date();
startOfToday.setHours(0, 0, 0, 0);
const todayMs = startOfToday.getTime();

// Дата считается по локальной зоне: toISOString() отдал бы UTC, и вечером
// в Москве «сегодня» превратилось бы во вчера.
function localDate(ms) {
  const date = new Date(ms);
  const pad = (value) => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function textOfUserMessage(event) {
  const content = event?.data?.content;
  if (!Array.isArray(content)) return null;
  const text = content
    .filter((block) => block?.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text.trim())
    .filter(Boolean)
    .join(' ');
  return text || null;
}

function readSession(meta) {
  let text;
  try {
    text = decodeZstd(fs.readFileSync(meta.file));
  } catch {
    return null;
  }
  if (!text) return null;

  const info = {
    id: meta.id,
    project: meta.project,
    title: null,
    task: null,
    tool: null,
    toolAt: null,
    lastEventAt: 0,
    startedAt: null,
    openTurns: 0,
    tokensToday: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    hadToday: false,
  };

  for (const line of text.split('\n')) {
    if (!line) continue;
    let event;
    try { event = JSON.parse(line); } catch { continue; }

    const time = typeof event.time === 'number' ? event.time : 0;
    if (time > info.lastEventAt) info.lastEventAt = time;

    switch (event.type) {
      case 'turn/start':
        info.openTurns += 1;
        if (!info.startedAt) info.startedAt = time;
        break;
      case 'turn/end':
        info.openTurns = Math.max(0, info.openTurns - 1);
        break;
      case 'session/title':
        if (typeof event?.data?.title === 'string' && event.data.title.trim()) {
          info.title = event.data.title.trim();
        }
        break;
      case 'user/message':
        // Только настоящие реплики человека: time-context, runtime-context,
        // approval и прочий служебный шум задачу не описывают.
        if (event?.data?.source?.kind === 'user') {
          const text = textOfUserMessage(event);
          if (text) info.task = text;
        }
        break;
      case 'tool/call':
        if (typeof event?.data?.name === 'string') {
          info.tool = event.data.name;
          info.toolAt = time;
        }
        break;
      case 'assistant/message': {
        const usage = event?.data?.usage;
        if (usage && time >= todayMs) {
          info.hadToday = true;
          info.tokensToday.input += usage.inputTokens || 0;
          info.tokensToday.output += usage.outputTokens || 0;
          info.tokensToday.cacheRead += usage.cacheReadTokens || 0;
          info.tokensToday.cacheWrite += usage.cacheWriteTokens || 0;
        }
        break;
      }
      default:
        break;
    }
  }

  return info;
}

function agentStatus(session, running) {
  if (!running) return 'off';
  if (!session) return 'idle';
  const age = now - session.lastEventAt;
  if (session.openTurns > 0) return age < 90_000 ? 'working' : 'waiting';
  return age < 120_000 ? 'working' : 'idle';
}

function collectAgent() {
  const sessionsRoot = path.join(dsHome, 'sessions');
  const files = collectSessionFiles(sessionsRoot);
  const running = isDshRunning();

  // Логи, которые не менялись сегодня, не могут содержать сегодняшних событий.
  const relevant = files.filter((meta) => meta.mtime >= todayMs);
  // Для списка сессий берём всё, что живо последние полчаса, даже если это
  // файл, начатый вчера.
  const recent = files.filter((meta) => meta.mtime >= now - 30 * 60_000);

  const byId = new Map();
  for (const meta of relevant) {
    const info = readSession(meta);
    if (info) byId.set(meta.id, info);
  }
  for (const meta of recent) {
    if (byId.has(meta.id)) continue;
    const info = readSession(meta);
    if (info) byId.set(meta.id, info);
  }

  const all = [...byId.values()];
  const today = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, sessions: 0 };
  for (const info of all) {
    if (!info.hadToday) continue;
    today.sessions += 1;
    today.input += info.tokensToday.input;
    today.output += info.tokensToday.output;
    today.cacheRead += info.tokensToday.cacheRead;
    today.cacheWrite += info.tokensToday.cacheWrite;
  }

  const active = all
    .filter((info) => now - info.lastEventAt < 30 * 60_000)
    .sort((a, b) => b.lastEventAt - a.lastEventAt);

  const statuses = active.map((info) => agentStatus(info, running));
  let status = 'idle';
  if (!running) status = 'off';
  else if (statuses.includes('working')) status = 'working';
  else if (statuses.includes('waiting')) status = 'waiting';

  return {
    dshRunning: running,
    status,
    sessions: active.slice(0, 8).map((info) => ({
      id: info.id,
      project: info.project,
      title: info.title,
      task: info.task ? info.task.slice(0, 240) : null,
      tool: info.tool,
      startedAt: info.startedAt,
      lastEventAt: info.lastEventAt,
      status: agentStatus(info, running),
    })),
    today: {
      date: localDate(todayMs),
      input: today.input,
      output: today.output,
      cacheRead: today.cacheRead,
      cacheWrite: today.cacheWrite,
      billable: today.input + today.output,
      total: today.input + today.output + today.cacheRead + today.cacheWrite,
      sessions: today.sessions,
    },
  };
}

function isDshRunning() {
  try {
    const out = execFileSync('/bin/ps', ['-axo', 'command'], {
      encoding: 'utf8',
      timeout: 4000,
      maxBuffer: 8 * 1024 * 1024,
    });
    return out.split('\n').some((line) =>
      /\bdsh\b\s+web\b/.test(line) || /dsh\/bin\/dsh\b.*\bweb\b/.test(line)
    );
  } catch {
    return false;
  }
}

// -------------------------------------------------------------- баланс ------

function apiKey() {
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY.trim();
  try {
    const text = fs.readFileSync(path.join(dsHome, '.credentials.yaml'), 'utf8');
    const match = text.match(/^\s*DEEPSEEK_API_KEY:\s*["']?([^"'\s]+)/m);
    return match ? match[1].trim() : null;
  } catch {
    return null;
  }
}

async function fetchBalance() {
  const key = apiKey();
  if (!key) {
    warnings.push('нет ключа DEEPSEEK_API_KEY');
    return null;
  }
  try {
    const response = await fetch('https://api.deepseek.com/user/balance', {
      headers: { Authorization: `Bearer ${key}` },
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) {
      warnings.push(`баланс: HTTP ${response.status}`);
      return null;
    }
    const payload = await response.json();
    const wallets = (payload.balance_infos || []).map((wallet) => ({
      currency: wallet.currency,
      total: Number.parseFloat(wallet.total_balance) || 0,
      granted: Number.parseFloat(wallet.granted_balance) || 0,
      toppedUp: Number.parseFloat(wallet.topped_up_balance) || 0,
    }));
    return { available: payload.is_available === true, at: Date.now(), wallets };
  } catch (error) {
    warnings.push(`баланс: ${error.message}`);
    return null;
  }
}

// --------------------------------------------------------------- курсы ------

function parseCbr(xml) {
  const rates = {};
  let date = null;
  const dateMatch = xml.match(/<ValCurs[^>]*Date="([^"]+)"/);
  if (dateMatch) date = dateMatch[1];
  const pattern = /<CharCode>([A-Z]{3})<\/CharCode>[\s\S]*?<Nominal>(\d+)<\/Nominal>[\s\S]*?<Value>([\d,.]+)<\/Value>/g;
  let match;
  while ((match = pattern.exec(xml)) !== null) {
    const [, code, nominal, value] = match;
    const parsed = Number.parseFloat(value.replace(',', '.'));
    if (Number.isFinite(parsed) && parsed > 0) {
      rates[code] = parsed / Number.parseInt(nominal, 10);
    }
  }
  return { date, rates };
}

async function fetchRates() {
  try {
    const response = await fetch('https://www.cbr.ru/scripts/XML_daily.asp', {
      signal: AbortSignal.timeout(8000),
    });
    if (!response.ok) {
      warnings.push(`курсы: HTTP ${response.status}`);
      return null;
    }
    // Ответ в windows-1251, но нужные поля — ASCII, поэтому читаем как latin1.
    const xml = Buffer.from(await response.arrayBuffer()).toString('latin1');
    const { date, rates } = parseCbr(xml);
    if (!rates.CNY && !rates.USD && !rates.EUR) {
      warnings.push('курсы: не удалось разобрать ответ ЦБ');
      return null;
    }
    return { at: Date.now(), source: 'ЦБ РФ', date, rates };
  } catch (error) {
    warnings.push(`курсы: ${error.message}`);
    return null;
  }
}

function withCache(key, ttl, loader) {
  const cache = readJSON(cachePath, {});
  const entry = cache[key];
  if (entry && now - entry.at < ttl) return Promise.resolve(entry.value);
  return loader().then((value) => {
    if (value) {
      cache[key] = { at: Date.now(), value };
      try {
        fs.mkdirSync(path.dirname(cachePath), { recursive: true });
        fs.writeFileSync(cachePath, JSON.stringify(cache));
      } catch { /* кэш не критичен */ }
      return value;
    }
    return entry ? entry.value : null;
  });
}

// ------------------------------------------------------------- снимок -------

async function buildSnapshot() {
  const started = Date.now();
  const agent = collectAgent();

  let balance = null;
  let rates = null;
  if (!skipBalance) {
    balance = await withCache('balance', 5 * 60_000, fetchBalance);
    rates = await withCache('rates', 12 * 60 * 60_000, fetchRates);
  }

  const walletRub = {};
  let rub = 0;
  let rubKnown = true;
  if (balance && rates && rates.rates) {
    for (const wallet of balance.wallets) {
      const rate = rates.rates[wallet.currency];
      if (!Number.isFinite(rate)) {
        if (wallet.total > 0) rubKnown = false;
        walletRub[wallet.currency] = null;
        continue;
      }
      const value = wallet.total * rate;
      walletRub[wallet.currency] = round(value, 2);
      rub += value;
    }
  } else {
    rubKnown = false;
  }

  const rubValue = rubKnown && balance && rates ? round(rub, 2) : null;
  // В снимок попадают только валюты, которые умеет показать панель: полный
  // список ЦБ — это шесть десятков строк, из которых нужны четыре.
  const shownCurrencies = ['CNY', 'USD', 'EUR'];
  const converted = {};
  if (rubValue !== null && rates && rates.rates) {
    for (const code of shownCurrencies) {
      const rate = rates.rates[code];
      if (Number.isFinite(rate) && rate > 0) converted[code] = round(rubValue / rate, 2);
    }
  }

  return {
    schemaVersion: 1,
    updatedAt: Date.now(),
    collector: {
      version: VERSION,
      tookMs: Date.now() - started,
      warnings: [...new Set(warnings)],
    },
    agent: {
      dshRunning: agent.dshRunning,
      status: agent.status,
      sessions: agent.sessions,
    },
    today: agent.today,
    balance: {
      available: balance ? balance.available : null,
      at: balance ? balance.at : null,
      wallets: balance ? balance.wallets : [],
      rub: rubValue,
      walletRub,
      rates: rates ? rates.rates : {},
      ratesAt: rates ? rates.at : null,
      ratesDate: rates ? rates.date : null,
      ratesSource: rates ? rates.source : null,
      converted,
    },
  };
}

// ------------------------------------------------------------------ вывод ----

function emit(snapshot) {
  const json = JSON.stringify(snapshot, null, toStdout ? 0 : 2);
  if (toStdout) {
    process.stdout.write(json + '\n');
    return;
  }
  try {
    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    const tmp = `${outPath}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, json);
    fs.renameSync(tmp, outPath);
  } catch (error) {
    process.stderr.write(`не удалось записать ${outPath}: ${error.message}\n`);
    process.exitCode = 1;
  }
}

if (typeof zlib.zstdDecompressSync !== 'function') {
  process.stderr.write(
    `Node ${process.version} не умеет zstd. Нужен Node 22.15+ (или 23+): обновите Node.\n`
  );
  process.exit(2);
}

buildSnapshot()
  .then((snapshot) => emit(snapshot))
  .catch((error) => {
    process.stderr.write(`collector error: ${error?.stack || error}\n`);
    process.exit(1);
  });
