import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// VPN manager for the bar. Lists every VPN / WireGuard connection that
// NetworkManager knows about. Everything is addressed by UUID, because
// NetworkManager happily allows several connections with the same name.
//
//   bar icon, left click  : open the list
//   bar icon, right click : quick toggle (the VPN that is up, else the preferred one)
//   row: gear   : saved username / password, split tunnel, delete
//   row: key    : connect in a terminal and ask for password / OTP
//   row: trash  : delete (asks to confirm)
//   header: +   : import a .ovpn / .conf file
Panel {
  id: root
  moduleName: "conduit.vpn"
  ipcTarget: "conduit.vpn"

  // Optional: which VPN the right-click shortcut should use when none is up.
  readonly property string preferredName: String(setting("connectionName", ""))
  readonly property int refreshSec: Math.max(1, Number(setting("refreshIntervalSec", 3)))

  // [{ uuid, name, type, state: "up" | "connecting" | "down", dupe: bool }]
  property var vpns: []
  property string busyUuid: ""
  property int cursorIndex: 0
  property bool cursorActive: false

  // "list" | "config" | "add"
  property string view: "list"
  property string configUuid: ""
  property string configName: ""
  property bool splitTunnel: true
  property bool hasSavedPassword: false
  property bool configLoading: false
  property bool configSaving: false
  property bool confirmDelete: false

  // "Save & Connect": connect (or reconnect) once the settings are saved.
  property bool connectAfterSave: false

  property bool importing: false
  property string statusText: ""
  property bool statusError: false

  // Reopen the popup on a given view (the file dialog closes it).
  property string pendingView: ""
  property string pendingUuid: ""
  property string pendingName: ""
  property string pendingLoad: ""
  property int loadTries: 0

  // Automation: VPNs that should connect by themselves (kept in a small state file),
  // plus what is needed to notice a dropped connection or a user-made disconnect.
  property var autoUuids: []
  property var prevState: ({})
  property var manualDown: ({})
  property var autoTried: ({})
  property var autoFailed: ({})
  property bool actionAuto: false
  property bool netUp: false
  property var info: ({})          // uuid -> { ip, ts } for connected VPNs
  property double nowMs: 0

  // Extra settings in the settings view.
  property bool useVpnDns: true
  property bool autoConnect: false
  property string otpUuid: ""
  property string otpName: ""

  readonly property Item importFieldItem: panel.loadedContent ? panel.loadedContent.importField : null
  readonly property Item userFieldItem: panel.loadedContent ? panel.loadedContent.userField : null
  readonly property Item passFieldItem: panel.loadedContent ? panel.loadedContent.passField : null
  readonly property Item nameFieldItem: panel.loadedContent ? panel.loadedContent.nameField : null
  readonly property Item otpFieldItem: panel.loadedContent ? panel.loadedContent.otpField : null

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var upNames: {
    var names = []
    for (var i = 0; i < vpns.length; i++) if (vpns[i].state === "up") names.push(vpns[i].name)
    return names
  }
  readonly property bool anyUp: upNames.length > 0
  readonly property bool anyConnecting: {
    for (var i = 0; i < vpns.length; i++) if (vpns[i].state === "connecting") return true
    return false
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Strings live in i18n/<language>.json and follow Setup > Language.
  readonly property string i18nDir: String(Qt.resolvedUrl("i18n")).replace(/^qs:\/\//, "")
  Commons.Translations { id: strings; directory: root.i18nDir }

  // ---- data ----------------------------------------------------------------

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  // `nmcli -t` lines. List lines are "UUID:NAME:TYPE": a UUID never holds a
  // colon, the type never does either, but the name can (nmcli writes "\:").
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
    var out = []
    for (var j = 0; j < known.length; j++) {
      var v = known[j]
      var st = "down"
      if (active[v.uuid] !== undefined) st = active[v.uuid] === "activated" ? "up" : "connecting"
      out.push({ uuid: v.uuid, name: v.name, type: v.type, state: st, dupe: counts[v.name] > 1 })
    }
    root.info = infos
    root.netUp = netCount > 0
    root.nowMs = Date.now()
    root.vpns = out
    if (root.cursorIndex >= out.length) root.cursorIndex = Math.max(0, out.length - 1)
    root.evaluate(out)
  }

  function isAuto(uuid) {
    return root.autoUuids.indexOf(uuid) >= 0
  }

  function setAuto(uuid, on) {
    var list = root.autoUuids.filter(function(u) { return u !== uuid })
    if (on) list.push(uuid)
    root.autoUuids = list
    autoSaveProc.environment = { "AUTO_LIST": list.join("\n") }
    autoSaveProc.running = true
  }

  // Runs after every refresh: tells the user when a VPN dropped by itself, and
  // connects VPNs marked "sambung otomatis" once the network is up. A VPN the
  // user switched off stays off, and a failed login is not retried in a loop.
  function evaluate(list) {
    var now = Date.now()
    for (var i = 0; i < list.length; i++) {
      var v = list[i]
      var prev = root.prevState[v.uuid]
      if (v.state === "up") {
        root.manualDown[v.uuid] = false
        root.autoFailed[v.uuid] = false
      }
      if (prev === "up" && v.state === "down" && !root.manualDown[v.uuid] && root.busyUuid !== v.uuid) {
        Quickshell.execDetached(["notify-send", "-u", "critical", strings.t("drop.title"),
          (root.isAuto(v.uuid) ? strings.t("drop.bodyAuto") : strings.t("drop.body")).arg(v.name)])
      }
      root.prevState[v.uuid] = v.state
      if (root.isAuto(v.uuid) && v.state === "down" && root.netUp && !root.manualDown[v.uuid]
          && !root.autoFailed[v.uuid] && !actionProc.running && now - (root.autoTried[v.uuid] || 0) > 30000) {
        root.autoTried[v.uuid] = now
        root.runAction(v.uuid, "up", true, "")
      }
    }
  }

  // "11 min", "1 h 05 m", "2 d 3 h" since the VPN came up (wording from the catalog).
  function uptimeText(uuid) {
    var inf = root.info[uuid]
    if (!inf || !inf.ts) return ""
    var s = Math.max(0, Math.floor(root.nowMs / 1000) - inf.ts)
    if (s < 60) return strings.t("time.justNow")
    var m = Math.floor(s / 60)
    if (m < 60) return strings.t("time.minutes").arg(m)
    var h = Math.floor(m / 60)
    m = m % 60
    if (h < 24) return strings.t("time.hoursMinutes").arg(h).arg((m < 10 ? "0" : "") + m)
    return strings.t("time.daysHours").arg(Math.floor(h / 24)).arg(h % 24)
  }

  function subtitleOf(v) {
    if (v.state === "up") {
      var inf = root.info[v.uuid]
      var parts = [root.stateLabel("up")]
      if (inf && inf.ip) parts.push(inf.ip)
      var up = root.uptimeText(v.uuid)
      if (up !== "") parts.push(up)
      return parts.join(" · ")
    }
    var base = root.typeLabel(v.type) + " · " + root.stateLabel(v.state)
    return v.dupe ? base + " · " + v.uuid.substring(0, 8) : base
  }

  function nameOf(uuid) {
    for (var i = 0; i < vpns.length; i++) if (vpns[i].uuid === uuid) return vpns[i].name
    return uuid
  }

  function stateLabel(state) {
    if (state === "up") return strings.t("state.connected")
    if (state === "connecting") return strings.t("state.connecting")
    return strings.t("state.disconnected")
  }

  function typeLabel(type) {
    return type === "wireguard" ? "WireGuard" : "OpenVPN"
  }

  function setStatus(text, isError) {
    root.statusText = text
    root.statusError = isError
  }

  // ---- connect / disconnect ------------------------------------------------

  // act: "up" | "down" | "reconnect" (down, then up again). `secret` is a
  // one-time password / OTP for this connection only; it is never stored.
  function runAction(uuid, act, isAuto, secret) {
    if (actionProc.running || !uuid) return
    root.actionAuto = isAuto === true
    if (!root.actionAuto) {
      root.autoFailed[uuid] = false
      root.manualDown[uuid] = act === "down"
    }
    root.busyUuid = uuid
    setStatus("", false)
    actionProc.environment = { "VPN_UUID": uuid, "VPN_ACT": act, "VPN_SECRET": secret || "" }
    actionProc.running = true
  }

  function toggleVpn(uuid, state) {
    runAction(uuid, state === "down" ? "up" : "down", false, "")
  }

  function stateOf(uuid) {
    for (var i = 0; i < vpns.length; i++) if (vpns[i].uuid === uuid) return vpns[i].state
    return "down"
  }

  // ---- one-time password / OTP ---------------------------------------------

  function openOtp(uuid, name) {
    root.otpUuid = uuid
    root.otpName = name
    setStatus("", false)
    root.view = "otp"
    if (otpFieldItem) otpFieldItem.text = ""
    Qt.callLater(function() { if (root.otpFieldItem) root.otpFieldItem.forceActiveFocus() })
  }

  function connectOtp() {
    if (!otpFieldItem) return
    var secret = otpFieldItem.text
    if (secret === "") {
      setStatus(strings.t("status.enterSecret"), true)
      return
    }
    otpFieldItem.text = ""
    var uuid = root.otpUuid
    closeConfig()
    runAction(uuid, "up", false, secret)
  }

  function quickToggle() {
    if (vpns.length === 0) { root.open(); return }
    for (var i = 0; i < vpns.length; i++)
      if (vpns[i].state !== "down") { toggleVpn(vpns[i].uuid, vpns[i].state); return }
    for (var j = 0; j < vpns.length; j++)
      if (vpns[j].name === preferredName) { toggleVpn(vpns[j].uuid, vpns[j].state); return }
    if (vpns.length === 1) toggleVpn(vpns[0].uuid, vpns[0].state)
    else root.open()
  }

  function activateCursor() {
    if (cursorIndex < 0 || cursorIndex >= vpns.length) return
    toggleVpn(vpns[cursorIndex].uuid, vpns[cursorIndex].state)
  }

  // ---- settings view -------------------------------------------------------

  function openConfig(uuid, name) {
    if (!uuid) return
    root.configUuid = uuid
    root.configName = name
    root.hasSavedPassword = false
    root.splitTunnel = true
    root.useVpnDns = true
    root.autoConnect = root.isAuto(uuid)
    root.configLoading = true
    root.confirmDelete = false
    root.view = "config"
    root.pendingLoad = uuid
    root.loadTries = 0
    tryLoad()
  }

  // The popup builds its content lazily, so right after a reopen the text fields
  // may not exist yet: wait for them before reading the saved settings.
  function tryLoad() {
    if (root.pendingLoad === "") return
    if (!userFieldItem || !passFieldItem || !nameFieldItem) {
      if (root.loadTries++ < 30) loadWait.restart()
      return
    }
    var uuid = root.pendingLoad
    root.pendingLoad = ""
    nameFieldItem.text = root.configName
    userFieldItem.text = ""
    passFieldItem.text = ""
    loadProc.command = [
      "bash", "-c",
      // Line 1: username, 2: never-default, 3: ignore-auto-dns, 4: whether a password is saved.
      // The password itself never leaves this shell.
      "nmcli -g vpn.user-name,ipv4.never-default,ipv4.ignore-auto-dns connection show uuid \"$1\"; " +
      "if [ -n \"$(nmcli -s -g vpn.secrets connection show uuid \"$1\" 2>/dev/null)\" ]; then echo saved; else echo none; fi",
      "_", uuid
    ]
    loadProc.running = true
    userFieldItem.forceActiveFocus()
  }

  function closeConfig() {
    root.view = "list"
    root.confirmDelete = false
    if (passFieldItem) passFieldItem.text = ""
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  function saveConfig(connectAfter) {
    if (saveProc.running || !userFieldItem || !passFieldItem || !nameFieldItem) return
    root.connectAfterSave = connectAfter === true
    root.configSaving = true
    var newName = String(nameFieldItem.text).trim()
    root.setAuto(root.configUuid, root.autoConnect)
    // Passed through the environment so nothing needs shell quoting.
    saveProc.environment = {
      "VPN_UUID": root.configUuid,
      "VPN_NEWNAME": newName !== root.configName ? newName : "",
      "VPN_IGNDNS": root.useVpnDns ? "no" : "yes",
      "VPN_USER": userFieldItem.text,
      "VPN_PASS": passFieldItem.text,
      "VPN_SPLIT": root.splitTunnel ? "yes" : "no"
    }
    saveProc.running = true
  }

  // ---- add -----------------------------------------------------------------

  function openAdd(keepStatus) {
    if (keepStatus !== true) setStatus("", false)
    root.view = "add"
    if (importFieldItem) importFieldItem.text = ""
    Qt.callLater(function() { if (root.importFieldItem) root.importFieldItem.forceActiveFocus() })
  }

  // The file dialog takes focus, which closes this popup. So picking a file
  // imports it right away, and the popup reopens on the new VPN's settings.
  function pickFile() {
    if (pickProc.running || importProc.running) return
    pickProc.running = true
  }

  function importVpn() {
    if (!importFieldItem) return
    var path = String(importFieldItem.text).trim()
    if (path === "") {
      setStatus(strings.t("status.enterPath"), true)
      return
    }
    importFile(path)
  }

  function importFile(path) {
    if (importProc.running) return
    if (path.indexOf("~/") === 0) path = Quickshell.env("HOME") + path.substring(1)
    setStatus(strings.t("status.importing").arg(path), false)
    root.importing = true
    importProc.environment = { "VPN_FILE": path }
    importProc.running = true
  }

  // ---- delete --------------------------------------------------------------

  function deleteVpn(uuid, name) {
    if (deleteProc.running || !uuid) return
    root.configName = name
    deleteProc.environment = { "VPN_UUID": uuid }
    deleteProc.running = true
  }

  function deleteFromConfig() {
    if (!root.confirmDelete) { root.confirmDelete = true; return }
    deleteVpn(root.configUuid, root.configName)
  }

  // ---- reopen on a view (after the file dialog) ----------------------------

  function resumeAt(targetView, uuid, name) {
    root.pendingView = targetView
    root.pendingUuid = uuid
    root.pendingName = name
    if (root.opened) applyPending()
    else root.open()
  }

  function applyPending() {
    var targetView = root.pendingView
    var uuid = root.pendingUuid
    var name = root.pendingName
    root.pendingView = ""
    root.pendingUuid = ""
    root.pendingName = ""
    if (targetView === "config") openConfig(uuid, name)
    else if (targetView === "add") openAdd(true)
    else if (targetView === "list") closeConfig()
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    view = "list"
    refresh()
    if (pendingView !== "") resumeTimer.restart()
    else {
      setStatus("", false)
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
    }
  }

  Timer {
    id: resumeTimer
    interval: 150
    onTriggered: root.applyPending()
  }

  Timer {
    id: loadWait
    interval: 100
    onTriggered: root.tryLoad()
  }

  // ---- processes -----------------------------------------------------------

  Process {
    id: listProc
    command: [
      "bash", "-c",
      "nmcli -t -f UUID,NAME,TYPE connection show | grep -E ':(vpn|wireguard)$'; echo '---'; " +
      "nmcli -t -f UUID,STATE connection show --active; " +
      // NET: how many non-VPN connections are up (is there a network at all).
      "echo \"NET:$(nmcli -t -f TYPE,STATE connection show --active | grep -v -E '^(vpn|wireguard|loopback|bridge|tun|dummy)' | grep -c ':activated')\"; " +
      // INFO: VPN address and activation time for each connected VPN.
      "for u in $(nmcli -t -f UUID,TYPE connection show --active | grep -E ':(vpn|wireguard)$' | cut -d: -f1); do " +
      "ip=$(nmcli -t -f IP4.ADDRESS connection show uuid \"$u\" 2>/dev/null | head -1 | cut -d: -f2 | cut -d/ -f1); " +
      "ts=$(nmcli -g connection.timestamp connection show uuid \"$u\" 2>/dev/null); " +
      "echo \"INFO:$u:$ip:$ts\"; done"
    ]
    stdout: StdioCollector {
      onStreamFinished: root.parse(text)
    }
  }

  Process {
    id: actionProc
    // On failure, also look for the server rejecting the login: nmcli itself
    // only says "activation failed", the reason is in the NetworkManager log.
    command: [
      "bash", "-c",
      "if [ \"$VPN_ACT\" = reconnect ]; then nmcli connection down uuid \"$VPN_UUID\" >/dev/null 2>&1; VPN_ACT=up; fi; " +
      // A one-time secret goes through a private temp file, never on a command line.
      "extra=''; f=''; if [ -n \"$VPN_SECRET\" ]; then f=$(mktemp -p \"${XDG_RUNTIME_DIR:-/tmp}\" vpn.XXXXXX); chmod 600 \"$f\"; " +
      "printf 'vpn.secrets.password:%s\\n' \"$VPN_SECRET\" > \"$f\"; unset VPN_SECRET; extra=\"passwd-file $f\"; fi; " +
      "out=$(nmcli connection \"$VPN_ACT\" uuid \"$VPN_UUID\" $extra 2>&1); rc=$?; [ -n \"$f\" ] && rm -f \"$f\"; " +
      "if [ $rc -ne 0 ]; then " +
      "if journalctl -u NetworkManager --since '-40s' --no-pager 2>/dev/null | grep -q AUTH_FAILED; then echo AUTH_FAILED; else printf '%s\\n' \"$out\"; fi; fi; exit $rc"
    ]
    stdout: StdioCollector {
      id: actionOut
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var uuid = root.busyUuid
      root.busyUuid = ""
      if (exitCode !== 0) {
        var out = String(actionOut.text).trim()
        var msg
        if (out === "AUTH_FAILED")
          msg = strings.t("err.authFailed").arg(root.nameOf(uuid))
        else if (out.indexOf("No valid secrets") >= 0)
          msg = strings.t("err.noSecret").arg(root.nameOf(uuid))
        else
          msg = strings.t("err.generic").arg(root.nameOf(uuid)).arg(out !== "" ? out.split("\n").pop().substring(0, 160) : strings.t("err.code").arg(exitCode))
        if (root.actionAuto) {
          // Do not retry a failed automatic connection in a loop.
          root.autoFailed[uuid] = true
          msg = strings.t("err.autoPrefix").arg(msg)
        }
        root.setStatus(msg, true)
        Quickshell.execDetached(["notify-send", "-u", "critical", "VPN", msg])
      }
      root.refresh()
    }
  }

  Process {
    id: loadProc
    stdout: StdioCollector {
      onStreamFinished: {
        var lines = String(text).split("\n")
        if (root.userFieldItem) root.userFieldItem.text = lines[0] || ""
        root.splitTunnel = (lines[1] || "").trim() === "yes"
        root.useVpnDns = (lines[2] || "").trim() !== "yes"
        root.hasSavedPassword = (lines[3] || "").trim() === "saved"
        root.configLoading = false
      }
    }
  }

  Process {
    id: saveProc
    command: [
      "bash", "-c",
      "set -e; " +
      "nmcli connection modify uuid \"$VPN_UUID\" vpn.user-name \"$VPN_USER\" ipv4.never-default \"$VPN_SPLIT\" ipv6.never-default \"$VPN_SPLIT\" " +
      "ipv4.ignore-auto-dns \"$VPN_IGNDNS\" ipv6.ignore-auto-dns \"$VPN_IGNDNS\"; " +
      "if [ -n \"$VPN_NEWNAME\" ]; then nmcli connection modify uuid \"$VPN_UUID\" connection.id \"$VPN_NEWNAME\"; fi; " +
      "if [ -n \"$VPN_PASS\" ]; then " +
      "nmcli connection modify uuid \"$VPN_UUID\" +vpn.data password-flags=0; " +
      "nmcli connection modify uuid \"$VPN_UUID\" vpn.secrets \"password=$VPN_PASS\"; fi"
    ]
    onExited: function(exitCode) {
      root.configSaving = false
      if (root.passFieldItem) root.passFieldItem.text = ""
      if (exitCode === 0) {
        var uuid = root.configUuid
        root.closeConfig()
        if (root.connectAfterSave) {
          // Already up: reconnect so the new login is used.
          root.runAction(uuid, root.stateOf(uuid) === "down" ? "up" : "reconnect")
        } else {
          Quickshell.execDetached(["notify-send", "VPN", strings.t("save.done").arg(root.configName)])
        }
      } else {
        Quickshell.execDetached(["notify-send", "-u", "critical", "VPN", strings.t("save.failed").arg(root.configName)])
      }
      root.refresh()
    }
  }

  // Which VPNs connect automatically is kept outside NetworkManager, in a
  // small state file (NetworkManager does not auto-start VPNs by itself).
  Process {
    id: autoLoadProc
    command: ["bash", "-c", "cat \"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-conduit/autoconnect\" 2>/dev/null"]
    stdout: StdioCollector {
      onStreamFinished: {
        root.autoUuids = String(text).split("\n").map(function(s) { return s.trim() })
          .filter(function(s) { return s !== "" })
      }
    }
  }

  Process {
    id: autoSaveProc
    command: ["bash", "-c", "d=\"${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-conduit\"; mkdir -p \"$d\"; printf '%s\\n' \"$AUTO_LIST\" > \"$d/autoconnect\""]
  }

  Component.onCompleted: autoLoadProc.running = true

  Process {
    id: pickProc
    command: [
      "zenity", "--file-selection", "--title=" + strings.t("pick.title"),
      "--file-filter=" + strings.t("pick.filterVpn") + " | *.ovpn *.conf", "--file-filter=" + strings.t("pick.filterAll") + " | *",
      "--filename=" + Quickshell.env("HOME") + "/Downloads/"
    ]
    stdout: StdioCollector {
      onStreamFinished: {
        var path = String(text).trim()
        if (path !== "") root.importFile(path)
        else root.resumeAt("add", "", "")   // dialog cancelled
      }
    }
  }

  Process {
    id: importProc
    // .conf is taken as WireGuard, anything else (.ovpn) as OpenVPN. A new VPN
    // gets a unique name (NAME-2, NAME-3, ...) and starts as split tunnel.
    // Output on success: line 1 = uuid, line 2 = final name.
    command: [
      "bash", "-c",
      "case \"$VPN_FILE\" in *.conf) t=wireguard;; *) t=openvpn;; esac; " +
      "out=$(nmcli connection import type \"$t\" file \"$VPN_FILE\" 2>&1) || { printf '%s\\n' \"$out\" >&2; exit 1; }; " +
      "uuid=$(printf '%s' \"$out\" | sed -n 's/.*(\\([0-9a-f-]\\{36\\}\\)).*/\\1/p' | head -1); " +
      "[ -n \"$uuid\" ] || { echo 'UUID koneksi baru tidak ditemukan' >&2; exit 1; }; " +
      "base=$(nmcli -g connection.id connection show uuid \"$uuid\"); name=\"$base\"; n=2; " +
      "while [ \"$(nmcli -g NAME connection show | grep -cxF -- \"$name\")\" -gt 1 ]; do name=\"$base-$n\"; n=$((n+1)); done; " +
      "[ \"$name\" = \"$base\" ] || nmcli connection modify uuid \"$uuid\" connection.id \"$name\"; " +
      "nmcli connection modify uuid \"$uuid\" ipv4.never-default yes ipv6.never-default yes; " +
      "printf '%s\\n%s\\n' \"$uuid\" \"$name\""
    ]
    stdout: StdioCollector {
      id: importOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: importErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.importing = false
      if (exitCode === 0) {
        var lines = String(importOut.text).trim().split("\n")
        var uuid = lines[0] || ""
        var name = lines[1] || uuid
        root.setStatus("", false)
        root.refresh()
        Quickshell.execDetached(["notify-send", "VPN", strings.t("import.added").arg(name)])
        root.resumeAt("config", uuid, name)
      } else {
        var msg = String(importErr.text).trim()
        root.setStatus(strings.t("import.failedStatus").arg(msg !== "" ? msg.substring(0, 220) : strings.t("err.code").arg(exitCode)), true)
        Quickshell.execDetached(["notify-send", "-u", "critical", "VPN", strings.t("import.failedNotice").arg(msg.substring(0, 200))])
        // Back to the add view (keeping the error) so the problem stays visible.
        root.resumeAt("add", "", "")
      }
    }
  }

  Process {
    id: deleteProc
    command: ["bash", "-c", "nmcli connection delete uuid \"$VPN_UUID\""]
    onExited: function(exitCode) {
      root.confirmDelete = false
      if (exitCode === 0) {
        Quickshell.execDetached(["notify-send", "VPN", strings.t("delete.done").arg(root.configName)])
        if (root.isAuto(root.configUuid)) root.setAuto(root.configUuid, false)
        if (root.view === "config") root.closeConfig()
      } else {
        Quickshell.execDetached(["notify-send", "-u", "critical", "VPN", strings.t("delete.failed").arg(root.configName)])
      }
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ---- bar icon ------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    active: root.anyUp
    activeColor: Commons.Color.accent
    opacity: root.busyUuid !== "" || root.anyConnecting ? 0.5 : (root.anyUp ? 1.0 : 0.7)
    tooltipText: root.anyUp
      ? strings.t("bar.up").arg(root.upNames.join(", "))
      : (root.anyConnecting ? strings.t("bar.connecting") : strings.t("bar.down"))
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.quickToggle()
      else root.toggle()
    }
  }

  // ---- popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(560))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias userField: userField
      property alias passField: passField
      property alias importField: importField
      property alias nameField: nameField
      property alias otpField: otpField
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      // The text fields own the keyboard while the settings / add view is open.
      blocked: root.view !== "list"
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (root.vpns.length === 0) return
        root.cursorIndex = Math.max(0, Math.min(root.vpns.length - 1, root.cursorIndex + dy))
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)
        // Shared horizontal inset so the title, rows and buttons line up.
        property int inset: Style.space(10)

        // ================= list view =================

        Item {
          visible: root.view === "list"
          width: parent.width
          height: Math.max(listTitle.implicitHeight, addButton.implicitHeight) + Style.space(2)

          Text {
            id: listTitle
            anchors.left: parent.left
            anchors.leftMargin: column.inset
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "VPN"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          PanelActionButton {
            id: addButton
            anchors.right: parent.right
            anchors.rightMargin: column.inset - Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: strings.t("tip.add")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.openAdd()
          }
        }

        Text {
          visible: root.view === "list" && root.statusText !== ""
          textFormat: Text.PlainText
          width: parent.width
          leftPadding: column.inset
          rightPadding: column.inset
          wrapMode: Text.WordWrap
          color: root.statusError ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: root.statusText
        }

        Text {
          visible: root.view === "list" && root.vpns.length === 0
          textFormat: Text.PlainText
          width: parent.width
          leftPadding: column.inset
          rightPadding: column.inset
          bottomPadding: Style.space(6)
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: strings.t("list.empty")
        }

        Column {
          visible: root.view === "list"
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.vpns

            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool isUp: modelData.state === "up"
              readonly property bool isBusy: root.busyUuid === modelData.uuid || modelData.state === "connecting"

              width: parent.width
              height: Style.space(52)
              radius: Style.cornerRadius
              color: row.isUp
                ? Qt.rgba(Commons.Color.accent.r, Commons.Color.accent.g, Commons.Color.accent.b, 0.12)
                : ((rowMouse.containsMouse || (root.cursorActive && root.cursorIndex === row.index))
                    ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.07)
                    : "transparent")

              // Connected rows carry an accent bar on the left edge.
              Rectangle {
                visible: row.isUp
                width: Style.space(3)
                height: parent.height
                radius: width / 2
                color: Commons.Color.accent
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: root.toggleVpn(row.modelData.uuid, row.modelData.state)
              }

              Column {
                anchors.left: parent.left
                anchors.leftMargin: column.inset
                anchors.right: controls.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: row.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: row.isUp
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  // Connected: address and time online. Otherwise the VPN type and state.
                  text: root.subtitleOf(row.modelData)
                  color: row.isUp ? Commons.Color.accent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              Row {
                id: controls
                anchors.right: parent.right
                anchors.rightMargin: column.inset
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: strings.t("tip.otp")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  visible: row.modelData.state === "down"
                  onClicked: root.openOtp(row.modelData.uuid, row.modelData.name)
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: ""
                  tooltipText: strings.t("tip.settings")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.openConfig(row.modelData.uuid, row.modelData.name)
                }

                VpnSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  checked: row.isUp
                  busy: row.isBusy
                  foreground: root.foreground
                  onToggled: root.toggleVpn(row.modelData.uuid, row.modelData.state)
                }
              }
            }
          }
        }

        // ================= add view =================

        Row {
          visible: root.view === "add"
          width: parent.width
          spacing: Style.space(8)

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: strings.t("tip.back")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.closeConfig()
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: strings.t("add.title")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        Column {
          visible: root.view === "add"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: strings.t("add.fileLabel")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: importField
            width: parent.width
            enabled: !root.importing
            placeholderText: strings.t("add.placeholder")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: root.importVpn()
            Keys.onEscapePressed: root.closeConfig()
          }
        }

        Row {
          visible: root.view === "add"
          spacing: Style.space(8)

          VpnButton {
            text: strings.t("add.choose")
            enabled: !root.importing
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.pickFile()
          }

          VpnButton {
            text: root.importing ? strings.t("add.importing") : strings.t("add.import")
            primary: true
            enabled: !root.importing
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.importVpn()
          }
        }

        Text {
          visible: root.view === "add" && root.statusText !== ""
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.statusError ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: root.statusText
        }

        Text {
          visible: root.view === "add"
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: strings.t("add.hint")
        }

        // ================= one-time password view =================

        Row {
          visible: root.view === "otp"
          width: parent.width
          spacing: Style.space(8)

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf060"
            tooltipText: strings.t("tip.back")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.closeConfig()
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            width: parent.width - Style.space(40)
            elide: Text.ElideRight
            text: strings.t("otp.title").arg(root.otpName)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        Column {
          visible: root.view === "otp"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: strings.t("otp.label")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: otpField
            width: parent.width
            password: true
            placeholderText: strings.t("otp.placeholder")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: root.connectOtp()
            Keys.onEscapePressed: root.closeConfig()
          }
        }

        VpnButton {
          visible: root.view === "otp"
          text: strings.t("otp.connect")
          primary: true
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.connectOtp()
        }

        Text {
          visible: root.view === "otp" && root.statusText !== ""
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.statusError ? root.urgent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: root.statusText
        }

        Text {
          visible: root.view === "otp"
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          text: strings.t("otp.hint")
        }

        // ================= settings view =================

        Row {
          visible: root.view === "config"
          width: parent.width
          spacing: Style.space(8)

          PanelActionButton {
            anchors.verticalCenter: parent.verticalCenter
            iconText: ""
            tooltipText: strings.t("tip.back")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.closeConfig()
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            width: parent.width - Style.space(40)
            elide: Text.ElideRight
            text: root.configName
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
        }

        Column {
          visible: root.view === "config"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: strings.t("cfg.name")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: nameField
            width: parent.width
            enabled: !root.configLoading && !root.configSaving
            placeholderText: strings.t("cfg.namePlaceholder")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: userField.forceActiveFocus()
            Keys.onEscapePressed: root.closeConfig()
          }
        }

        Column {
          visible: root.view === "config"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: strings.t("cfg.username")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: userField
            width: parent.width
            enabled: !root.configLoading && !root.configSaving
            placeholderText: strings.t("cfg.usernamePlaceholder")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: passField.forceActiveFocus()
            Keys.onEscapePressed: root.closeConfig()
          }
        }

        Column {
          visible: root.view === "config"
          width: parent.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: strings.t("cfg.password")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: passField
            width: parent.width
            password: true
            enabled: !root.configLoading && !root.configSaving
            placeholderText: root.hasSavedPassword ? strings.t("cfg.passwordSaved") : strings.t("cfg.passwordPlaceholder")
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            foreground: root.foreground
            horizontalPadding: Style.spacing.controlGap
            verticalPadding: Style.spacing.controlPaddingY
            onAccepted: root.saveConfig(true)
            Keys.onEscapePressed: root.closeConfig()
          }
        }

        Column {
          visible: root.view === "config"
          width: parent.width
          spacing: Style.space(10)

          VpnToggleRow {
            width: parent.width
            title: strings.t("cfg.split.title")
            subtitle: root.splitTunnel
              ? strings.t("cfg.split.on")
              : strings.t("cfg.split.off")
            checked: root.splitTunnel
            foreground: root.foreground
            fontFamily: root.fontFamily
            onToggled: root.splitTunnel = !root.splitTunnel
          }

          VpnToggleRow {
            width: parent.width
            title: strings.t("cfg.dns.title")
            subtitle: root.useVpnDns
              ? strings.t("cfg.dns.on")
              : strings.t("cfg.dns.off")
            checked: root.useVpnDns
            foreground: root.foreground
            fontFamily: root.fontFamily
            onToggled: root.useVpnDns = !root.useVpnDns
          }

          VpnToggleRow {
            width: parent.width
            title: strings.t("cfg.auto.title")
            subtitle: root.autoConnect
              ? strings.t("cfg.auto.on")
              : strings.t("cfg.auto.off")
            checked: root.autoConnect
            foreground: root.foreground
            fontFamily: root.fontFamily
            onToggled: root.autoConnect = !root.autoConnect
          }
        }

        Row {
          visible: root.view === "config"
          spacing: Style.space(8)

          VpnButton {
            text: root.configSaving ? strings.t("cfg.saving") : strings.t("cfg.saveConnect")
            primary: true
            enabled: !root.configLoading && !root.configSaving
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.saveConfig(true)
          }

          VpnButton {
            text: strings.t("cfg.save")
            enabled: !root.configLoading && !root.configSaving
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.saveConfig(false)
          }
        }

        // Destructive action, kept apart from the save buttons.
        Rectangle {
          visible: root.view === "config"
          width: parent.width
          height: 1
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
        }

        Item {
          visible: root.view === "config"
          width: parent.width
          height: deleteButton.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: strings.t("cfg.deleteLabel")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          VpnButton {
            id: deleteButton
            anchors.right: parent.right
            text: root.confirmDelete ? strings.t("cfg.deleteConfirm") : strings.t("cfg.delete")
            danger: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.deleteFromConfig()
          }
        }
      }
    }
  }
}
