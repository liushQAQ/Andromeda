//  Andromeda LocSim - Route Extension
//  Created by son3ra1n.

import SwiftUI
import MapKit
import UIKit
import AlertKit

/// 分笔接缝（第 index 笔起点离上一笔终点多少米）
private struct StrokeGap: Identifiable {
    let index: Int
    let meters: Double
    var id: Int { index }
}

struct RouteSimSheet: View {
    @ObservedObject var routeSimulator: RouteSimulator
    @Binding var mapRegion: MKCoordinateRegion?
    @Binding var isPresented: Bool
    
    @State private var startText: String = ""
    @State private var endText: String = ""
    // DriftFix v2.7: 出行方式/速度区间/组合选项 全部记住上次选择（不再每次回到驾车 30~60）
    @AppStorage("andromedaTravelMode") private var travelModeRaw: String = TravelMode.walking.rawValue
    @AppStorage("andromedaSpeedMin") private var speedMinKmh: Double = 8.0
    @AppStorage("andromedaSpeedMax") private var speedMaxKmh: Double = 10.0
    @AppStorage("andromedaSkipPct") private var skipProbPct: Double = 0
    @AppStorage("andromedaSwapEnds") private var swapEndsOn: Bool = false
    @AppStorage("andromedaRandomFlip") private var randomFlipOn: Bool = false
    @AppStorage("andromedaLoops") private var loopCount: Int = 1
    @AppStorage("andromedaSnapLong") private var snapLongOn: Bool = true
    @AppStorage("andromedaFillSpacing") private var fillSpacing: Double = 200
    @State private var isSearchingStart: Bool = false
    @State private var isSearchingEnd: Bool = false
    @State private var startResults: [MKMapItem] = []
    @State private var endResults: [MKMapItem] = []
    @State private var activeField: ActiveField = .none
    @State private var routeReady: Bool = false
    @State private var wptText: String = ""
    @State private var isSearchingWpt: Bool = false
    @State private var wptResults: [MKMapItem] = []
    @State private var showMapPicker: Bool = false
    @State private var pickerRegion: MKCoordinateRegion? = nil
    @State private var pickerPoints: [CLLocationCoordinate2D] = []
    // DriftFix v3.0 区域自动绕行
    @State private var showAreaPicker: Bool = false
    @State private var areaSelecting: Int = 1          // 0=移动地图 1=框选区域
    @State private var areaPickerRegion: MKCoordinateRegion? = nil
    @State private var areaDraft: RouteSimulator.AreaRect? = nil
    @State private var showDrawOverlay: Bool = false
    @State private var optimizedPoints: [CLLocationCoordinate2D]? = nil
    @State private var drawPreviewOn: Bool = false
    @State private var drawMode: Int = 1          // 0=移动地图 1=画笔绘制 2=修改线路
    @State private var drawStrokes: [[CLLocationCoordinate2D]] = []
    @State private var showGPXPicker: Bool = false
    @AppStorage("andromedaSavedSort") private var savedSortRaw: String = RouteSimulator.SavedSort.dateDesc.rawValue
    @State private var savedRoutes: [RouteSimulator.SavedRouteInfo] = []
    @State private var shareItem: ShareItem? = nil

    struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    private var savedSort: RouteSimulator.SavedSort {
        RouteSimulator.SavedSort(rawValue: savedSortRaw) ?? .dateDesc
    }

    /// 出行方式走 AppStorage：选过就记住，重开面板不会跳回「驾车」
    private var selectedMode: TravelMode {
        get { TravelMode(rawValue: travelModeRaw) ?? .walking }
        nonmutating set { travelModeRaw = newValue.rawValue }
    }

    private func refreshSavedRoutes() {
        savedRoutes = RouteSimulator.savedRouteInfos(sort: savedSort)
    }
    
    enum ActiveField {
        case none, start, end, waypoint
    }
    
    var body: some View {
        ZStack {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    // MARK: - Route Status (when simulating)
                    if routeSimulator.isSimulating {
                        simulationStatusCard
                    } else {
                        // MARK: - Start Point
                        locationCard(
                            title: "起点",
                            icon: "play.circle.fill",
                            iconColor: .green,
                            text: $startText,
                            isSearching: isSearchingStart,
                            results: startResults,
                            selectedCoord: routeSimulator.userWaypoints.first,
                            field: .start
                        )
                        
                        // Arrow between cards
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundColor(.accentColor)
                        
                        // MARK: - End Point
                        locationCard(
                            title: "终点",
                            icon: "flag.checkered.circle.fill",
                            iconColor: .red,
                            text: $endText,
                            isSearching: isSearchingEnd,
                            results: endResults,
                            selectedCoord: (routeSimulator.userWaypoints.count >= 2 ? routeSimulator.userWaypoints.last : nil),
                            field: .end
                        )

                        // MARK: - DriftFix v2 线路模式
                        routeModeSection

                        // MARK: - DriftFix v2.4 模式相关区块
                        if routeSimulator.routeMode == .draw {
                            drawHintCard
                        } else if routeSimulator.routeMode == .area {
                            areaSection
                        } else {
                            addWaypointCard
                            waypointsSection
                            midFillCard
                            comboOptionsSection
                        }

                        travelModeSection
                        
                        // MARK: - DriftFix v2.2 速度区间（区间内随机游走，杜绝匀速）
                        speedRangeSection
                        
                        // MARK: - Calculate Button
                                Button(action: calculateRoute) {
                                    HStack {
                                        if routeSimulator.isCalculatingRoute {
                                            ProgressView()
                                                .scaleEffect(0.8)
                                                .tint(.white)
                                        } else {
                                            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath.fill")
                                        }
                                        Text(routeSimulator.isCalculatingRoute ? "算路中..." : (routeSimulator.routeMode == .area ? "生成区域路线" : "生成路线"))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill((routeSimulator.userWaypoints.count >= 2
                                                   && (routeSimulator.routeMode != .area || routeSimulator.areaRect != nil))
                                                  ? Color.indigo : Color.gray)
                                    )
                                    .foregroundColor(.white)
                                    .font(.headline)
                                }
                        .disabled(routeSimulator.userWaypoints.count < 2
                                  || routeSimulator.isCalculatingRoute
                                  || (routeSimulator.routeMode == .area && routeSimulator.areaRect == nil))
                        .padding(.horizontal)
                        
                        // MARK: - Route Selection (shown after calculation)
                        if routeReady && !routeSimulator.availableRoutes.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Image(systemName: "map.fill")
                                        .foregroundColor(.accentColor)
                                    Text("选择路线")
                                        .font(.headline)
                                    Spacer()
                                    Text("共 \(routeSimulator.availableRoutes.count) 条路线")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal)

                                ForEach(Array(routeSimulator.availableRoutes.enumerated()), id: \.element.id) { idx, option in
                                    routeOptionCard(option: option, index: idx)
                                }
                            }
                        }

