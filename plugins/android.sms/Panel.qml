import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Android SMS: text via a connected Android device over KDE Connect.
// Works with most Android phones (Pixel, Samsung, Motorola, OnePlus…):
// the device is resolved at runtime via `android-sms-device`
// ($ANDROID_SMS_DEVICE wins, else first reachable phone).
// Contacts (name/number/photo) come from ~/.cache/android-sms/contacts.json,
// built by `android-sms-contacts` from the phone-synced vCards.
Panel {
  id: root
  moduleName: "android.sms"
  ipcTarget: "android.sms"

  property string devId: ""
  property var contacts: []
  property string filterText: ""
  property int selectedIndex: -1
  property string selectedNumber: ""
  property string messageText: ""
  property string sendStatus: ""
  property bool sending: false
  property bool connected: false
  property string connLabel: "Checking phone…"
  // Conversation history (last 10) for the selected contact.
  property var threads: []
  property int threadId: -1
  property var threadMsgs: []
  property bool threadLoading: false
  property string threadStatus: ""

  function filtered() {
    var q = filterText.trim().toLowerCase()
    if (!q) return contacts
    return contacts.filter(function(c) {
      return (c.name + " " + c.number).toLowerCase().indexOf(q) !== -1
    })
  }

  function selectContact(idx, c) {
    selectedIndex = idx
    selectedNumber = c.number || ""
    sendStatus = ""
    resolveThread()
  }

  function normNum(n) { return String(n || "").replace(/\D/g, "") }

  // Match a contact number to a conversation thread by digits
  // (handles +1, dashes, spaces: compares last 10 digits).
  // Prefers 1:1 threads over group threads that merely include the number.
  function addrMatches(have, want) {
    if (!have) return false
    if (have === want) return true
    return have.length >= 10 && want.length >= 10
      && have.slice(-10) === want.slice(-10)
  }
  function threadFor(number) {
    var want = normNum(number)
    if (!want) return -1
    var i, j, addrs, have, solo, k
    for (i = 0; i < threads.length; i++) {
      addrs = threads[i].addresses || []
      if (addrs.length === 0) continue
      solo = true
      for (j = 0; j < addrs.length; j++) {
        if (!addrMatches(normNum(addrs[j]), want)) { solo = false; break }
      }
      if (solo) return threads[i].threadID
    }
    for (k = 0; k < threads.length; k++) {
      addrs = threads[k].addresses || []
      for (j = 0; j < addrs.length; j++) {
        if (addrMatches(normNum(addrs[j]), want)) return threads[k].threadID
      }
    }
    return -1
  }

  function resolveThread() {
    threadMsgs = []
    threadStatus = ""
    if (!selectedNumber || threads.length === 0) {
      threadId = -1
      if (selectedNumber && threads.length === 0) loadThreadsCache()
      return
    }
    threadId = threadFor(selectedNumber)
    if (threadId >= 0) loadThread()
  }

  function loadThreadsCache() {
    if (!threadsProc.running) threadsProc.running = true
  }

  function refreshThreads() {
    if (!threadsRefreshProc.running) threadsRefreshProc.running = true
  }

  function loadThread() {
    if (threadId < 0 || msgProc.running) return
    threadLoading = true
    msgProc.command = ["android-sms-thread", String(threadId), "10"]
    msgProc.running = true
  }

  function fmtTime(ms) {
    var d = new Date(Number(ms) || 0)
    var now = new Date()
    var hh = d.getHours(), mm = ("0" + d.getMinutes()).slice(-2)
    var ap = hh >= 12 ? "p" : "a"
    hh = hh % 12
    if (hh === 0) hh = 12
    var t = hh + ":" + mm + ap
    if (d.toDateString() === now.toDateString()) return t
    return (d.getMonth() + 1) + "/" + d.getDate() + " " + t
  }

  function refresh() {
    if (!deviceProc.running) deviceProc.running = true
  }

  function syncFromPhone() {
    if (!devId) {
      sendStatus = "No phone reachable — pair KDE Connect first."
      return
    }
    sendStatus = "Syncing contacts from phone…"
    if (!syncProc.running) syncProc.running = true
  }

  function sendSms() {
    if (sending || !devId || !selectedNumber || !messageText.trim()) return
    sending = true
    sendStatus = "Sending…"
    if (threadId >= 0) {
      // Reply inside the existing conversation (falls back phone-side on cache miss).
      sendProc.command = ["android-sms-reply", String(threadId), messageText.trim()]
    } else {
      // No thread yet: send by address (creates the conversation).
      sendProc.command = ["kdeconnect-cli", "-d", devId,
        "--send-sms", messageText.trim(), "--destination", selectedNumber]
    }
    sendProc.running = true
  }

  Component.onCompleted: refresh()

  // Resolve the phone, then pull reachability + contacts behind it.
  Process {
    id: deviceProc
    command: ["android-sms-device"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = text.trim().split("\n")[0]
        root.devId = id
        root.connected = id !== ""
        root.connLabel = id !== "" ? "Phone connected" : "No phone reachable"
        if (id !== "") {
          if (!contactsProc.running) contactsProc.running = true
        } else {
          root.contacts = []
        }
      }
    }
    onExited: function(code) {
      if (code !== 0 || root.devId === "") {
        root.devId = ""
        root.connected = false
        root.connLabel = "No phone reachable"
        root.contacts = []
      }
    }
  }

  // Contacts JSON via helper (helper prints summary to stdout, JSON lives in cache).
  Process {
    id: contactsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.contacts = JSON.parse(text)
          if (root.selectedIndex >= root.contacts.length) root.selectedIndex = -1
        } catch (e) { root.contacts = [] }
      }
    }
  }
  function loadContacts() {
    contactsProc.command = ["bash", "-c", "android-sms-contacts " + root.devId + " >/dev/null 2>&1; cat ~/.cache/android-sms/contacts.json 2>/dev/null || echo '[]'"]
    if (!contactsProc.running) contactsProc.running = true
  }
  Connections {
    target: root
    function onDevIdChanged() { if (root.devId !== "") root.loadContacts() }
  }

  // Ask the phone to push fresh contacts, then re-parse.
  Process {
    id: syncProc
    onExited: function() { syncDelay.start() }
  }
  function runSync() {
    syncProc.command = ["gdbus", "call", "--session",
      "--dest", "org.kde.kdeconnect",
      "--object-path", "/modules/kdeconnect/devices/" + devId + "/contacts",
      "--method", "org.kde.kdeconnect.device.contacts.synchronizeRemoteWithLocal"]
    syncProc.running = true
  }
  Timer {
    id: syncDelay
    interval: 3000
    repeat: false
    onTriggered: root.refresh()
  }

  Process {
    id: sendProc
    stdout: StdioCollector { id: sendOut; waitForEnd: true }
    stderr: StdioCollector { id: sendErr; waitForEnd: true }
    onExited: function(code) {
      root.sending = false
      if (code === 0) {
        root.sendStatus = "Sent to " + root.selectedNumber
        root.messageText = ""
        msgArea.text = ""
        // Re-fetch so the reply appears in the history.
        resendDelay.start()
      } else {
        root.sendStatus = "Send failed (code " + code + "). Is the phone connected?"
      }
    }
  }
  Timer {
    id: resendDelay
    interval: 2500
    repeat: false
    onTriggered: {
      // A first-ever message creates the thread: refresh threads, then load.
      if (root.threadId < 0) root.refreshThreads()
      else root.loadThread()
    }
  }

  // Thread index cache (threadID <-> addresses), instant on open.
  Process {
    id: threadsProc
    command: ["bash", "-c", "cat ~/.cache/android-sms/threads.json 2>/dev/null || echo '[]'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.threads = JSON.parse(text)
        } catch (e) { root.threads = [] }
        // Re-resolve in case a contact is already selected.
        if (root.selectedNumber) root.resolveThread()
      }
    }
  }

  // Full refresh from the phone (slow on big histories: streams threads).
  Process {
    id: threadsRefreshProc
    command: ["android-sms-threads", "--wait", "12"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          root.threads = JSON.parse(text)
        } catch (e) { /* cache file still updated by helper */ root.loadThreadsCache() }
        if (root.selectedNumber) root.resolveThread()
      }
    }
  }

  // Last-10 messages of the selected thread.
  Process {
    id: msgProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.threadLoading = false
        try {
          var rows = JSON.parse(text)
          root.threadMsgs = rows
          root.threadStatus = ""
        } catch (e) {
          root.threadStatus = "Couldn't load history."
        }
      }
    }
    onExited: function(code) {
      root.threadLoading = false
      if (code !== 0 && root.threadMsgs.length === 0)
        root.threadStatus = "No history yet — say hi below."
    }
  }

  // Re-check reachability while open.
  Timer {
    id: connPoll
    interval: 5000
    repeat: true
    running: root.opened
    onTriggered: if (!deviceProc.running) deviceProc.running = true
  }

  // Live-ish history while open: refetch the visible thread.
  Timer {
    id: threadPoll
    interval: 15000
    repeat: true
    running: root.opened && root.threadId >= 0
    onTriggered: if (!msgProc.running && !root.sending) root.loadThread()
  }

  // Opening the plugin: threads cache first (history shows instantly).
  Connections {
    target: root
    function onOpenedChanged() {
      if (root.opened) {
        root.loadThreadsCache()
        if (root.threads.length === 0) root.refreshThreads()
      }
    }
  }

  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color dimForeground: Qt.darker(contentForeground, 1.45)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.connected ? "󰍦 SMS" : "󰍦 …"
    labelVisible: true
    fixedWidth: -1
    fontSize: Style.font.caption
    foreground: root.barForeground
    tooltipText: root.connLabel + " — " + root.contacts.length + " contacts"
    onPressed: function(code) {
      if (code === Qt.LeftButton) { root.refresh(); root.toggle() }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(dir) { root.switchPanel(dir) }

      Column {
        id: contentColumn
        width: parent.width
        spacing: Style.space(8)

        // Status row
        RowLayout {
          width: parent.width
          spacing: Style.space(8)
          Rectangle {
            width: Style.space(10); height: Style.space(10); radius: width / 2
            color: root.connected ? Color.accent : "#888888"
            Layout.alignment: Qt.AlignVCenter
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.connLabel + " · " + root.contacts.length + " contacts"
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          PanelActionButton {
            iconText: "󰑐"
            tooltipText: "Sync contacts from phone"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            fontSize: Style.font.body
            size: Style.space(26)
            bordered: false
            onClicked: {
              if (!root.devId) {
                root.sendStatus = "No phone reachable — pair KDE Connect first."
              } else {
                root.sendStatus = "Syncing contacts from phone…"
                root.runSync()
              }
            }
          }
        }

        // Search
        TextField {
          id: searchField
          width: parent.width
          placeholderText: "Search contacts…"
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          text: root.filterText
          onTextChanged: { root.filterText = text; root.selectedIndex = -1 }
          Keys.onEscapePressed: root.close()
        }

        // Contact list
        ListView {
          id: list
          width: parent.width
          height: Math.min(280, Math.max(120, count * 52))
          clip: true
          model: root.filtered()
          delegate: Item {
            required property var modelData
            required property int index
            width: list.width
            height: 52
            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(10)
              Rectangle {
                width: 36; height: 36; radius: 18
                color: Qt.darker(root.contentForeground, 1.8)
                clip: true
                Layout.alignment: Qt.AlignVCenter
                Image {
                  anchors.fill: parent
                  visible: modelData.avatar !== ""
                  source: modelData.avatar || ""
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  cache: true
                }
                Text {
                  anchors.centerIn: parent
                  visible: modelData.avatar === ""
                  text: ""
                  color: root.contentForeground
                  font.pixelSize: Style.font.body
                }
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.name
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: index === root.selectedIndex
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.number + (modelData.numbers.length > 1 ? "  (+" + (modelData.numbers.length - 1) + " more)" : "")
                  color: root.dimForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
            Rectangle {
              anchors.fill: parent
              color: "transparent"
              border.width: index === root.selectedIndex ? 1 : 0
              border.color: Color.accent
              radius: Style.cornerRadius
            }
            MouseArea {
              anchors.fill: parent
              onClicked: root.selectContact(index, modelData)
            }
          }
        }

        // Conversation history: last 10, oldest at top.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.selectedIndex >= 0
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: root.threadLoading
            text: "Loading history…"
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.threadLoading && root.threadStatus !== ""
            text: root.threadStatus
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
          ListView {
            id: historyList
            width: parent.width
            height: Math.min(260, Math.max(80, count * 44))
            visible: count > 0
            clip: true
            model: root.threadMsgs
            delegate: Item {
              required property var modelData
              width: historyList.width
              height: bubble.implicitHeight + Style.space(6)
              Rectangle {
                id: bubble
                // Incoming left/grey, outgoing right/accent-tinted.
                anchors.left: modelData.incoming ? parent.left : undefined
                anchors.right: modelData.incoming ? undefined : parent.right
                anchors.leftMargin: modelData.incoming ? 0 : Style.space(28)
                anchors.rightMargin: modelData.incoming ? Style.space(28) : 0
                width: Math.min(parent.width - Style.space(28),
                  Math.max(60, msgText.implicitWidth + Style.space(16)))
                implicitHeight: msgCol.implicitHeight + Style.space(12)
                radius: Style.space(8)
                color: modelData.incoming
                  ? Qt.darker(root.contentForeground, 1.8)
                  : Qt.darker(Color.accent, 1.35)
                Column {
                  id: msgCol
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  spacing: 2
                  Text {
                    id: msgText
                    width: parent.width
                    text: modelData.body + (modelData.hasAttachment ? "  📷" : "")
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    text: root.fmtTime(modelData.date)
                    horizontalAlignment: modelData.incoming ? Text.AlignLeft : Text.AlignRight
                    color: root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
            onCountChanged: if (count > 0) Qt.callLater(function() {
              historyList.positionViewAtEnd()
            })
          }
        }

        // Compose (visible once a contact is picked)
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.selectedIndex >= 0
          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: {
              var rows = root.filtered()
              var c = rows[root.selectedIndex]
              return c ? ("To: " + c.name + " · " + root.selectedNumber) : ""
            }
            color: root.contentForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }
          // Alternate numbers, if any
          ComboBox {
            width: parent.width
            visible: {
              var rows = root.filtered()
              var c = rows[root.selectedIndex]
              return !!(c && c.numbers && c.numbers.length > 1)
            }
            model: {
              var rows = root.filtered()
              var c = rows[root.selectedIndex]
              return c ? c.numbers : []
            }
            onCurrentTextChanged: if (currentText) root.selectedNumber = currentText
          }
          TextArea {
            id: msgArea
            width: parent.width
            height: 80
            wrapMode: TextArea.Wrap
            placeholderText: root.threadId >= 0 ? "Reply… (Enter to send, Shift+Enter newline)" : "Type message… (Enter to send, Shift+Enter newline)"
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
            text: root.messageText
            onTextChanged: if (text !== root.messageText) root.messageText = text
            Keys.onPressed: function(e) {
              if (e.key === Qt.Key_Return && !(e.modifiers & Qt.ShiftModifier)) {
                e.accepted = true
                root.sendSms()
              } else if (e.key === Qt.Key_Escape) {
                root.close()
              }
            }
          }
          RowLayout {
            width: parent.width
            Text {
              textFormat: Text.PlainText
              text: root.messageText.length + " chars" + (root.messageText.length > 160 ? " (" + Math.ceil(root.messageText.length / 153) + " parts)" : "")
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
            Item { Layout.fillWidth: true }
            PanelActionButton {
              iconText: "󰍦"
              tooltipText: "Send SMS"
              foreground: Color.accent
              fontFamily: root.contentFontFamily
              fontSize: Style.font.iconLarge
              size: Style.space(32)
              bordered: false
              enabled: !root.sending && root.messageText.trim() !== "" && root.selectedNumber !== "" && root.devId !== ""
              onClicked: root.sendSms()
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          visible: root.sendStatus !== ""
          text: root.sendStatus
          color: root.sendStatus.indexOf("fail") !== -1 ? "#e05555" : root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          width: parent.width
          text: "Click 󰑐 to pull fresh contacts · Enter sends · Esc closes"
          color: root.dimForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
