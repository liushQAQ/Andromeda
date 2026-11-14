//
//  RouteSimulator.swift
//  Andromeda
//
//  Route simulation - moves location along a real route with background support
//

import Foundation
import CoreLocation
import MapKit
import UIKit

enum TravelMode: String, CaseIterable {
    case walking = "步行"
    case cycling = "骑行"
    case driving = "驾车"
    
    var speed: Double { // meters per second
        switch self {
        case .walking: return 1.4   // ~5 km/h
        case .cycling: return 5.5   // ~20 km/h
        case .driving: return 13.9  // ~50 km/h
        }
    }
    
    var icon: String {
        switch self {
        case .walking: return "figure.walk"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        }
    }
    
    var transportType: MKDirectionsTransportType {
        switch self {
        case .walking: return .walking
        case .cycling: return .walking
        case .driving: return .automobile
        }
    }
}

class RouteOption: Identifiable, ObservableObject {
    let id = UUID()
    let route: MKRoute
    let index: Int
    
    var name: String {
        if index == 0 { return "最快路线" }
        return "备选路线 \(index)"
    }
    
    var distanceText: String {
        if route.distance >= 1000 {
            return String(format: "%.1f km", route.distance / 1000)
        }
        return String(format: "%.0f m", route.distance)
    }
    
    var etaText: String {
        let minutes = Int(route.expectedTravelTime / 60)
        if minutes > 60 {
            let hours = minutes / 60
            let rem = minutes % 60
            return "\(hours)小时\(rem)分"
        }
        return "\(minutes) 分钟"
    }
    
    init(route: MKRoute, index: Int) {
        self.route = route
        self.index = index
    }
}

