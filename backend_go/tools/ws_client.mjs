// Minimal realtime client for testing (Node 22+, no dependencies).
//
//   node tools/ws_client.mjs <ws-url> <access-token> [room_id ...]
//   node tools/ws_client.mjs ws://localhost:8080/v1/ws "$(JWT_SECRET=... go run ./cmd/devtoken -user 5)" 12
//
// It sends the auth frame, subscribes to the given rooms, pings every 25 s and prints every event.
// Try it in two terminals (two users), then send a chat message / gift / seat request over REST.
const [url, token, ...rooms] = process.argv.slice(2);
if (!url || !token) { console.error('usage: node tools/ws_client.mjs <ws-url> <token> [room_id ...]'); process.exit(2); }

const ws = new WebSocket(url);
const send = (o) => ws.send(JSON.stringify(o));
let ping;
ws.onopen = () => { send({ op: 'auth', token }); ping = setInterval(() => send({ op: 'ping' }), 25000); };
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  console.log(new Date().toISOString().slice(11, 23), JSON.stringify(m));
  if (m.type === 'ready') for (const r of rooms) send({ op: 'subscribe_room', room_id: Number(r) });
  if (m.type === 'resync') console.log('   ^ events may have been missed: reload room snapshot / inbox / messages?after_id=');
};
ws.onclose = (e) => { clearInterval(ping); console.log('closed', e.code, e.reason); process.exit(0); };
ws.onerror = () => console.error('connection error');
