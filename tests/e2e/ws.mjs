// Minimal obs-websocket v5 client for the local test OBS (127.0.0.1:4466, no auth).
// Usage: node ws.mjs RequestType [base64 of UTF-8 JSON request data]
const [type, data] = process.argv.slice(2);
const ws = new WebSocket('ws://127.0.0.1:4466');
const timer = setTimeout(() => { console.error('timeout'); process.exit(2); }, 10000);
ws.onmessage = (event) => {
	const msg = JSON.parse(event.data);
	if (msg.op === 0) {
		ws.send(JSON.stringify({ op: 1, d: { rpcVersion: 1, eventSubscriptions: 0 } }));
	} else if (msg.op === 2) {
		const requestData = data ? JSON.parse(Buffer.from(data, 'base64').toString('utf8')) : undefined;
		ws.send(JSON.stringify({ op: 6, d: { requestType: type, requestId: '1', requestData } }));
	} else if (msg.op === 7) {
		clearTimeout(timer);
		console.log(JSON.stringify({ ok: msg.d.requestStatus.result, code: msg.d.requestStatus.code, comment: msg.d.requestStatus.comment, data: msg.d.responseData }));
		ws.close();
		process.exit(msg.d.requestStatus.result ? 0 : 1);
	}
};
ws.onerror = (e) => { console.error('ws error', e.message ?? e); process.exit(3); };
