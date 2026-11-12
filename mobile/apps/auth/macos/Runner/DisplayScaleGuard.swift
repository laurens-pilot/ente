import Cocoa
import FlutterMacOS
import os

final class DisplayScaleGuard: NSObject {
  private weak var window: NSWindow?
  private weak var controller: FlutterViewController?
  private let channel: FlutterMethodChannel
  private let logger = Logger(subsystem: "io.ente.auth", category: "DisplayScale")
  private var pendingRecovery: DispatchWorkItem?
  private var dartReady = false

  init(window: NSWindow, controller: FlutterViewController) {
    self.window = window
    self.controller = controller
    channel = FlutterMethodChannel(
      name: "io.ente.auth/display_scale",
      binaryMessenger: controller.engine.binaryMessenger
    )
    super.init()

    for name in [
      NSWindow.didChangeScreenNotification,
      NSWindow.didChangeBackingPropertiesNotification,
      NSWindow.didBecomeKeyNotification,
      NSWindow.didDeminiaturizeNotification,
    ] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(displayChanged(_:)), name: name, object: window
      )
    }
    for name in [
      NSApplication.didChangeScreenParametersNotification,
      NSApplication.didBecomeActiveNotification,
    ] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(displayChanged(_:)), name: name, object: nil
      )
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(displayChanged(_:)),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "start" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.dartReady = true
      self?.scheduleRecovery(reason: "dart-ready")
      result(nil)
    }
    scheduleRecovery(reason: "window-ready")
  }

  deinit {
    pendingRecovery?.cancel()
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    channel.setMethodCallHandler(nil)
  }

  @objc private func displayChanged(_ notification: Notification) {
    let reason = notification.name.rawValue
    recordGeometry(reason: reason, phase: "notification")
    if [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didDeminiaturizeNotification,
      NSApplication.didBecomeActiveNotification,
    ].contains(notification.name) {
      recoverScale(reason: reason, refreshMatchingScale: false)
    }
    scheduleRecovery(reason: reason)
  }

  private func scheduleRecovery(reason: String) {
    pendingRecovery?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.pendingRecovery = nil
      self?.recordGeometry(reason: reason, phase: "settled")
      self?.recoverScale(reason: reason, refreshMatchingScale: true)
    }
    pendingRecovery = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
  }

  private func recoverScale(reason: String, refreshMatchingScale: Bool) {
    guard let window, window.screen != nil,
      let view = renderingView(), view.window === window, let layer = view.layer
    else { return }

    let backingSize = view.convertToBacking(NSRect(x: 0, y: 0, width: 1, height: 1)).size
    let scale = backingSize.width
    guard scale.isFinite, scale > 0,
      backingSize.height.isFinite,
      abs(backingSize.height - scale) < 0.000001,
      abs(window.backingScaleFactor - scale) < 0.000001
    else { return }

    let corrected = !layer.contentsScale.isFinite || abs(layer.contentsScale - scale) > 0.000001
    guard corrected || refreshMatchingScale else { return }
    if corrected {
      layer.contentsScale = scale
    }
    view.viewDidChangeBackingProperties()
    view.needsDisplay = true
    recordGeometry(reason: reason, phase: "refreshed", corrected: corrected)
  }

  private func renderingView() -> NSView? {
    guard let controller, controller.isViewLoaded,
      let viewClass = NSClassFromString("FlutterView")
    else { return nil }
    return findRenderingView(in: controller.view, viewClass: viewClass)
  }

  private func findRenderingView(in view: NSView, viewClass: AnyClass) -> NSView? {
    if view.isKind(of: viewClass) { return view }
    for child in view.subviews {
      if let found = findRenderingView(in: child, viewClass: viewClass) { return found }
    }
    return nil
  }

  private func recordGeometry(reason: String, phase: String, corrected: Bool = false) {
    guard let window else { return }
    let view = renderingView()
    var geometry: [String: Any] = [
      "reason": reason,
      "phase": phase,
      "corrected": corrected,
      "windowBackingScale": number(window.backingScaleFactor),
      "windowVisible": window.isVisible,
      "windowMiniaturized": window.isMiniaturized,
      "renderingViewFound": view != nil,
    ]
    if let view {
      let unitSize = view.convertToBacking(NSRect(x: 0, y: 0, width: 1, height: 1)).size
      let backingSize = view.convertToBacking(view.bounds).size
      geometry["viewBackingScaleX"] = number(unitSize.width)
      geometry["viewBackingScaleY"] = number(unitSize.height)
      geometry["layerContentsScale"] = view.layer.map { number($0.contentsScale) } ?? NSNull()
      geometry["viewWidth"] = number(view.bounds.width)
      geometry["viewHeight"] = number(view.bounds.height)
      geometry["backingWidth"] = number(backingSize.width)
      geometry["backingHeight"] = number(backingSize.height)
    }
    if let data = try? JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys]),
      let message = String(data: data, encoding: .utf8)
    {
      logger.info("\(message, privacy: .public)")
    }
    if dartReady {
      channel.invokeMethod("geometry", arguments: geometry)
    }
  }

  private func number(_ value: CGFloat) -> Any {
    value.isFinite ? Double(value) : NSNull()
  }
}
