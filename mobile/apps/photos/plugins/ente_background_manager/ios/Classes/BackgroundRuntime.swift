import BackgroundTasks
@preconcurrency import Flutter
import Foundation
import UIKit
import os

@MainActor
final class BackgroundRuntime: NSObject {
  static let shared = BackgroundRuntime()
  private static let logger = Logger(subsystem: "io.ente.background", category: "BackgroundManager")
  private var configuration = StoredConfiguration.load()
  private var isAllowed: () -> Bool = { false }
  private var registrant: ((FlutterPluginRegistry) -> Void)?
  private let observers = NSHashTable<BackgroundManagerPlugin>.weakObjects()
  private var registrations: [String: Bool] = [:]
  private var active: Run?
  private var isForeground = false
  private var installed = false
  private var reconciling = false
  private var needsRearm = Set<String>()
  private var changedTasks = Set<String>()
  private var configurationResults: [FlutterResult] = []

  private final class Run {
    let task: BGTask
    let configuration: TaskConfiguration
    let startedAt: TimeInterval
    let invocation = UUID().uuidString
    var engine: FlutterEngine?
    var channel: FlutterMethodChannel?
    var ready = false
    var retiring = false
    var stopReason: String?
    var budgetTimer: DispatchWorkItem?
    var foregroundTimer: DispatchWorkItem?
    var stopResults: [FlutterResult] = []

    init(task: BGTask, configuration: TaskConfiguration, startedAt: TimeInterval) {
      self.task = task
      self.configuration = configuration
      self.startedAt = startedAt
    }
  }