class RouteSimulator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var isSimulating: Bool = false
    @Published var isPaused: Bool = false
    @Published var currentPointIndex: Int = 0
    @Published var totalPoints: Int = 0
    @Published var routePolyline: MKPolyline? = nil
    @Published var currentPosition: CLLocationCoordinate2D? = nil
    @Published var progress: Double = 0.0
    @Published var isCalculatingRoute: Bool = false
    @Published var estimatedTime: String = ""
    @Published var travelMode: TravelMode = .driving
    
    @Published var availableRoutes: [RouteOption] = []
    @Published var allRoutePolylines: [MKPolyline] = []
    @Published var selectedRouteIndex: Int = 0

    // MARK: - DriftFix v2 自由路线 + 途径点
    // 老总实测定案：内部道路/步行道不在 Apple 路网里，MKDirections 会把 A/B 强制吸附到
    // 最近的可导航点再算路——看起来像"漂移"，实为路网吸附替换。
    // ① 自由路线(.free)：完全不经过导航引擎，用户点列依序直线插值，点在哪轨迹就在哪；
    // ② 道路导航(.road)：MKDirections 不支持多途径点（Apple API 限制），A→B、B→C 分段
    //    链式算路拼接，每个用户指定的点都是一段的精确起终点。
    @Published var routeMode: RouteMode = .road
    @Published var userWaypoints: [CLLocationCoordinate2D] = []   // 用户点列(GCJ 显示系)，顺序=起→途经→终
    @Published var waypointModes: [Bool] = []                     // 与 userWaypoints 对齐：true=随机(每次洗牌)，false=固定顺序
    @Published var visitSequenceText: String = ""                 // 本次实际访问顺序（起→#3→#1→终）

    private var routePoints: [CLLocationCoordinate2D] = []
    private var timer: Timer? = nil
    private var altitude: Double = 0.0
    private var speedMultiplier: Double = 1.0
    private let updateInterval: TimeInterval = 1.0

    // MARK: - DriftFix v2.2 速度区间（m/s）
    // 匀速轨迹一眼假。播放时速度在 [min,max] 内慢速随机游走（带回归中值的惯性），
    // 相邻点间距=当前速度×1s。GPX 存档保存的是实际注入序列（变间距），重放逐点还原。
    var speedMinMps: Double = 1.3
    var speedMaxMps: Double = 1.7

    // MARK: - DriftFix 坐标基准自动判定
    // 搜索结果/地图瓦片 = GCJ-02（实测：搜索 pin 落点正确）；
    // 中国大陆 MKDirections 返回的 polyline = WGS-84 真坐标（实测：一点 Calculate Routes 路线整体偏移）。
    // 判据 = polyline 首点与请求起点(GCJ) 的距离：>200m 判为 WGS。
    // 判为 WGS 时：注入直接用 polyline 原始点（避免 gcj02ToWgs84 双重转换）；地图显示层转 GCJ。
    private var polylineIsWGS = false
    private var requestStartCoord: CLLocationCoordinate2D? = nil
    
    // Background handling
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let locationManager = CLLocationManager()
    
    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }
    
    func calculateRoutes(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D, mode: TravelMode, speedMult: Double, completion: @escaping (Bool, String?) -> Void) {
        isCalculatingRoute = true
        travelMode = mode
        speedMultiplier = speedMult
        
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end))
        request.transportType = mode.transportType
        request.requestsAlternateRoutes = true
        
        let directions = MKDirections(request: request)
        directions.calculate { [weak self] response, error in
            DispatchQueue.main.async {
                self?.isCalculatingRoute = false
                if let error = error {
                    completion(false, "Route error: \(error.localizedDescription)")
                    return
                }
                guard let routes = response?.routes, !routes.isEmpty else {
                    completion(false, "No route found")
                    return
                }
                self?.availableRoutes = routes.enumerated().map { RouteOption(route: $0.element, index: $0.offset) }

                // DriftFix: 判定 polyline 基准（WGS-84 vs GCJ-02）
                var isWGS = false
                if let firstRoute = routes.first {
                    let firstCoords = CoordTransform.polylineCoordinates(firstRoute.polyline)
                    if let first = firstCoords.first {
                        let d = CLLocation(latitude: first.latitude, longitude: first.longitude)
                            .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
                        isWGS = d > 200.0
                    }
                }
                self?.polylineIsWGS = isWGS
                self?.requestStartCoord = start

                // DriftFix: 显示用 polyline 转 GCJ（WGS 线画在 GCJ 瓦片上会整体偏移）
                self?.allRoutePolylines = routes.map {
                    isWGS ? CoordTransform.displayPolyline($0.polyline) : $0.polyline
                }
                self?.selectRoute(at: 0)
                completion(true, nil)
            }
        }
    }
    
    func selectRoute(at index: Int) {
        guard index < availableRoutes.count else { return }
        selectedRouteIndex = index
        let route = availableRoutes[index].route
        
        let pointCount = route.polyline.pointCount
        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pointCount)
        route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        
        let effectiveSpeed = travelMode.speed * speedMultiplier
        routePoints = interpolateRoute(coords: coords, speed: effectiveSpeed, interval: updateInterval)
        totalPoints = routePoints.count
        // DriftFix: 显示用副本转 GCJ；注入点(routePoints)保持 polyline 原始坐标
        routePolyline = polylineIsWGS ? CoordTransform.displayPolyline(route.polyline) : route.polyline
        
        let totalDistance = route.distance
        let timeSeconds = totalDistance / effectiveSpeed
        let minutes = Int(timeSeconds / 60)
        let seconds = Int(timeSeconds) % 60
        estimatedTime = minutes > 60 ? "\(minutes/60)h \(minutes%60)m" : "\(minutes)m \(seconds)s"
    }
    
    private func interpolateRoute(coords: [CLLocationCoordinate2D], speed: Double, interval: TimeInterval) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2 else { return coords }
        let stepDistance = speed * interval
        var result: [CLLocationCoordinate2D] = [coords[0]]
        var remainingDistance: Double = 0.0

        for i in 1..<coords.count {
            let from = coords[i-1]; let to = coords[i]
            let segmentDistance = distanceBetween(from, to)
            guard segmentDistance > 0 else { continue }
            var coveredInSegment = remainingDistance > 0 ? -remainingDistance : 0.0

            while coveredInSegment + stepDistance <= segmentDistance {
                coveredInSegment += stepDistance
                let fraction = coveredInSegment / segmentDistance
                let lat = from.latitude + (to.latitude - from.latitude) * fraction
                let lng = from.longitude + (to.longitude - from.longitude) * fraction
                result.append(CLLocationCoordinate2D(latitude: lat, longitude: lng))
            }
            remainingDistance = segmentDistance - coveredInSegment
        }
        if let last = coords.last { result.append(last) }
        return result
    }

    /// DriftFix v2.2 变速插值：沿点列前进，每步距离=当前速度×interval，
    /// 速度在 [min,max] 内慢速随机游走（向区间中值回归 + 随机漂移），杜绝匀速。
    private func interpolateVariableRoute(coords: [CLLocationCoordinate2D], minSpeed: Double, maxSpeed: Double, interval: TimeInterval) -> [CLLocationCoordinate2D] {
        guard coords.count >= 2 else { return coords }
        let lo = max(minSpeed, 0.1)
        let hi = max(maxSpeed, lo + 0.05)
        let mid = (lo + hi) / 2
        var result: [CLLocationCoordinate2D] = [coords[0]]
        var speed = mid
        for i in 1..<coords.count {
            let from = coords[i - 1]
            let to = coords[i]
            var segRemaining = distanceBetween(from, to)
            guard segRemaining > 0 else { continue }
            var traveled: Double = 0
            while segRemaining - traveled > 0.05 {
                // 慢速游走：小步漂移 + 向中值回归，避免速度突变
                let drift = Double.random(in: -0.25...0.25) * (hi - lo) + (mid - speed) * 0.3
                speed = min(max(speed + drift, lo), hi)
                var step = speed * interval
                if traveled + step > segRemaining { step = segRemaining - traveled }
                let t = (traveled + step) / segRemaining
                result.append(CLLocationCoordinate2D(
                    latitude: from.latitude + (to.latitude - from.latitude) * t,
                    longitude: from.longitude + (to.longitude - from.longitude) * t
                ))
                traveled += step
            }
        }
        if let last = coords.last, let lastResult = result.last,
           lastResult.latitude != last.latitude || lastResult.longitude != last.longitude {
            result.append(last)
        }
        return result
    }
    
    private func distanceBetween(_ c1: CLLocationCoordinate2D, _ c2: CLLocationCoordinate2D) -> Double {
        return CLLocation(latitude: c1.latitude, longitude: c1.longitude).distance(from: CLLocation(latitude: c2.latitude, longitude: c2.longitude))
    }

    // MARK: - DriftFix v2 路线模式与点列管理

    enum RouteMode: String, CaseIterable, Identifiable {
        case road = "road"
        case free = "free"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .road: return "道路导航"
            case .free: return "自由路线"
            }
        }
    }

    /// 起点卡：设 userWaypoints[0]（保留已有途经点）。
    func setStart(_ coord: CLLocationCoordinate2D) {
        if userWaypoints.isEmpty { userWaypoints = [coord] } else { userWaypoints[0] = coord }
    }

    /// 终点卡：设最后一个点（保留已有途经点）。
    func setEnd(_ coord: CLLocationCoordinate2D) {
        if userWaypoints.count < 2 { userWaypoints.append(coord) } else { userWaypoints[userWaypoints.count - 1] = coord }
    }

    /// 地图选点添加：插入在终点之前（终点保持收尾）。
    func addPickedWaypoint(_ coord: CLLocationCoordinate2D) {
        if userWaypoints.count < 2 { userWaypoints.append(coord) }
        else { userWaypoints.insert(coord, at: userWaypoints.count - 1) }
    }

    func removeWaypoint(at index: Int) {
        guard userWaypoints.indices.contains(index) else { return }
        userWaypoints.remove(at: index)
        if waypointModes.indices.contains(index) { waypointModes.remove(at: index) }
    }

    /// 途经点行：固定顺序 ⇄ 随机 切换
    func toggleWaypointMode(at index: Int) {
        guard userWaypoints.indices.contains(index) else { return }
        while waypointModes.count < userWaypoints.count { waypointModes.append(false) }
        waypointModes[index].toggle()
    }

    // MARK: - DriftFix v2.3 访问序列生成（多自由度组合）
    // ① 每个途经点独立标签：固定顺序（保持相对次序、必到）/ 随机（洗牌+可跳过）
    // ② 随机点每次 Calculate/每圈重新洗牌，随机插入固定点序列的空隙
    // ③ 随机跳过概率只作用于随机点（固定点必到）
    // ④ 起终点随机互换 = 奇数圈反向（往返绕圈）
    // ⑤ 绕圈次数：整序列重复，每圈重新组合，接缝自动去重
    func generateVisitSequence(skipProbability: Double, swapEnds: Bool, loops: Int) -> [Int] {
        let n = userWaypoints.count
        guard n >= 2 else { return [0] }
        let middle = Array(1...(n - 2))
        let skip = min(max(skipProbability, 0), 1)
        let modes = waypointModes
        let modeAt: (Int) -> Bool = { $0 < modes.count && modes[$0] }

        var out: [Int] = [0]
        let loopCount = max(1, loops)
        for l in 0..<loopCount {
            var seq = middle.filter { !modeAt($0) }          // 固定点：保持相对顺序
            var wilds = middle.filter { modeAt($0) }          // 随机点
            if skip > 0 {
                wilds = wilds.filter { Double.random(in: 0...1) >= skip }
            }
            wilds.shuffle()
            for w in wilds {
                seq.insert(w, at: Int.random(in: 0...seq.count))
            }
            var leg = [0] + seq + [n - 1]
            if swapEnds && l % 2 == 1 {
                leg = [n - 1] + leg.dropFirst().dropLast().reversed() + [0]
            }
            for i in leg {
                if let last = out.last, last == i { continue }  // 圈间接缝去重
                out.append(i)
            }
        }
        visitSequenceText = out.map { $0 == 0 ? "起" : ($0 == n - 1 ? "终" : "#\($0)") }.joined(separator: " → ")
        return out
    }

    /// 自由路线：完全不经过导航引擎。用户点列(GCJ)依序直线插值 → routePoints。
    /// polylineIsWGS=false → updateLocation 逐点 GCJ→WGS 注入（与地图点选单点同一条正确路径）；
    /// 显示线 = 用户点原样连线（GCJ 画在 GCJ 瓦片上：零偏移、零吸附，内部道路随便走）。
    func buildFreeRoute(points: [CLLocationCoordinate2D], minSpeed: Double, maxSpeed: Double) {
        guard points.count >= 2 else { return }
        let effectiveSpeed = max((minSpeed + maxSpeed) / 2, 0.2)
        polylineIsWGS = false
        routePoints = interpolateVariableRoute(coords: points, minSpeed: minSpeed, maxSpeed: maxSpeed, interval: updateInterval)
        totalPoints = routePoints.count
        currentPointIndex = 0
        progress = 0.0
        isSimulating = false
        isPaused = false
        currentPosition = nil
        availableRoutes = []
        allRoutePolylines = []
        routePolyline = MKPolyline(coordinates: points, count: points.count)
        var totalMeters: Double = 0
        for i in 1..<userWaypoints.count {
            totalMeters += distanceBetween(points[i - 1], points[i])
        }
        let secs = totalMeters / effectiveSpeed
        let m = Int(secs) / 60
        estimatedTime = m > 60 ? "\(m/60)h \(m%60)m" : "\(m)m \(Int(secs) % 60)s"
    }

    /// 道路导航 + 任意多途径点：MKDirections 不支持多途经点，按 A→B、B→C… 分段链式算路拼接。
    /// 任一段无导航路线 → 直接失败并提示改用自由路线（绝不做路网吸附替换——这就是本修复要根除的行为）。
    func calculateFlexibleRoute(points: [CLLocationCoordinate2D], mode: TravelMode, minSpeed: Double, maxSpeed: Double, completion: @escaping (Bool, String?) -> Void) {
        guard points.count >= 2 else { completion(false, "至少需要起点和终点两个点"); return }
        isCalculatingRoute = true
        travelMode = mode
        speedMultiplier = 1.0
        availableRoutes = []
        allRoutePolylines = []
        selectedRouteIndex = 0

        let legs = zip(points, points.dropFirst()).map { (from: $0.0, to: $0.1) }
        var rawCoords: [CLLocationCoordinate2D] = []      // 注入用（保持返回坐标系）
        var displayCoords: [CLLocationCoordinate2D] = []  // 显示用（GCJ）
        var totalDistance: Double = 0
        var detectedWGS: Bool? = nil
        var firstError: String? = nil

        func runLeg(_ idx: Int) {
            if idx >= legs.count {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.isCalculatingRoute = false
                    if let err = firstError {
                        completion(false, err)
                        return
                    }
                    self.polylineIsWGS = detectedWGS ?? false
                    self.requestStartCoord = points.first
                    let eff = max((minSpeed + maxSpeed) / 2, 0.2)
                    self.routePoints = self.interpolateVariableRoute(coords: rawCoords, minSpeed: minSpeed, maxSpeed: maxSpeed, interval: self.updateInterval)
                    self.totalPoints = self.routePoints.count
                    self.currentPointIndex = 0
                    self.progress = 0.0
                    self.isSimulating = false
                    self.isPaused = false
                    self.currentPosition = nil
                    if displayCoords.count >= 2 {
                        self.routePolyline = MKPolyline(coordinates: displayCoords, count: displayCoords.count)
                    }
                    let secs = totalDistance / eff
                    let m = Int(secs) / 60
                    self.estimatedTime = m > 60 ? "\(m/60)h \(m%60)m" : "\(m)m \(Int(secs) % 60)s"
                    completion(true, nil)
                }
                return
            }
            let leg = legs[idx]
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: leg.from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: leg.to))
            request.transportType = mode.transportType
            request.requestsAlternateRoutes = false
            let directions = MKDirections(request: request)
            directions.calculate { [weak self] response, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let error = error {
                        if firstError == nil { firstError = "第 \(idx + 1) 段算路失败: \(error.localizedDescription)" }
                        runLeg(idx + 1)
                        return
                    }
                    guard let routes = response?.routes, let best = routes.first, best.polyline.pointCount >= 2 else {
                        if firstError == nil {
                            firstError = "第 \(idx + 1) 段无导航路线（内部道路/步行道不在路网）——请改用「自由路线」模式"
                        }
                        runLeg(idx + 1)
                        return
                    }
                    let pc = best.polyline.pointCount
                    var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pc)
                    best.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pc))
                    if detectedWGS == nil, let first = coords.first {
                        let d = CLLocation(latitude: first.latitude, longitude: first.longitude)
                            .distance(from: CLLocation(latitude: leg.from.latitude, longitude: leg.from.longitude))
                        detectedWGS = d > 200.0
                    }
                    rawCoords += coords
                    if detectedWGS == true {
                        displayCoords += coords.map { CoordTransform.wgs84ToGcj02($0) }
                    } else {
                        displayCoords += coords
                    }
                    if idx + 1 < legs.count && rawCoords.count > 1 {
                        rawCoords.removeLast()
                        displayCoords.removeLast()
                    }
                    totalDistance += best.distance
                    runLeg(idx + 1)
                }
            }
        }
        runLeg(0)
    }
    
    func startSimulation(altitude: Double = 0.0) {
        guard !routePoints.isEmpty else { return }
        self.altitude = altitude
        currentPointIndex = 0
        isSimulating = true
        isPaused = false
        progress = 0.0
        
        // Request "Always" authorization for background
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        
        startBackgroundTask()
        updateLocation(at: 0)
        
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.advanceToNextPoint()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }
    
    func togglePause() {
        if isPaused {
            isPaused = false
            startBackgroundTask()
            timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
                self?.advanceToNextPoint()
            }
            RunLoop.current.add(timer!, forMode: .common)
        } else {
            isPaused = true
            timer?.invalidate()
            timer = nil
            endBackgroundTask()
        }
    }
    
    func stopSimulation() {
        timer?.invalidate()
        timer = nil
        isSimulating = false
        isPaused = false
        currentPointIndex = 0
        progress = 0.0
        routePoints = []
        routePolyline = nil
        allRoutePolylines = []
        availableRoutes = []
        currentPosition = nil
        estimatedTime = ""
        locationManager.stopUpdatingLocation()
        endBackgroundTask()
        LocSimManager.stopLocSim()
    }
    
    private func advanceToNextPoint() {
        currentPointIndex += 1
        
        if currentPointIndex >= routePoints.count {
            // Route completed! 
            // We STOP the timer but do NOT call stopLocSim()
            // This keeps the user's location fixed at the destination.
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.timer?.invalidate()
                self.timer = nil
                self.isSimulating = false // UI shows it's finished
                self.isPaused = false
                self.progress = 1.0
                self.endBackgroundTask()
                self.locationManager.stopUpdatingLocation()
                // IMPORTANT: We do NOT call LocSimManager.stopLocSim() here
                // so the fake location stays at the last point.
            }
            return
        }
        
        updateLocation(at: currentPointIndex)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.progress = Double(self.currentPointIndex) / Double(max(self.totalPoints - 1, 1))
        }
    }
    
    private func updateLocation(at index: Int) {
        guard index < routePoints.count else { return }
        var coord = routePoints[index]
        
        // MARK: - Human-like Realism
        // Add tiny random jitter (0.5 - 1.5 meters) to look less "robotic"
        let latJitter = Double.random(in: -0.00001...0.00001)
        let lngJitter = Double.random(in: -0.00001...0.00001)
        coord.latitude += latJitter
        coord.longitude += lngJitter
        
        // DriftFix: 显示层坐标 —— polyline 判为 WGS 时转 GCJ，否则原样
        let displayCoord = polylineIsWGS ? CoordTransform.wgs84ToGcj02(coord) : coord
        DispatchQueue.main.async { [weak self] in
            self?.currentPosition = displayCoord
        }

        // DriftFix: 注入坐标 —— polyline 判为 WGS 时直接用原始点（避免 GCJ→WGS 双重转换）
        let wgsCoord = polylineIsWGS ? coord : CoordTransform.gcj02ToWgs84(coord)
        let location = CLLocation(
            coordinate: wgsCoord,
            altitude: altitude + Double.random(in: -0.5...0.5), // Slight altitude jitter
            horizontalAccuracy: Double.random(in: 3.0...6.0),   // Varying accuracy
            verticalAccuracy: 5,
            timestamp: Date()
        )
        LocSimManager.startLocSim(location: location)
    }
    
    // MARK: - DriftFix 线路保存/加载
    // 存的是"实际注入序列"（WGS-84 真坐标）写成标准 GPX 落盘到 Documents/AndromedaRoutes/：
    // 重放时直接把 GPX 点列作为 routePoints（polylineIsWGS=true 直注），不再依赖基准判定；
    // 文件在 Files App 可见，可导出备份，也可走原有 GPX 导入按钮重灌。
    static func routesDirectory() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndromedaRoutes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func listSavedRoutes() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: routesDirectory(), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "gpx" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// 保存当前已算好的路线（routePoints 换算成实际注入的 WGS 序列）。
    func saveCurrentRoute(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, routePoints.count >= 2 else { return false }
        let wgsPoints = routePoints.map { polylineIsWGS ? $0 : CoordTransform.gcj02ToWgs84($0) }
        var gpx = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        gpx += "<gpx version=\"1.1\" creator=\"Andromeda DriftFix\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        gpx += "<trk><name>\(Self.xmlEscape(name))</name><trkseg>\n"
        for p in wgsPoints {
            gpx += String(format: "<trkpt lat=\"%.7f\" lon=\"%.7f\"/>\n", p.latitude, p.longitude)
        }
        gpx += "</trkseg></trk>\n</gpx>\n"
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
        let url = Self.routesDirectory().appendingPathComponent("\(safe).gpx")
        do {
            try gpx.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// 加载已存线路：GPX 点列（WGS）直接作为注入序列，显示线转 GCJ。
    func loadSavedRoute(at url: URL) -> Bool {
        guard let result = GPXParser.parse(url: url), !result.isEmpty else { return false }
        let coords = result.allCoordinates
        guard coords.count >= 2 else { return false }

        timer?.invalidate()
        timer = nil
        polylineIsWGS = true            // 存档即 WGS 真坐标，注入直用
        routePoints = coords
        totalPoints = coords.count
        currentPointIndex = 0
        progress = 0.0
        isSimulating = false
        isPaused = false
        currentPosition = nil
        allRoutePolylines = []
        availableRoutes = []
        routePolyline = CoordTransform.displayPolyline(
            MKPolyline(coordinates: coords, count: coords.count)
        )
        let secs = Double(coords.count) * updateInterval
        let minutes = Int(secs) / 60
        estimatedTime = minutes > 60 ? "\(minutes/60)h \(minutes%60)m" : "\(minutes)m \(Int(secs) % 60)s"
        return true
    }

    // MARK: - DriftFix v2.5 线路管理（重命名/删除/排序/分享导出）
    struct SavedRouteInfo: Identifiable {
        let url: URL
        let name: String
        let date: Date
        let sizeBytes: Int
        var id: String { url.lastPathComponent }
    }

    enum SavedSort: String, CaseIterable {
        case dateDesc = "时间↓"
        case dateAsc = "时间↑"
        case nameAsc = "名称A-Z"
        case nameDesc = "名称Z-A"
    }

    static func savedRouteInfos(sort: SavedSort) -> [SavedRouteInfo] {
        let fm = FileManager.default
        let infos = listSavedRoutes().compactMap { url -> SavedRouteInfo? in
            guard let st = try? fm.attributesOfItem(atPath: url.path) else { return nil }
            let date = (st[.modificationDate] as? Date) ?? Date.distantPast
            let size = (st[.size] as? Int) ?? 0
            return SavedRouteInfo(url: url, name: url.deletingPathExtension().lastPathComponent, date: date, sizeBytes: size)
        }
        switch sort {
        case .dateDesc: return infos.sorted { $0.date > $1.date }
        case .dateAsc: return infos.sorted { $0.date < $1.date }
        case .nameAsc: return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDesc: return infos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        }
    }

    static func deleteSavedRoute(at url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    /// 重命名（目标同名自动加 (2)(3)… 后缀，绝不覆盖别人的线路）。
    static func renameSavedRoute(at url: URL, to rawName: String) -> URL? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "?", with: "_")
        var target = routesDirectory().appendingPathComponent(safe + ".gpx")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path)
                && target.standardizedFileURL.path != url.standardizedFileURL.path {
            target = routesDirectory().appendingPathComponent("\(safe) (\(n)).gpx")
            n += 1
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    // MARK: - Background Task Management
    private func startBackgroundTask() {
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "RouteSimulation") { [weak self] in
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
