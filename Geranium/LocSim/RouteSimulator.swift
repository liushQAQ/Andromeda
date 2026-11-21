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
    // DriftFix v3.2: 自动绕行区域改成「手画」——老总实测矩形框选太傻，
    // 小区/公园/校区基本都不是规整矩形，框大了跑出边界，框小了漏掉一半。
    // 存多边形顶点（GCJ 显示系，首尾不重复、顺序闭合），外接矩形只用于切车道方向。
    @Published var areaPolygon: [CLLocationCoordinate2D]? = nil
    // v2.7.6：圆形区域（中心 + 半径）。参考 LocSuper「扫街」的选法——
    // 大多数人画不出一圈像样的多边形，而「点一下中心、拖一个半径」两步就能选完。
    // 圆形在内部转成 48 边形，面积校验 / 蛇形 / 贴路全部复用，不多一条算法分支。
    @Published var areaCircleCenter: CLLocationCoordinate2D? = nil
    @Published var areaCircleRadius: Double = 300
    @Published var areaTargetKm: Double = 5.0                     // DriftFix v3.0: 目标里程（公里）
    @Published var visitSequenceText: String = ""                 // 本次实际访问顺序（起→#3→#1→终）
    @Published var estimatedMeters: Double = 0                    // DriftFix v2.6: 预估总里程（米）
    @Published var estimatedSteps: Int = 0                        // DriftFix v2.6: 预估步数 = 里程 ÷ 步幅
    // DriftFix v2.9: 手画笔画常驻（存在这里而不是 View 的 @State，关掉面板/退出 App 都不丢）
    @Published var drawnStrokes: [[CLLocationCoordinate2D]] = []
    // v2.7.9 画笔模式（与 drawnStrokes 一 一 对齐）：0=固定（坐标严格照画线，一分不差）；1=随机（沿画线小幅摆动，转成点序列后参与顺序打乱）
    // 老总原话：「更换画笔，画笔样式或者颜色不同，来指定某段区域固定，不随机。」
    @Published var drawnStrokeModes: [Int] = []

    // v2.7.11 改 internal：续跑滑杆（RouteSimView）要读点位显示坐标/序号。
    // didSet：路线重生成（哪怕点数恰好相同）必须把「距起点里程」前缀和缓存一并作废，
    // 否则滑杆会显示上一条线的旧里程（2026-11-19 审计发现）。
    var routePoints: [CLLocationCoordinate2D] = [] {
        didSet { cumDistForCount = -1 }
    }
    private var timer: Timer? = nil
    private var altitude: Double = 0.0
    private var speedMultiplier: Double = 1.0
    private let updateInterval: TimeInterval = 1.0

    // MARK: - DriftFix v3.3 定位报文真实性（参考 wloc 的实测经验）
    // wloc 用改网络定位的方式做假位置，它的配置里精度默认就是 25 米 —— 真实定位本来就不精确。
    // 我们之前每点给 3~6 米、还每秒重摇，等于宣称"比真 GPS 还准"，部分 App 会把这种点当高可信点直接用，
    // 一旦和它自己的判步/配速模型对不上就丢点、重算，表现成跳一下。
    // 现在：水平精度取 4~9 米并慢漂移（十几秒才换一次），垂直精度固定 12 米，海拔不再逐秒抖。
    // 同时把 speed / course 补上 —— 不给的话 CLLocation 里是 -1（无效），App 只能拿两点反推，
    // 遇到停走、拐弯就容易出「99'99"」这类怪值。
    private var lastInjected: (coord: CLLocationCoordinate2D, at: Date)? = nil
    private var reportedAccuracy: Double = 5.0
    private var accuracyNextUpdate = Date.distantPast
    // 起步沉降：locationd 是融合引擎，切换目标后要一两拍才收敛（wloc 的文档也强调 iOS 26 起缓存更重）。
    // 原来第 0 秒投起点、第 1 秒就出发，等于在收敛窗口里就开始走，首段容易被吞或被拉回。
    private var warmupTicks = 0

    // MARK: - DriftFix v2.7.10 轨迹拟真（抹掉「合成感」）
    // 纯等距折线 + 精度恒定 4~9 米，本身就是机器特征：真机每一拍都在 1 米内低频游走，
    // 钻进树荫/桥洞时精度会掉到二三十米、几秒后恢复。这里加的都是界面上看不出来的量：
    //   · 注入坐标低频游走（一阶惯性，相关时间 25 秒，上限 1.2 米）—— 街道级缩放不到 1 像素；
    //     绝不是逐秒独立随机（那是 v3.2 已经修掉的锯齿/漂移）；
    //   · 每 2~6 公里偶发 3~8 秒精度骤降（18~45 米）；
    //   · 垂直精度 8~18 米慢变（原来恒 12 米，固定值本身也是一条特征）。
    // 显示层与存档仍用未加噪的原始折线 —— 地图上看到的还是你画的那条线。
    private var gpsRealism: Bool = (UserDefaults.standard.object(forKey: "andromedaGpsRealism") as? Bool) ?? true
    private var noiseEast: Double = 0.0
    private var noiseNorth: Double = 0.0
    private var noiseLastAt: Date = .distantPast
    private var metersSinceDropout: Double = 0.0
    private var nextDropoutMeters: Double = 2500.0
    private var dropoutUntil: Date = .distantPast
    private var dropoutAccuracy: Double = 25.0
    private var reportedVertical: Double = 12.0
    private var verticalNextUpdate = Date.distantPast

    // MARK: - DriftFix v2.7.12 偶发驻足 / 海拔游走 / 步频联动（对照真人基准图：步频37、爬升30m、走走停停）
    private var strollEnabled = (UserDefaults.standard.object(forKey: "andromedaStrolls") as? Bool) ?? true
    private var strollUntil: Date = .distantPast
    private var nextStrollAt: Date = .distantPast
    private var altitudeBase: Double = 0.0
    private var altNoise: Double = 0.0
    private var altLastAt: Date = .distantPast
    private var currentSpeedMps: Double = 0.0
    private var stepLinkEnabled = (UserDefaults.standard.object(forKey: "andromedaCadenceLink") as? Bool) ?? true
    private var lastLinkAt: Date = .distantPast
    private var lastLinkCadence: Int = 0
    // v2.7.13 防检测加固：速度/航向的缓变噪声（等距点算出来的 speed/course 曲线过分平滑，本身就是机器指纹）
    private var speedNoiseOu: Double = 0.0
    private var courseNoiseOu: Double = 0.0

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
        if let km = UserDefaults.standard.object(forKey: "andromedaAreaTargetKm") as? Double, km >= 0.5 {
            areaTargetKm = km
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
        case area = "area"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .road: return "道路导航"
            case .free: return "自由路线"
            case .draw: return "手画路线"
            case .area: return "区域自动"
            }
        }
    }

    // MARK: - DriftFix v3.0 区域内自动绕行
    // 老总需求：只给起点和终点 + 画一块大区域 + 目标公里数；中间怎么走自动决定，
    // 走满公里数才停，不够就在区域内继续绕；尽量走地图已有的道路、不来回交叉。
    // 做法：区域按长边切成等距「车道」，蛇形（弓字形）串起来——天然不交叉；
    // 每段锚点交给 MKDirections 步行算路贴街道，失败/绕太远则自然弯兜底。
    struct AreaRect: Equatable {
        var south: Double
        var west: Double
        var north: Double
        var east: Double

        static func from(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> AreaRect {
            AreaRect(south: min(a.latitude, b.latitude),
                     west: min(a.longitude, b.longitude),
                     north: max(a.latitude, b.latitude),
                     east: max(a.longitude, b.longitude))
        }

        var isValid: Bool { north > south && east > west }

        var center: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: (south + north) / 2, longitude: (west + east) / 2)
        }

        var widthMeters: Double {
            CLLocation(latitude: center.latitude, longitude: west)
                .distance(from: CLLocation(latitude: center.latitude, longitude: east))
        }

        var heightMeters: Double {
            CLLocation(latitude: south, longitude: center.longitude)
                .distance(from: CLLocation(latitude: north, longitude: center.longitude))
        }

        var summaryText: String {
            String(format: "%.2f × %.2f km", widthMeters / 1000, heightMeters / 1000)
        }

        /// DriftFix v3.2: 由手画多边形取外接矩形
        static func bounding(of poly: [CLLocationCoordinate2D]) -> AreaRect? {
            guard poly.count >= 3 else { return nil }
            let lats = poly.map { $0.latitude }
            let lons = poly.map { $0.longitude }
            guard let s = lats.min(), let n = lats.max(),
                  let w = lons.min(), let e = lons.max() else { return nil }
            return AreaRect(south: s, west: w, north: n, east: e)
        }
    }

    /// 手画区域的外接矩形（只用于选车道方向/判尺寸；蛇形点由多边形裁出来）
    var areaRect: AreaRect? {
        guard let poly = areaPolygon else { return nil }
        return AreaRect.bounding(of: poly)
    }

    /// 手画区域的最低可用门槛（v2.7.4 放宽：原来要 4 万 m²=60 亩，几十亩的场地全被拦下）
    static let minAreaM2: Double = 3000
    static let minSideMeters: Double = 70

    /// 面积的人话写法（老总按「亩」理解场地大小，页面和报错都用这个口径）
    static func areaText(_ m2: Double) -> String {
        if m2 >= 10000 {
            return String(format: "%.1f 万 m²（约 %.0f 亩）", m2 / 10000, m2 / 666.67)
        }
        return String(format: "%.0f m²（约 %.1f 亩）", m2, m2 / 666.67)
    }

    /// 圆形区域 → 多边形（默认 48 边，面积误差 <0.3%）。
    /// 中心 + 半径是 LocSuper「扫街」那套选法：不用画圈，也不会画出自交多边形。
    static func circlePolygon(center: CLLocationCoordinate2D,
                              radiusMeters: Double,
                              segments: Int = 48) -> [CLLocationCoordinate2D] {
        let n = max(12, min(96, segments))
        let r = max(60.0, min(5000.0, radiusMeters))
        let latScale = 111320.0
        let lonScale = max(1.0, 111320.0 * cos(center.latitude * Double.pi / 180))
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t = 2.0 * Double.pi * Double(i) / Double(n)
            out.append(CLLocationCoordinate2D(
                latitude: center.latitude + (r * sin(t)) / latScale,
                longitude: center.longitude + (r * cos(t)) / lonScale))
        }
        return out
    }

    /// 多边形面积（平方米，Shoelace + 米制投影）
    static func polygonAreaM2(_ poly: [CLLocationCoordinate2D]) -> Double {
        guard poly.count >= 3 else { return 0 }
        let lat0 = poly.reduce(0.0) { $0 + $1.latitude } / Double(poly.count)
        let lon0 = poly.reduce(0.0) { $0 + $1.longitude } / Double(poly.count)
        let latScale = 111320.0
        let lonScale = 111320.0 * cos(lat0 * Double.pi / 180)
        guard lonScale > 1 else { return 0 }
        // 先平移到质心再套鞋带公式：经度绝对值 ~1e2、乘以米制系数后 ~1e7，
        // 直接相乘会在 1e14 量级上做差，几十万 m² 的圈能算出 0.x m² 的偏差。
        var sum = 0.0
        for i in 0..<poly.count {
            let a = poly[i]
            let b = poly[(i + 1) % poly.count]
            let ax = (a.longitude - lon0) * lonScale, ay = (a.latitude - lat0) * latScale
            let bx = (b.longitude - lon0) * lonScale, by = (b.latitude - lat0) * latScale
            sum += ax * by - bx * ay
        }
        return abs(sum) / 2
    }

    /// 多边形绕质心缩放
    private static func scalePolygon(_ poly: [CLLocationCoordinate2D], by k: Double) -> [CLLocationCoordinate2D] {
        guard !poly.isEmpty else { return poly }
        let cLat = poly.reduce(0.0) { $0 + $1.latitude } / Double(poly.count)
        let cLon = poly.reduce(0.0) { $0 + $1.longitude } / Double(poly.count)
        return poly.map {
            CLLocationCoordinate2D(latitude: cLat + ($0.latitude - cLat) * k,
                                   longitude: cLon + ($0.longitude - cLon) * k)
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

    /// 地图连续选点：一次把按下的 1/2/3… 顺序插到终点之前（不被打乱）
    func addPickedWaypoints(_ coords: [CLLocationCoordinate2D]) {
        guard !coords.isEmpty else { return }
        normalizeModes()
        if userWaypoints.count < 2 {
            userWaypoints.append(contentsOf: coords)
            waypointModes.append(contentsOf: [Bool](repeating: false, count: coords.count))
        } else {
            let at = userWaypoints.count - 1
            userWaypoints.insert(contentsOf: coords, at: at)
            waypointModes.insert(contentsOf: [Bool](repeating: false, count: coords.count), at: at)
        }
        normalizeModes()
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
    // ② 随机点先按几何位置归到「相邻锚点之间的空档」，再按**沿这段路走了多远**定序，
    //    随机只做**相邻两项互换**（每点最多换一次）—— a、b 两点只可能 ab 或 ba，
    //    绝不会变成 a→c→d→b 那种跨位乱序（v2.7.8，老总点名）；
    // ③ 多生成几组候选，取「线段交叉最少 → 总里程最短」的一组；
    // ④ 随机跳过只作用于随机点；往返 = 偶数圈反向（去一回一）；
    //    起终点随机互换 = 每次生成随机决定整条线路从哪一头起跑（和"往返"不是一回事）。
    func generateVisitSequence(skipProbability: Double, swapEnds: Bool, randomFlip: Bool = false, loops: Int) -> [Int] {
        normalizeModes()
        let n = userWaypoints.count
        guard n >= 2 else { return [0] }
        let skip = min(max(skipProbability, 0), 1)
        let modes = waypointModes
        let flipAll = randomFlip && Bool.random()

        var out: [Int] = []
        var prevLeg: [Int] = []
        let loopCount = max(1, loops)
        for _ in 0..<loopCount {
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
            if flipAll { leg.reverse() }
            // 第二圈起：上一圈停在终点，下一圈又从起点开始。如果直接连过去，
            // 就是一条横穿整张地图的直线（老总说的「开飞机」）。这里改成沿上一圈
            // 原路走回来——人多跑一圈本来也是这么走的，既连贯又不会乱穿。
            if !prevLeg.isEmpty, let lastIdx = out.last, let headIdx = leg.first,
               distanceBetween(userWaypoints[lastIdx], userWaypoints[headIdx]) > 150 {
                var k = prevLeg.count - 2
                while k >= 0 {
                    if let last = out.last, last == prevLeg[k] { k -= 1; continue }
                    out.append(prevLeg[k])
                    k -= 1
                }
            }
            for i in leg {
                if let last = out.last, last == i { continue }  // 圈间接缝去重
                out.append(i)
            }
            prevLeg = leg
            // 往返：每圈原路再跑回来（去一回一）；绕圈 N 次 = N 个来回
            if swapEnds {
                var back: [Int] = []
                var k = leg.count - 2
                while k >= 1 {
                    back.append(leg[k])
                    k -= 1
                }
                if let firstIdx = leg.first { back.append(firstIdx) }
                for i in back {
                    if let last = out.last, last == i { continue }
                    out.append(i)
                }
            }
        }
        if out.isEmpty { out = [0, n - 1] }
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

        // v2.7.8 老总原话：「某一条路只能 ab 能走，随机会导致 acdb / adbc / acdb 这样胡乱搭配，
        // 只能 ab 或 ba 这样。」⇒ 桶内不再「贪心挑最近的三个」，改成**先定序、只许相邻交换**：
        // ① 先把桶里的点按「在 anchors[g] → anchors[g+1] 这条线上走了多远」排好 —— 这就是"有序"：
        //    谁先谁后由它在这条路上的位置决定，不由随机数决定。只有 a、b 两个点时，顺序必然是
        //    a→b 或 b→a，c、d 再也不可能挤到它们中间去。
        // ② 随机只允许相邻两项互换，且每个点最多换一次（换完跳过下一位）—— 绝不出现
        //    a→c→d→b 这种跨位乱序；小折返（人走路本来也会绕一下）由上层「交叉最少/里程最短」兜住。
        for g in 0..<max(anchors.count - 1, 1) {
            guard g + 1 < anchors.count, buckets[g].count > 1 else { continue }
            let a = userWaypoints[anchors[g]]
            let b = userWaypoints[anchors[g + 1]]
            buckets[g].sort { projectionT(userWaypoints[$0], a, b) < projectionT(userWaypoints[$1], a, b) }
        }

        var out: [Int] = [anchors[0]]
        for g in 0..<max(anchors.count - 1, 1) {
            var seq = buckets[g]
            if jitter && seq.count > 1 {
                var i = 0
                while i + 1 < seq.count {
                    if Bool.random() {
                        seq.swapAt(i, i + 1)
                        i += 2          // 这一对换过了，下一位不再参与，保证每个点最多换一次
                    } else {
                        i += 1
                    }
                }
            }
            out.append(contentsOf: seq)
            if g + 1 < anchors.count { out.append(anchors[g + 1]) }
        }
        return out
    }

    /// 点在 a→b 线段上的投影参数（0 = 在 a，1 = 在 b，可越界）。
    /// 只用来给同一段路上的点定"先后"，不做任何截断 —— 截断会让线上游的点并列。
    private func projectionT(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let latScale = 111320.0
        let lonScale = 111320.0 * cos(a.latitude * Double.pi / 180)
        let ax = a.longitude * lonScale, ay = a.latitude * latScale
        let bx = b.longitude * lonScale, by = b.latitude * latScale
        let px = p.longitude * lonScale, py = p.latitude * latScale
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-9 else { return 0 }
        return ((px - ax) * dx + (py - ay) * dy) / len2
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

    /// DriftFix v3.1 手画路线：画什么就走什么（不再「先简化再平滑」）。
    /// 血案：旧实现是 DP 5m 简化 + 2 轮平滑，简化后只剩几个拐点，平滑再把拐角削掉——
    /// 实测 90° 直角网格最大偏离原画 69.6m、操场圆环 16.6m。用户看到的就是
    /// 「一点开始，位置跟我画的不一样，漂移了」。现在原始笔画点只做 1.5m 去重，
    /// 直接沿折线 1Hz 重采样，模拟点严格落在画出来的线上。
    func buildFromDrawnPath(points: [CLLocationCoordinate2D], minSpeed: Double, maxSpeed: Double) -> Bool {
        guard points.count >= 2 else { return false }
        let shaped = dedupeDrawnPoints(points, minMeters: 1.5)
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

    /// DriftFix v3.1 「AI 优化」（显式开关才走）：DP 简化(5m) → 两轮平滑 → 再逐点拉回
    /// 原画 2m 以内。平滑只做"手感变顺"，绝不允许把拐角削掉几十米。
    func optimizeDrawnPath(points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        let simplified = simplifyPolyline(points, epsilon: 5.0)
        let smoothed = smoothPolyline(simplified, passes: 2)
        return clampToPolyline(smoothed, reference: points, maxOffset: 2.0)
    }

    /// DriftFix v2.7.9 多画笔手画：固定笔严格照画线（零偏移），随机笔沿画线走但横向最多偏 2.2 米。
    /// 老总原话：「更换画笔，画笔样式或者颜色不同，来指定某段区域固定，不随机。」
    /// 只有随机笔才产生偏移，固定笔的点原样进入注入序列——分区控制，不做全局抖动。
    func buildFromDrawnStrokes(_ strokes: [[CLLocationCoordinate2D]], modes: [Int],
                               minSpeed: Double, maxSpeed: Double,
                               loops: Int = 1, roundTrip: Bool = false) -> Bool {
        var flat: [CLLocationCoordinate2D] = []
        var wildFlags: [Bool] = []
        for (i, s) in strokes.enumerated() {
            let wild = i < modes.count && modes[i] == 1
            for c in s { flat.append(c); wildFlags.append(wild) }
        }
        guard flat.count >= 2 else { return false }

        // 1.5m 去重，模式跟着走（合并时「只要沾了随机笔就算随机」）
        var pts: [CLLocationCoordinate2D] = [flat[0]]
        var flags: [Bool] = [wildFlags[0]]
        for i in 1..<flat.count {
            if let last = pts.last, distanceBetween(last, flat[i]) < 1.5 {
                if wildFlags[i] { flags[flags.count - 1] = true }
                continue
            }
            pts.append(flat[i])
            flags.append(wildFlags[i])
        }
        if let lastP = flat.last, let lastOut = pts.last, distanceBetween(lastOut, lastP) > 0.5 {
            pts.append(lastP)
            flags.append(wildFlags.last ?? false)
        }
        guard pts.count >= 2 else { return false }
        let base = pts

        // v2.7.14 往返 / 重复：往返回程走原线（尾点衔接不重复）；重复=每轮去掉首点接续，
        // 不往返时轮间接缝是一段直线走回起点（1Hz 重采样会匀速走，不瞬移）。
        // 拼接后的序列整体做 1Hz 重采样与随机笔摆动 —— 回程经过同一坐标时时间不同，
        // OU 游走状态不同，天然不会出现像素级重线（防检测）。
        var seq = base
        var seqFlags = flags
        if roundTrip {
            seq += Array(base.dropLast().reversed())
            seqFlags += Array(flags.dropLast().reversed())
        }
        let n = max(1, min(loops, 20))
        var full = seq
        var fullFlags = seqFlags
        if n > 1 {
            for _ in 1..<n {
                full += Array(seq.dropFirst())
                fullFlags += Array(seqFlags.dropFirst())
            }
        }

        let resampled = interpolateVariableRoute(coords: full, minSpeed: minSpeed, maxSpeed: maxSpeed, interval: updateInterval)
        let injected = applyRandomBrushSway(resampled, reference: full, wild: fullFlags)

        polylineIsWGS = false
        routePoints = injected.count >= 2 ? injected : full
        totalPoints = routePoints.count
        currentPointIndex = 0
        progress = 0.0
        isSimulating = false
        isPaused = false
        currentPosition = nil
        availableRoutes = []
        allRoutePolylines = []
        routePolyline = MKPolyline(coordinates: base, count: base.count)
        var totalMeters: Double = 0
        for i in 1..<full.count {
            totalMeters += distanceBetween(full[i - 1], full[i])
        }
        let eff = max((minSpeed + maxSpeed) / 2, 0.2)
        let secs = totalMeters / eff
        let m = Int(secs) / 60
        estimatedTime = m > 60 ? "\(m/60)h \(m%60)m" : "\(m)m \(Int(secs) % 60)s"
        estimatedMeters = totalMeters
        estimatedSteps = Int(totalMeters / strideForEstimate)
        return true
    }

    /// 随机笔画的横向摆动：偏移量只与「沿路走了多远」有关，所以是连续的，不会一顿一跳；
    /// 权重在随机段与固定段交界处按 8 拍平滑，接缝不出现突跳。固定段权重恒 0 ⇒ 像素级照画线。
    private func applyRandomBrushSway(_ pts: [CLLocationCoordinate2D],
                                      reference: [CLLocationCoordinate2D],
                                      wild: [Bool]) -> [CLLocationCoordinate2D] {
        guard pts.count >= 3, reference.count >= 2, wild.count == reference.count else { return pts }
        guard wild.contains(true) else { return pts }   // 全是固定笔：一个坐标都不动
        // v2.7.11：幅度手画页可调（andromedaDrawSway，0 = 完全不抖）
        let amp: Double
        if let v = UserDefaults.standard.object(forKey: "andromedaDrawSway") as? Double { amp = v } else { amp = 2.2 }
        guard amp > 0.05 else { return pts }

        // 重采样点本来就沿参考折线前进 ⇒ 用单调指针找最近点，O(n+m)，不在这里做全量比距离
        var raw = [Double](repeating: 0, count: pts.count)
        var j = 0
        for i in 0..<pts.count {
            var bestJ = j
            var bestD = distanceBetween(pts[i], reference[j])
            var k = j
            while k + 1 < reference.count {
                let dNext = distanceBetween(pts[i], reference[k + 1])
                if dNext <= bestD {
                    bestD = dNext
                    bestJ = k + 1
                    k += 1
                } else {
                    break
                }
            }
            j = bestJ
            raw[i] = wild[bestJ] ? 1.0 : 0.0
        }
        // 8 拍滑动平均：随机/固定交界柔化
        let radius = 8
        let weight: [Double] = (0..<pts.count).map { i in
            let lo = max(0, i - radius)
            let hi = min(pts.count - 1, i + radius)
            var sum = 0.0
            for k in lo...hi { sum += raw[k] }
            return sum / Double(hi - lo + 1)
        }

        var out = pts
        var traveled = 0.0
        for i in 1..<pts.count {
            traveled += distanceBetween(pts[i - 1], pts[i])
            guard weight[i] > 0.01 else { continue }
            let a = pts[max(0, i - 1)]
            let b = pts[min(pts.count - 1, i + 1)]
            let bearing = bearing(from: a, to: b) * Double.pi / 180.0
            // 两个不同波长叠一起，看起来像人贴着线走而不是机器正弦
            let wob = sin(2 * Double.pi * traveled / 43.0) * 0.65
                    + sin(2 * Double.pi * traveled / 101.0 + 1.7) * 0.35
            let offset = amp * wob * weight[i]
            let perp = bearing + Double.pi / 2
            let dLat = offset * cos(perp)
            let dLon = offset * sin(perp)
            let lat = pts[i].latitude + dLat / 111_320.0
            let lon = pts[i].longitude + dLon / (111_320.0 * max(cos(pts[i].latitude * Double.pi / 180.0), 0.2))
            out[i] = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return out
    }

    /// 手画原始点去重（1.5m 内视为同一点）：不简化、不平滑，保证走线 = 画线。
    private func dedupeDrawnPoints(_ pts: [CLLocationCoordinate2D], minMeters: Double) -> [CLLocationCoordinate2D] {
        guard pts.count >= 2 else { return pts }
        var out: [CLLocationCoordinate2D] = [pts[0]]
        for p in pts.dropFirst() {
            if let last = out.last, distanceBetween(last, p) < minMeters { continue }
            out.append(p)
        }
        if let firstP = pts.first, let lastP = pts.last, out.count == 1,
           distanceBetween(firstP, lastP) >= 0.5 {
            out.append(lastP)
        }
        if let lastP = pts.last, let lastOut = out.last, distanceBetween(lastOut, lastP) > 0.5 {
            out.append(lastP)
        }
        return out
    }

    /// 把平滑后的点逐点拉回参考折线 maxOffset 米内（平滑过头 → 拐角抄近路的兜底）。
    private func clampToPolyline(_ pts: [CLLocationCoordinate2D],
                                 reference: [CLLocationCoordinate2D],
                                 maxOffset: Double) -> [CLLocationCoordinate2D] {
        guard reference.count >= 2, pts.count >= 2 else { return pts }
        return pts.map { p in
            let near = nearestPointOnPolyline(p, reference)
            return near.distance > maxOffset ? near.coordinate : p
        }
    }

    private func nearestPointOnPolyline(_ p: CLLocationCoordinate2D,
                                        _ poly: [CLLocationCoordinate2D]) -> (coordinate: CLLocationCoordinate2D, distance: Double) {
        var best = p
        var bestD = Double.greatestFiniteMagnitude
        let latScale = 111320.0
        let lonScale = 111320.0 * cos(p.latitude * Double.pi / 180)
        let px = p.longitude * lonScale, py = p.latitude * latScale
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            let ax = a.longitude * lonScale, ay = a.latitude * latScale
            let bx = b.longitude * lonScale, by = b.latitude * latScale
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
            t = min(max(t, 0), 1)
            let cx = ax + dx * t, cy = ay + dy * t
            let d = ((px - cx) * (px - cx) + (py - cy) * (py - cy)).squareRoot()
            if d < bestD {
                bestD = d
                best = CLLocationCoordinate2D(latitude: cy / latScale, longitude: cx / lonScale)
            }
        }
        return (best, bestD)
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

    // MARK: - DriftFix v2.9 手画笔画持久化（关面板/退出 App 都不丢，回来接着改）
    static func drawnStrokesURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("andromeda_drawn_strokes.json")
    }

    func persistDrawnStrokes() {
        let raw: [[[Double]]] = drawnStrokes.map { $0.map { [$0.latitude, $0.longitude] } }
        // v2.7.9: 画笔模式一起存；老版本文件是纯数组，restore 时按「全部固定」读回
        let payload: [String: Any] = ["v": 2, "strokes": raw, "modes": normalizedStrokeModes(count: drawnStrokes.count)]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: Self.drawnStrokesURL(), options: .atomic)
    }

    func restoreDrawnStrokes() {
        guard let data = try? Data(contentsOf: Self.drawnStrokesURL()),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        var raw: [[[Double]]] = []
        var modes: [Int] = []
        if let arr = obj as? [[[Double]]] {
            raw = arr
        } else if let dict = obj as? [String: Any], let arr = dict["strokes"] as? [[[Double]]] {
            raw = arr
            if let m = dict["modes"] as? [Int] { modes = m }
        } else {
            return
        }
        let strokes: [[CLLocationCoordinate2D]] = raw.map { stroke in
            stroke.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
            }
        }
        if !strokes.isEmpty {
            drawnStrokes = strokes
            drawnStrokeModes = normalizeModeArray(modes, count: strokes.count)
        }
    }

    /// 画笔模式补齐/截断到与笔画数一致（缺的按「固定」处理）
    func normalizedStrokeModes(count: Int) -> [Int] {
        normalizeModeArray(drawnStrokeModes, count: count)
    }

    private func normalizeModeArray(_ src: [Int], count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var out = Array(src.prefix(count))
        if out.count < count { out.append(contentsOf: [Int](repeating: 0, count: count - out.count)) }
        return out.map { $0 == 1 ? 1 : 0 }
    }

    func clearDrawnStrokes() {
        drawnStrokes = []
        drawnStrokeModes = []
        try? FileManager.default.removeItem(at: Self.drawnStrokesURL())
    }

    /// 手画完成后把起/终点对齐到画线的首末点：面板显示、保存的元数据、点序列全部一致，
    /// 不再出现「起点卡片写着别的地方，实际走的是画线」这种对不上的情况。
    func setDrawnEndpoints(start: CLLocationCoordinate2D, end: CLLocationCoordinate2D) {
        userWaypoints = [start, end]
        waypointModes = [false, false]
        normalizeModes()
    }

    /// 手画线路 → 点序列：把简化后的关键节点写入 userWaypoints，
    /// 这样画完还能在「点序列」里逐点删除/改顺序/中间补点，不用整条重画。
    @discardableResult
    func adoptDrawnAsWaypoints(points: [CLLocationCoordinate2D],
                               wildSource: [CLLocationCoordinate2D] = [],
                               maxPoints: Int = 40) -> Int {
        guard points.count >= 2 else { return 0 }
        var picked = simplifyPolyline(points, epsilon: 8.0)
        if picked.count > maxPoints {
            let step = Double(picked.count - 1) / Double(maxPoints - 1)
            var thinned: [CLLocationCoordinate2D] = []
            for i in 0..<maxPoints {
                let idx = min(picked.count - 1, Int((Double(i) * step).rounded()))
                thinned.append(picked[idx])
            }
            picked = thinned
        }
        userWaypoints = picked
        // v2.7.9: 落在「随机」画笔那几笔上的点，转成点序列后自动带随机标记（起终点由 normalizeModes 强制固定）
        if wildSource.isEmpty {
            waypointModes = [Bool](repeating: false, count: picked.count)
        } else {
            waypointModes = picked.map { p in wildSource.contains { distanceBetween(p, $0) <= 8.0 } }
        }
        normalizeModes()
        return picked.count
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
    
    // MARK: - DriftFix v3.2 区域自动绕行（手画多边形 → 扫描线蛇形 → 走满目标公里数 → 回到终点）

    private struct AreaPlan {
        var spacing: Double
        var laps: Int
    }

    /// 选一个车道间距，让「单圈蛇形长度」尽量贴住目标里程；目标太大就多绕几圈。
    private func planArea(rect: AreaRect, targetMeters: Double) -> AreaPlan {
        let spanX = max(rect.widthMeters, 1)
        let spanY = max(rect.heightMeters, 1)
        let useEW = spanX >= spanY
        let laneLen = (useEW ? spanX : spanY) * 0.92
        let stepLen = (useEW ? spanY : spanX) * 0.92
        // 从密到疏扫一遍，取「最稀疏但仍够目标」的那一档——区域大、目标小时不会硬塞几十条车道
        var spacing = 400.0
        var found = false
        var s = 45.0
        while s <= 400.0 {
            let n = max(2, min(40, Int(stepLen / s) + 1))
            let realStep = stepLen / Double(n - 1)
            let capacity = Double(n) * laneLen + Double(n - 1) * realStep + laneLen * 0.35
            if capacity >= targetMeters * 1.02 {
                spacing = s
                found = true
            }
            s += 10
        }
        if !found {
            // 连 2% 余量都凑不出：最稀疏一档仍够目标就取它，否则最密 + 多绕几圈
            let nMax = max(2, min(40, Int(stepLen / 400.0) + 1))
            let realMax = stepLen / Double(nMax - 1)
            let capMax = Double(nMax) * laneLen + Double(nMax - 1) * realMax + laneLen * 0.35
            spacing = capMax >= targetMeters ? 400.0 : 45.0
        }
        let n = max(2, min(40, Int(stepLen / spacing) + 1))
        let realStep = stepLen / Double(n - 1)
        let cap = Double(n) * laneLen + Double(n - 1) * realStep + laneLen * 0.35
        var laps = 1
        if cap < targetMeters {
            laps = min(8, Int(ceil(targetMeters / max(cap, 1.0))))
        }
        return AreaPlan(spacing: spacing, laps: laps)
    }

    /// v2.7.7 网格就近随机走位（老总原话：「不要像开飞机一样在天上飞、胡乱交叉，
    /// 要有顺序，就像网格一样，只能就近点位随机选择一个」）。
    ///
    /// 做法：把区域按 cell 米切开，留下落在形状内的格点；从离起点最近的格点出发，
    /// 每一步只在上下左右四个邻格中挑一个——同向直行权重最高、拐弯次之、掉头几乎不选，
    /// 没走过的格优先，最后几格自动朝终点收。于是：
    ///   · 任意一腿只有一个格子长，不会横跨几百米，不可能出现「飞行线」；
    ///   · 走向始终是相邻格，天然排成网格，不会满图乱穿；
    ///   · 走过的格偶尔可以再进（人也会绕回原路），但权重很低，不会原地打转。
    private func areaGridWalk(polygon: [CLLocationCoordinate2D],
                              cell: Double,
                              from start: CLLocationCoordinate2D,
                              to end: CLLocationCoordinate2D,
                              targetMeters: Double) -> [CLLocationCoordinate2D] {
        guard polygon.count >= 3, cell > 10 else { return [] }
        let lats = polygon.map { $0.latitude }
        let lons = polygon.map { $0.longitude }
        guard let latMin0 = lats.min(), let latMax0 = lats.max(),
              let lonMin0 = lons.min(), let lonMax0 = lons.max() else { return [] }
        let latScale = 111320.0
        let lonScale = 111320.0 * cos((latMin0 + latMax0) / 2 * Double.pi / 180)
        guard lonScale > 1 else { return [] }

        // 格架向内缩 1/4 格：贴边的点会落在多边形边界上，射线法判内外不稳
        let padLat = 0.25 * cell / latScale
        let padLon = 0.25 * cell / lonScale
        let latMin = latMin0 + padLat, latMax = latMax0 - padLat
        let lonMin = lonMin0 + padLon, lonMax = lonMax0 - padLon
        guard latMax > latMin, lonMax > lonMin else { return [] }
        let cols = min(72, max(2, Int(((lonMax - lonMin) * lonScale) / cell) + 1))
        let rows = min(72, max(2, Int(((latMax - latMin) * latScale) / cell) + 1))
        let stepX = (lonMax - lonMin) / Double(cols - 1)
        let stepY = (latMax - latMin) / Double(rows - 1)

        func coord(_ i: Int, _ j: Int) -> CLLocationCoordinate2D {
            // v2.7.12 每格 ±0.18 格确定性抖动：破掉直角网格与规整外圈（同格哈希一致，
            // 预检 inPolygon 与行走用同一坐标，不会出现「预检过、走时出界」）
            let h = UInt64(truncatingIfNeeded: (i &* 73856093) ^ (j &* 19349663))
            let jx = (Double(h % 1000) / 1000.0 - 0.5) * 0.36 * cell / lonScale
            let jy = (Double((h >> 20) % 1000) / 1000.0 - 0.5) * 0.36 * cell / latScale
            return CLLocationCoordinate2D(latitude: latMin + stepY * Double(j) + jy,
                                          longitude: lonMin + stepX * Double(i) + jx)
        }

        func inPolygon(_ p: CLLocationCoordinate2D) -> Bool {
            var inside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let a = polygon[i], b = polygon[j]
                if (a.latitude > p.latitude) != (b.latitude > p.latitude) {
                    let f = (p.latitude - a.latitude) / (b.latitude - a.latitude)
                    if p.longitude < a.longitude + f * (b.longitude - a.longitude) {
                        inside.toggle()
                    }
                }
                j = i
            }
            return inside
        }

        var ok = [Bool](repeating: false, count: cols * rows)
        for j in 0..<rows {
            for i in 0..<cols {
                ok[j * cols + i] = inPolygon(coord(i, j))
            }
        }
        var usable: [Int] = []
        for k in 0..<(cols * rows) where ok[k] { usable.append(k) }
        guard usable.count >= 4 else { return [] }

        func nearestNode(to p: CLLocationCoordinate2D) -> Int {
            var best = usable[0]
            var bestD = Double.greatestFiniteMagnitude
            for k in usable {
                let d = distanceBetween(coord(k % cols, k / cols), p)
                if d < bestD { bestD = d; best = k }
            }
            return best
        }

        let startNode = nearestNode(to: start)
        let cellLen = max(stepX * lonScale, stepY * latScale)
        guard cellLen > 10 else { return [] }
        let goal = max(cellLen * 4, targetMeters * 0.9)

        var visit = [Int](repeating: 0, count: cols * rows)
        var cur = startNode
        visit[cur] = 1
        var out: [CLLocationCoordinate2D] = [coord(cur % cols, cur / cols)]
        var walked = 0.0
        var prevDir = -1                       // -1 起步；0 东 1 西 2 北 3 南（反向 = d ^ 1）
        let dirs: [(Int, Int)] = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var spins = 0

        while walked < goal && spins < 40000 {
            spins += 1
            let ci = cur % cols, cj = cur / cols
            var cands: [(node: Int, dir: Int, w: Double)] = []
            for (dir, step) in dirs.enumerated() {
                let ni = ci + step.0, nj = cj + step.1
                if ni < 0 || ni >= cols || nj < 0 || nj >= rows { continue }
                let nk = nj * cols + ni
                if !ok[nk] { continue }
                var w = 1.0
                if dir == prevDir {
                    w *= 3.6                                    // 一直往前走：最像人在走直线
                } else if prevDir >= 0 && dir == (prevDir ^ 1) {
                    w *= 0.10                                    // 原路掉头：几乎不选
                } else if prevDir >= 0 {
                    w *= 1.5                                     // 拐 90°：正常
                }
                if visit[nk] == 0 {
                    w *= 5.0                                     // 没走过的格优先，把区域铺开
                } else {
                    w *= max(0.05, 1.0 / Double(visit[nk] + 1))
                }
                let remain = goal - walked
                if remain < cellLen * 8 {
                    let here = coord(ci, cj)
                    let next = coord(ni, nj)
                    w *= distanceBetween(next, end) < distanceBetween(here, end) ? 3.0 : 0.7
                }
                w *= Double.random(in: 0.75...1.25)
                cands.append((nk, dir, w))
            }
            guard !cands.isEmpty else { break }
            let total = cands.reduce(0.0) { $0 + $1.w }
            var pick = Double.random(in: 0..<total)
            var chosen = cands[0]
            for c in cands {
                pick -= c.w
                if pick <= 0 { chosen = c; break }
            }
            cur = chosen.node
            prevDir = chosen.dir
            visit[cur] += 1
            out.append(coord(cur % cols, cur / cols))
            walked += cellLen
        }
        return out
    }

    /// 多边形蛇形锚点（DriftFix v3.2，替代按矩形切车道）：
    /// 沿一个方向逐条扫描线切开手画区域，扫描线与多边形边的交点两两配对得到「内部区间」，
    /// 区间内每 ≈350m 一个锚点，奇偶行反向。天然只在画出来的形状里走、不来回交叉；
    /// 凹形（L 形 / 月牙）区域一条扫描线会有多段，按行依次串起来照样走满。
    /// 扫描方向自动选：南北明显更长时改按经度扫，否则细长区域会切成梳子状来回拐。
    private func areaSerpentine(polygon: [CLLocationCoordinate2D],
                                spacing: Double,
                                startFrom: CLLocationCoordinate2D) -> [CLLocationCoordinate2D] {
        guard polygon.count >= 3 else { return [] }
        let lats = polygon.map { $0.latitude }
        let lons = polygon.map { $0.longitude }
        guard let latMin = lats.min(), let latMax = lats.max(),
              let lonMin = lons.min(), let lonMax = lons.max() else { return [] }
        let latScale = 111320.0
        let lonScale = 111320.0 * cos((latMin + latMax) / 2 * Double.pi / 180)
        guard lonScale > 1 else { return [] }
        let widthM = (lonMax - lonMin) * lonScale
        let heightM = (latMax - latMin) * latScale
        guard widthM > 60, heightM > 60 else { return [] }
        let scanLat = heightM <= widthM * 1.6

        // 统一到 (u=横向, v=扫描推进方向) 米制平面，算完再映射回经纬度
        func uv(_ c: CLLocationCoordinate2D) -> (u: Double, v: Double) {
            let x = c.longitude * lonScale, y = c.latitude * latScale
            return scanLat ? (x, y) : (y, x)
        }
        func coord(_ u: Double, _ v: Double) -> CLLocationCoordinate2D {
            if scanLat {
                return CLLocationCoordinate2D(latitude: v / latScale, longitude: u / lonScale)
            }
            return CLLocationCoordinate2D(latitude: u / latScale, longitude: v / lonScale)
        }

        let flat = polygon.map { uv($0) }
        guard flat.count >= 3, let vMin = flat.map({ $0.v }).min(), let vMax = flat.map({ $0.v }).max() else { return [] }
        let vSpan = vMax - vMin
        guard vSpan > 100 else { return [] }

        let stepM = max(60.0, min(spacing, 400.0))
        let rows = max(2, min(40, Int(vSpan / stepM) + 1))
        let realStep = vSpan / Double(rows - 1)

        var out: [CLLocationCoordinate2D] = []
        for i in 0..<rows {
            let v = vMin + realStep * Double(i)
            // 扫描线与每条边的交点（半开区间判定，正好落在顶点时只算一次）
            var xs: [Double] = []
            for k in 0..<flat.count {
                let a = flat[k], b = flat[(k + 1) % flat.count]
                if (a.v <= v && b.v > v) || (b.v <= v && a.v > v) {
                    let t = (v - a.v) / (b.v - a.v)
                    xs.append(a.u + (b.u - a.u) * t)
                }
            }
            xs.sort()
            guard xs.count >= 2 else { continue }
            var spans: [(Double, Double)] = []
            var j = 0
            while j + 1 < xs.count {
                if xs[j + 1] > xs[j] { spans.append((xs[j], xs[j + 1])) }
                j += 2
            }
            guard !spans.isEmpty else { continue }
            let forward = i % 2 == 0
            let ordered: [(Double, Double)] = forward ? spans : Array(spans.reversed())
            for sp in ordered {
                let lo = forward ? sp.0 : sp.1
                let hi = forward ? sp.1 : sp.0
                guard abs(hi - lo) > 30 else { continue }
                let n = max(1, Int(abs(hi - lo) / 350.0))
                for m in 0...n {
                    let f = Double(m) / Double(n)
                    out.append(coord(lo + (hi - lo) * f, v))
                }
            }
        }
        if let first = out.first, let last = out.last,
           distanceBetween(first, startFrom) > distanceBetween(last, startFrom) {
            out.reverse()
        }
        return out
    }

    /// 手画区域比目标里程大太多时，绕质心等比缩小——
    /// 蛇形总长 ≈ 多边形面积 ÷ 车道间距，所以按 sqrt 比例缩，迭代几次收敛。
    private func fitAreaPolygon(_ polygon: [CLLocationCoordinate2D], targetMeters: Double) -> [CLLocationCoordinate2D] {
        guard polygon.count >= 3 else { return polygon }
        let spacing = 150.0
        let wantArea = targetMeters * 1.15 * spacing
        var result = polygon
        for _ in 0..<5 {
            let area = Self.polygonAreaM2(result)
            if area <= wantArea * 1.3 { break }
            let k = max(0.08, min(0.98, sqrt(wantArea / area)))
            let next = Self.scalePolygon(result, by: k)
            if let b = AreaRect.bounding(of: next), b.widthMeters < 80 || b.heightMeters < 80 { break }
            result = next
        }
        return result
    }

    /// 区域自动线路：起点 → 区域蛇形 → 终点。每段先试步行导航贴真实街道（容忍 300m 端点偏差、
    /// 2.2 倍绕远），拿不到就自然弯兜底；全程平滑 + 变速 1Hz 重采样。
    func buildAreaRoute(start: CLLocationCoordinate2D,
                        end: CLLocationCoordinate2D,
                        polygon: [CLLocationCoordinate2D],
                        targetMeters: Double,
                        minSpeed: Double,
                        maxSpeed: Double,
                        snapToRoads: Bool,
                        completion: @escaping (Bool, String?) -> Void) {
        guard polygon.count >= 3 else { completion(false, "请先在地图上画一块要绕行的区域"); return }
        let areaM2 = Self.polygonAreaM2(polygon)
        guard areaM2 >= Self.minAreaM2 else {
            completion(false, "画的区域只有 \(Self.areaText(areaM2))，至少要 \(Self.areaText(Self.minAreaM2))。把圈再放大一点重新保存就行。")
            return
        }
        guard let bounds = AreaRect.bounding(of: polygon),
              bounds.widthMeters >= Self.minSideMeters, bounds.heightMeters >= Self.minSideMeters else {
            completion(false, "画的区域太窄（最短的一边不到 \(Int(Self.minSideMeters)) 米），绕不开车道。把圈画宽一点再保存。")
            return
        }
        let target = max(targetMeters, 500)
        isCalculatingRoute = true
        availableRoutes = []
        allRoutePolylines = []
        selectedRouteIndex = 0

        // v2.7.7 网格就近随机（老总：不要像开飞机一样直切、不要胡乱交叉，像网格一样只挑隔壁点）。
        // 原来每 350 米才放一个锚点，两点之间只能拉直线——一公里长的区域看着就是贴地飞。
        // 现在先把区域切成几十米一格，每一步只走上下左右一个格，天然贴地、天然成网格。
        let minSide = min(bounds.widthMeters, bounds.heightMeters)
        let cell = max(40.0, min(90.0, minSide / 4.0))
        var anchors = areaGridWalk(polygon: polygon, cell: cell, from: start, to: end, targetMeters: target)
        if anchors.count < 3 {
            // 区域太小或太窄，格点凑不出来：退回蛇形，能走多少算多少
            let plan = planArea(rect: bounds, targetMeters: target)
            anchors = []
            var cursor = start
            for _ in 0..<plan.laps {
                let lanes = areaSerpentine(polygon: polygon, spacing: plan.spacing, startFrom: cursor)
                if lanes.count < 2 { break }
                anchors.append(contentsOf: lanes)
                cursor = lanes[lanes.count - 1]
            }
        }
        if anchors.isEmpty { anchors = [start] }
        anchors.insert(start, at: 0)
        anchors.append(end)
        // v2.7.12 拐角弧化：格点折角处退距插过渡点，90° 直角变自然弧（贴路长腿不受影响）
        anchors = roundedPath(anchors)

        var path: [CLLocationCoordinate2D] = []
        var legIndex = 0

        func appendLeg(_ seg: [CLLocationCoordinate2D]) {
            guard !seg.isEmpty else { return }
            if let last = path.last, let first = seg.first, self.distanceBetween(last, first) < 1.0 {
                path.append(contentsOf: seg.dropFirst())
            } else {
                path.append(contentsOf: seg)
            }
        }

        func finish() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.isCalculatingRoute = false
                guard path.count >= 2 else {
                    completion(false, "区域算路失败：换一个区域再试")
                    return
                }
                var shaped = self.smoothPolyline(path, passes: 2)
                guard shaped.count >= 2 else {
                    completion(false, "区域算路失败：换一个区域再试")
                    return
                }
                shaped[0] = start
                shaped[shaped.count - 1] = end
                let resampled = self.interpolateVariableRoute(coords: shaped,
                                                              minSpeed: minSpeed,
                                                              maxSpeed: maxSpeed,
                                                              interval: self.updateInterval)
                self.polylineIsWGS = false
                self.routePoints = resampled.count >= 2 ? resampled : shaped
                self.totalPoints = self.routePoints.count
                self.currentPointIndex = 0
                self.progress = 0.0
                self.isSimulating = false
                self.isPaused = false
                self.currentPosition = nil
                self.routePolyline = MKPolyline(coordinates: shaped, count: shaped.count)

                var meters: Double = 0
                for i in 1..<shaped.count {
                    meters += self.distanceBetween(shaped[i - 1], shaped[i])
                }
                let eff = max((minSpeed + maxSpeed) / 2, 0.2)
                let secs = meters / eff
                let m = Int(secs) / 60
                self.estimatedTime = m > 60 ? "\(m/60)h \(m%60)m" : "\(m)m \(Int(secs) % 60)s"
                self.estimatedMeters = meters
                self.estimatedSteps = Int(meters / self.strideForEstimate)
                if meters < target * 0.95 {
                    completion(true, "区域内只走出 \(Int(meters)) 米，没到目标；把手画区域画大一点再生成一次")
                } else {
                    completion(true, nil)
                }
            }
        }

        // 网格走位之后，绝大多数腿只有几十米，没必要逐段问 Apple 的步行路线
        // （一段一问会被限流，而且 60 米也问不出街道）。只给「进区域 / 出区域」这类
        // 超过 120 米的腿留 10 次贴路预算，其余一律按格线走。
        var roadBudget = 10

        func step() {
            if legIndex >= anchors.count - 1 {
                finish()
                return
            }
            let from = anchors[legIndex]
            let to = anchors[legIndex + 1]
            let d = self.distanceBetween(from, to)
            legIndex += 1
            if !snapToRoads || d < 120 || roadBudget <= 0 {
                appendLeg(self.curvedSegment(from: from, to: to))
                step()
                return
            }
            roadBudget -= 1
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: to))
            request.transportType = .walking
            request.requestsAlternateRoutes = false
            MKDirections(request: request).calculate { [weak self] response, _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    var used = false
                    if let best = response?.routes.first, best.polyline.pointCount >= 2 {
                        let pc = best.polyline.pointCount
                        var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: pc)
                        best.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: pc))
                        if let f = coords.first, let l = coords.last {
                            // 按段判基准：首点离请求起点 >200m 视为 WGS，否则本来就是 GCJ（防双重转换）
                            let gcj = self.distanceBetween(f, from) > 200
                                ? coords.map { CoordTransform.wgs84ToGcj02($0) }
                                : coords
                            if let gf = gcj.first, let gl = gcj.last {
                                let df = self.distanceBetween(gf, from)
                                let dt = self.distanceBetween(gl, to)
                                let detour = best.distance / max(d, 1.0)
                                if df <= 300 && dt <= 300 && detour <= 2.2 {
                                    appendLeg(gcj)
                                    used = true
                                }
                            }
                        }
                    }
                    if !used { appendLeg(self.curvedSegment(from: from, to: to)) }
                    step()
                }
            }
        }
        step()
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
        lastInjected = nil
        accuracyNextUpdate = .distantPast
        warmupTicks = 2          // 原地 2 拍再起步，让定位先落到起点
        // v2.7.10：每次开始都重置拟真状态，不然上一趟残留的噪声偏移会被当成"位置漂了一下"
        noiseEast = 0.0
        noiseNorth = 0.0
        noiseLastAt = .distantPast
        metersSinceDropout = 0.0
        nextDropoutMeters = Double.random(in: 2000.0...6000.0)
        dropoutUntil = .distantPast
        verticalNextUpdate = .distantPast
        // v2.7.12：驻足/海拔/联动状态开跑重置
        strollUntil = .distantPast
        nextStrollAt = Date().addingTimeInterval(Double.random(in: 120.0...300.0))
        altitudeBase = altitude
        altNoise = 0.0
        altLastAt = Date()
        currentSpeedMps = 0.0
        lastLinkAt = .distantPast
        syncStepLink(force: true)
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
            warmupTicks = 1      // 恢复时也先沉一拍，避免长时间不动后第一拍速度骤降
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
        warmupTicks = 0
        lastInjected = nil
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

    // MARK: - DriftFix v2.7.11 停止=驻留（老总令：停止不许跳回真实位置，轨迹要能接得上）
    // 不清线路、不动进度、不 stopLocSim —— LocSimManager 的保活本来就会每秒补投最后一个点
    // （新时间戳 + 速度 0），位置就定在原地。真想回到现实位置，走「真实位置」按钮（stopSimulation）。
    func holdSimulation() {
        timer?.invalidate()
        timer = nil
        isSimulating = false
        isPaused = true          // 卡片保持可见，按钮变 Resume，可直接原地继续
        warmupTicks = 0
        locationManager.stopUpdatingLocation()
        endBackgroundTask()
    }

    // MARK: - DriftFix v2.7.11 从指定点继续（老总令：不论哪个方案哪条线路，都能指定从某个点接着走）
    func resumeFrom(index: Int) {
        guard !routePoints.isEmpty else { return }
        currentPointIndex = max(0, min(index, routePoints.count - 1))
        isSimulating = true
        isPaused = false
        progress = Double(currentPointIndex) / Double(max(totalPoints - 1, 1))
        locationManager.requestAlwaysAuthorization()
        locationManager.startUpdatingLocation()
        startBackgroundTask()
        lastInjected = nil
        accuracyNextUpdate = .distantPast
        warmupTicks = 2          // 原地 2 拍再起步，先让系统接受"人就在这一点"
        noiseEast = 0.0
        noiseNorth = 0.0
        noiseLastAt = .distantPast
        metersSinceDropout = 0.0
        nextDropoutMeters = Double.random(in: 2000.0...6000.0)
        dropoutUntil = .distantPast
        verticalNextUpdate = .distantPast
        updateLocation(at: currentPointIndex)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.advanceToNextPoint()
        }
        RunLoop.current.add(timer!, forMode: .common)
    }

    /// 距起点沿路里程（缓存前缀和，滑杆拖动时 O(1)）
    private var cumDistCache: [Double] = []
    private var cumDistForCount = -1
    func distanceFromStart(to index: Int) -> Double {
        guard routePoints.count >= 2 else { return 0 }
        if cumDistForCount != routePoints.count || cumDistCache.count != routePoints.count {
            var acc = 0.0
            cumDistCache = [0.0]
            for i in 1..<routePoints.count {
                acc += distanceBetween(routePoints[i - 1], routePoints[i])
                cumDistCache.append(acc)
            }
            cumDistForCount = routePoints.count
        }
        let i = max(0, min(index, cumDistCache.count - 1))
        return cumDistCache[i]
    }

    private func advanceToNextPoint() {
        // 起步沉降期：坐标不动、时间戳照常刷新，让系统先接受"人就在起点"
        if warmupTicks > 0 {
            warmupTicks -= 1
            updateLocation(at: currentPointIndex)
            return
        }

        // v2.7.12 偶发驻足：每 2~8 分钟随机停 10~40 秒。坐标不动、时间戳照常、速度自然归 0，
        // 平均配速被拉向真人漫步档，配速曲线才会出现红色慢段（对照真人基准图：5h20m 只走 10km）。
        if strollEnabled {
            let nowS = Date()
            if nowS >= strollUntil && nowS >= nextStrollAt {
                strollUntil = nowS.addingTimeInterval(Double.random(in: 10.0...40.0))
                nextStrollAt = nowS.addingTimeInterval(Double.random(in: 120.0...480.0))
                syncStepLink(force: true)   // 驻足切档时顺带对齐步频
            }
            if nowS < strollUntil {
                updateLocation(at: currentPointIndex)
                return
            }
        }

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
        // DriftFix v3.2 去掉坐标随机抖动：原来每个点 ±0.00001°(约±1.1m) 随机偏移，
        // 1Hz 下等于每秒横向甩一次，叠在 1.4m/s 的步进上就是肉眼可见的锯齿/漂移。
        // LocSuper 扫街之所以"选什么样就走什么样"，就是因为它一个字都不改地照发折线点。
        // 真实感靠速度区间随机游走实现，不靠坐标噪声。
        let coord = routePoints[index]
        
        // DriftFix: 显示层坐标 —— polyline 判为 WGS 时转 GCJ，否则原样
        let displayCoord = polylineIsWGS ? CoordTransform.wgs84ToGcj02(coord) : coord
        DispatchQueue.main.async { [weak self] in
            self?.currentPosition = displayCoord
        }

        // DriftFix: 注入坐标 —— polyline 判为 WGS 时直接用原始点（避免 GCJ→WGS 双重转换）
        let wgsCoord = polylineIsWGS ? coord : CoordTransform.gcj02ToWgs84(coord)
        let now = Date()

        // 水平精度慢漂移（真实 GPS 是分钟级缓变，不是每秒乱跳）
        if now >= accuracyNextUpdate {
            reportedAccuracy = Double.random(in: 4.0...9.0)
            accuracyNextUpdate = now.addingTimeInterval(Double.random(in: 12.0...25.0))
        }

        // 用"上一拍的基准坐标"算瞬时速度和航向；停着不动就是 0 速、无航向。
        // 基准坐标不带噪声 —— 速度是融合引擎滤波后的量，拿带噪坐标反推会把速度放大成乱跳。
        var speed = 0.0
        var course = -1.0
        var stepMeters = 0.0
        if let last = lastInjected {
            let dt = min(max(now.timeIntervalSince(last.at), 0.5), 2.0)
            let d = CLLocation(latitude: last.coord.latitude, longitude: last.coord.longitude)
                .distance(from: CLLocation(latitude: wgsCoord.latitude, longitude: wgsCoord.longitude))
            stepMeters = d
            speed = d / dt
            currentSpeedMps = speed
            speedEma = speedEma * 0.85 + speed * 0.15
            if d > 0.3 {
                course = bearing(from: last.coord, to: wgsCoord)
            } else {
                course = -1
            }
        }

        // v2.7.10 拟真：精度骤降 + 垂直精度慢变 + 注入坐标低频游走（显示与存档不受影响）
        var accuracy = reportedAccuracy
        var vertical = reportedVertical
        var emitCoord = wgsCoord
        if gpsRealism {
            metersSinceDropout += stepMeters
            if now >= dropoutUntil {
                if metersSinceDropout >= nextDropoutMeters {
                    dropoutUntil = now.addingTimeInterval(Double.random(in: 3.0...8.0))
                    dropoutAccuracy = Double.random(in: 18.0...45.0)
                    metersSinceDropout = 0.0
                    nextDropoutMeters = Double.random(in: 2000.0...6000.0)
                }
            } else {
                accuracy = max(accuracy, dropoutAccuracy)
            }
            if now >= verticalNextUpdate {
                reportedVertical = Double.random(in: 8.0...18.0)
                verticalNextUpdate = now.addingTimeInterval(Double.random(in: 20.0...60.0))
            }
            vertical = reportedVertical
            emitCoord = jittered(wgsCoord, at: now)

            // v2.7.13 防检测加固（老总令：防检测封号第一）——四个机器指纹的收尾：
            // ① 速度曲线：等距点 d/dt 算出的 speed 过分平滑，真实 GPS 速度自带 ±3~8% 缓变；
            // ② 航向：反推 course 是干净的数学值，真机有 ±2~3° 摆动；
            // ③ 精度高频微跳：4~9m 十几秒一换仍太稳，真机每拍都在小幅随机跳；
            // ④ 停下歇脚时精度短暂变差（人站着 GPS 漂移更大），配速慢段与精度曲线互相印证。
            let dtN = min(max(now.timeIntervalSince(altLastAt), 0.0), 5.0)
            let decayN = exp(-dtN / 15.0)
            let kN = sqrt(max(0.0, 1.0 - decayN * decayN))
            speedNoiseOu = speedNoiseOu * decayN + gaussRandom() * 1.0 * kN
            if speed > 0.2 {
                speed = max(0.0, speed * (1.0 + speedNoiseOu / 30.0))
            }
            let decayC = exp(-dtN / 6.0)
            let kC = sqrt(max(0.0, 1.0 - decayC * decayC))
            courseNoiseOu = courseNoiseOu * decayC + gaussRandom() * 1.5 * kC
            if course > 0 {
                course = (course + courseNoiseOu).truncatingRemainder(dividingBy: 360.0)
                if course < 0 { course += 360.0 }
            }
            accuracy = min(max(accuracy + gaussRandom() * 0.5, 3.0), 60.0)
            if now < strollUntil {
                accuracy = max(accuracy, Double.random(in: 10.0...16.0))
            }
        }

        // v2.7.12 海拔低频游走：真实 GPS 高程噪声 ±3~8m 就是「累计爬升」的来源（真人 30m vs 我们 2.6m）
        var altOut = altitude
        if gpsRealism {
            let dtA = min(max(now.timeIntervalSince(altLastAt), 0.0), 5.0)
            altLastAt = now
            let decayA = exp(-dtA / 90.0)
            let kA = sqrt(max(0.0, 1.0 - decayA * decayA))
            altNoise = altNoise * decayA + gaussRandom() * 3.5 * kA
            if altNoise > 8.0 { altNoise = 8.0 } else if altNoise < -8.0 { altNoise = -8.0 }
            altOut = altitudeBase + altNoise
        }

        let location = CLLocation(
            coordinate: emitCoord,
            altitude: altOut,
            horizontalAccuracy: accuracy,
            verticalAccuracy: vertical,
            course: course,
            speed: speed,
            timestamp: now
        )
        lastInjected = (wgsCoord, now)
        LocSimManager.startLocSim(location: location)
    }

    /// v2.7.10：给注入坐标叠一层「低频游走」，像真 GPS 而不是数学折线。
    /// 一阶惯性：offset ← offset·e^(-dt/25) + 高斯·σ·√(1-e^(-2dt/25))，稳态标准差 0.6 米、上限 1.2 米。
    /// 相邻两拍只差几厘米，绝不会出现 v3.2 那种每秒横甩的锯齿。
    private func jittered(_ c: CLLocationCoordinate2D, at now: Date) -> CLLocationCoordinate2D {
        let dt = (noiseLastAt == .distantPast) ? 1.0 : min(max(now.timeIntervalSince(noiseLastAt), 0.0), 3.0)
        noiseLastAt = now
        let tau = 25.0
        let decay = exp(-dt / tau)
        let sigma = 0.60
        let k = sqrt(max(0.0, 1.0 - decay * decay))
        noiseEast  = noiseEast  * decay + gaussRandom() * sigma * k
        noiseNorth = noiseNorth * decay + gaussRandom() * sigma * k
        let mag = sqrt(noiseEast * noiseEast + noiseNorth * noiseNorth)
        if mag > 1.2 {
            noiseEast  *= 1.2 / mag
            noiseNorth *= 1.2 / mag
        }
        let dLat = noiseNorth / 110540.0
        let dLon = noiseEast / max(111320.0 * cos(c.latitude * .pi / 180.0), 1.0)
        return CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
    }

    /// Box-Muller：两个均匀分布 → 标准正态
    private func gaussRandom() -> Double {
        var u = Double.random(in: 0.0...1.0)
        if u < 1e-9 { u = 1e-9 }
        let v = Double.random(in: 0.0...1.0)
        return sqrt(-2.0 * log(u)) * cos(2.0 * .pi * v)
    }

    // MARK: - DriftFix v2.7.12 步频联动（deb 零改动）
    // 把实际模拟速度换算成步数插件的 cadenceSpm / strideMeters，写它的配置域
    // （deb 每 2 秒巡检热切、换档不回溯），deb 一行不用改。
    // 换算：cadence = 90 + v×30（钳 100~190，与 deb 拟真钳制同区间）；stride = v×60/cadence（钳 0.55~1.25）。
    // 走 0.9m/s → 117spm；跑 2.6m/s → 168spm×0.93m ✓。悦跑圈反推步幅 = GPS距离÷步数 = 真实。
    var plannedSpeedMps: Double = 1.4          // 开始前由视图按速度区间中值设定
    private var speedEma: Double = 0.0
    // lastLinkAt / lastLinkCadence 在 v2.7.12 状态段声明（此处不重复）

    func syncStepLink(force: Bool = false) {
        guard stepLinkEnabled else { return }
        let nowL = Date()
        if !force, nowL.timeIntervalSince(lastLinkAt) < 120.0 { return }
        let v = max(speedEma > 0.15 ? speedEma : plannedSpeedMps, 0.95)   // 防失配：deb 表达域最慢 100×0.55=0.92，低于它写出的组合必与 GPS 矛盾
        var cad = min(max(90.0 + v * 30.0, 100.0), 190.0)
        var stride = min(max(v * 60.0 / cad, 0.55), 1.25)
        cad = min(max(v * 60.0 / stride, 100.0), 190.0)
        let cadI = Int(cad.rounded())
        if !force, cadI == lastLinkCadence { return }
        lastLinkCadence = cadI
        lastLinkAt = nowL
        // /usr/bin/defaults 走 cfprefsd 正规通道（直接写文件会被缓存吞掉），root spawn 保权限
        let domain = "com.liush.joyrunsteps"
        spawnRoot("/usr/bin/defaults", ["defaults", "write", domain, "cadenceSpm", "-float", String(cadI)], nil, nil)
        spawnRoot("/usr/bin/defaults", ["defaults", "write", domain, "strideMeters", "-float", String(format: "%.2f", stride)], nil, nil)
    }

    /// v2.7.12 网格拐角弧化：锚点折角处退距 r 插二次贝塞尔过渡点，90° 直角变自然弧（对照真人轨迹贴路弯）
    private func roundedPath(_ pts: [CLLocationCoordinate2D], radiusMeters: Double = 18.0) -> [CLLocationCoordinate2D] {
        guard pts.count >= 3 else { return pts }
        var out: [CLLocationCoordinate2D] = [pts[0]]
        for k in 1..<(pts.count - 1) {
            let prev = pts[k - 1], cur = pts[k], next = pts[k + 1]
            let dIn = distanceBetween(prev, cur), dOut = distanceBetween(cur, next)
            guard dIn > 2, dOut > 2 else { out.append(cur); continue }
            let r = min(radiusMeters, dIn * 0.4, dOut * 0.4)
            let f = r / dIn, g = r / dOut
            let a = CLLocationCoordinate2D(latitude: cur.latitude + (prev.latitude - cur.latitude) * f,
                                           longitude: cur.longitude + (prev.longitude - cur.longitude) * f)
            let b = CLLocationCoordinate2D(latitude: cur.latitude + (next.latitude - cur.latitude) * g,
                                           longitude: cur.longitude + (next.longitude - cur.longitude) * g)
            out.append(a)
            out.append(CLLocationCoordinate2D(latitude: (a.latitude + cur.latitude * 2 + b.latitude) / 4.0,
                                              longitude: (a.longitude + cur.longitude * 2 + b.longitude) / 4.0))
            out.append(b)
        }
        out.append(pts[pts.count - 1])
        return out
    }

    /// 方位角（0° = 正北，顺时针）
    private func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var deg = atan2(y, x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
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
        // DriftFix v3.0: 区域自动绕行（可选，老存档解出来是 nil）
        // v3.2 起区域是手画多边形，顶点序列存这里；四个 area* 边界字段只用于兼容旧存档
        var areaSouth: Double? = nil
        var areaWest: Double? = nil
        var areaNorth: Double? = nil
        var areaEast: Double? = nil
        var areaTargetKm: Double? = nil
        var areaPolygon: [[Double]]? = nil
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
            if let poly = m.areaPolygon, poly.count >= 3 {
                let verts = poly.compactMap { $0.count >= 2
                    ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil }
                if verts.count >= 3 { areaPolygon = verts }
            } else if let s = m.areaSouth, let w = m.areaWest, let n = m.areaNorth, let e = m.areaEast {
                // 旧存档只有矩形：还原成矩形四角多边形
                areaPolygon = [CLLocationCoordinate2D(latitude: s, longitude: w),
                               CLLocationCoordinate2D(latitude: s, longitude: e),
                               CLLocationCoordinate2D(latitude: n, longitude: e),
                               CLLocationCoordinate2D(latitude: n, longitude: w)]
            }
            if let t = m.areaTargetKm { areaTargetKm = t }
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