  func install(
    isEnabled: @escaping () -> Bool,
    registrant: @escaping (FlutterPluginRegistry) -> Void
  ) {
    isAllowed = isEnabled
    self.registrant = registrant
    guard !installed else { return }
    installed = true
    isForeground = UIApplication.shared.applicationState == .active
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(foreground), name: UIApplication.willEnterForegroundNotification,
      object: nil)
    center.addObserver(
      self, selector: #selector(foreground), name: UIApplication.didBecomeActiveNotification,
      object: nil)
    center.addObserver(
      self, selector: #selector(background), name: UIApplication.didEnterBackgroundNotification,
      object: nil)
  }

  func register(identifier: String, processing: Bool) -> Bool {
    if let existing = registrations[identifier] { return existing == processing }
    let registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: identifier, using: .main
    ) { task in
      let startedAt = ProcessInfo.processInfo.systemUptime
      MainActor.assumeIsolated {
        self.deliver(task, startedAt: startedAt)
      }
    }
    if registered {
      registrations[identifier] = processing
    } else {
      report(identifier: identifier, outcome: "failed", reason: "registration")
    }
    return registered
  }

  func attach(_ plugin: BackgroundManagerPlugin) {
    observers.add(plugin)
  }

  func detach(_ plugin: BackgroundManagerPlugin) {
    observers.remove(plugin)
  }

  @objc private func foreground() {
    isForeground = true
    if let run = active { stop(run, reason: "foreground") }
  }

  @objc private func background() {
    isForeground = false
  }

  func requestStop(result: FlutterResult? = nil) {
    guard let run = active else {
      result?(nil)
      return
    }
    if let result { run.stopResults.append(result) }
    stop(run, reason: "requested")
  }

  func configure(_ data: [String: Any]?, result: @escaping FlutterResult) {
    guard let data, let callback = data["callbackHandle"] as? NSNumber,
      let tasks = data["tasks"] as? [[String: Any]], let enabled = data["enabled"] as? Bool,
      installed
    else {
      result(
        FlutterError(
          code: "configuration", message: "Background manager was not installed at launch",
          details: nil))
      return
    }
    do {
      let parsed = try tasks.map { try TaskConfiguration($0, callbackHandle: callback.int64Value) }
      guard Set(parsed.map(\.identifier)).count == parsed.count else {
        throw TaskConfiguration.ConfigurationError.duplicateIdentifier
      }
      for task in parsed {
        guard registrations[task.identifier] == (task.kind == "processing") else {
          throw TaskConfiguration.ConfigurationError.unregisteredIdentifier
        }
        if !configuration.tasks.contains(task) { changedTasks.insert(task.identifier) }
      }
      let next = StoredConfiguration(enabled: enabled, tasks: parsed)
      try next.save()
      configuration = next
      if !enabled { requestStop() }
      configurationResults.append(result)
      reconcile()
    } catch {
      result(FlutterError(code: "configuration", message: String(describing: error), details: nil))
    }
  }

  private func reconcile() {
    guard !reconciling else { return }
    reconciling = true
    BGTaskScheduler.shared.getPendingTaskRequests { requests in
      DispatchQueue.main.async {
        let pending = Dictionary(
          requests.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        let enabled = self.configuration.enabled && self.isAllowed()
        let desired = enabled ? self.configuration.tasks : []
        let identifiers = Set(desired.map(\.identifier))
        for identifier in self.registrations.keys where !identifiers.contains(identifier) {
          BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        var failure: Error?
        for task in desired {
          let rearming = self.needsRearm.contains(task.identifier)
          if pending[task.identifier] != nil && !rearming
            && !self.changedTasks.contains(task.identifier)
          {
            continue
          }
          let request: BGTaskRequest
          if task.kind == "processing" {
            let processing = BGProcessingTaskRequest(identifier: task.identifier)
            processing.requiresNetworkConnectivity = task.requiresNetwork
            processing.requiresExternalPower = task.requiresCharging
            request = processing
          } else {
            request = BGAppRefreshTaskRequest(identifier: task.identifier)
          }
          let delay = rearming ? task.frequencyMs : task.initialDelayMs
          request.earliestBeginDate = Date(timeIntervalSinceNow: Double(delay) / 1000)
          do {
            try BGTaskScheduler.shared.submit(request)
          } catch {
            failure = error
            self.report(
              identifier: task.identifier, outcome: "failed", reason: "schedule",
              error: String(describing: error))
          }
        }
        self.changedTasks.removeAll()
        self.needsRearm.removeAll()
        self.reconciling = false
        let results = self.configurationResults
        self.configurationResults.removeAll()
        for result in results {
          if let failure {
            result(
              FlutterError(code: "schedule", message: String(describing: failure), details: nil))
          } else {
            result(nil)
          }
        }
      }
    }
  }

  func scheduledTasks(_ result: @escaping FlutterResult) {
    BGTaskScheduler.shared.getPendingTaskRequests { requests in
      DispatchQueue.main.async {
        let pending = Set(requests.map(\.identifier))
        result(
          Dictionary(
            uniqueKeysWithValues: self.configuration.tasks.map {
              ($0.identifier, pending.contains($0.identifier))
            }))
      }
    }
  }

  private func deliver(_ task: BGTask, startedAt: TimeInterval) {
    guard configuration.enabled, isAllowed(),
      let policy = configuration.tasks.first(where: { $0.identifier == task.identifier })
    else {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: task.identifier)
      report(identifier: task.identifier, outcome: "skipped", reason: "disabled")
      task.setTaskCompleted(success: true)
      return
    }
    needsRearm.insert(task.identifier)
    reconcile()
    let skip: String?
    if active != nil {
      skip = "busy"
    } else if isForeground || UIApplication.shared.applicationState != .background {
      skip = "foreground"
    } else {
      skip = nil
    }
    if let skip {
      report(identifier: task.identifier, outcome: "skipped", reason: skip)
      task.setTaskCompleted(success: true)
      return
    }
    let run = Run(task: task, configuration: policy, startedAt: startedAt)
    active = run
    task.expirationHandler = { [weak run] in
      DispatchQueue.main.async {
        guard let run, self.active === run else { return }
        self.stop(run, reason: "system")
        self.retire(run, outcome: "stopped", reason: "expired", success: false)
      }
    }
    if let budget = policy.runBudgetMs {
      let timer = DispatchWorkItem { [weak run] in
        guard let run, self.active === run else { return }
        self.stop(run, reason: "budget")
      }
      run.budgetTimer = timer
      DispatchQueue.main.asyncAfter(
        deadline: .now() + Double(max(0, budget - elapsed(run))) / 1000, execute: timer)
    }
    guard let callback = FlutterCallbackCache.lookupCallbackInformation(policy.callbackHandle),
      let registrant
    else {
      retire(
        run, outcome: "failed", reason: "bootstrap", error: "Background dispatcher is unavailable")
      return
    }
    let engine = FlutterEngine(
      name: "ente-background-\(run.invocation)", project: nil, allowHeadlessExecution: true)
    run.engine = engine
    let channel = FlutterMethodChannel(
      name: "io.ente.background/worker", binaryMessenger: engine.binaryMessenger)
    run.channel = channel
    channel.setMethodCallHandler { [weak run] call, result in
      guard let run, self.active === run, !run.retiring else {
        result(nil)
        return
      }
      switch call.method {
      case "ready":
        guard !run.ready else {
          result(
            FlutterError(code: "bootstrap", message: "Dispatcher already started", details: nil))
          return
        }
        run.ready = true
        var data: [String: Any] = [
          "identifier": policy.identifier,
          "invocation": run.invocation,
          "elapsedMs": self.elapsed(run),
        ]
        if let budget = policy.runBudgetMs { data["runBudgetMs"] = budget }
        if let reason = run.stopReason { data["stopReason"] = reason }
        result(data)
      case "complete":
        guard let data = call.arguments as? [String: Any],
          data["invocation"] as? String == run.invocation,
          let outcome = data["outcome"] as? String,
          ["completed", "skipped", "stopped", "failed"].contains(outcome)
        else {
          result(
            FlutterError(code: "completion", message: "Invalid background completion", details: nil)
          )
          return
        }
        result(nil)
        self.retire(run, outcome: outcome, reason: run.stopReason, error: data["error"] as? String)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    guard
      engine.run(withEntrypoint: callback.callbackName, libraryURI: callback.callbackLibraryPath)
    else {
      retire(run, outcome: "failed", reason: "bootstrap", error: "Flutter engine failed to start")
      return
    }
    registrant(engine)
  }

  private func elapsed(_ run: Run) -> Int64 {
    Int64(max(0, ProcessInfo.processInfo.systemUptime - run.startedAt) * 1000)
  }

  private func stop(_ run: Run, reason: String) {
    guard active === run, !run.retiring else { return }
    if run.stopReason == nil {
      run.stopReason = reason
      if run.ready {
        run.channel?.invokeMethod(
          "stop", arguments: ["invocation": run.invocation, "reason": reason])
      }
    }
    if reason == "foreground", run.foregroundTimer == nil,
      let grace = run.configuration.foregroundStopTimeoutMs
    {
      let timer = DispatchWorkItem { [weak run] in
        guard let run, self.active === run else { return }
        self.retire(run, outcome: "forcedTeardown", reason: "foreground")
      }
      run.foregroundTimer = timer
      DispatchQueue.main.asyncAfter(deadline: .now() + Double(grace) / 1000, execute: timer)
    }
  }

  private func retire(
    _ run: Run, outcome: String, reason: String? = nil, error: String? = nil, success: Bool? = nil
  ) {
    guard active === run, !run.retiring else { return }
    run.retiring = true
    run.budgetTimer?.cancel()
    run.foregroundTimer?.cancel()
    run.task.expirationHandler = nil
    let terminal = outcome == "completed" && run.stopReason != nil ? "stopped" : outcome
    run.channel?.setMethodCallHandler(nil)
    run.engine?.destroyContext()
    run.channel = nil
    run.engine = nil
    run.task.setTaskCompleted(
      success: success ?? (terminal != "failed" && terminal != "forcedTeardown"))
    active = nil
    if terminal != "completed" {
      report(
        identifier: run.configuration.identifier, outcome: terminal, reason: reason, error: error)
    }
    for result in run.stopResults { result(nil) }
    run.stopResults.removeAll()
  }

  private func report(
    identifier: String, outcome: String, reason: String? = nil, error: String? = nil
  ) {
    var event: [String: Any] = ["identifier": identifier, "outcome": outcome]
    if let reason { event["reason"] = reason }
    if let error { event["error"] = error }
    let fallback = {
      Self.logger.warning(
        "\(identifier, privacy: .public): \(outcome, privacy: .public) (\(reason ?? "task", privacy: .public)) \(error ?? "", privacy: .public)"
      )
    }
    if let observer = observers.allObjects.last(where: \.canReport) {
      observer.report(event, fallback: fallback)
    } else {
      fallback()
    }
  }
}
