import Cocoa
import FlutterMacOS
import window_manager

class MainFlutterWindow: NSWindow {
  private var displayScaleGuard: DisplayScaleGuard?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController.init()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    displayScaleGuard = DisplayScaleGuard(window: self, controller: flutterViewController)
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
