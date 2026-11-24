// Tiny local RTMP sink for testing OBS streaming: accepts publishers on 127.0.0.1:19350
// and writes the received audio/video into an FLV file per connection.
// Usage: node rtmp-sink.mjs <output-dir>
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';

const outDir = process.argv[2] ?? '.';
let connectionCount = 0;

function amfEncode(values) {
	const parts = [];
	const enc = (v) => {
		if (v === null) parts.push(Buffer.from([0x05]));
		else if (typeof v === 'number') { const b = Buffer.alloc(9); b[0] = 0; b.writeDoubleBE(v, 1); parts.push(b); }
		else if (typeof v === 'string') { const s = Buffer.from(v, 'utf8'); const h = Buffer.alloc(3); h[0] = 2; h.writeUInt16BE(s.length, 1); parts.push(h, s); }
		else if (typeof v === 'boolean') parts.push(Buffer.from([0x01, v ? 1 : 0]));
		else if (typeof v === 'object') {
			parts.push(Buffer.from([0x03]));
			for (const [k, val] of Object.entries(v)) { const kb = Buffer.from(k, 'utf8'); const kh = Buffer.alloc(2); kh.writeUInt16BE(kb.length); parts.push(kh, kb); enc(val); }
			parts.push(Buffer.from([0, 0, 9]));
		}
	};
	values.forEach(enc);
	return Buffer.concat(parts);
}

function amfDecodeHead(buf) {
	if (buf[0] !== 2) return { name: '', txid: 0 };
	const len = buf.readUInt16BE(1);
	const name = buf.toString('utf8', 3, 3 + len);
	const o = 3 + len;
	const txid = buf[o] === 0 ? buf.readDoubleBE(o + 1) : 0;
	return { name, txid };
}

function chunkMessage(csid, type, streamId, payload) {
	const out = [];
	const size = 4096;
	for (let off = 0; off < payload.length || off === 0; off += size) {
		const piece = payload.subarray(off, off + size);
		if (off === 0) {
			const h = Buffer.alloc(12);
			h[0] = csid & 0x3f;
			h.writeUIntBE(payload.length, 4, 3);
			h[7] = type;
			h.writeUInt32LE(streamId, 8);
			out.push(h, piece);
		} else out.push(Buffer.from([0xc0 | (csid & 0x3f)]), piece);
		if (payload.length === 0) break;
	}
	return Buffer.concat(out);
}

const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };

net.createServer((sock) => {
	const id = ++connectionCount;
	const file = path.join(outDir, `stream-${Date.now()}-${id}.flv`);
	const flv = fs.openSync(file, 'w');
	fs.writeSync(flv, Buffer.from([0x46, 0x4c, 0x56, 1, 5, 0, 0, 0, 9, 0, 0, 0, 0]));
	console.log(`connection ${id} -> ${file}`);
	let buf = Buffer.alloc(0);
	let stage = 0;
	let inChunk = 128;
	const streams = new Map();
	let bytes = 0, videoTags = 0, audioTags = 0;
	const send = (b) => sock.write(b);
	const writeTag = (type, ts, data) => {
		const h = Buffer.alloc(11);
		h[0] = type;
		h.writeUIntBE(data.length, 1, 3);
		h.writeUIntBE(ts & 0xffffff, 4, 3);
		h[7] = (ts >>> 24) & 0xff;
		fs.writeSync(flv, Buffer.concat([h, data, u32(data.length + 11)]));
	};
	const onMessage = (m) => {
		if (m.type === 1) inChunk = m.payload.readUInt32BE(0) & 0x7fffffff;
		else if (m.type === 20) {
			const { name, txid } = amfDecodeHead(m.payload);
			if (name === 'connect') {
				send(chunkMessage(2, 5, 0, u32(2500000)));
				send(chunkMessage(2, 1, 0, u32(4096)));
				send(chunkMessage(3, 20, 0, amfEncode(['_result', txid, { fmsVer: 'FMS/3,0,1,123', capabilities: 31 }, { level: 'status', code: 'NetConnection.Connect.Success', description: 'ok', objectEncoding: 0 }])));
			} else if (name === 'createStream') {
				send(chunkMessage(3, 20, 0, amfEncode(['_result', txid, null, 1])));
			} else if (name === 'releaseStream' || name === 'FCPublish') {
				send(chunkMessage(3, 20, 0, amfEncode(['_result', txid, null, null])));
			} else if (name === 'publish') {
				send(chunkMessage(5, 20, 1, amfEncode(['onStatus', 0, null, { level: 'status', code: 'NetStream.Publish.Start', description: 'publishing' }])));
			}
		} else if (m.type === 8 || m.type === 9 || m.type === 18) {
			if (m.type === 9) videoTags++;
			if (m.type === 8) audioTags++;
			writeTag(m.type, m.ts, m.payload);
		}
	};
	const parse = () => {
		for (;;) {
			if (stage === 0) {
				if (buf.length < 1537) return;
				send(Buffer.concat([Buffer.from([3]), Buffer.alloc(1536), buf.subarray(1, 1537)]));
				buf = buf.subarray(1537); stage = 1; continue;
			}
			if (stage === 1) { if (buf.length < 1536) return; buf = buf.subarray(1536); stage = 2; continue; }
			if (buf.length < 1) return;
			const fmt = buf[0] >> 6;
			let csid = buf[0] & 0x3f, o = 1;
			if (csid === 0) { if (buf.length < 2) return; csid = 64 + buf[1]; o = 2; }
			else if (csid === 1) { if (buf.length < 3) return; csid = 64 + buf[1] + buf[2] * 256; o = 3; }
			const hl = [11, 7, 3, 0][fmt];
			if (buf.length < o + hl) return;
			const st = streams.get(csid) ?? { ts: 0, delta: 0, len: 0, type: 0, parts: [], got: 0, ext: false };
			let tsField = 0;
			if (fmt <= 2) tsField = buf.readUIntBE(o, 3);
			if (fmt <= 1) { st.len = buf.readUIntBE(o + 3, 3); st.type = buf[o + 6]; }
			o += hl;
			const ext = fmt <= 2 ? tsField === 0xffffff : st.ext;
			if (ext) { if (buf.length < o + 4) return; tsField = buf.readUInt32BE(o); o += 4; }
			const starting = st.got === 0;
			const need = Math.min(inChunk, st.len - st.got);
			if (buf.length < o + need) return;
			if (fmt <= 2) st.ext = ext;
			if (starting) {
				if (fmt === 0) st.ts = tsField;
				else if (fmt <= 2) { st.delta = tsField; st.ts += tsField; }
				else st.ts += st.delta;
			}
			st.parts.push(buf.subarray(o, o + need));
			st.got += need;
			buf = buf.subarray(o + need);
			streams.set(csid, st);
			if (st.got >= st.len) {
				const payload = Buffer.concat(st.parts);
				st.parts = []; st.got = 0;
				onMessage({ type: st.type, ts: st.ts, payload });
			}
		}
	};
	sock.on('data', (d) => { bytes += d.length; buf = Buffer.concat([buf, d]); try { parse(); } catch (e) { console.error('parse error', e); sock.destroy(); } });
	sock.on('close', () => { fs.closeSync(flv); console.log(`connection ${id} closed: ${bytes} bytes, video ${videoTags}, audio ${audioTags}`); });
	sock.on('error', () => {});
}).listen(19350, '127.0.0.1', () => console.log('rtmp sink listening on 127.0.0.1:19350'));
