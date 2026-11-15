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
    @Published var estimatedMeters: Double = 0                    // DriftFix v2.6: 预估总里程（米）
    @Published var estimatedSteps: Int = 0                        // DriftFix v2.6: 预估步数 = 里程 ÷ 步幅

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
    private let strideForEstimate: Double = 1.07   // 步幅取老总真实轨迹: 15.93km/14911步 = 1.068m/步
    private var polylineIsWGS = false
    private var requestStartCoord: CLLocationCoordinate2D? = nil
    
    // Background handling
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private let locationManager = CLLocationManager()
    
    override init() {
        super.init()
        if let raw = UserDefaults.standard.string(forKey: "andromedaRouteMode"),
           let saved = RouteMode(rawValue: raw) {
            routeMode = saved
        }
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
        case draw = "draw"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .road: return "道路导航"
            case .free: return "自由路线"
            case .draw: return "手画路线"
            }
        }
    }

    /// 起点卡：设 userWaypoints[0]（保留已有途经点）。
    func setStart(_ coord: CLLocationCoordinate2D) {
        normalizeModes()
        if userWaypoints.isEmpty { userWaypoints = [coord] } else { userWaypoints[0] = coord }
    }

    /// 终点卡：设最后一个点（保留已有途经点）。
    func setEnd(_ coord: CLLocationCoordinate2D) {
        normalizeModes()
        if userWaypoints.count < 2 {
            userWaypoints.append(coord)
            waypointModes.append(false)
        } else {
            userWaypoints[userWaypoints.count - 1] = coord
        }
    }

    /// 地图选点添加：插入在终点之前（终点保持收尾）。
    func addPickedWaypoint(_ coord: CLLocationCoordinate2D) {
        normalizeModes()
        if userWaypoints.count < 2 {
            userWaypoints.append(coord)
            waypointModes.append(false)
        } else {
            userWaypoints.insert(coord, at: userWaypoints.count - 1)
            waypointModes.insert(false, at: max(0, userWaypoints.count - 1))
        }
    }

    func removeWaypoint(at index: Int) {
        normalizeModes()
        guard userWaypoints.indices.contains(index) else { return }
        userWaypoints.remove(at: index)
        if waypointModes.indices.contains(index) { waypointModes.remove(at: index) }
    }

    /// DriftFix v2.6: modes 数组与点列长度对齐（防越界闪退——确认添加崩溃的根因）
    private func normalizeModes() {
        while waypointModes.count < userWaypoints.count { waypointModes.append(false) }
        if waypointModes.count > userWaypoints.count {
            waypointModes = Array(waypointModes.prefix(userWaypoints.count))
        }
    }

    /// 途经点行：固定顺序 ⇄ 随机 切换
    func toggleWaypointMode(at index: Int) {
        guard userWaypoints.indices.contains(index) else { return }
        while waypointModes.count < userWaypoints.count { waypointModes.append(false) }
        waypointModes[index].toggle()
    }

    // MARK: - DriftFix v2.7 访问序列生成（就近排序，杜绝交叉乱穿）
    // 旧版把随机点「随机位置 insert」——线路来回交叉，看起来像 GPS 漂移。
    // 新版规则：
    // ① 固定点保持用户给定次序（必到）；
    // ② 随机点先按几何位置归到「相邻锚点之间的空档」，再沿空档做就近串联，
    //    只保留「前两个最近里随机取一个」的轻微随机（有变化但不打结）；
    // ③ 多生成几组候选，取「线段交叉最少 → 总里程最短」的一组；
    // ④ 随机跳过只作用于随机点；起终点互换 = 奇数圈反向（往返）；绕圈次数 = 整序列重复。
    func generateVisitSequence(skipProbability: Double, swapEnds: Bool, loops: Int) -> [Int] {
        normalizeModes()
        let n = userWaypoints.count
        guard n >= 2 else { return [0] }
        let skip = min(max(skipProbability, 0), 1)
        let modes = waypointModes

        var out: [Int] = [0]
        let loopCount = max(1, loops)
        for l in 0..<loopCount {
            var fixed: [Int] = []
            var wilds: [Int] = []
            if n > 2 {
                for m in 1...(n - 2) {
                    let isWild = m < modes.count && modes[m]
                    if isWild {
                        if skip > 0 && Double.random(in: 0.0...1.0) < skip { continue }
                        wilds.append(m)
                    } else {
                        fixed.append(m)
                    }
                }
            }
            var leg = smoothOrder(fixed: fixed, wilds: wilds, n: n)
            if swapEnds && l % 2 == 1 {
                var rev: [Int] = [n - 1]
                var i = leg.count - 2
                while i >= 1 {
                    rev.append(leg[i])
                    i -= 1
                }
                rev.append(0)
                leg = rev
            }
            for i in leg {
                if let last = out.last, last == i { continue }  // 圈间接缝去重
                out.append(i)
            }
        }
        visitSequenceText = out.map { $0 == 0 ? "起" : ($0 == n - 1 ? "终" : "#\($0)") }.joined(separator: " → ")
        return out
    }

    /// 锚点（起 → 固定点… → 终）为骨架，随机点插进各自最贴合的相邻锚点空档里就地串联。
    /// 候选里挑交叉最少、里程最短的一条。
    private func smoothOrder(fixed: [Int], wilds: [Int], n: Int) -> [Int] {
        var anchors: [Int] = [0]
        anchors.append(contentsOf: fixed)
        anchors.append(n - 1)
        if wilds.isEmpty { return anchors }

        var best: [Int] = anchors
        var bestCross = Int.max
        var bestLen = Double.greatestFiniteMagnitude
        for _ in 0..<12 {
            let cand = anchorOrder(anchors: anchors, wilds: wilds, jitter: true)
            let cross = crossingCount(cand)
            let len = pathLength(cand)
            if cross < bestCross || (cross == bestCross && len < bestLen) {
                best = cand
                bestCross = cross
                bestLen = len
            }
            if bestCross == 0 { break }
        }
        return best
    }

    private func anchorOrder(anchors: [Int], wilds: [Int], jitter: Bool) -> [Int] {
        var buckets = [[Int]](repeating: [], count: max(anchors.count - 1, 1))
        for w in wilds {
            var bestGap = 0
            var bestD = Double.greatestFiniteMagnitude
            if anchors.count >= 2 {
                for g in 0..<(anchors.count - 1) {
                    let d = pointToSegmentDistance(userWaypoints[w], userWaypoints[anchors[g]], userWaypoints[anchors[g + 1]])
                    if d < bestD {
                        bestD = d
                        bestGap = g
                    }
                }
            }
            buckets[bestGap].append(w)
        }

        var out: [Int] = [anchors[0]]
        for g in 0..<max(anchors.count - 1, 1) {
            var remain = buckets[g]
            var cur = anchors[g]
            while !remain.isEmpty {
                let ordered = remain.sorted {
                    distanceBetween(userWaypoints[cur], userWaypoints[$0]) < distanceBetween(userWaypoints[cur], userWaypoints[$1])
                }
                var pick = 0
                if jitter && ordered.count > 1 && Bool.random() { pick = 1 }
                let next = ordered[pick]
                out.append(next)
                remain.removeAll { $0 == next }
                cur = next
            }
            if g + 1 < anchors.count { out.append(anchors[g + 1]) }
        }
        return out
    }

    private func pathLength(_ order: [Int]) -> Double {
        guard order.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<order.count {
            total += distanceBetween(userWaypoints[order[i - 1]], userWaypoints[order[i]])
        }
        return total
    }

    private func crossingCount(_ order: [Int]) -> Int {
        guard order.count >= 4 else { return 0 }
        let segs = order.count - 1
        var count = 0
        if segs >= 2 {
            for i in 0..<(segs - 1) {
                for j in (i + 2)..<segs {
                    if segmentsIntersect(userWaypoints[order[i]], userWaypoints[order[i + 1]],
                                         userWaypoints[order[j]], userWaypoints[order[j + 1]]) {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    private func metersXY(_ c: CLLocationCoordinate2D, origin: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let latScale = 111320.0
        let lonScale = 111320.0 * cos(origin.latitude * Double.pi / 180)
        return ((c.longitude - origin.longitude) * lonScale, (c.latitude - origin.latitude) * latScale)
    }

    private func segmentsIntersect(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D,
                                   _ c: CLLocationCoordinate2D, _ d: CLLocationCoordinate2D) -> Bool {
        let pa = metersXY(a, origin: a)
        let pb = metersXY(b, origin: a)
        let pc = metersXY(c, origin: a)
        let pd = metersXY(d, origin: a)
        func orient(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double), _ r: (x: Double, y: Double)) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        let d1 = orient(pa, pb, pc)
        let d2 = orient(pa, pb, pd)
        let d3 = orient(pc, pd, pa)
        let d4 = orient(pc, pd, pb)
        let cross1 = (d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)
        let cross2 = (d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)
        return cross1 && cross2
    }

    /// DriftFix v2.4 自由路线（智能版）：
    ///   短段（≤阈值）直线连接（用户点精确）；长段优先步行导航贴合真实街道——
    ///   但端点容差 150m 内才采用（绝不把用户的点替换成别的点），失败/偏差过大 → 弯曲化兜底；
    ///   全程平滑 + 变速插值。杜绝直线穿越，也杜绝路网吸附到"别的点"。
    func buildSmartFreeRoute(points: [CLLocationCoordinate2D], minSpeed: Double, maxSpeed: Double, snapLongSegments: Bool, completion: @escaping (Bool, String?) -> Void) {
        guard points.count >= 2 else { completion(false, "至少需要两个点"); return }
        let threshold = 350.0
        let tolerance = 150.0
        var pathCoords: [CLLocationCoordinate2D] = [points[0]]
        let legs = zip(points, points.dropFirst()).map { (from: $0.0, to: $0.1) }

        func appendSegment(_ seg: [CLLocationCoordinate2D]) {
            if let last = pathCoords.last, let first = seg.first, distanceBetween(last, first) < 1.0 {
                pathCoords += Array(seg.dropFirst())
            } else {
                pathCoords += seg
            }
        }

        func finalize() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                var shaped = self.smoothPolyline(pathCoords, passes: 2)
                shaped[0] = points[0]
                shaped[shaped.count - 1] = points[points.count - 1]
                // DriftFix v2.7: 按速度区间重采样成 1 秒一点——节点直接播放会一秒跳几十米，
                // 在 App 里看起来就是"GPS 漂移"。重采样后每秒位移 = 真实速度，轨迹连续。
                let resampled = self.interpolateVariableRoute(coords: shaped, minSpeed: minSpeed, maxSpeed: maxSpeed, interval: self.updateInterval)
                self.polylineIsWGS = false
                self.routePoints = resampled.count >= 2 ? resampled : shaped
                self.totalPoints = self.routePoints.count
                self.currentPointIndex = 0
                self.progress = 0.0
                self.isSimulating = false
                self.isPaused = false
                self.currentPosition = nil
                self.availableRoutes = []
                self.allRoutePolylines = []
                self.routePolyline = MKPolyline(coordinates: shaped, count: shaped.count)
                var totalMeters: Double = 0
                for i in 1..<shaped.count {
                    totalMeters += self.distanceBetween(shaped[i - 1], shaped[i])
                }
                let eff = max((minSpeed + maxSpeed) / 2, 0.2)
                let secs = totalMeters / eff
                let m = Int(secs) / 60
                self.estimatedTime = m > 60 ? "\(m/60)h \(m%60)m" : "\(m)m \(Int(secs) % 60)s"
                self.estimatedMeters = totalMeters
                self.estimatedSteps = Int(totalMeters / strideForEstimate)
                completion(true, nil)
            }
        }

        func runLeg(_ idx: Int) {
            if idx >= legs.count {
                finalize()
                return
            }
            let leg = legs[idx]
            let legDistance = distanceBetween(leg.from, leg.to)

            if legDistance <= threshold || !snapLongSegments {
                // DriftFix v2.8: 任何一段都走自然化（短段幅度自动收敛到 <1m），不再有一条直尺线
                appendSegment(self.curvedSegment(from: leg.from, to: leg.to))
                runLeg(idx + 1)
                return
            }

            // 长段：尝试步行导航贴合真实街道（端点容差内才采用）
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: leg.from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: leg.to))
            request.transportType = .walking
            MKDirections(request: request).calculate { response, error in
                DispatchQueue.main.async { [weak self] in
                    guard self != nil else { return }
                    var accepted = false
                    if let routes = response?.routes, let best = routes.first, best.polyline.pointCount >= 2 {
                        let pc = best.polyline.pointCount
                        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pc)
                        best.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pc))
                        if let f0 = coords.first, let l0 = coords.last {
                            let df = self!.distanceBetween(f0, leg.from)
                            let dt = self!.distanceBetween(l0, leg.to)
                            // 距离优先（老总 v2.8）：步行导航绕行超过 18% 一律不采用，
                            // 改走低幅自然弯——杜绝"两点之间被导航拉得很长"。
                            let detourRatio = best.distance / max(legDistance, 1.0)
                            if df <= tolerance && dt <= tolerance && detourRatio <= 1.18 {
                                let gcj = coords.map { CoordTransform.wgs84ToGcj02($0) }
                                appendSegment(gcj)
                                accepted = true
                            }
                        }
                    }
                    if !accepted {
                        appendSegment(self!.curvedSegment(from: leg.from, to: leg.to))
                    }
                    runLeg(idx + 1)
                }
            }
        }
        runLeg(0)
    }

    /// DriftFix v2.4 手画路线：简化（DP 5m）→ 平滑（2 轮）→ 变速重采样就绪。
    func buildFromDrawnPath(points: [CLLocationCoordinate2D], minSpeed: Double, maxSpeed: Double) -> Bool {
        guard points.count >= 2 else { return false }
        let simplified = simplifyPolyline(points, epsilon: 5.0)
        let shaped = smoothPolyline(simplified, passes: 2)
        guard shaped.count >= 2 else { return false }
        let resampled = interpolateVariableRoute(coords: shaped, minSpeed: minSpeed, maxSpeed: maxSpeed, interval: updateInterval)
        polylineIsWGS = false
        routePoints = resampled.count >= 2 ? resampled : shaped
        totalPoints = routePoints.count
        currentPointIndex = 0
        progress = 0.0
        isSimulating = false
        isPaused = false
        currentPosition = nil
        availableRoutes = []
        allRoutePolylines = []
        routePolyline = MKPolyline(coordinates: shaped, count: shaped.count)
        var totalMeters: Double = 0
        for i in 1..<shaped.count {
            totalMeters += distanceBetween(shaped[i - 1], shaped[i])
        }
        let eff = max((minSpeed + maxSpeed) / 2, 0.2)
        let secs = totalMeters / eff
        let m = Int(secs) / 60
        estimatedTime = m > 60 ? "\(m/60)h \(m%60)m" : "\(m)m \(Int(secs) % 60)s"
        estimatedMeters = totalMeters
        estimatedSteps = Int(totalMeters / strideForEstimate)
        return true
    }

    /// DriftFix v2.4 「AI 优化」：手画原始轨迹 → DP 简化(5m) → 两轮平滑 → 自然步态线路
    func optimizeDrawnPath(points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        let simplified = simplifyPolyline(points, epsilon: 5.0)
        return smoothPolyline(simplified, passes: 2)
    }

    // MARK: - DriftFix v2.4 几何工具（平滑/简化/弯曲化）
    private func smoothPolyline(_ input: [CLLocationCoordinate2D], passes: Int) -> [CLLocationCoordinate2D] {
        var pts = input
        for _ in 0..<max(passes, 0) {
            guard pts.count > 2 else { return pts }
            var out: [CLLocationCoordinate2D] = [pts[0]]
            for i in 1..<(pts.count - 1) {
                let a = pts[i - 1], b = pts[i], c = pts[i + 1]
                out.append(CLLocationCoordinate2D(latitude: (a.latitude + 2 * b.latitude + c.latitude) / 4,
                                                  longitude: (a.longitude + 2 * b.longitude + c.longitude) / 4))
            }
            out.append(pts[pts.count - 1])
            pts = out
        }
        return pts
    }

    private func simplifyPolyline(_ pts: [CLLocationCoordinate2D], epsilon: Double) -> [CLLocationCoordinate2D] {
        guard pts.count > 3 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var maxD = 0.0
            var maxI = s
            for i in (s + 1)..<e {
                let d = pointToSegmentDistance(pts[i], pts[s], pts[e])
                if d > maxD { maxD = d; maxI = i }
            }
            if maxD > epsilon {
                keep[maxI] = true
                stack.append((s, maxI))
                stack.append((maxI, e))
            }
        }
        var out: [CLLocationCoordinate2D] = []
        for (i, p) in pts.enumerated() where keep[i] { out.append(p) }
        return out
    }

    private func pointToSegmentDistance(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let latScale = 111320.0
        let lonScale = 111320.0 * cos(a.latitude * Double.pi / 180)
        let ax = a.longitude * lonScale, ay = a.latitude * latScale
        let bx = b.longitude * lonScale, by = b.latitude * latScale
        let px = p.longitude * lonScale, py = p.latitude * latScale
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else {
            return CLLocation(latitude: p.latitude, longitude: p.longitude)
                .distance(from: CLLocation(latitude: a.latitude, longitude: a.longitude))
        }
        var t = ((px - ax) * dx + (py - ay) * dy) / len2
        t = min(max(t, 0), 1)
        let cx = ax + dx * t, cy = ay + dy * t
        return ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
    }

    /// DriftFix v2.8 长段自然化：每 ≈110m 一个几何节点，沿走向做低幅蛇形摆动。
    /// 旧版整段只放 2~4 个摆动点、幅度最大 20m——1km 以上看起来就是一条直尺线（假）。
    /// 现在节点密度跟 GPS 1Hz 的采样量级对齐；横向幅度只 ±0.8~7m 且端点收敛到 0，
    /// 总里程增幅 <0.1%（老总要求：尽量距离最短，不许为了"自然"绕远）。
    private func curvedSegment(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        let d = distanceBetween(from, to)
        guard d > 12 else { return [from, to] }
        let nodeSpacing = 110.0
        let n = max(2, Int((d / nodeSpacing).rounded()))
        let amp = min(max(d * 0.012, 0.8), 7.0)
        let latScale = 111320.0
        let lonScale = 111320.0 * cos(from.latitude * Double.pi / 180)
        let dx = (to.longitude - from.longitude) * lonScale
        let dy = (to.latitude - from.latitude) * latScale
        let ux = dx / d, uy = dy / d
        let px = -uy, py = ux
        let phase1 = Double.random(in: 0...(2 * Double.pi))
        let phase2 = Double.random(in: 0...(2 * Double.pi))
        var out: [CLLocationCoordinate2D] = [from]
        for k in 1..<n {
            let t = Double(k) / Double(n)
            let envelope = sin(Double.pi * t)          // 两端归零，起终点精确
            let lateral = amp * envelope * (0.62 * sin(2 * Double.pi * 1.35 * t + phase1)
                                          + 0.38 * sin(2 * Double.pi * 0.62 * t + phase2))
            let x = dx * t + px * lateral
            let y = dy * t + py * lateral
            out.append(CLLocationCoordinate2D(latitude: from.latitude + y / latScale,
                                              longitude: from.longitude + x / lonScale))
        }
        out.append(to)
        return out
    }

    /// DriftFix v2.8 中间补点：把每段按 spacing 米等分，插入直线插值点（只加点，不改里程）。
    /// 供 UI「中间补点」按钮调用——长段太长的根治法：先在几何上把段拆细，再由 1Hz 重采样出轨迹。
    func densifyPoints(_ points: [CLLocationCoordinate2D], spacing: Double) -> [CLLocationCoordinate2D] {
        guard points.count >= 2, spacing > 20 else { return points }
        var out: [CLLocationCoordinate2D] = [points[0]]
        for i in 1..<points.count {
            let from = points[i - 1]
            let to = points[i]
            let d = distanceBetween(from, to)
            if d > spacing {
                let pieces = max(2, Int((d / spacing).rounded()))
                for k in 1..<pieces {
                    let t = Double(k) / Double(pieces)
                    out.append(CLLocationCoordinate2D(
                        latitude: from.latitude + (to.latitude - from.latitude) * t,
                        longitude: from.longitude + (to.longitude - from.longitude) * t))
                }
            }
            out.append(to)
        }
        return out
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
                    self.estimatedMeters = totalDistance
                    self.estimatedSteps = Int(totalDistance / strideForEstimate)
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

    // MARK: - DriftFix v2.7 线路存档元数据
    // 只存 GPX 点位时，重新载入只有一条线——起终点、途经点、出行方式、速度区间全丢，
    // 点序列空着、也无法「重新生成」。元数据以 base64 塞进 <extensions>，
    // 单文件随 GPX 一起走（导出/分享不丢），老存档无此段自动降级为首末点。
    struct SavedRouteMeta: Codable {
        var mode: String = "free"
        var travelMode: String = TravelMode.walking.rawValue
        var speedMinKmh: Double = 8.0
        var speedMaxKmh: Double = 10.0
        var skipPct: Double = 0
        var swapEnds: Bool = false
        var loops: Int = 1
        var snapLong: Bool = true
        var waypoints: [[Double]] = []      // 用户点列（GCJ 显示系，含起终点）
        var waypointModes: [Bool] = []
    }

    struct RouteLoadResult {
        let ok: Bool
        let meta: SavedRouteMeta?
    }

    private static func metaTag(_ meta: SavedRouteMeta) -> String {
        guard let data = try? JSONEncoder().encode(meta) else { return "" }
        return "<extensions><andromedaMeta encoding=\"base64\">\(data.base64EncodedString())</andromedaMeta></extensions>\n"
    }

    private static func readMeta(from gpx: String) -> SavedRouteMeta? {
        guard let open = gpx.range(of: "<andromedaMeta"),
              let openEnd = gpx.range(of: ">", range: open.upperBound..<gpx.endIndex),
              let close = gpx.range(of: "</andromedaMeta>", range: openEnd.upperBound..<gpx.endIndex) else { return nil }
        let b64 = String(gpx[openEnd.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: b64) else { return nil }
        return try? JSONDecoder().decode(SavedRouteMeta.self, from: data)
    }

    /// 保存当前已算好的路线（routePoints 换算成实际注入的 WGS 序列）+ 元数据。
    func saveCurrentRoute(named rawName: String, meta: SavedRouteMeta? = nil) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, routePoints.count >= 2 else { return false }
        let wgsPoints = routePoints.map { polylineIsWGS ? $0 : CoordTransform.gcj02ToWgs84($0) }
        var gpx = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        gpx += "<gpx version=\"1.1\" creator=\"Andromeda DriftFix\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n"
        gpx += "<trk><name>\(Self.xmlEscape(name))</name>\n"
        if let meta = meta { gpx += Self.metaTag(meta) }
        gpx += "<trkseg>\n"
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

    /// 加载已存线路：GPX 点列（WGS）直接作为注入序列，显示线转 GCJ；
    /// 有元数据则一并恢复起终点/途经点/出行方式/速度区间（点序列与参数全部回填）。
    func loadSavedRoute(at url: URL) -> RouteLoadResult {
        guard let result = GPXParser.parse(url: url), !result.isEmpty else {
            return RouteLoadResult(ok: false, meta: nil)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let coords = result.allCoordinates
        guard coords.count >= 2 else { return RouteLoadResult(ok: false, meta: nil) }

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
        var savedMeters: Double = 0
        for i in 1..<coords.count {
            savedMeters += distanceBetween(coords[i - 1], coords[i])
        }
        estimatedMeters = savedMeters
        estimatedSteps = Int(savedMeters / strideForEstimate)

        let meta = Self.readMeta(from: text)
        var restored: [CLLocationCoordinate2D] = []
        if let m = meta {
            for pair in m.waypoints where pair.count >= 2 {
                restored.append(CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1]))
            }
        }
        if restored.count >= 2 {
            userWaypoints = restored
        } else {
            // 老存档没有元数据：至少用首末点回填起终点，点序列不再是空的
            userWaypoints = [coords[0], coords[coords.count - 1]]
        }
        waypointModes = []
        for i in 0..<userWaypoints.count {
            let flag = (meta?.waypointModes.count ?? 0) > i ? (meta?.waypointModes[i] ?? false) : false
            waypointModes.append(flag)
        }
        if let m = meta {
            routeMode = RouteMode(rawValue: m.mode) ?? routeMode
            travelMode = TravelMode(rawValue: m.travelMode) ?? travelMode
            speedMinMps = m.speedMinKmh / 3.6
            speedMaxMps = m.speedMaxKmh / 3.6
        }
        visitSequenceText = ""
        return RouteLoadResult(ok: true, meta: meta)
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