                        // MARK: - Start / Save（算路或从存档加载后可用）
                        if routeReady {
                            // DriftFix v2.3: 本次实际访问顺序（随机组合后的结果）
                            if !routeSimulator.visitSequenceText.isEmpty {
                                Text("本次顺序: \(routeSimulator.visitSequenceText)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            }
                            // DriftFix v2.6: 预估评估三件套（里程/时长/步数）
                            if routeSimulator.estimatedMeters > 0 {
                                Text(String(format: "预估: 总里程 %.2f km · 时长 %@ · 步数 ≈ %d 步", routeSimulator.estimatedMeters / 1000, routeSimulator.estimatedTime, routeSimulator.estimatedSteps))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                            }
                            // Start button
                            Button(action: startRoute) {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("开始路线模拟")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.green)
                                )
                                .foregroundColor(.white)
                                .font(.headline)
                            }
                            .padding(.horizontal)

                            // DriftFix: 保存线路（存"实际注入序列"为 GPX，可重放可导出）
                            Button(action: saveCurrentRoute) {
                                HStack {
                                    Image(systemName: "square.and.arrow.down.fill")
                                    Text("保存线路")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.indigo.opacity(0.9))
                                )
                                .foregroundColor(.white)
                                .font(.headline)
                            }
                            .padding(.horizontal)
                        }

                        // MARK: - Saved Routes (DriftFix)
                        savedRoutesSection
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("路线模拟")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        routeSimulator.stopSimulation()
                        routeReady = false
                    }) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(.red)
                            .font(.title3)
                    }
                    .opacity(routeSimulator.isSimulating ? 1 : 0)
                    .disabled(!routeSimulator.isSimulating)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showGPXPicker = true }) {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.indigo)
                            .font(.title3)
                    }
                    .opacity(routeSimulator.isSimulating ? 0 : 1)
                    .disabled(routeSimulator.isSimulating)
                }
            }
            .sheet(isPresented: $showGPXPicker) {
                GPXDocumentPicker { url in
                    guard let result = GPXParser.parse(url: url), !result.isEmpty else {
                        UIApplication.shared.alert(body: "GPX 文件解析失败或为空。")
                        return
                    }
                    
                    // DriftFix: GPX 是真实轨迹(WGS-84)；地图/算路请求统一用 GCJ-02（与搜索结果同一基准）
                    let coords = result.allCoordinates.map { CoordTransform.wgs84ToGcj02($0) }
                    if coords.count >= 2 {
                        // Use first and last as start/end
                        routeSimulator.userWaypoints = [coords.first ?? CLLocationCoordinate2D(), coords.last ?? CLLocationCoordinate2D()]
                        startText = "GPX Start"
                        endText = "GPX End (\(coords.count) points)"
                        
                        // Fit map to route
                        let centerLat = coords.map { $0.latitude }.reduce(0, +) / Double(coords.count)
                        let centerLon = coords.map { $0.longitude }.reduce(0, +) / Double(coords.count)
                        mapRegion = MKCoordinateRegion(
                            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                        )
                        
                        AlertKitAPI.present(title: "GPX 已载入！\(coords.count) 个点", icon: .done, style: .iOS17AppleMusic, haptic: .success)
                    }
                }
            }
            .onAppear {
                refreshSavedRoutes()
                routeSimulator.restoreDrawnStrokes()
                if drawStrokes.isEmpty { drawStrokes = routeSimulator.drawnStrokes }
            }
            .sheet(item: $shareItem) { item in
                ActivityShareSheet(items: [item.url])
            }
        }

        if showMapPicker {
            mapPickerOverlay
        }

        if showDrawOverlay {
            drawOverlay
        }

        if showAreaPicker {
            areaPickerOverlay
        }
        }
    }

    // MARK: - 出行方式（拆子视图：body 表达式过大触发类型检查超时）
    private var travelModeSection: some View {
        // MARK: - Travel Mode
        VStack(alignment: .leading, spacing: 8) {
            Text("出行方式")
                .font(.headline)
                .padding(.horizontal)
            
            HStack(spacing: 12) {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    Button(action: {
                        // 只在真正切换模式时套默认速度；重复点同一种不会覆盖你自己调好的区间
                        if mode != selectedMode {
                            selectedMode = mode
                            applyModeSpeedDefaults(mode)
                        }
                        routeReady = false
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: mode.icon)
                                .font(.title2)
                            Text(mode.rawValue)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedMode == mode ?
                                      Color.accentColor.opacity(0.2) :
                                      Color(UIColor.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedMode == mode ?
                                        Color.accentColor : Color.clear, lineWidth: 2)
                        )
                    }
                    .foregroundColor(selectedMode == mode ? .accentColor : .primary)
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - 速度区间（拆子视图：同上）
    private var speedRangeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("速度区间")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f ~ %.1f km/h", speedMinKmh, speedMaxKmh))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            HStack {
                Text("最低")
                    .font(.caption)
                    .frame(width: 34)
                Slider(value: $speedMinKmh, in: 0.5...120, step: 0.5)
                    .onChange(of: speedMinKmh) { v in
                        if v > speedMaxKmh { speedMaxKmh = v }
                        routeReady = false
                    }
            }
            .padding(.horizontal)

            HStack {
                Text("最高")
                    .font(.caption)
                    .frame(width: 34)
                Slider(value: $speedMaxKmh, in: 0.5...120, step: 0.5)
                    .onChange(of: speedMaxKmh) { v in
                        if v < speedMinKmh { speedMinKmh = v }
                        routeReady = false
                    }
            }
            .padding(.horizontal)

            Text("实际速度在区间内每秒慢速随机变化（不是匀速机器人）；平均配速 \(paceText())")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            Text(String(format: "GPS 每秒采一点：平均 %.1f 米/点，约 %.1f 步/点（步幅 1.07m）",
                        (speedMinKmh + speedMaxKmh) / 2 / 3.6,
                        (speedMinKmh + speedMaxKmh) / 2 / 3.6 / 1.07))
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
    }

    // MARK: - DriftFix v2.3 组合选项（随机顺序/跳过/往返/绕圈）
    private var comboOptionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.orange)
                Text("组合选项")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            skipOptionGroup

            directionOptionGroup

            Stepper(value: $loopCount, in: 1...20) {
                Text("绕圈次数 ×\(loopCount)")
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .onChange(of: loopCount) { _ in routeReady = false }

            Toggle("长段贴合真实道路（绕远超过 18% 自动放弃）", isOn: $snapLongOn)
                .font(.subheadline)
                .padding(.horizontal)
                .onChange(of: snapLongOn) { _ in routeReady = false }

            Text("途经点行可单独切换 顺序/随机；每次生成重新组合。跳过只作用于「随机」点，固定点按序必到。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var skipOptionGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("随机点跳过")
                    .font(.caption)
                    .frame(width: 74)
                Slider(value: $skipProbPct, in: 0...100, step: 5)
                    .onChange(of: skipProbPct) { _ in routeReady = false }
                Text("\(Int(skipProbPct))%")
                    .font(.caption)
                    .frame(width: 36)
            }
            Text("每次生成线路时，被标成「随机」的途经点各有这个概率被跳过；标成「顺序」的点一定到。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }

    private var directionOptionGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("往返（去程 + 原路回程）", isOn: $swapEndsOn)
                .font(.subheadline)
                .onChange(of: swapEndsOn) { _ in routeReady = false }
            Text("按上面这条线路跑到头，再原路跑回来；绕圈 3 次就是 3 个来回。")
                .font(.caption2)
                .foregroundColor(.secondary)

            Toggle("起点终点随机互换（每次随机决定从哪头起跑）", isOn: $randomFlipOn)
                .font(.subheadline)
                .onChange(of: randomFlipOn) { _ in routeReady = false }
            Text("每次生成时随机决定整条线路从起点跑还是从终点跑（不是来回跑，只换方向）。")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - DriftFix v2.4 手画路线提示卡
    private var drawHintCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "hand.draw")
                    .foregroundColor(.accentColor)
                Text("手画路线")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)
            Text("点「生成路线」进入手画地图：先用「移动地图」定位，切「画笔绘制」按住拖动画线（可分多笔，单指画线/双指缩放）。你画成什么样，模拟就走什么样（不再自动简化、不会削拐角）。画完可切「修改线路」长按拖动改点、轻点删点，不用整条重画。笔画会自动保存，关掉再进来能接着改。")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var routeModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路模式")
                .font(.headline)
                .padding(.horizontal)
            HStack(spacing: 12) {
                ForEach(RouteSimulator.RouteMode.allCases) { m in
                    Button(action: {
                        routeSimulator.routeMode = m
                        UserDefaults.standard.set(m.rawValue, forKey: "andromedaRouteMode")
                        routeReady = false
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: modeIcon(m))
                            Text(m.label).font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(routeSimulator.routeMode == m ?
                                      Color.indigo.opacity(0.2) :
                                      Color(UIColor.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(routeSimulator.routeMode == m ? Color.indigo : Color.clear, lineWidth: 2)
                        )
                    }
                    .foregroundColor(routeSimulator.routeMode == m ? .indigo : .primary)
                }
            }
            .padding(.horizontal)
            Text(routeModeHint(routeSimulator.routeMode))
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
    }

    private func modeIcon(_ m: RouteSimulator.RouteMode) -> String {
        switch m {
        case .road: return "road.lanes"
        case .free: return "point.topleft.down.to.point.bottomright.curvepath"
        case .draw: return "hand.draw"
        case .area: return "rectangle.dashed"
        }
    }

    private func routeModeHint(_ m: RouteSimulator.RouteMode) -> String {
        switch m {
        case .road:
            return "道路导航：走真实路网；某段没有导航路线会直接报错，请改用自由路线（不再偷偷吸附替换）。"
        case .free:
            return "自由路线：按你选的点依序直线连接，完全不吸附路网——内部道路/园区/步行道随便走。"
        case .draw:
            return "手画路线：在地图上按住拖动画出线路，系统自动平滑优化成自然步态轨迹。"
        case .area:
            return "区域自动：只设起点和终点，再框一块区域、定一个目标公里数。中间怎么走系统自己排：先尽量贴地图上的道路，区域里蛇形绕行不来回交叉，走满公里数才停，不够就继续在区域里绕。"
        }
    }

    // MARK: - DriftFix v2.1 添加途径点卡片（搜索 + 地图选点弹层）
    private var addWaypointCard: some View {
        VStack(spacing: 8) {
            locationCard(
                title: "添加途径点",
                icon: "mappin.circle.fill",
                iconColor: .blue,
                text: $wptText,
                isSearching: isSearchingWpt,
                results: wptResults,
                selectedCoord: nil,
                field: .waypoint
            )
            Button(action: {
                pickerPoints = []
                // 打开就落在当前线路区域（没有就落在起点附近），不用先自己找位置
                if let r = mapRegion {
                    pickerRegion = r
                } else if let first = routeSimulator.userWaypoints.first {
                    pickerRegion = MKCoordinateRegion(center: first,
                                                      latitudinalMeters: 3000,
                                                      longitudinalMeters: 3000)
                }
                showMapPicker = true
            }) {
                HStack {
                    Image(systemName: "map.fill")
                    Text("在地图上连续选点添加")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.15))
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
        }
    }

    // MARK: - DriftFix v2.9 地图连续选点（一次打开，长按加 1/2/3…，右上角一次保存）
    private var mapPickerOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") {
                    showMapPicker = false
                    pickerPoints = []
                }
                .foregroundColor(.red)
                Spacer()
                Text("长按地图连续加点")
                    .font(.headline)
                Spacer()
                Button(action: commitPickedPoints) {
                    Text(pickerPoints.isEmpty ? "保存" : "保存 \(pickerPoints.count) 个")
                        .fontWeight(.semibold)
                }
                .disabled(pickerPoints.isEmpty)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            MultiPickMapView(points: $pickerPoints, moveToRegion: $pickerRegion)
                .frame(maxHeight: .infinity)
                .cornerRadius(12)
                .padding(.horizontal, 12)
                .overlay(alignment: .top) {
                    Text("长按地图任意位置放一个点，可以连放很多个；点下面的数字标签可删除")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if pickerPoints.isEmpty {
                        Text("还没有点：长按地图放点")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(pickerPoints.enumerated()), id: \.offset) { idx, p in
                            HStack(spacing: 4) {
                                Text("\(idx + 1)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Color.blue))
                                Text(String(format: "%.4f,%.4f", p.latitude, p.longitude))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Button(action: {
                                    if pickerPoints.indices.contains(idx) {
                                        pickerPoints.remove(at: idx)
                                    }
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(UIColor.secondarySystemBackground)))
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 56)

            if !pickerPoints.isEmpty {
                Button(action: { pickerPoints = [] }) {
                    Text("全部清空")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.bottom, 10)
            }
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(10)
    }

    private func commitPickedPoints() {
        guard !pickerPoints.isEmpty else { return }
        let pts = pickerPoints
        pickerPoints = []
        showMapPicker = false
        routeSimulator.addPickedWaypoints(pts)
        routeReady = false
        AlertKitAPI.present(title: "📍 已添加 \(pts.count) 个途经点", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    // MARK: - DriftFix v3.0 区域自动绕行（框选区域 + 目标公里数）
    private var areaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "rectangle.dashed")
                    .foregroundColor(.purple)
                Text("自动绕行区域")
                    .font(.headline)
                Spacer()
                if let r = routeSimulator.areaRect {
                    Text(r.summaryText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)

            HStack(spacing: 8) {
                Button(action: openAreaPicker) {
                    HStack(spacing: 6) {
                        Image(systemName: "map")
                        Text(routeSimulator.areaRect == nil ? "框选区域" : "重新框选")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.15)))
                    .foregroundColor(.purple)
                    .font(.subheadline.weight(.semibold))
                }
                if routeSimulator.areaRect != nil {
                    Button(action: {
                        routeSimulator.areaRect = nil
                        routeReady = false
                    }) {
                        Text("清除")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.red.opacity(0.12)))
                            .foregroundColor(.red)
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            HStack {
                Text("目标")
                    .font(.caption)
                    .frame(width: 34)
                Slider(value: $routeSimulator.areaTargetKm, in: 1...30, step: 0.5)
                    .onChange(of: routeSimulator.areaTargetKm) { v in
                        UserDefaults.standard.set(v, forKey: "andromedaAreaTargetKm")
                        routeReady = false
                    }
                Text(String(format: "%.1f km", routeSimulator.areaTargetKm))
                    .font(.caption)
                    .frame(width: 58)
            }
            .padding(.horizontal)

            Text("怎么走：起点先进区域 → 区域里按街道蛇形绕行（不会来回交叉）→ 走满 \(String(format: "%.1f", routeSimulator.areaTargetKm)) 公里 → 最后回到终点。贴路会稍微绕远，实际里程一般略多于目标。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            Toggle("尽量走地图上的道路", isOn: $snapLongOn)
                .font(.subheadline)
                .padding(.horizontal)
                .onChange(of: snapLongOn) { _ in routeReady = false }

            if routeSimulator.areaRect == nil {
                Text("⚠️ 还没框选区域：点上面「框选区域」，在地图上按住从一个角拖到对角。")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private var areaPickerOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") {
                    showAreaPicker = false
                }
                .foregroundColor(.red)
                Spacer()
                Text("框选区域")
                    .font(.headline)
                Spacer()
                Button(action: commitArea) {
                    Text(areaDraft == nil ? "保存" : "保存区域")
                        .fontWeight(.semibold)
                }
                .disabled(areaDraft == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Picker("", selection: $areaSelecting) {
                Text("移动地图").tag(0)
                Text("框选区域").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ZStack {
                AreaSelectMapView(
                    rect: $areaDraft,
                    moveToRegion: $areaPickerRegion,
                    selecting: areaSelecting == 1,
                    start: routeSimulator.userWaypoints.first,
                    end: routeSimulator.userWaypoints.count >= 2 ? routeSimulator.userWaypoints.last : nil
                )
                if areaDraft == nil {
                    Text(areaSelecting == 1
                         ? "按住地图，从一个角拖到对角，框出要绕行的区域"
                         : "先移动/缩放地图到要走的范围，再切「框选区域」")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .cornerRadius(12)
            .padding(.horizontal, 12)

            if let r = areaDraft {
                Text(String(format: "区域约 %.2f × %.2f km（%.2f km²）",
                            r.widthMeters / 1000, r.heightMeters / 1000,
                            r.widthMeters * r.heightMeters / 1_000_000))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                Text("区域内有起点/终点标记时，会自动把它们圈进来参考")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }

            Button(action: commitArea) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("使用这个区域")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(areaDraft == nil ? Color.gray : Color.purple)
                )
                .foregroundColor(.white)
                .font(.headline)
            }
            .disabled(areaDraft == nil)
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(12)
    }

    private func openAreaPicker() {
        areaDraft = routeSimulator.areaRect
        areaSelecting = routeSimulator.areaRect == nil ? 1 : 0
        if let r = routeSimulator.areaRect {
            areaPickerRegion = MKCoordinateRegion(center: r.center,
                                                  latitudinalMeters: max(r.heightMeters * 1.6, 1500),
                                                  longitudinalMeters: max(r.widthMeters * 1.6, 1500))
        } else if routeSimulator.userWaypoints.count >= 2,
                  let first = routeSimulator.userWaypoints.first,
                  let last = routeSimulator.userWaypoints.last {
            let mid = CLLocationCoordinate2D(latitude: (first.latitude + last.latitude) / 2,
                                             longitude: (first.longitude + last.longitude) / 2)
            let d = CLLocation(latitude: first.latitude, longitude: first.longitude)
                .distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            areaPickerRegion = MKCoordinateRegion(center: mid,
                                                  latitudinalMeters: max(d * 1.8, 2000),
                                                  longitudinalMeters: max(d * 1.8, 2000))
        } else if let c = routeSimulator.userWaypoints.first ?? mapRegion?.center {
            areaPickerRegion = MKCoordinateRegion(center: c,
                                                  latitudinalMeters: 3000,
                                                  longitudinalMeters: 3000)
        }
        showAreaPicker = true
    }

    private func commitArea() {
        guard let r = areaDraft else { return }
        guard r.widthMeters >= 150, r.heightMeters >= 150 else {
            UIApplication.shared.alert(body: "区域太小：至少框 150 米见方。")
            return
        }
        routeSimulator.areaRect = r
        routeReady = false
        showAreaPicker = false
        mapRegion = MKCoordinateRegion(center: r.center,
                                       latitudinalMeters: max(r.heightMeters * 1.3, 800),
                                       longitudinalMeters: max(r.widthMeters * 1.3, 800))
        AlertKitAPI.present(title: "区域已选 \(r.summaryText)", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    // MARK: - DriftFix v2.9 手画路线弹层（画笔 / 移动 / 修改 三模式，笔画常驻可反复改）
    private var drawStrokesBinding: Binding<[[CLLocationCoordinate2D]]> {
        $drawStrokes
    }

    /// 画笔改动落到 RouteSimulator 并存盘（关面板/退出 App 都不丢）
    private func syncDrawStrokes() {
        routeSimulator.drawnStrokes = drawStrokes
        routeSimulator.persistDrawnStrokes()
    }

    private var drawOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭") {
                    // 笔画常驻（存盘），下次进来接着改，不用重画
                    syncDrawStrokes()
                    showDrawOverlay = false
                }
                .foregroundColor(.red)
                Spacer()
                Text("手画路线")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    drawStrokes = []
                    routeSimulator.clearDrawnStrokes()
                    optimizedPoints = nil
                    routeReady = false
                }
                .foregroundColor(.orange)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Picker("", selection: $drawMode) {
                Text("移动地图").tag(0)
                Text("画笔绘制").tag(1)
                Text("修改线路").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            // v3.1：旧笔画/断笔提醒——路线是「所有笔画按画的顺序连起来」，两笔离太远会拉直线
            if !drawStrokes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已有上次画的 \(drawStrokes.count) 笔（\(allDrawPoints.count) 点），会一起参与这条路线；要重画先点右上角「清空」。")
                    ForEach(strokeGapWarnings()) { g in
                        Text("第 \(g.index) 笔的起点离上一笔终点 \(Int(g.meters.rounded())) 米，中间会直线连过去。")
                            .foregroundColor(.orange)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 6)
            }

            ZStack {
                DrawMapView(
                    strokes: drawStrokesBinding,
                    moveToRegion: $mapRegion,
                    drawingEnabled: drawMode == 1,
                    editingEnabled: drawMode == 2,
                    previewPoints: drawPreviewOn ? optimizedPoints : nil
                )
                if allDrawPoints.isEmpty {
                    Text(drawMode == 1
                         ? "在此区域按住并拖动，画出你的跑步线路\n（单指画线、双指缩放；可分多笔画，内部道路随意）"
                         : (drawMode == 2
                            ? "长按线路上的点拖动可以改形\n轻点线路上的点可以删掉它"
                            : "先移动/缩放地图到你要画的区域\n再切到「画笔绘制」开始画"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .cornerRadius(12)
            .padding(.horizontal, 12)

            if drawMode == 2 {
                Text("修改模式：长按线路上的点拖动改形，轻点点删掉；改完点下面「完成·采用」。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {
                Button(action: undoLastStroke) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.uturn.backward")
                        Text("撤销一笔")
                    }
                    .font(.caption)
                }
                .disabled(drawStrokes.isEmpty)
                Button(action: togglePreview) {
                    HStack(spacing: 2) {
                        Image(systemName: "wand.and.stars")
                        Text(drawPreviewOn ? "看原始" : "AI 优化")
                    }
                    .font(.caption)
                }
                .disabled(allDrawPoints.count < 3)
                Spacer()
                Text("笔画 \(drawStrokes.count) · 点 \(allDrawPoints.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack(spacing: 8) {
                Button(action: adoptDrawAsWaypoints) {
                    HStack(spacing: 2) {
                        Image(systemName: "list.number")
                        Text("转成可编辑点")
                    }
                    .font(.caption)
                }
                .disabled(allDrawPoints.count < 2)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            Button(action: finishDraw) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text(drawPreviewOn ? "完成·采用优化线路" : "完成·采用手画线路")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(allDrawPoints.count >= 2 ? Color.green : Color.gray)
                )
                .foregroundColor(.white)
                .font(.headline)
            }
            .disabled(allDrawPoints.count < 2)
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(11)
    }

    private var allDrawPoints: [CLLocationCoordinate2D] {
        drawStrokes.flatMap { $0 }
    }

    /// 已有笔画的外接区域（留 60% 余量）：打开手画地图直接定位过去
    private func drawStrokesRegion() -> MKCoordinateRegion? {
        let pts = allDrawPoints
        guard let first = pts.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in pts {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.6, 0.004),
                                    longitudeDelta: max((maxLon - minLon) * 1.6, 0.004))
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                                                 longitude: (minLon + maxLon) / 2),
                                  span: span)
    }

    /// 分笔接缝：第 index 笔的起点离上一笔终点多远（>120m 会拉出一条明显不是画出来的直线）
    private func strokeGapWarnings() -> [StrokeGap] {
        guard drawStrokes.count >= 2 else { return [] }
        var out: [StrokeGap] = []
        for i in 1..<drawStrokes.count {
            guard let prevEnd = drawStrokes[i - 1].last, let start = drawStrokes[i].first else { continue }
            let d = CLLocation(latitude: prevEnd.latitude, longitude: prevEnd.longitude)
                .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
            if d > 120 { out.append(StrokeGap(index: i + 1, meters: d)) }
        }
        return out
    }

    private func undoLastStroke() {
        guard !drawStrokes.isEmpty else { return }
        drawStrokes.removeLast()
        if drawStrokes.isEmpty { optimizedPoints = nil }
        syncDrawStrokes()
        routeReady = false
    }

    private func adoptDrawAsWaypoints() {
        let src = drawPreviewOn
            ? routeSimulator.optimizeDrawnPath(points: allDrawPoints)
            : allDrawPoints
        let n = routeSimulator.adoptDrawnAsWaypoints(points: src)
        guard n >= 2 else {
            UIApplication.shared.alert(body: "线路太短，多画一点再转。")
            return
        }
        if let first = routeSimulator.userWaypoints.first {
            startText = String(format: "%.5f, %.5f", first.latitude, first.longitude)
        }
        if let last = routeSimulator.userWaypoints.last {
            endText = String(format: "%.5f, %.5f", last.latitude, last.longitude)
        }
        routeReady = false
        showDrawOverlay = false
        syncDrawStrokes()
        AlertKitAPI.present(title: "已转成 \(n) 个可编辑点", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    private func togglePreview() {
        if drawPreviewOn {
            drawPreviewOn = false
        } else {
            optimizedPoints = routeSimulator.optimizeDrawnPath(points: allDrawPoints)
            drawPreviewOn = true
        }
    }

    private func finishDraw() {
        // v3.1: 每次按当前笔画现算，不再用缓存的预览点——否则改完点/撤销一笔后，
        // 走的还是改之前那条线（另一个「画的和走的不一样」的来源）
        let src = drawPreviewOn
            ? routeSimulator.optimizeDrawnPath(points: allDrawPoints)
            : allDrawPoints
        let minMps = speedMinKmh / 3.6
        let maxMps = speedMaxKmh / 3.6
        if routeSimulator.buildFromDrawnPath(points: src, minSpeed: minMps, maxSpeed: maxMps) {
            // 起终点对齐到画线首末点：卡片显示与实际走的完全一致
            if let f = src.first, let l = src.last {
                routeSimulator.setDrawnEndpoints(start: f, end: l)
                startText = String(format: "%.5f, %.5f", f.latitude, f.longitude)
                endText = String(format: "%.5f, %.5f", l.latitude, l.longitude)
            }
            syncDrawStrokes()
            showDrawOverlay = false
            routeReady = true
            showRouteOnMap()
            AlertKitAPI.present(title: "手画线路已生成", icon: .done, style: .iOS17AppleMusic, haptic: .success)
        } else {
            UIApplication.shared.alert(body: "画出的线路太短，请多画一些再点完成。")
        }
    }

    // MARK: - DriftFix v2 途经点列表（起点/途径1..N/终点 全序列，可逐条删）
    private var waypointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "list.number")
                    .foregroundColor(.accentColor)
                Text("点序列")
                    .font(.headline)
                Spacer()
                Text("\(routeSimulator.userWaypoints.count) pts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            if routeSimulator.userWaypoints.isEmpty {
                Text("还没有点：先设起终点（搜索/地图），再用上方卡片加途径点。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                let last = routeSimulator.userWaypoints.count - 1
                ForEach(routeSimulator.userWaypoints.indices, id: \.self) { idx in
                    let isStart = idx == 0
                    let isEnd = idx == last
                    let isWild = idx > 0 && idx < last
                        && idx < routeSimulator.waypointModes.count
                        && routeSimulator.waypointModes[idx]
                    HStack(spacing: 8) {
                        Image(systemName: isStart ? "play.fill" : (isEnd ? "flag.checkered.fill" : "mappin"))
                            .font(.caption)
                            .foregroundColor(isStart ? .green : (isEnd ? .red : .blue))
                        Text(isStart ? "起点" : (isEnd ? "终点" : "途经点 \(idx)"))
                            .font(.subheadline)
                        if !isStart && !isEnd {
                            Button(action: { routeSimulator.toggleWaypointMode(at: idx) }) {
                                HStack(spacing: 2) {
                                    Image(systemName: isWild ? "shuffle" : "lock.fill")
                                    Text(isWild ? "随机" : "顺序")
                                }
                                .font(.caption2)
                                .foregroundColor(isWild ? .orange : .secondary)
                            }
                            .padding(.horizontal, 2)
                        }
                        Spacer()
                        Text(String(format: "%.4f, %.4f",
                                    routeSimulator.userWaypoints[idx].latitude,
                                    routeSimulator.userWaypoints[idx].longitude))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Button(action: {
                            routeSimulator.removeWaypoint(at: idx)
                            routeReady = false
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(.red)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }
    
    // MARK: - DriftFix v2.8 中间补点（「两点之间太长」→ 按米数等分插点，里程不变）
    private var midFillCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "plus.circle.dashed")
                    .foregroundColor(.teal)
                Text("中间补点")
                    .font(.headline)
                Spacer()
                Text("\(Int(fillSpacing)) m")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            HStack {
                Text("间距")
                    .font(.caption)
                    .frame(width: 34)
                Slider(value: $fillSpacing, in: 50...500, step: 50)
                    .onChange(of: fillSpacing) { _ in routeReady = false }
                Text("\(Int(fillSpacing)) m")
                    .font(.caption)
                    .frame(width: 52)
            }
            .padding(.horizontal)

            Button(action: fillIntermediatePoints) {
                HStack {
                    Image(systemName: "plus.circle.fill")
                    Text("每段按 \(Int(fillSpacing)) m 插入途经点")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.teal.opacity(0.15)))
                .foregroundColor(.teal)
                .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal)

            Text("插入的是直线等分点，总里程不变（距离最短）。补完可在点序列里逐个删除或改成随机。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private func fillIntermediatePoints() {
        guard routeSimulator.userWaypoints.count >= 2 else { return }
        let before = routeSimulator.userWaypoints.count
        let dense = routeSimulator.densifyPoints(routeSimulator.userWaypoints, spacing: fillSpacing)
        guard dense.count > before else {
            AlertKitAPI.present(title: "每段都短于 \(Int(fillSpacing)) m，无需补点", icon: .done, style: .iOS17AppleMusic, haptic: .warning)
            return
        }
        routeSimulator.userWaypoints = dense
        routeSimulator.waypointModes = [Bool](repeating: false, count: dense.count)
        routeReady = false
        AlertKitAPI.present(title: "已插入 \(dense.count - before) 个中间点", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    // MARK: - Route Option Card
    private func routeOptionCard(option: RouteOption, index: Int) -> some View {
        let isSelected = routeSimulator.selectedRouteIndex == index
        let routeColors: [Color] = [.blue, .orange, .purple, .pink]
        let color = routeColors[index % routeColors.count]
        
        return Button(action: {
            routeSimulator.selectRoute(at: index)
            // Show this route on map
            showRouteOnMap()
        }) {
            HStack(spacing: 12) {
                // Color indicator
                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: 6, height: 50)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(option.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        if index == 0 {
                            Text("最快")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundColor(.green)
                                .cornerRadius(4)
                        }
                    }
                    
                    HStack(spacing: 16) {
                        HStack(spacing: 4) {
                            Image(systemName: "ruler")
                                .font(.caption2)
                            Text(option.distanceText)
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text(option.etaText)
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        
                        HStack(spacing: 4) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.caption2)
                            Text("\(option.route.polyline.pointCount) pts")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.caption2)
                        Text("预计时间: \(routeSimulator.estimatedTime)")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? color : Color.white.opacity(0.2), lineWidth: 2)
            )
        }
        .foregroundColor(.primary)
        .padding(.horizontal)
    }
    
    // MARK: - Simulation Status Card
    private var simulationStatusCard: some View {
        VStack(spacing: 16) {
            // Progress
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: selectedMode.icon)
                        .foregroundColor(.accentColor)
                    Text("路线模拟进行中")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(routeSimulator.progress * 100))%")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.accentColor)
                }
                
                ProgressView(value: routeSimulator.progress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                
                HStack {
                    Text("进度点 \(routeSimulator.currentPointIndex)/\(routeSimulator.totalPoints)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("预计时间: \(routeSimulator.estimatedTime)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(UIColor.secondarySystemBackground))
            )
            
            // Controls
            HStack(spacing: 20) {
                Button(action: {
                    routeSimulator.togglePause()
                }) {
                    HStack {
                        Image(systemName: routeSimulator.isPaused ? "play.fill" : "pause.fill")
                        Text(routeSimulator.isPaused ? "Resume" : "Pause")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.orange)
                    )
                    .foregroundColor(.white)
                    .font(.headline)
                }
                
                Button(action: {
                    routeSimulator.stopSimulation()
                    routeReady = false
                    AlertKitAPI.present(
                        title: "路线已停止",
                        icon: .done,
                        style: .iOS17AppleMusic,
                        haptic: .success
                    )
                }) {
                    HStack {
                        Image(systemName: "stop.fill")
                        Text("停止")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.red)
                    )
                    .foregroundColor(.white)
                    .font(.headline)
                }
            }
            
            // Current position info
            if let pos = routeSimulator.currentPosition {
                HStack {
                    Image(systemName: "location.fill")
                        .foregroundColor(.blue)
                    Text(String(format: "%.5f, %.5f", pos.latitude, pos.longitude))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Location Card
    @ViewBuilder
    private func locationCard(
        title: String,
        icon: String,
        iconColor: Color,
        text: Binding<String>,
        isSearching: Bool,
        results: [MKMapItem],
        selectedCoord: CLLocationCoordinate2D?,
        field: ActiveField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.title3)
                Text(title)
                    .font(.headline)
                Spacer()
                if selectedCoord != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal)
            
            HStack {
                TextField("搜索地址...", text: text, onCommit: {
                    searchLocation(query: text.wrappedValue, field: field)
                })
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .onTapGesture {
                    activeField = field
                }
                
                if isSearching {
                    ProgressView()
                        .scaleEffect(0.7)
                }
                
                Button(action: {
                    searchLocation(query: text.wrappedValue, field: field)
                }) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)
            
            if selectedCoord != nil {
                HStack {
                    Image(systemName: "mappin")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.4f, %.4f", selectedCoord!.latitude, selectedCoord!.longitude))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
            }
            
            // Search Results
            if activeField == field && !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(results.prefix(5), id: \.self) { item in
                        Button(action: {
                            selectLocation(item, field: field)
                        }) {
                            HStack {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundColor(iconColor)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name ?? "Unknown")
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    if let addr = item.placemark.title {
                                        Text(addr)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                        }
                        Divider().padding(.leading, 40)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(UIColor.tertiarySystemBackground))
                )
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }
    
    // MARK: - Computed
    private func paceText() -> String {
        let avg = (speedMinKmh + speedMaxKmh) / 2
        guard avg > 0.2 else { return "—" }
        let totalSec = 3600 / avg
        return String(format: "%d'%02d\"/km", Int(totalSec / 60), Int(totalSec) % 60)
    }

    private func applyModeSpeedDefaults(_ mode: TravelMode) {
        switch mode {
        case .walking: speedMinKmh = 3.5; speedMaxKmh = 4.5   // 老总真实漫步实测: 3.7km/h(16'08/km) 步频58
        case .cycling: speedMinKmh = 15.0; speedMaxKmh = 25.0
        case .driving: speedMinKmh = 30.0; speedMaxKmh = 60.0
        }
    }
    
    // MARK: - Actions
    private func searchLocation(query: String, field: ActiveField) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        activeField = field

        if field == .start { isSearchingStart = true }
        else if field == .end { isSearchingEnd = true }
        else { isSearchingWpt = true }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query

        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                if field == .start { isSearchingStart = false }
                else if field == .end { isSearchingEnd = false }
                else { isSearchingWpt = false }

                if let items = response?.mapItems {
                    if field == .start { startResults = items }
                    else if field == .end { endResults = items }
                    else { wptResults = items }
                }
            }
        }
    }
    
    private func selectLocation(_ item: MKMapItem, field: ActiveField) {
        let coord = item.placemark.coordinate

        if field == .start {
            routeSimulator.setStart(coord)
            startText = item.name ?? "Selected"
            startResults = []
        } else if field == .end {
            routeSimulator.setEnd(coord)
            endText = item.name ?? "Selected"
            endResults = []
        } else {
            routeSimulator.addPickedWaypoint(coord)
            wptText = ""
            wptResults = []
            AlertKitAPI.present(title: "📍 途径点已添加", icon: .done, style: .iOS17AppleMusic, haptic: .success)
        }

        activeField = .none
        routeReady = false
    }
    
    private func calculateRoute() {
        // DriftFix v2.9: 手画模式 → 打开手画地图（笔画常驻，可接着改；默认直接进画笔模式）
        if routeSimulator.routeMode == .draw {
            drawMode = 1
            // v3.1: 已有上次的笔画时，地图直接落在笔画范围——不再停在空白地图上，
            // 免得在别处新画一笔，跟旧笔画拼成一条横跨几百米的怪线路。
            if let region = drawStrokesRegion() { mapRegion = region }
            showDrawOverlay = true
            return
        }
        // DriftFix v3.0: 区域自动绕行
        if routeSimulator.routeMode == .area {
            guard let rect = routeSimulator.areaRect else {
                UIApplication.shared.alert(body: "先在「自动绕行区域」里框一块区域。")
                return
            }
            guard routeSimulator.userWaypoints.count >= 2,
                  let s = routeSimulator.userWaypoints.first,
                  let e = routeSimulator.userWaypoints.last else {
                UIApplication.shared.alert(body: "先设好起点和终点。")
                return
            }
            let minMps = speedMinKmh / 3.6
            let maxMps = speedMaxKmh / 3.6
            routeSimulator.travelMode = selectedMode
            routeSimulator.buildAreaRoute(start: s,
                                          end: e,
                                          rect: rect,
                                          targetMeters: routeSimulator.areaTargetKm * 1000,
                                          minSpeed: minMps,
                                          maxSpeed: maxMps,
                                          snapToRoads: snapLongOn) { ok, message in
                if ok {
                    routeReady = true
                    showRouteOnMap()
                    if let msg = message { UIApplication.shared.alert(body: msg) }
                } else {
                    UIApplication.shared.alert(body: message ?? "区域算路失败")
                }
            }
            return
        }
        guard routeSimulator.userWaypoints.count >= 2 else { return }
        let minMps = speedMinKmh / 3.6
        let maxMps = speedMaxKmh / 3.6
        // DriftFix v2.3: 多自由度组合——每点 顺序/随机 + 跳过 + 往返 + 随机互换 + 绕圈
        let seq = routeSimulator.generateVisitSequence(skipProbability: skipProbPct / 100,
                                                       swapEnds: swapEndsOn,
                                                       randomFlip: randomFlipOn,
                                                       loops: loopCount)
        guard seq.count >= 2 else { return }
        let pts = seq.map { routeSimulator.userWaypoints[$0] }

        if routeSimulator.routeMode == .free {
            // DriftFix v2.4: 自由路线智能版——短段直线，长段贴路/弯曲化，杜绝直线穿越与吸附
            routeSimulator.travelMode = selectedMode
            routeSimulator.buildSmartFreeRoute(points: pts, minSpeed: minMps, maxSpeed: maxMps, snapLongSegments: snapLongOn) { success, error in
                if success {
                    routeReady = true
                    showRouteOnMap()
                } else {
                    UIApplication.shared.alert(body: error ?? "Failed to calculate route")
                }
            }
            return
        }
        routeSimulator.calculateFlexibleRoute(points: pts, mode: selectedMode, minSpeed: minMps, maxSpeed: maxMps) { success, error in
            if success {
                routeReady = true
                showRouteOnMap()
            } else {
                UIApplication.shared.alert(body: error ?? "Failed to calculate route")
            }
        }
    }
    
    private func showRouteOnMap() {
        // Show all routes on map, zoom to fit
        if let selectedPolyline = routeSimulator.routePolyline {
            let rect = selectedPolyline.boundingMapRect
            let region = MKCoordinateRegion(rect.insetBy(dx: -rect.size.width * 0.2, dy: -rect.size.height * 0.2))
            mapRegion = region
        }
    }

    // MARK: - Saved Routes (DriftFix v2.5: 管理=载入/重命名/删除/排序/分享导出)
    private var savedRoutesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tray.full.fill")
                    .foregroundColor(.accentColor)
                Text("保存的线路")
                    .font(.headline)
                Spacer()
                Text("\(savedRoutes.count) 条")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button(action: {
                    savedSortRaw = nextSort().rawValue
                    refreshSavedRoutes()
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(savedSort.rawValue)
                    }
                    .font(.caption)
                }
                Button(action: refreshSavedRoutes) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal)

            if savedRoutes.isEmpty {
                Text("暂无保存线路。算好路线点 Save Route，即可在这里载入/重命名/删除/排序/分享导出。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                ForEach(savedRoutes) { info in
                    HStack(spacing: 8) {
                        Button(action: { loadSavedRoute(info) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "figure.walk.circle.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(info.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Text("\(fmtDate(info.date)) · \(max(1, info.sizeBytes / 1024)) KB")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button(action: { shareItem = ShareItem(url: info.url) }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15))
                                .foregroundColor(.accentColor)
                        }
                        .padding(.horizontal, 3)
                        Button(action: { renameRoute(info) }) {
                            Image(systemName: "pencil")
                                .font(.system(size: 15))
                                .foregroundColor(.orange)
                        }
                        .padding(.horizontal, 3)
                        Button(action: { deleteRoute(info) }) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 15))
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 3)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    Divider().padding(.leading, 36)
                }
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }

    private func nextSort() -> RouteSimulator.SavedSort {
        let all = RouteSimulator.SavedSort.allCases
        guard let i = all.firstIndex(of: savedSort) else { return .dateDesc }
        return all[(i + 1) % all.count]
    }

    private func fmtDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    private func renameRoute(_ info: RouteSimulator.SavedRouteInfo) {
        UIApplication.shared.TextFieldAlert(
            title: "重命名线路",
            textFieldPlaceHolder: info.name
        ) { text, _ in
            guard let newName = text, !newName.isEmpty else { return }
            if RouteSimulator.renameSavedRoute(at: info.url, to: newName) != nil {
                refreshSavedRoutes()
                AlertKitAPI.present(title: "已重命名", icon: .done, style: .iOS17AppleMusic, haptic: .success)
            } else {
                UIApplication.shared.alert(body: "重命名失败")
            }
        }
    }

    private func deleteRoute(_ info: RouteSimulator.SavedRouteInfo) {
        UIApplication.shared.confirmAlert(
            title: "删除线路",
            body: "确定删除「\(info.name)」？此操作不可恢复。",
            onOK: {
                if RouteSimulator.deleteSavedRoute(at: info.url) {
                    refreshSavedRoutes()
                    AlertKitAPI.present(title: "已删除", icon: .done, style: .iOS17AppleMusic, haptic: .success)
                } else {
                    UIApplication.shared.alert(body: "删除失败")
                }
            },
            noCancel: false
        )
    }

    private func saveCurrentRoute() {
        UIApplication.shared.TextFieldAlert(
            title: "线路名称",
            textFieldPlaceHolder: "Example: Morning Run"
        ) { text, _ in
            guard let name = text, !name.isEmpty else { return }
            // DriftFix v2.7: 连同起终点/途经点/出行方式/速度区间一起存，载入后能完整还原
            let meta = RouteSimulator.SavedRouteMeta(
                mode: routeSimulator.routeMode.rawValue,
                travelMode: selectedMode.rawValue,
                speedMinKmh: speedMinKmh,
                speedMaxKmh: speedMaxKmh,
                skipPct: skipProbPct,
                swapEnds: swapEndsOn,
                loops: loopCount,
                snapLong: snapLongOn,
                waypoints: routeSimulator.userWaypoints.map { [$0.latitude, $0.longitude] },
                waypointModes: routeSimulator.waypointModes,
                areaSouth: routeSimulator.areaRect?.south,
                areaWest: routeSimulator.areaRect?.west,
                areaNorth: routeSimulator.areaRect?.north,
                areaEast: routeSimulator.areaRect?.east,
                areaTargetKm: routeSimulator.areaRect == nil ? nil : routeSimulator.areaTargetKm
            )
            if routeSimulator.saveCurrentRoute(named: name, meta: meta) {
                savedRoutes = RouteSimulator.savedRouteInfos(sort: savedSort)
                AlertKitAPI.present(title: "已保存", icon: .done, style: .iOS17AppleMusic, haptic: .success)
            } else {
                UIApplication.shared.alert(body: "没有可保存的内容（尚未载入路线）。")
            }
        }
    }

    private func loadSavedRoute(_ info: RouteSimulator.SavedRouteInfo) {
        let res = routeSimulator.loadSavedRoute(at: info.url)
        guard res.ok else {
            UIApplication.shared.alert(body: "线路文件载入失败。")
            return
        }
        // 元数据回填：出行方式/速度区间/组合选项/起终点文字——和保存时一模一样
        if let meta = res.meta {
            if let m = TravelMode(rawValue: meta.travelMode) { travelModeRaw = m.rawValue }
            speedMinKmh = meta.speedMinKmh
            speedMaxKmh = meta.speedMaxKmh
            skipProbPct = meta.skipPct
            swapEndsOn = meta.swapEnds
            loopCount = meta.loops
            snapLongOn = meta.snapLong
        }
        if let first = routeSimulator.userWaypoints.first {
            startText = String(format: "%.5f, %.5f", first.latitude, first.longitude)
        }
        if let last = routeSimulator.userWaypoints.last {
            endText = String(format: "%.5f, %.5f", last.latitude, last.longitude)
        }
        routeReady = true
        if let poly = routeSimulator.routePolyline {
            let rect = poly.boundingMapRect
            mapRegion = MKCoordinateRegion(rect.insetBy(dx: -rect.size.width * 0.2, dy: -rect.size.height * 0.2))
        }
        AlertKitAPI.present(title: "已载入", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }
    
    private func startRoute() {
        routeSimulator.startSimulation(altitude: 0.0)
        
        AlertKitAPI.present(
            title: "路线已开始！",
            icon: .done,
            style: .iOS17AppleMusic,
            haptic: .success
        )
    }
}

// MARK: - DriftFix v2.5: 系统分享面板（线路 GPX 导出：存文件/AirDrop/微信等）
struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - DriftFix v2.4: 手画地图（画笔/移动/修改三模式：单指绘制轨迹，移动时滚动/缩放定位）
struct DrawMapView: UIViewRepresentable {
    @Binding var strokes: [[CLLocationCoordinate2D]]
    @Binding var moveToRegion: MKCoordinateRegion?
    var drawingEnabled: Bool = true
    var editingEnabled: Bool = false
    var previewPoints: [CLLocationCoordinate2D]? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        // 移动/绘制由 drawingEnabled 动态切换（updateUIView 统一设置）
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.minimumNumberOfTouches = 1
        mv.addGestureRecognizer(pan)

        // 修改模式：长按拖动改点 / 轻点点删点
        let editPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEditDrag(_:)))
        editPress.minimumPressDuration = 0.35
        editPress.numberOfTouchesRequired = 1
        editPress.isEnabled = false
        mv.addGestureRecognizer(editPress)
        context.coordinator.editPress = editPress

        let editTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleEditTap(_:)))
        editTap.numberOfTouchesRequired = 1
        editTap.isEnabled = false
        mv.addGestureRecognizer(editTap)
        context.coordinator.editTap = editTap
        return mv
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.isScrollEnabled = !drawingEnabled   // 画笔=地图固定单指画线；移动=恢复滚动定位
        uiView.isZoomEnabled = !drawingEnabled     // 画笔模式禁双击/捏合缩放（防误触变成缩放地图）
        uiView.isPitchEnabled = false
        uiView.isRotateEnabled = false
        context.coordinator.editPress?.isEnabled = editingEnabled
        context.coordinator.editTap?.isEnabled = editingEnabled
        if let region = moveToRegion {
            uiView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.moveToRegion = nil }
        }
        let sig = "\(strokes.count)|\(strokes.last?.count ?? -1)|\(previewPoints?.count ?? -1)|\(drawingEnabled)|\(editingEnabled)"
        if context.coordinator.lastSig != sig {
            context.coordinator.lastSig = sig
            context.coordinator.syncOverlay(uiView, strokes: strokes, preview: previewPoints)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        struct EditDrag {
            let stroke: Int
            let anchor: CLLocationCoordinate2D
            let members: [(idx: Int, origin: CLLocationCoordinate2D, weight: Double)]
        }

        var parent: DrawMapView
        var lastSig: String = "-"
        var editPress: UILongPressGestureRecognizer?
        var editTap: UITapGestureRecognizer?
        private var editDrag: EditDrag? = nil
        init(_ parent: DrawMapView) { self.parent = parent }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let mv = g.view as? MKMapView else { return }
            if !parent.drawingEnabled { return }   // 移动模式：交给地图自身手势
            switch g.state {
            case .began:
                if parent.strokes.last?.isEmpty != true { parent.strokes.append([]) }
            case .changed:
                // DriftFix v2.6: 修复空笔画 guard 死锁——第一个点永远写不进去导致无法绘制
                if parent.strokes.isEmpty || parent.strokes.last?.isEmpty == true { parent.strokes.append([]) }
                let p = g.location(in: mv)
                let c = mv.convert(p, toCoordinateFrom: mv)
                if let lastC = parent.strokes.last?.last {
                    let d = CLLocation(latitude: lastC.latitude, longitude: lastC.longitude)
                        .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
                    if d < 8 { break }   // 8m 采样节流
                }
                parent.strokes[parent.strokes.count - 1].append(c)
            case .ended:
                // 单击（未拖动）也记一个点，避免"点了没反应"
                if parent.strokes.isEmpty || parent.strokes.last?.isEmpty ?? true {
                    if parent.strokes.isEmpty { parent.strokes.append([]) }
                    let p = g.location(in: mv)
                    parent.strokes[parent.strokes.count - 1].append(mv.convert(p, toCoordinateFrom: mv))
                }
            default:
                break
            }
        }

        // MARK: - DriftFix v2.9 修改线路（拖动改点 / 轻点删点）

        private func nearestVertex(_ mv: MKMapView, at point: CGPoint) -> (Int, Int)? {
            var best: (Int, Int)? = nil
            var bestD = CGFloat.greatestFiniteMagnitude
            for (s, stroke) in parent.strokes.enumerated() {
                for (i, c) in stroke.enumerated() {
                    let p = mv.convert(c, toPointTo: mv)
                    let dx = p.x - point.x
                    let dy = p.y - point.y
                    let d = (dx * dx + dy * dy).squareRoot()
                    if d < bestD { bestD = d; best = (s, i) }
                }
            }
            return bestD <= 36 ? best : nil
        }

        @objc func handleEditDrag(_ g: UILongPressGestureRecognizer) {
            guard parent.editingEnabled, let mv = g.view as? MKMapView else { return }
            let p = g.location(in: mv)
            switch g.state {
            case .began:
                guard let hit = nearestVertex(mv, at: p) else { editDrag = nil; return }
                let anchor = parent.strokes[hit.0][hit.1]
                let radius = 30.0
                var members: [(idx: Int, origin: CLLocationCoordinate2D, weight: Double)] = []
                for (idx, c) in parent.strokes[hit.0].enumerated() {
                    let d = CLLocation(latitude: c.latitude, longitude: c.longitude)
                        .distance(from: CLLocation(latitude: anchor.latitude, longitude: anchor.longitude))
                    if d <= radius {
                        members.append((idx, c, 1.0 - (d / radius) * 0.85))
                    }
                }
                editDrag = EditDrag(stroke: hit.0, anchor: anchor, members: members)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .changed:
                guard let drag = editDrag, parent.strokes.indices.contains(drag.stroke) else { return }
                let c = mv.convert(p, toCoordinateFrom: mv)
                let dLat = c.latitude - drag.anchor.latitude
                let dLon = c.longitude - drag.anchor.longitude
                for m in drag.members where parent.strokes[drag.stroke].indices.contains(m.idx) {
                    parent.strokes[drag.stroke][m.idx] = CLLocationCoordinate2D(
                        latitude: m.origin.latitude + dLat * m.weight,
                        longitude: m.origin.longitude + dLon * m.weight
                    )
                }
                syncOverlay(mv, strokes: parent.strokes, preview: parent.previewPoints)
            case .ended, .cancelled, .failed:
                editDrag = nil
            default:
                break
            }
        }

        @objc func handleEditTap(_ g: UITapGestureRecognizer) {
            guard parent.editingEnabled, let mv = g.view as? MKMapView else { return }
            guard let hit = nearestVertex(mv, at: g.location(in: mv)) else { return }
            guard parent.strokes.indices.contains(hit.0), parent.strokes[hit.0].indices.contains(hit.1) else { return }
            let anchor = parent.strokes[hit.0][hit.1]
            let radius = 25.0
            let kept = parent.strokes[hit.0].filter {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: anchor.latitude, longitude: anchor.longitude)) > radius
            }
            parent.strokes[hit.0] = kept
            if kept.isEmpty { parent.strokes.remove(at: hit.0) }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            syncOverlay(mv, strokes: parent.strokes, preview: parent.previewPoints)
        }

        func syncOverlay(_ mv: MKMapView, strokes: [[CLLocationCoordinate2D]], preview: [CLLocationCoordinate2D]?) {
            for o in mv.overlays where o is MKPolyline { mv.removeOverlay(o) }
            for s in strokes where s.count >= 2 {
                let poly = MKPolyline(coordinates: s, count: s.count)
                mv.addOverlay(poly, level: .aboveRoads)
            }
            if let pv = preview, pv.count >= 2 {
                let poly = MKPolyline(coordinates: pv, count: pv.count)
                mv.addOverlay(poly, level: .aboveRoads)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                let isPreview = parent.previewPoints != nil &&
                    abs(poly.pointCount - (parent.previewPoints?.count ?? 0)) <= 1 &&
                    mapView.overlays.last === poly
                r.strokeColor = isPreview ? .systemBlue : .systemGreen
                r.lineWidth = isPreview ? 4 : 5
                r.alpha = isPreview ? 0.95 : 0.9
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - DriftFix v2.9: 连续选点地图（长按放点、编号、可单个删除）
struct MultiPickMapView: UIViewRepresentable {
    @Binding var points: [CLLocationCoordinate2D]
    @Binding var moveToRegion: MKCoordinateRegion?

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.isPitchEnabled = false
        mv.isRotateEnabled = false
        mv.showsCompass = false
        mv.pointOfInterestFilter = .includingAll

        let lp = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        lp.minimumPressDuration = 0.28
        lp.allowableMovement = 24
        mv.addGestureRecognizer(lp)
        return mv
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        if let region = moveToRegion {
            uiView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.moveToRegion = nil }
        }
        context.coordinator.sync(uiView, points: points)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MultiPickMapView
        var lastSig: String = "-"
        init(_ parent: MultiPickMapView) { self.parent = parent }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard let mv = g.view as? MKMapView else { return }
            guard g.state == .began else { return }
            let p = g.location(in: mv)
            let c = mv.convert(p, toCoordinateFrom: mv)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            parent.points.append(c)
        }

        func sync(_ mv: MKMapView, points: [CLLocationCoordinate2D]) {
            let sig = points.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: "|")
            if sig == lastSig { return }
            lastSig = sig
            mv.removeAnnotations(mv.annotations.filter { $0 is NumberedPointAnnotation })
            for (i, c) in points.enumerated() {
                let a = NumberedPointAnnotation()
                a.coordinate = c
                a.index = i + 1
                mv.addAnnotation(a)
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let np = annotation as? NumberedPointAnnotation else { return nil }
            let id = "NumberedPoint"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: np, reuseIdentifier: id)
            view.annotation = np
            view.canShowCallout = false
            view.markerTintColor = .systemBlue
            view.glyphText = "\(np.index)"
            view.displayPriority = .required
            view.animatesWhenAdded = false
            return view
        }
    }
}

