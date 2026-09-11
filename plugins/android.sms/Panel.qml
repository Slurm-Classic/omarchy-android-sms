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
    sendProc.command = ["kdeconnect-cli", "-d", devId,
      "--send-sms", messageText.trim(), "--destination", selectedNumber]
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
      } else {
        root.sendStatus = "Send failed (code " + code + "). Is the phone connected?"
      }
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
            placeholderText: "Type message… (Enter to send, Shift+Enter newline)"
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
