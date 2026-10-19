// Doubao SAUC v1 binary framing. No websocket or local-model dependency here.
import { gzipSync, gunzipSync } from 'node:zlib';

export const MAX_PACKET_BYTES = 4 * 1024 * 1024;
export const MAX_PAYLOAD_BYTES = 8 * 1024 * 1024;
export class ProtocolError extends Error {
  constructor(message = 'Invalid ASR protocol response') { super(message); this.name = 'ProtocolError'; }
}

function encode(type, sequence, payload, last = false) {
  if (!Number.isInteger(sequence) || sequence < 1 || sequence > 0x7fffffff) throw new ProtocolError('Invalid packet sequence');
  const compressed = gzipSync(payload);
  if (compressed.length > MAX_PACKET_BYTES - 12) throw new ProtocolError('ASR packet too large');
  const packet = Buffer.allocUnsafe(12 + compressed.length);
  // Official sample uses JSON serialization nibble for both init and audio.
  packet.set([0x11, (type << 4) | (last ? 3 : 1), 0x11, 0], 0);
  packet.writeInt32BE(last ? -sequence : sequence, 4);
  packet.writeUInt32BE(compressed.length, 8);
  compressed.copy(packet, 12);
  return packet;
}
export function encodeInit(sequence, payload) {
  return encode(1, sequence, Buffer.from(JSON.stringify(payload), 'utf8'));
}
export function encodeAudio(sequence, pcm, last = false) {
  if (!Buffer.isBuffer(pcm) || pcm.length % 2) throw new ProtocolError('Audio must contain PCM16 samples');
  return encode(2, sequence, pcm, last);
}

export function parseResponse(input) {
  const packet = Buffer.isBuffer(input) ? input : Buffer.from(input);
  const invalid = () => { throw new ProtocolError(); };
  if (packet.length < 4 || packet.length > MAX_PACKET_BYTES) invalid();
  const version = packet[0] >> 4, headerBytes = (packet[0] & 15) * 4;
  const type = packet[1] >> 4, flags = packet[1] & 15;
  const serialization = packet[2] >> 4, compression = packet[2] & 15;
  if (version !== 1 || headerBytes < 4 || headerBytes > packet.length || ![9, 15].includes(type) ||
      (flags & 8) || ![0, 1].includes(serialization) || ![0, 1].includes(compression)) invalid();
  let offset = headerBytes;
  const read = (signed = false) => {
    if (offset + 4 > packet.length) invalid();
    const value = signed ? packet.readInt32BE(offset) : packet.readUInt32BE(offset);
    offset += 4; return value;
  };
  const sequence = flags & 1 ? read(true) : null;
  const event = flags & 4 ? read() : null;
  const code = type === 15 ? read(true) : 0;
  const size = read();
  if (size !== packet.length - offset) invalid();
  let payload = packet.subarray(offset);
  if (payload.length && compression === 1) {
    try { payload = gunzipSync(payload, { maxOutputLength: MAX_PAYLOAD_BYTES }); }
    catch { invalid(); }
  }
  if (payload.length > MAX_PAYLOAD_BYTES) invalid();
  let body = null;
  if (payload.length) {
    if (serialization === 1) {
      try { body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(payload)); }
      catch { invalid(); }
      if (body === null || typeof body !== 'object' || Array.isArray(body)) invalid();
    } else if (type !== 15) invalid();
    // Raw server error strings are deliberately never surfaced or logged.
  }
  return { type, sequence, event, code, isLast: Boolean(flags & 2), body };
}

export function normalizeResult(body, final = false) {
  const result = body?.result;
  const results = Array.isArray(result) ? result : result && typeof result === 'object' ? [result] : [];
  const segments = [];
  const texts = [];
  const time = value => Number.isFinite(value) && value >= 0 ? value : 0;
  for (const r of results) {
    if (typeof r?.text === 'string') texts.push(r.text);
    if (!Array.isArray(r?.utterances)) continue;
    for (const u of r.utterances) {
      if (!u || typeof u.text !== 'string') continue;
      segments.push({ text: u.text, start: time(u.start_time), end: time(u.end_time), definite: final || u.definite === true });
    }
  }
  return { text: texts.join('') || segments.map(s => s.text).join(''), segments };
}

const BOOLEAN_OPTIONS = ['enable_nonstream', 'enable_itn', 'enable_punc', 'enable_ddc', 'show_utterances',
  'enable_speaker_info', 'enable_accelerate_text', 'enable_lid', 'show_speech_rate', 'show_volume'];
