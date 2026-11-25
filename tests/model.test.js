// Run with: node tests/model.test.js
const fs = require("fs");
const path = require("path");
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const M = new Function(src + "\nreturn { parse, evaluate, escapeMarkup, notifyCommand };")();

let pass = 0, fail = 0;
const eq = (a, b, m) => { const ok = JSON.stringify(a) === JSON.stringify(b); ok ? pass++ : fail++; console.log((ok ? "PASS " : "FAIL ") + m + (ok ? "" : `  got ${JSON.stringify(a)} want ${JSON.stringify(b)}`)); };

// ---- parse ----
const U1 = "11111111-1111-1111-1111-111111111111", U2 = "22222222-2222-2222-2222-222222222222", U3 = "33333333-3333-3333-3333-333333333333";
let r = M.parse(`${U1}:Work:vpn\n${U2}:home wg:wireguard\n---\nNET:1\n`);
eq(r.vpns.map(v => [v.name, v.type, v.state]), [["home wg", "wireguard", "down"], ["Work", "vpn", "down"]], "sorted by name, all down");
eq(r.netUp, true, "net up");
r = M.parse(`${U1}:Work:vpn\n---\nNET:0\n`);
eq(r.netUp, false, "net down");
eq(M.parse("").vpns, [], "empty input");
eq(M.parse("garbage\n:\n---\n").vpns, [], "garbage lines ignored");
r = M.parse(`${U1}:Office\\: HQ:vpn\n---\nNET:1\n`);
eq(r.vpns[0].name, "Office: HQ", "escaped colon in name");
r = M.parse(`${U1}:A:vpn\n${U2}:B:vpn\n${U3}:C:wireguard\n---\n${U1}:activated\n${U2}:activating\nNET:1\nINFO:${U1}:10.0.0.2:1700000000\n`);
eq(r.vpns.map(v => v.state), ["up", "connecting", "down"], "up / connecting / down");
eq(r.info[U1], { ip: "10.0.0.2", ts: 1700000000 }, "info parsed");
eq(r.info[U2], undefined, "no info for others");
r = M.parse(`${U1}:Dup:vpn\n${U2}:dup:vpn\n${U3}:Dup:vpn\n---\n`);
eq(r.vpns.map(v => [v.name, v.uuid, v.dupe]), [["Dup", U1, true], ["dup", U2, false], ["Dup", U3, true]], "dupe flag is per exact name; ties sort by uuid");
r = M.parse(`${U2}:same:vpn\n${U1}:same:vpn\n---\n`);
eq(r.vpns.map(v => v.uuid), [U1, U2], "same name sorts by uuid");
r = M.parse(`${U1}:x:vpn\n---\nINFO:${U1}\nNET:abc\n`);
eq(r.info[U1], { ip: "", ts: 0 }, "short INFO tolerated");
eq(r.netUp, false, "non-numeric NET is 0");
r = M.parse(`${U1}:x:vpn\r\n---\n`);
eq(r.vpns.length, 1, "CRLF does not crash");

// ---- evaluate ----
const fresh = () => ({ prevState: {}, manualDown: {}, autoFailed: {}, autoFails: {}, autoTried: {} });
const ctx = (o) => Object.assign({ autoUuids: [], busyUuid: "", netUp: true, actionRunning: false }, o);
const vp = (uuid, state, name) => ({ uuid, name: name || uuid, type: "vpn", state, dupe: false });
let st = fresh();
let e = M.evaluate([vp(U1, "up")], st, ctx(), 1000);
eq(e, { drops: [], connect: "" }, "up: nothing to do");
e = M.evaluate([vp(U1, "down", "Work")], st, ctx(), 2000);
eq(e.drops, [{ uuid: U1, name: "Work", auto: false }], "drop after up is reported");
e = M.evaluate([vp(U1, "down", "Work")], st, ctx(), 3000);
eq(e.drops, [], "drop reported once");

st = fresh(); M.evaluate([vp(U1, "up")], st, ctx(), 1);
st.manualDown[U1] = true;
e = M.evaluate([vp(U1, "down")], st, ctx({ autoUuids: [U1] }), 100000);
eq(e, { drops: [], connect: "" }, "manual down: no drop, no auto-connect");

st = fresh(); M.evaluate([vp(U1, "up")], st, ctx(), 1);
e = M.evaluate([vp(U1, "down")], st, ctx({ busyUuid: U1 }), 2);
eq(e.drops, [], "busy uuid: no drop notice");

st = fresh(); M.evaluate([vp(U1, "up")], st, ctx({ autoUuids: [U1] }), 1);
e = M.evaluate([vp(U1, "down", "W")], st, ctx({ autoUuids: [U1] }), 100000);
eq(e, { drops: [{ uuid: U1, name: "W", auto: true }], connect: U1 }, "auto vpn drops: notice (auto) and reconnect");
e = M.evaluate([vp(U1, "down")], st, ctx({ autoUuids: [U1] }), 100000 + 29000);
eq(e.connect, "", "no retry within 30 s");
e = M.evaluate([vp(U1, "down")], st, ctx({ autoUuids: [U1] }), 100000 + 30001);
eq(e.connect, U1, "retry after 30 s");

st = fresh();
eq(M.evaluate([vp(U1, "down")], st, ctx({ autoUuids: [U1], netUp: false }), 100000).connect, "", "no connect without network");
eq(M.evaluate([vp(U1, "down")], st, ctx({ autoUuids: [U1], actionRunning: true }), 100000).connect, "", "no connect while an action runs");
eq(M.evaluate([vp(U1, "down")], st, ctx({ autoUuids: [] }), 100000).connect, "", "not marked auto: no connect");
eq(M.evaluate([vp(U1, "connecting")], st, ctx({ autoUuids: [U1] }), 100000).connect, "", "connecting: no connect");
st.autoFailed[U1] = true;
eq(M.evaluate([vp(U1, "down")], st, ctx({ autoUuids: [U1] }), 100000).connect, "", "failed login: not retried");
M.evaluate([vp(U1, "up")], st, ctx(), 200000);
eq([st.autoFailed[U1], st.autoFails[U1], st.manualDown[U1]], [false, 0, false], "coming up clears failure memory");

st = fresh();
e = M.evaluate([vp(U1, "down"), vp(U2, "down")], st, ctx({ autoUuids: [U1, U2] }), 100000);
eq(e.connect, U1, "only one auto-connect per round");
e = M.evaluate([vp(U1, "down"), vp(U2, "down")], st, ctx({ autoUuids: [U1, U2] }), 100001);
eq(e.connect, U2, "next round takes the other one (first is within 30 s)");

// ---- notifications ----
eq(M.escapeMarkup("a & <b>"), "a &amp; &lt;b&gt;", "markup escaped");
eq(M.escapeMarkup("&lt;"), "&amp;lt;", "ampersand first, no double decoding");
eq(M.notifyCommand("VPN", "x", false), ["notify-send", "--", "VPN", "x"], "plain command");
eq(M.notifyCommand("t", "-oops <img>", true), ["notify-send", "-u", "critical", "--", "t", "-oops &lt;img&gt;"], "critical, leading dash safe, markup escaped");

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
