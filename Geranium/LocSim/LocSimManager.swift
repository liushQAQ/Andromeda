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

    // MARK: - DriftFix 单点保活重注入
    // 原实现只 append 一个静止点就 flush，之后永不更新——locationd 是融合定位引擎，
    // Wi-Fi/蜂窝不断产生真定位，与这一个静止假点"打架"，蓝点在真假位置之间漂。
    // 现在注入后由 keep-alive Timer 每 0.75s 重注入最后一个点，持续压住融合引擎。
    // 路线模式(RouteSimulator)每 1s 调 startLocSim 喂新点 → lastLocation 不断刷新，二者不冲突；
    // 路线跑完后计时器继续保活终点，顺带修复"到达终点后又开始漂"。
    // 注意：keep-alive 走主线程 Timer(.common)，锁屏后台时主 RunLoop 挂起则保活暂停（前台场景完全覆盖）。
    private static var keepAliveTimer: Timer?
    private static var lastLocation: CLLocation?
    private static let keepAliveInterval: TimeInterval = 0.75

    /// Updates timezone
    static func post_required_timezone_update(){
        CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterGetDarwinNotifyCenter(), .init("AutomaticTimeZoneUpdateNeeded" as CFString), nil, nil, kCFNotificationDeliverImmediately);
    }

    /// 单次注入：与原实现完全相同的会话周期（stop→clear→append→flush→start）
    private static func injectOnce(location: CLLocation) {
        simManager.stopLocationSimulation()
        simManager.clearSimulatedLocations()
        simManager.appendSimulatedLocation(location)
        simManager.flush()
        simManager.startLocationSimulation()
    }

    private static func startKeepAlive() {
        keepAliveTimer?.invalidate()
        let timer = Timer(timeInterval: keepAliveInterval, repeats: true) { _ in
            guard let loc = lastLocation else { return }
            injectOnce(location: loc)
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAliveTimer = timer
    }

    /// Starts a location simulation of specified argument "location"
    static func startLocSim(location: CLLocation) {
        lastLocation = location
        DispatchQueue.main.async {
            injectOnce(location: location)
            startKeepAlive()
            post_required_timezone_update();
        }
    }

    /// Stops location simulation
    static func stopLocSim(){
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        lastLocation = nil
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
