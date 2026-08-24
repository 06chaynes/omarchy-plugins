import QtQuick
import qs.Commons

Item {
  id: root

  property color color: Color.foreground
  property real iconSize: Style.space(22)
  property string fontFamily: Style.font.family

  implicitWidth: iconSize
  implicitHeight: iconSize

  Text {
    anchors.centerIn: parent
    text: "󰳆"
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: root.iconSize
  }
}
