//  Andromeda LocSim
//  Created by son3ra1n.
//  Enhanced version of Geranium.
//  Developed by son3ra1n.
//

import SwiftUI
import CoreLocation
import MapKit
import AlertKit

struct LocSimView: View {
    @StateObject private var appSettings = AppSettings()
    @StateObject private var routeSimulator = RouteSimulator()
    
    @State private var locationManager = CLLocationManager()
    @State private var lat: Double = 0.0
    @State private var long: Double = 0.0
    @State private var altitude: String = "0.0"
    @State private var tappedCoordinate: EquatableCoordinate? = nil
    @State private var bookmarkSheetToggle: Bool = false
    @State private var showRouteSheet: Bool = false
    @State private var showSearchBar: Bool = false
    @State private var searchText: String = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var isSearching: Bool = false
    @State private var mapRegion: MKCoordinateRegion? = nil
    
    // Joystick
    @State private var joystickActive: Bool = false
    @State private var joystickCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784)
    
    // Favorites
    @State private var showFavorites: Bool = false
    
    // App Profiles
    @State private var showAppProfiles: Bool = false

    // DriftFix: 手动坐标输入
    @State private var showManualCoord: Bool = false
    
    // Timer
    @State private var showTimerPicker: Bool = false
    @State private var timerRemaining: Int = 0
    @State private var timerActive: Bool = false
    @State private var simTimer: Timer? = nil
    var body: some View {
        LocSimMainView()
    }
    @ViewBuilder
        private func LocSimMainView() -> some View {
            ZStack(alignment: .topTrailing) {
                // MARK: - Main Map
                CustomMapView(tappedCoordinate: $tappedCoordinate, moveToRegion: $mapRegion, routePolyline: routeSimulator.routePolyline, allRoutePolylines: routeSimulator.allRoutePolylines, selectedRouteIndex: routeSimulator.selectedRouteIndex, movingPosition: routeSimulator.currentPosition)
                    .onAppear {
                        CLLocationManager().requestAlwaysAuthorization()
                    }
                    .onChange(of: tappedCoordinate) { newCoord in
                        guard let coord = newCoord else { return }
                        let altitudeValue = Double(altitude) ?? 0.0
                        startSimulation(at: coord.coordinate, altitude: altitudeValue)
                    }
                    .ignoresSafeArea(.all, edges: [.top, .leading, .trailing])
                
                // MARK: - Address Search Overlay (Top)
                if showSearchBar {
                    VStack(spacing: 0) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.gray)
                            TextField("Search address...", text: $searchText, onCommit: {
                                searchAddress()
                            })
                            .textFieldStyle(PlainTextFieldStyle())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            
                            if isSearching {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                            
                            if !searchText.isEmpty {
                                Button(action: {
                                    searchText = ""
                                    searchResults = []
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.gray)
                                }
                            }
                            
                            Button(action: {
                                withAnimation {
                                    showSearchBar = false
                                    searchText = ""
                                    searchResults = []
                                }
                            }) {
                                Text("Cancel")
                                    .font(.subheadline)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(UIColor.systemBackground))
                                .shadow(color: Color.black.opacity(0.2), radius: 8, x: 0, y: 4)
                        )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        
                        // Search Results List
                        if !searchResults.isEmpty {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(searchResults, id: \.self) { item in
                                        Button(action: {
                                            selectSearchResult(item)
                                        }) {
                                            HStack {
                                                Image(systemName: "mappin.circle.fill")
                                                    .foregroundColor(.red)
                                                    .font(.title3)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(item.name ?? "Unknown")
                                                        .font(.subheadline)
                                                        .fontWeight(.medium)
                                                        .foregroundColor(.primary)
                                                    if let address = item.placemark.title {
                                                        Text(address)
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                }
                                                Spacer()
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                        }
                                        Divider()
                                            .padding(.leading, 44)
                                    }
                                }
                            }
                            .frame(maxHeight: 250)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color(UIColor.systemBackground))
                                    .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
                            )
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                        }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
                }

            
            // MARK: - Floating Quick Menu (Long Press + Drag)
            FloatingQuickMenu(
                onAction: { action in
                    handleQuickMenuAction(action)
                },
                joystickActive: joystickActive,
                timerActive: timerActive
            )
            .padding(.trailing, 16)
            .padding(.top, 60)
            
            // MARK: - Joystick Overlay
            if joystickActive {
                JoystickView(
                    isActive: $joystickActive,
                    onMove: { newCoord in
                        joystickCoordinate = newCoord
                        let location = CLLocation(coordinate: newCoord, altitude: Double(altitude) ?? 0, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
                        LocSimManager.startLocSim(location: location)
                        lat = newCoord.latitude
                        long = newCoord.longitude
                    },
                    currentCoordinate: $joystickCoordinate
                )
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            
            // MARK: - Timer Countdown
            if timerActive {
                VStack {
                    Spacer()
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "timer")
                                .foregroundColor(.orange)
                            Text(timerString())
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                            Button(action: { cancelTimer() }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.red.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(20)
                        .shadow(color: .black.opacity(0.15), radius: 8)
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .sheet(isPresented: $bookmarkSheetToggle) {
            BookMarkSlider(lat: $lat, long: $long)
        }
        .sheet(isPresented: $showRouteSheet) {
            RouteSimSheet(routeSimulator: routeSimulator, mapRegion: $mapRegion, isPresented: $showRouteSheet)
        }
        .sheet(isPresented: $showFavorites) {
            FavoritesView(isPresented: $showFavorites, currentLat: lat, currentLong: long) { favLat, favLong, name in
                let coord = CLLocationCoordinate2D(latitude: favLat, longitude: favLong)
                let region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                mapRegion = region
                startSimulationFromWGS(at: coord, altitude: Double(altitude) ?? 0.0)
                AlertKitAPI.present(title: "📍 \(name)", icon: .done, style: .iOS17AppleMusic, haptic: .success)
            }
        }
        .actionSheet(isPresented: $showTimerPicker) {
            ActionSheet(title: Text("Auto-Stop Timer"), message: Text("LocSim will stop automatically after:"), buttons: [
                .default(Text("15 minutes")) { startTimer(minutes: 15) },
                .default(Text("30 minutes")) { startTimer(minutes: 30) },
                .default(Text("1 hour")) { startTimer(minutes: 60) },
                .default(Text("2 hours")) { startTimer(minutes: 120) },
                .cancel()
            ])
        }
        .sheet(isPresented: $showAppProfiles) {
            AppProfilesView(isPresented: $showAppProfiles, currentLat: lat, currentLong: long) { profLat, profLong, name in
                let coord = CLLocationCoordinate2D(latitude: profLat, longitude: profLong)
                let region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01))
                mapRegion = region
                startSimulationFromWGS(at: coord, altitude: Double(altitude) ?? 0.0)
                AlertKitAPI.present(title: name, icon: .done, style: .iOS17AppleMusic, haptic: .success)
            }
        }
        .sheet(isPresented: $showManualCoord) {
            ManualCoordinateSheet(lat: $lat, long: $long, altitude: Double(altitude) ?? 0.0)
        }
    }
    
    private func startSimulation(at gcjCoordinate: CLLocationCoordinate2D, altitude: Double) {
        let wgsCoordinate = CoordTransform.gcj02ToWgs84(gcjCoordinate)

        self.lat = wgsCoordinate.latitude
        self.long = wgsCoordinate.longitude

        let location = CLLocation(coordinate: wgsCoordinate, altitude: altitude,horizontalAccuracy:5,verticalAccuracy: 5,timestamp: Date())
        LocSimManager.startLocSim(location: location)

        joystickCoordinate = wgsCoordinate

        AlertKitAPI.present(
            title: "Started!",
            icon: .done,
            style: .iOS17AppleMusic,
            haptic: .success
        )
    }

    /// DriftFix: 收藏/书签/App预设 存储的都是 WGS-84 真实坐标（startSimulation 写入的 lat/long），
    /// 点击这些入口直接注入，绝不能再当 GCJ 二次转换（曾导致每次固定偏移 ~500m）。
    private func startSimulationFromWGS(at wgsCoordinate: CLLocationCoordinate2D, altitude: Double) {
        self.lat = wgsCoordinate.latitude
        self.long = wgsCoordinate.longitude

        let location = CLLocation(coordinate: wgsCoordinate, altitude: altitude, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        LocSimManager.startLocSim(location: location)

        joystickCoordinate = wgsCoordinate

        AlertKitAPI.present(
            title: "Started!",
            icon: .done,
            style: .iOS17AppleMusic,
            haptic: .success
        )
    }
    
    // MARK: - Address Search
    private func searchAddress() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true
        searchResults = []
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                isSearching = false
                if let response = response {
                    searchResults = response.mapItems
                } else {
                    UIApplication.shared.alert(body: "No results found for '\(searchText)'")
                }
            }
        }
    }
    
    private func selectSearchResult(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        let altitudeValue = Double(altitude) ?? 0.0
        
        // Move the map to the selected location
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        mapRegion = region
        
        // Start simulation at the selected location
        startSimulation(at: coordinate, altitude: altitudeValue)
        
        // Close search UI
        showSearchBar = false
        searchText = ""
        searchResults = []
    }
    
    // MARK: - Timer
    private func startTimer(minutes: Int) {
        timerRemaining = minutes * 60
        timerActive = true
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            if timerRemaining > 0 {
                timerRemaining -= 1
            } else {
                stopSimulation()
                cancelTimer()
            }
        }
        AlertKitAPI.present(title: "Timer: \(minutes)m", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }
    
    private func cancelTimer() {
        simTimer?.invalidate()
        simTimer = nil
        timerActive = false
        timerRemaining = 0
    }
    
    private func timerString() -> String {
        let h = timerRemaining / 3600
        let m = (timerRemaining % 3600) / 60
        let s = timerRemaining % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
    
    // MARK: - Quick Menu Handler
    private func handleQuickMenuAction(_ action: QuickMenuAction) {
        switch action {
        case .search:
            showSearchBar.toggle()
        case .manualCoord:
            showManualCoord = true
        case .favorites:
            showFavorites.toggle()
        case .appProfiles:
            showAppProfiles.toggle()
        case .joystick:
            withAnimation(.spring(response: 0.3)) {
                joystickActive.toggle()
                if joystickActive {
                    joystickCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: long)
                }
            }
        case .route:
            showRouteSheet.toggle()
        case .altitude:
            UIApplication.shared.TextFieldAlert(
                title: "Set Altitude",
                message: "Enter the altitude in meters.",
                textFieldPlaceHolder: "Altitude (m)"
            ) { altitudeText, _ in
                if let altText = altitudeText, !altText.isEmpty {
                    self.altitude = altText
                    AlertKitAPI.present(title: "Altitude Set!", icon: .done, style: .iOS17AppleMusic, haptic: .success)
                }
            }
        case .timer:
            showTimerPicker = true
        case .stop:
            stopSimulation()
        }
    }
    
    private func stopSimulation() {
        LocSimManager.stopLocSim()
        joystickActive = false
        cancelTimer()
        AlertKitAPI.present(title: "Stopped!", icon: .done, style: .iOS17AppleMusic, haptic: .success)
    }
    
    // MARK: - Modern UI Helpers
    private func controlIcon(systemName: String, color: Color = .indigo) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 44, height: 44)
            .background(color.opacity(0.9))
            .background(.ultraThinMaterial)
            .clipShape(Circle())
            .shadow(color: color.opacity(0.3), radius: 8, x: 0, y: 4)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
    }
}