export function buildPayload(mode, options = {}) {
  if (!['sentence', 'realtime'].includes(mode) || !options || typeof options !== 'object' || Array.isArray(options)) {
    throw new ProtocolError('Invalid ASR options');
  }
  const request = { model_name: 'bigmodel', enable_itn: true, enable_punc: true, enable_ddc: false,
    show_utterances: true, result_type: 'full', end_window_size: 800 };
  if (mode === 'realtime') request.enable_nonstream = true;
  for (const key of BOOLEAN_OPTIONS) {
    if (options[key] !== undefined) {
      if (typeof options[key] !== 'boolean') throw new ProtocolError('Invalid ASR options');
      if (key !== 'enable_nonstream' || mode === 'realtime') request[key] = options[key];
    }
  }
  for (const [key, min, max] of [['end_window_size', 300, 5000], ['force_to_speech_time', 0, 10000],
    ['vad_segment_duration', 1, 60000], ['accelerate_score', 0, 100]]) {
    if (options[key] !== undefined) {
      if (!Number.isInteger(options[key]) || options[key] < min || options[key] > max) throw new ProtocolError('Invalid ASR options');
      request[key] = options[key];
    }
  }
  if (options.result_type !== undefined && options.result_type !== 'full') {
    throw new ProtocolError('Worker requires full ASR results');
  }
  const audio = { format: 'pcm', codec: 'raw', rate: 16000, bits: 16, channel: 1 };
  if (options.language !== undefined && options.language !== '' && options.language !== 'auto') {
    if (typeof options.language !== 'string' || options.language.length > 16) throw new ProtocolError('Invalid ASR language');
    if (mode === 'sentence') audio.language = options.language;
    else throw new ProtocolError('Explicit language is supported only in sentence mode');
  }
  if (options.hotwords !== undefined) {
    const words = typeof options.hotwords === 'string' ? options.hotwords.split(/[,，、\n]/) : options.hotwords;
    if (!Array.isArray(words) || words.some(w => typeof w !== 'string')) throw new ProtocolError('Invalid ASR hotwords');
    const hotwords = words.map(w => w.trim()).filter(Boolean).map(word => ({ word }));
    if (JSON.stringify(hotwords).length > 32000) throw new ProtocolError('ASR hotwords too large');
    if (hotwords.length) request.corpus = { context: JSON.stringify({ hotwords }) };
  }
  return { user: { uid: 'voice-typer' }, audio, request };
}

// Strict native RIFF/WAVE reader: no conversion, no ffmpeg, no fixed 44-byte offset.
export function parsePcmWav(input) {
  const b = Buffer.isBuffer(input) ? input : Buffer.from(input);
  if (b.length < 12 || b.toString('ascii', 0, 4) !== 'RIFF' || b.toString('ascii', 8, 12) !== 'WAVE') {
    throw new ProtocolError('Expected PCM16 mono 16000 Hz WAV');
  }
  const end = b.readUInt32LE(4) + 8;
  if (end > b.length || end < 12) throw new ProtocolError('Truncated WAV');
  let format = false, data = null;
  for (let at = 12; at < end;) {
    if (at + 8 > end) throw new ProtocolError('Truncated WAV chunk');
    const name = b.toString('ascii', at, at + 4), size = b.readUInt32LE(at + 4), start = at + 8;
    if (size > end - start) throw new ProtocolError('Truncated WAV chunk');
    if (name === 'fmt ') {
      if (size < 16 || b.readUInt16LE(start) !== 1 || b.readUInt16LE(start + 2) !== 1 ||
          b.readUInt32LE(start + 4) !== 16000 || b.readUInt32LE(start + 8) !== 32000 ||
          b.readUInt16LE(start + 12) !== 2 || b.readUInt16LE(start + 14) !== 16) {
        throw new ProtocolError('Expected PCM16 mono 16000 Hz WAV');
      }
      format = true;
    } else if (name === 'data') {
      if (data) throw new ProtocolError('Multiple WAV data chunks are unsupported');
      data = b.subarray(start, start + size);
    }
    at = start + size + (size & 1);
    if (at > end) throw new ProtocolError('Truncated WAV padding');
  }
  if (!format || !data?.length || data.length % 2) throw new ProtocolError('Missing PCM16 WAV audio');
  return data;
}
