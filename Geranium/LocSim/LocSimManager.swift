//
//  LocSimManager.swift
//  Andromeda
//
//  Developed by son3ra1n.
//

import Foundation
import CoreLocation


class LocSimManager {
    static let simManager = CLSimulationManager()

    // MARK: - DriftFix v3.2 会话常驻（对齐 LocSuper 扫街：只喂坐标，不重建会话）
    // 原实现每喂一个点都 stop→clear→append→flush→start，1 秒一次；保活 Timer 又每 0.75s 整套重跑，
    // 等于每秒 1.3 次把模拟会话拆掉重开。locationd 是融合引擎，拆会话的空窗会漏出真实定位，
    // 重建后又跳回假点 —— 这就是「一点开始，位置就跟我画的不一样」的漂移来源。
    // 现在：会话只在第一个点时开一次，之后每个点只 append+flush 续投，全程不再 stop/clear；
    // 保活只在「没有新点」时补投最后一个点，绝不打断正在跑的线路。
    private static var keepAliveTimer: Timer?
    private static var lastLocation: CLLocation?
    private static var lastPushAt = Date.distantPast
    private static var sessionActive = false
    private static let keepAliveInterval: TimeInterval = 1.0
    private static let idleHoldAfter: TimeInterval = 1.6

    /// Updates timezone
    static func post_required_timezone_update(){
        CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterGetDarwinNotifyCenter(), .init("AutomaticTimeZoneUpdateNeeded" as CFString), nil, nil, kCFNotificationDeliverImmediately);
    }

    /// 投递一个点：第一次建会话（stop→clear→append→flush→start），之后仅 append+flush 续投。
    private static func push(_ location: CLLocation) {
        let first = !sessionActive
        if first {
            simManager.stopLocationSimulation()
            simManager.clearSimulatedLocations()
        }
        // DriftFix v3.3：补投不能把旧 CLLocation 原样再发一遍 —— 它的 timestamp 停在最后一个
        // 轨迹点，系统会把"过期定位"当无效丢掉，回落到真实定位，位置就跳回现实了。
        // 补投一律按「原地站住」重建：新时间戳 + 速度 0 + 航向无效。
        let injected: CLLocation
        if Date().timeIntervalSince(location.timestamp) > 0.5 {
            injected = CLLocation(
                coordinate: location.coordinate,
                altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy,
                verticalAccuracy: location.verticalAccuracy,
                course: -1,
                speed: 0,
                timestamp: Date()
            )
        } else {
            injected = location
        }
        simManager.appendSimulatedLocation(injected)
        simManager.flush()
        if first {
            simManager.startLocationSimulation()
            sessionActive = true
        }
        lastLocation = injected
        lastPushAt = Date()
    }

    private static func startKeepAlive() {
        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: keepAliveInterval, repeats: true) { _ in
            // 线路正在推进（1.6s 内刚喂过点）就什么都不做，避免把上一个点再补一遍造成一顿一顿
            guard Date().timeIntervalSince(lastPushAt) > idleHoldAfter, let loc = lastLocation else { return }
            push(loc)
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    /// Starts a location simulation of specified argument "location"
    static func startLocSim(location: CLLocation) {
        DispatchQueue.main.async {
            push(location)
            if keepAliveTimer == nil { startKeepAlive() }
            post_required_timezone_update();
        }
    }

    /// Stops location simulation
    static func stopLocSim(){
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        lastLocation = nil
        sessionActive = false
        DispatchQueue.main.async {
            simManager.stopLocationSimulation()
            simManager.clearSimulatedLocations()
            simManager.flush()
            post_required_timezone_update();
        }
    }
}


struct EquatableCoordinate: Equatable {
    var coordinate: CLLocationCoordinate2D
    
    static func ==(lhs: EquatableCoordinate, rhs: EquatableCoordinate) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}


// https://stackoverflow.com/a/75703059

class LocationModel: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    @Published var authorisationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        self.locationManager.delegate = self
    }

    public func requestAuthorisation(always: Bool = false) {
        if always {
            self.locationManager.requestAlwaysAuthorization()
        } else {
            self.locationManager.requestWhenInUseAuthorization()
        }
    }
}

extension LocationModel: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        self.authorisationStatus = status
    }
}
