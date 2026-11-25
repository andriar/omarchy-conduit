.pragma library

// Pure logic for the VPN list: parsing the `nmcli` output of the refresh script,
// deciding what to notify and what to auto-connect, and escaping text for
// notifications. No QML objects in here, so it runs under plain `node` in
// tests/model.test.js.

// Output of the refresh script. List lines are "UUID:NAME:TYPE": a UUID never
// holds a colon, the type never does either, but the name can (nmcli writes "\:").
// After a "---" line come "NET:<count>", "INFO:<uuid>:<ip>:<since>" and
// "<uuid>:<nmcli state>" lines.
function parse(text) {
  var lines = String(text).split("\n")
  var known = []
  var active = {}
  var inActive = false
  var netCount = 0
  var infos = {}
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "---") { inActive = true; continue }
    if (line === "") continue
    var first = line.indexOf(":")
    if (first < 0) continue
    if (inActive) {
      var tag = line.substring(0, first)
      if (tag === "NET") {
        netCount = parseInt(line.substring(first + 1)) || 0
      } else if (tag === "INFO") {
        var p = line.substring(first + 1).split(":")
        infos[p[0]] = { ip: p[1] || "", ts: parseInt(p[2]) || 0 }
      } else {
        active[tag] = line.substring(first + 1)
      }
    } else {
      var last = line.lastIndexOf(":")
      if (last <= first) continue
      known.push({
        uuid: line.substring(0, first),
        name: line.substring(first + 1, last).replace(/\\:/g, ":"),
        type: line.substring(last + 1)
      })
    }
  }
  var counts = {}
  for (var c = 0; c < known.length; c++) counts[known[c].name] = (counts[known[c].name] || 0) + 1
  known.sort(function(a, b) {
    var x = a.name.toLowerCase(), y = b.name.toLowerCase()
    return x < y ? -1 : (x > y ? 1 : (a.uuid < b.uuid ? -1 : 1))
  })
  var vpns = []
  for (var j = 0; j < known.length; j++) {
    var v = known[j]
    var st = "down"
    if (active[v.uuid] !== undefined) st = active[v.uuid] === "activated" ? "up" : "connecting"
    vpns.push({ uuid: v.uuid, name: v.name, type: v.type, state: st, dupe: counts[v.name] > 1 })
  }
  return { vpns: vpns, info: infos, netUp: netCount > 0 }
}

// Runs after every refresh. `st` holds the memory between refreshes and is
// updated in place: { prevState, manualDown, autoFailed, autoFails, autoTried }
// (uuid -> value). `ctx` is { autoUuids, busyUuid, netUp, actionRunning }.
// Returns { drops: [{uuid, name, auto}], connect: uuid | "" }: who dropped by
// itself (tell the user) and which one to connect now (at most one, since only
// one action runs at a time). A VPN the user switched off stays off, a failed
// login is not retried, and a try is made at most every 30 s.
function evaluate(list, st, ctx, now) {
  var drops = []
  var connect = ""
  var busy = ctx.actionRunning === true
  for (var i = 0; i < list.length; i++) {
    var v = list[i]
    var prev = st.prevState[v.uuid]
    var isAuto = (ctx.autoUuids || []).indexOf(v.uuid) >= 0
    if (v.state === "up") {
      st.manualDown[v.uuid] = false
      st.autoFailed[v.uuid] = false
      st.autoFails[v.uuid] = 0
    }
    if (prev === "up" && v.state === "down" && !st.manualDown[v.uuid] && ctx.busyUuid !== v.uuid)
      drops.push({ uuid: v.uuid, name: v.name, auto: isAuto })
    st.prevState[v.uuid] = v.state
    if (isAuto && v.state === "down" && ctx.netUp && !st.manualDown[v.uuid]
        && !st.autoFailed[v.uuid] && !busy && now - (st.autoTried[v.uuid] || 0) > 30000) {
      st.autoTried[v.uuid] = now
      connect = v.uuid
      busy = true
    }
  }
  return { drops: drops, connect: connect }
}

// Names come from imported files, so they are untrusted: markup is escaped for
// notification daemons that render it.
function escapeMarkup(x) {
  return String(x).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// The notify-send command line. "--" stops a name that starts with "-" being
// read as an option.
function notifyCommand(summary, body, critical) {
  var cmd = ["notify-send"]
  if (critical) cmd.push("-u", "critical")
  cmd.push("--", escapeMarkup(summary), escapeMarkup(body))
  return cmd
}
