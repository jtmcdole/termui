import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var lastLeftMouseDownEvent: NSEvent?

  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      lastLeftMouseDownEvent = event
    case .leftMouseUp:
      lastLeftMouseDownEvent = nil
    default:
      break
    }
    super.sendEvent(event)
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    self.styleMask.insert(.fullSizeContentView)
    self.titlebarAppearsTransparent = true
    self.titleVisibility = .hidden
    self.isMovableByWindowBackground = false

    let windowChannel = FlutterMethodChannel(
      name: "fterm/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    windowChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(nil)
        return
      }
      switch call.method {
      case "startDrag":
        let current = NSApp.currentEvent
        let primaryDown = (NSEvent.pressedMouseButtons & 1) != 0
        if primaryDown, current?.type != .leftMouseUp {
          let dragEvent: NSEvent? = switch current?.type {
          case .leftMouseDown:
            current
          case .leftMouseDragged:
            self.lastLeftMouseDownEvent
          default:
            nil
          }
          if let dragEvent {
            self.performDrag(with: dragEvent)
          }
        }
        result(nil)
      case "zoomWindow":
        self.performZoom(nil)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