final class NumberedPointAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()
    var index: Int = 0
}

// MARK: - DriftFix v3.0: 区域框选地图（切「框选区域」后按住拖出一个矩形）
struct AreaSelectMapView: UIViewRepresentable {
    @Binding var rect: RouteSimulator.AreaRect?
    @Binding var moveToRegion: MKCoordinateRegion?
    var selecting: Bool
    var start: CLLocationCoordinate2D?
    var end: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.isPitchEnabled = false
        mv.isRotateEnabled = false
        mv.showsCompass = false
        mv.pointOfInterestFilter = .includingAll
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        mv.addGestureRecognizer(pan)
        return mv
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        // 框选模式只禁单指拖动（留给画框），双指缩放保留——框大区域前需要先缩小看一眼
        uiView.isScrollEnabled = !selecting
        if let region = moveToRegion {
            uiView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.moveToRegion = nil }
        }
        context.coordinator.sync(uiView, rect: rect, start: start, end: end)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: AreaSelectMapView
        private var anchor: CLLocationCoordinate2D? = nil
        private var draft: MKPolygon? = nil
        private var lastSig: String = "-"

        init(_ parent: AreaSelectMapView) { self.parent = parent }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard parent.selecting, let mv = g.view as? MKMapView else { return }
            let c = mv.convert(g.location(in: mv), toCoordinateFrom: mv)
            switch g.state {
            case .began:
                anchor = c
            case .changed:
                guard let a = anchor else { return }
                if let old = draft { mv.removeOverlay(old) }
                let poly = Self.polygon(RouteSimulator.AreaRect.from(a, c))
                draft = poly
                mv.addOverlay(poly)
            case .ended, .cancelled, .failed:
                guard let a = anchor else { return }
                anchor = nil
                let r = RouteSimulator.AreaRect.from(a, c)
                if r.widthMeters >= 150 && r.heightMeters >= 150 {
                    parent.rect = r
                }
            default:
                break
            }
        }

        static func polygon(_ r: RouteSimulator.AreaRect) -> MKPolygon {
            var coords: [CLLocationCoordinate2D] = [
                CLLocationCoordinate2D(latitude: r.south, longitude: r.west),
                CLLocationCoordinate2D(latitude: r.south, longitude: r.east),
                CLLocationCoordinate2D(latitude: r.north, longitude: r.east),
                CLLocationCoordinate2D(latitude: r.north, longitude: r.west)
            ]
            return MKPolygon(coordinates: &coords, count: 4)
        }

        func sync(_ mv: MKMapView, rect: RouteSimulator.AreaRect?, start: CLLocationCoordinate2D?, end: CLLocationCoordinate2D?) {
            let rectSig = rect.map { String(format: "%.6f,%.6f,%.6f,%.6f", $0.south, $0.west, $0.north, $0.east) } ?? "-"
            let startSig = start.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) } ?? "-"
            let endSig = end.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) } ?? "-"
            let sig = rectSig + "|" + startSig + "|" + endSig
            if sig == lastSig { return }
            lastSig = sig

            for o in mv.overlays where o is MKPolygon { mv.removeOverlay(o) }
            draft = nil
            if let r = rect, r.isValid {
                let poly = Self.polygon(r)
                draft = poly
                mv.addOverlay(poly)
            }
            mv.removeAnnotations(mv.annotations.filter { $0 is AreaPinAnnotation })
            if let s = start {
                mv.addAnnotation(AreaPinAnnotation(coordinate: s, title: "起", tint: .systemGreen))
            }
            if let e = end {
                mv.addAnnotation(AreaPinAnnotation(coordinate: e, title: "终", tint: .systemRed))
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: poly)
                r.fillColor = UIColor.systemPurple.withAlphaComponent(0.15)
                r.strokeColor = UIColor.systemPurple
                r.lineWidth = 2
                r.lineDashPattern = [NSNumber(value: 6), NSNumber(value: 4)]
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let a = annotation as? AreaPinAnnotation else { return nil }
            let id = "AreaPin"
            let v = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: a, reuseIdentifier: id)
            v.annotation = a
            v.canShowCallout = false
            v.markerTintColor = a.tint
            v.glyphText = a.title
            v.displayPriority = .required
            v.animatesWhenAdded = false
            return v
        }
    }
}

final class AreaPinAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var tint: UIColor
    init(coordinate: CLLocationCoordinate2D, title: String, tint: UIColor) {
        self.coordinate = coordinate
        self.title = title
        self.tint = tint
        super.init()
    }
}
