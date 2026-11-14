//  Andromeda LocSim - Route Extension
//  Created by son3ra1n.

import SwiftUI
import MapKit
import UIKit
import AlertKit

struct RouteSimSheet: View {
    @ObservedObject var routeSimulator: RouteSimulator
    @Binding var mapRegion: MKCoordinateRegion?
    @Binding var isPresented: Bool
    
    @State private var startText: String = ""
    @State private var endText: String = ""
    @State private var selectedMode: TravelMode = .driving
    @State private var speedMinKmh: Double = 30.0
    @State private var speedMaxKmh: Double = 60.0
    @State private var skipProbPct: Double = 0
    @State private var swapEndsOn: Bool = false
    @State private var loopCount: Int = 1
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
    @State private var pickerTapped: EquatableCoordinate? = nil
    @State private var pickerPending: EquatableCoordinate? = nil
    @State private var pickerRegion: MKCoordinateRegion? = nil
    @State private var showDrawOverlay: Bool = false
    @State private var drawStrokes: [[CLLocationCoordinate2D]] = []
    @State private var optimizedPoints: [CLLocationCoordinate2D]? = nil
    @State private var drawPreviewOn: Bool = false
    @State private var drawBrushOn: Bool = false
    @State private var drawMoveToRegion: MKCoordinateRegion? = nil
    @State private var snapLongOn: Bool = true
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
                        } else {
                            addWaypointCard
                            waypointsSection
                            comboOptionsSection
                        }

                        // MARK: - Travel Mode
                        VStack(alignment: .leading, spacing: 8) {
                            Text("出行方式")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            HStack(spacing: 12) {
                                ForEach(TravelMode.allCases, id: \.self) { mode in
                                    Button(action: {
                                        selectedMode = mode
                                        applyModeSpeedDefaults(mode)
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
                        
                        // MARK: - DriftFix v2.2 速度区间（区间内随机游走，杜绝匀速）
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
                        }
                        
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
                                        Text(routeSimulator.isCalculatingRoute ? "算路中..." : "生成路线")
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(
                                        RoundedRectangle(cornerRadius: 14)
                                            .fill(routeSimulator.userWaypoints.count >= 2 ?
                                                  Color.indigo : Color.gray)
                                    )
                                    .foregroundColor(.white)
                                    .font(.headline)
                                }
                        .disabled(routeSimulator.userWaypoints.count < 2 || routeSimulator.isCalculatingRoute)
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

            HStack {
                Text("随机跳过")
                    .font(.caption)
                    .frame(width: 74)
                Slider(value: $skipProbPct, in: 0...100, step: 5)
                    .onChange(of: skipProbPct) { _ in routeReady = false }
                Text("\(Int(skipProbPct))%")
                    .font(.caption)
                    .frame(width: 36)
            }
            .padding(.horizontal)

            Toggle("起终点随机互换（往返）", isOn: $swapEndsOn)
                .font(.subheadline)
                .padding(.horizontal)
                .onChange(of: swapEndsOn) { _ in routeReady = false }

            Stepper(value: $loopCount, in: 1...20) {
                Text("绕圈次数 ×\(loopCount)")
                    .font(.subheadline)
            }
            .padding(.horizontal)
            .onChange(of: loopCount) { _ in routeReady = false }

            Toggle("长段自动贴合道路（自由路线生效）", isOn: $snapLongOn)
                .font(.subheadline)
                .padding(.horizontal)
                .onChange(of: snapLongOn) { _ in routeReady = false }

            Text("途经点行可单独切换 顺序/随机；每次 Calculate 重新随机组合。跳过只作用于「随机」点，固定点保持按序必到。")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
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
            Text("点「生成路线」进入手画地图：先用「移动地图」定位到区域，切「画笔绘制」按住拖动画线（可分多笔，单指画线/双指缩放，撤销/清空随意）。画完点「AI 优化」预览平滑线路，满意点「完成·采用」。")
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
                        routeReady = false
                    }) {
                        VStack(spacing: 4) {
                            Image(systemName: m == .road ? "road.lanes" : (m == .draw ? "hand.draw" : "point.topleft.down.to.point.bottomright.curvepath"))
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
            Text(routeSimulator.routeMode == .free
                 ? "自由路线：按你选的点依序直线连接，完全不吸附路网——内部道路/园区/步行道随便走。"
                 : (routeSimulator.routeMode == .draw
                    ? "手画路线：在地图上按住拖动画出线路，系统自动平滑优化成自然步态轨迹。"
                    : "道路导航：走真实路网；某段没有导航路线会直接报错，请改用自由路线（不再偷偷吸附替换）。"))
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal)
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
            Button(action: { showMapPicker = true }) {
                HStack {
                    Image(systemName: "map.fill")
                    Text("在地图上选点添加")
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

    // MARK: - DriftFix v2.1 地图选点弹层（在路线页内完成，不切出去）
    private var mapPickerOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button("取消") {
                    showMapPicker = false
                    pickerPending = nil
                }
                .foregroundColor(.red)
                Spacer()
                Text("点地图选途径点")
                    .font(.headline)
                Spacer()
                Button(action: confirmPick) {
                    Text("确认添加")
                        .fontWeight(.semibold)
                }
                .disabled(pickerPending == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            CustomMapView(
                tappedCoordinate: $pickerTapped,
                moveToRegion: $pickerRegion,
                movingPosition: pickerPending?.coordinate
            )
            .frame(maxHeight: .infinity)
            .cornerRadius(12)
            .padding(.horizontal, 12)
            .onChange(of: pickerTapped) { v in
                // DriftFix v2.5: 选点地图点击 → 待确认坐标（修复「点击没任何反应」）
                if let v = v { pickerPending = v }
            }

            HStack(spacing: 6) {
                if let p = pickerPending {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.green)
                    Text(String(format: "%.5f, %.5f", p.coordinate.latitude, p.coordinate.longitude))
                        .font(.caption)
                        .foregroundColor(.primary)
                } else {
                    Text("在上方地图任意位置点一下")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 10)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(10)
    }

    private func confirmPick() {
        guard let picked = pickerPending else { return }
        routeSimulator.addPickedWaypoint(picked.coordinate)
        pickerPending = nil
        showMapPicker = false
        routeReady = false
        AlertKitAPI.present(title: "📍 途径点已添加", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }

    // MARK: - DriftFix v2.4 手画路线弹层（单指绘制，双指缩放）
    // MARK: - DriftFix v2.4 手画路线弹层（画笔/移动双模式 + 撤销/清除 + AI 优化预览 + 完成采用）
    private var drawOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭") {
                    // 保留已画笔画，重开可继续画/改
                    showDrawOverlay = false
                }
                .foregroundColor(.red)
                Spacer()
                Text("手画路线")
                    .font(.headline)
                Spacer()
                Button("清空") {
                    drawStrokes = []
                    optimizedPoints = nil
                    routeReady = false
                }
                .foregroundColor(.orange)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            Picker("", selection: $drawBrushOn) {
                Text("移动地图").tag(false)
                Text("画笔绘制").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ZStack {
                DrawMapView(
                    strokes: $drawStrokes,
                    moveToRegion: $mapRegion,
                    drawingEnabled: drawBrushOn,
                    previewPoints: drawPreviewOn ? optimizedPoints : nil
                )
                if drawStrokes.isEmpty {
                    Text(drawBrushOn
                         ? "在此区域按住并拖动，画出你的跑步线路\n（单指画线、双指缩放；可分多笔画，内部道路随意）"
                         : "先移动/缩放地图到你要画的区域\n再切到「画笔绘制」开始画")
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

    private func undoLastStroke() {
        guard !drawStrokes.isEmpty else { return }
        drawStrokes.removeLast()
        if drawStrokes.isEmpty { optimizedPoints = nil }
        routeReady = false
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
        let src = (drawPreviewOn && (optimizedPoints?.count ?? 0) >= 2) ? optimizedPoints! : allDrawPoints
        let minMps = speedMinKmh / 3.6
        let maxMps = speedMaxKmh / 3.6
        if routeSimulator.buildFromDrawnPath(points: src, minSpeed: minMps, maxSpeed: maxMps) {
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
        // DriftFix v2.4: 手画模式 → 打开手画地图（保留已有笔画，可继续画/改）
        if routeSimulator.routeMode == .draw {
            showDrawOverlay = true
            return
        }
        guard routeSimulator.userWaypoints.count >= 2 else { return }
        let minMps = speedMinKmh / 3.6
        let maxMps = speedMaxKmh / 3.6
        // DriftFix v2.3: 多自由度组合——每点 顺序/随机 + 跳过 + 往返 + 绕圈，每次重新生成
        let seq = routeSimulator.generateVisitSequence(skipProbability: skipProbPct / 100, swapEnds: swapEndsOn, loops: loopCount)
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
            if routeSimulator.saveCurrentRoute(named: name) {
                savedRoutes = RouteSimulator.savedRouteInfos(sort: savedSort)
                AlertKitAPI.present(title: "已保存", icon: .done, style: .iOS17AppleMusic, haptic: .success)
            } else {
                UIApplication.shared.alert(body: "没有可保存的内容（尚未载入路线）。")
            }
        }
    }

    private func loadSavedRoute(_ info: RouteSimulator.SavedRouteInfo) {
        if routeSimulator.loadSavedRoute(at: info.url) {
            routeReady = true
            if let poly = routeSimulator.routePolyline {
                let rect = poly.boundingMapRect
                mapRegion = MKCoordinateRegion(rect.insetBy(dx: -rect.size.width * 0.2, dy: -rect.size.height * 0.2))
            }
            AlertKitAPI.present(title: "已载入", icon: .done, style: .iOS17AppleMusic, haptic: .success)
        } else {
            UIApplication.shared.alert(body: "线路文件载入失败。")
        }
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

// MARK: - DriftFix v2.4: 手画地图（画笔/移动双模式：单指绘制轨迹，移动时滚动/缩放定位）
struct DrawMapView: UIViewRepresentable {
    @Binding var strokes: [[CLLocationCoordinate2D]]
    @Binding var moveToRegion: MKCoordinateRegion?
    var drawingEnabled: Bool = true
    var previewPoints: [CLLocationCoordinate2D]? = nil

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        // 移动/绘制由 drawingEnabled 动态切换（updateUIView 统一设置）
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.minimumNumberOfTouches = 1
        mv.addGestureRecognizer(pan)
        return mv
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {
        uiView.isScrollEnabled = !drawingEnabled   // 画笔=地图固定单指画线；移动=恢复滚动定位
        uiView.isPitchEnabled = false
        uiView.isRotateEnabled = false
        if let region = moveToRegion {
            uiView.setRegion(region, animated: true)
            DispatchQueue.main.async { self.moveToRegion = nil }
        }
        let sig = "\(strokes.count)|\(strokes.last?.count ?? -1)|\(previewPoints?.count ?? -1)|\(drawingEnabled)"
        if context.coordinator.lastSig != sig {
            context.coordinator.lastSig = sig
            context.coordinator.syncOverlay(uiView, strokes: strokes, preview: previewPoints)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: DrawMapView
        var lastSig: String = "-"
        init(_ parent: DrawMapView) { self.parent = parent }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let mv = g.view as? MKMapView else { return }
            if !parent.drawingEnabled { return }   // 移动模式：交给地图自身手势
            switch g.state {
            case .began:
                parent.strokes.append([])
            case .changed:
                guard !(parent.strokes.last?.isEmpty ?? true) || parent.strokes.isEmpty else { break }
                let p = g.location(in: mv)
                let c = mv.convert(p, toCoordinateFrom: mv)
                if parent.strokes.isEmpty { parent.strokes.append([]) }
                if let last = parent.strokes.last, let lastC = last.last {
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