// MARK: - DriftFix: 手动坐标输入（对齐 Geranium 任意坐标能力，Andromeda 原本只有搜索）
struct ManualCoordinateSheet: View {
    @Environment(\.dismiss) var dismiss
    @Binding var lat: Double
    @Binding var long: Double
    var altitude: Double
    @State private var latText: String = ""
    @State private var longText: String = ""
    @State private var datum: Datum = .gcj

    enum Datum: String, CaseIterable, Identifiable {
        case gcj = "地图/搜索 (GCJ-02)"
        case wgs = "真实GPS/GPX (WGS-84)"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Coordinate")) {
                    TextField("Latitude  例: 22.543210", text: $latText)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Longitude  例: 114.123456", text: $longText)
                        .keyboardType(.numbersAndPunctuation)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(header: Text("Datum 坐标系"),
                        footer: Text("从中国地图/搜索结果抄的选 GCJ-02；从 GPX/真实 GPS 抄的选 WGS-84。选错会固定偏几百米。")) {
                    Picker("Datum", selection: $datum) {
                        ForEach(Datum.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Button(action: start) {
                        Text("Simulate 模拟此坐标")
                            .frame(maxWidth: .infinity)
                            .font(.headline)
                    }
                    .disabled(!inputValid)
                }
            }
            .navigationTitle("Manual Coordinate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private var inputValid: Bool {
        guard let la = Double(latText), let lo = Double(longText) else { return false }
        return abs(la) <= 90 && abs(lo) <= 180
    }

    private func start() {
        guard let la = Double(latText), let lo = Double(longText) else { return }
        var wgs = CLLocationCoordinate2D(latitude: la, longitude: lo)
        if datum == .gcj {
            wgs = CoordTransform.gcj02ToWgs84(wgs)
        }
        lat = wgs.latitude
        long = wgs.longitude
        let location = CLLocation(coordinate: wgs, altitude: altitude, horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: Date())
        LocSimManager.startLocSim(location: location)
        AlertKitAPI.present(title: "Started!", icon: .done, style: .iOS17AppleMusic, haptic: .success)
        dismiss()
    }
}

#Preview {
    LocSimView()
}
