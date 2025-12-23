//
//  CircleMatrixViewModel.swift
//  DynamicMatrix
//
//  Created by 陈皆成 on 2025/12/21.
//

import SwiftUI
import Combine

class CircleMatrixViewModel: ObservableObject {
    @Published var circles: [CircleData] = []

    // Touch interaction (single finger)
    @Published var touchLocation: CGPoint? = nil

    struct AttractionSettings: Equatable {
        var isEnabled: Bool = true
        /// Influence radius in points.
        var radius: CGFloat = 220
        /// Max displacement (points) when finger is very close.
        var maxOffset: CGFloat = 14
        /// Controls how quickly attraction decays with distance. Higher = tighter around finger.
        var falloffPower: CGFloat = 1

        /// Spring for attraction smoothing (tweak for "very smooth").
        var springResponse: CGFloat = 0.22
        var springDampingFraction: CGFloat = 0.86
        var springBlendDuration: CGFloat = 0.0

        /// Optional UI/debug
        var showsTouchIndicator: Bool = false
    }

    @Published var attractionSettings: AttractionSettings = .init()

    // MARK: - Matrix shift (slider-driven, only in .matrix mode)
    /// Slider value in [-1, 1]. Positive shifts right; negative shifts left.
    @Published var matrixShiftValue: CGFloat = 0

    struct MatrixShiftSettings: Equatable {
        var isEnabled: Bool = true
        /// Max horizontal displacement at the strongest point (matrix center).
        var maxXOffset: CGFloat = 80
        /// Optional vertical displacement (default 0 for pure horizontal shifting).
        var maxYOffset: CGFloat = 0

        /// Falloff shaping from center to edges (>= 1 tighter to center; < 1 more spread).
        var falloffPower: CGFloat = 1.0

        /// Anisotropic influence: larger scale => stronger decay along that axis.
        /// Set horizontal > vertical to make the horizontal center band stronger (as requested).
        var horizontalFalloffScale: CGFloat = 0.8
        var verticalFalloffScale: CGFloat = 1.0

        /// Extra emphasis for circles near the horizontal center line.
        var horizontalCenterBoost: CGFloat = 0.7
        var horizontalCenterBoostPower: CGFloat = 2.2

        /// Spring for slider smoothing.
        var springResponse: CGFloat = 0.24
        var springDampingFraction: CGFloat = 0.88
        var springBlendDuration: CGFloat = 0.0
    }

    @Published var matrixShiftSettings: MatrixShiftSettings = .init()
    
    // Matrix configuration
    let rows: Int = 20
    let columns: Int = 12
    let gap: CGFloat = 32
    let circleSize: CGFloat = 3
    
    enum Mode: Equatable {
        case random
        case animatingToMatrix
        case matrix
    }
    
    /// Current behavior state (random movement vs organized matrix).
    @Published private(set) var mode: Mode = .random
    
    /// Back-compat convenience for the UI: true only while traveling to matrix.
    var isAnimatingToMatrix: Bool { mode == .animatingToMatrix }
    
    // Frame boundaries (extends beyond screen)
    var frameBounds: CGRect = .zero
    let framePadding: CGFloat = 200 // Extends 200 points beyond screen in all directions

    // Matrix geometry (used for center-weighted effects)
    private(set) var matrixCenter: CGPoint = .zero
    private(set) var matrixHalfSize: CGSize = .zero
    
    // Physics constants
    let minSpeed: CGFloat = 0.3
    let maxSpeed: CGFloat = 0.8
    let speedVariation: CGFloat = 0.5
    private let matrixAnimationDuration: TimeInterval = 0.8
    
    private var timer: Timer?
    private var modeCompletionWorkItem: DispatchWorkItem?
    
    init() {
        // Initialization will happen when frame bounds are set
    }

    // MARK: - Touch attraction
    func setTouchLocation(_ location: CGPoint?) {
        touchLocation = location
    }

    func attractionOffset(for basePosition: CGPoint) -> CGSize {
        guard attractionSettings.isEnabled, let touch = touchLocation else { return .zero }

        let dx = touch.x - basePosition.x
        let dy = touch.y - basePosition.y
        let distance = hypot(dx, dy)

        let radius = max(attractionSettings.radius, 0.0001)
        if distance >= radius { return .zero }

        // Normalized closeness in [0, 1]
        let t = max(0, min(1, 1 - (distance / radius)))

        // Smoothstep function, then adjustable power for artistic control
        let smooth = t * t * (3 - 2 * t) // s(t) = 3t^2 - 2t^3
        let weight = pow(smooth, attractionSettings.falloffPower) // w = s(t)^p
        /// s = 0.25
        /// p=1: w=0.25 (same as s)
        /// p=2: w=0.0625 (weaker)
        /// p=0.5: w=0.5 (stronger)

        let maxOffset = attractionSettings.maxOffset
        let magnitude = maxOffset * weight

        // Direction towards finger; when distance == 0, offset should be 0 (already at finger).
        if distance < 0.0001 { return .zero }
        let ux = dx / distance
        let uy = dy / distance
        return CGSize(width: ux * magnitude, height: uy * magnitude)
    }

    func matrixShiftOffset(for matrixPosition: CGPoint) -> CGSize {
        guard mode == .matrix, matrixShiftSettings.isEnabled else { return .zero }
        let shift = max(-1, min(1, matrixShiftValue))
        if abs(shift) < 0.0001 { return .zero }

        // Normalize distance to matrix center in [0, 1] (per axis)
        let halfW = max(matrixHalfSize.width, 0.0001)
        let halfH = max(matrixHalfSize.height, 0.0001)
        let dx = matrixPosition.x - matrixCenter.x
        let dy = matrixPosition.y - matrixCenter.y

        let nx = min(1, abs(dx) / halfW)
        let ny = min(1, abs(dy) / halfH)

        // Elliptical distance with separate horizontal/vertical falloff scaling.
        let d = hypot(nx * matrixShiftSettings.horizontalFalloffScale,
                      ny * matrixShiftSettings.verticalFalloffScale)
        let t = max(0, min(1, 1 - d))

        // IMPORTANT:
        // Use a falloff that remains smooth at the edges (t≈0) but DOES NOT flatten at the center (t≈1),
        // otherwise many near-center circles end up with nearly identical weights.
        var weight = pow(t, matrixShiftSettings.falloffPower)

        // Extra horizontal-center emphasis (stronger around nx ≈ 0) without clamping-induced plateaus.
        // xBoostFactor ∈ [0, 1] (assuming horizontalCenterBoost ∈ [0, 1]).
        let xCenterCloseness = max(0, 1 - nx)
        let xBoostFactor = max(0, min(1, matrixShiftSettings.horizontalCenterBoost))
            * pow(xCenterCloseness, matrixShiftSettings.horizontalCenterBoostPower)
        // Move weight towards 1 near the horizontal center line, but never exceed 1.
        weight = weight + (1 - weight) * xBoostFactor

        let x = matrixShiftSettings.maxXOffset * shift * weight
        let y = matrixShiftSettings.maxYOffset * shift * weight
        return CGSize(width: x, height: y)
    }
    
    func setupCircles(in bounds: CGRect) {
        // Reset mode/state on fresh setup (e.g. rotation)
        modeCompletionWorkItem?.cancel()
        mode = .random
        matrixShiftValue = 0

        // Set frame bounds with padding
        frameBounds = CGRect(
            x: bounds.minX - framePadding,
            y: bounds.minY - framePadding,
            width: bounds.width + framePadding * 2,
            height: bounds.height + framePadding * 2
        )
        
        // Calculate matrix center position
        let matrixWidth = CGFloat(columns - 1) * gap
        let matrixHeight = CGFloat(rows - 1) * gap
        matrixCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        matrixHalfSize = CGSize(width: matrixWidth / 2, height: matrixHeight / 2)
        let matrixStartX = bounds.midX - matrixWidth / 2
        let matrixStartY = bounds.midY - matrixHeight / 2
        
        // Create circles with default matrix positions
        circles = (0..<(rows * columns)).map { index in
            let row = index / columns
            let col = index % columns
            
            let targetX = matrixStartX + CGFloat(col) * gap
            let targetY = matrixStartY + CGFloat(row) * gap
            
            // Random starting position within frame bounds
            let startX = CGFloat.random(in: frameBounds.minX...frameBounds.maxX)
            let startY = CGFloat.random(in: frameBounds.minY...frameBounds.maxY)
            
            // Random velocity with speed variation
            let speed = CGFloat.random(in: minSpeed...maxSpeed)
            let angle = CGFloat.random(in: 0...(2 * .pi))
            let velocity = CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed)
            
            return CircleData(
                position: CGPoint(x: startX, y: startY),
                velocity: velocity,
                targetPosition: CGPoint(x: targetX, y: targetY),
                speed: speed
            )
        }
        
        startRandomMovement()
    }
    
    func startRandomMovement() {
        guard mode == .random else { return }
        
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.updateCirclePositions()
        }
    }
    
    private func updateCirclePositions() {
        guard mode == .random else { return }
        
        // Batch update all circles at once for better performance
        var updatedCircles = circles
        
        for index in updatedCircles.indices {
            var circle = updatedCircles[index]
            
            // Update position
            circle.position.x += circle.velocity.dx
            circle.position.y += circle.velocity.dy
            
            // Bounce off frame boundaries
            if circle.position.x <= frameBounds.minX || circle.position.x >= frameBounds.maxX {
                circle.velocity.dx *= -1
                circle.position.x = max(frameBounds.minX, min(frameBounds.maxX, circle.position.x))
            }
            
            if circle.position.y <= frameBounds.minY || circle.position.y >= frameBounds.maxY {
                circle.velocity.dy *= -1
                circle.position.y = max(frameBounds.minY, min(frameBounds.maxY, circle.position.y))
            }
            
            updatedCircles[index] = circle
        }
        
        // Single update to trigger view refresh
        // Disable implicit animation for timer-driven movement.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            circles = updatedCircles
        }
    }
    
    func animateToMatrix() {
        guard mode == .random else { return }
        
        modeCompletionWorkItem?.cancel()
        mode = .animatingToMatrix
        timer?.invalidate()
        matrixShiftValue = 0
        
        // Smooth animation to target positions
        withAnimation(.easeInOut(duration: matrixAnimationDuration)) {
            for index in circles.indices {
                circles[index].position = circles[index].targetPosition
                circles[index].velocity = .zero
            }
        }
        
        // Reset animation state after animation completes
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.mode == .animatingToMatrix {
                self.mode = .matrix
            }
        }
        modeCompletionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + matrixAnimationDuration, execute: work)
    }
    
    func resetToRandomMovement() {
        // Can be called even during animating-to-matrix to interrupt.
        modeCompletionWorkItem?.cancel()
        mode = .random
        
        // Ensure timer isn't left in a stopped state.
        timer?.invalidate()
        matrixShiftValue = 0
        
        // Give circles random velocities again
        var updatedCircles = circles
        for index in updatedCircles.indices {
            let speed = CGFloat.random(in: minSpeed...maxSpeed)
            let angle = CGFloat.random(in: 0...(2 * .pi))
            updatedCircles[index].velocity = CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed)
        }
        circles = updatedCircles
        
        startRandomMovement()
    }
    
    // Method to update circle positions programmatically (for future touch interactions)
    func updateCirclePosition(id: UUID, position: CGPoint, animated: Bool = true) {
        guard let index = circles.firstIndex(where: { $0.id == id }) else { return }
        
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                circles[index].position = position
            }
        } else {
            circles[index].position = position
        }
    }
    
    // Method to update multiple circles (for future multi-touch interactions)
    func updateCirclePositions(updates: [(id: UUID, position: CGPoint)], animated: Bool = true) {
        if animated {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                for update in updates {
                    if let index = circles.firstIndex(where: { $0.id == update.id }) {
                        circles[index].position = update.position
                    }
                }
            }
        } else {
            for update in updates {
                if let index = circles.firstIndex(where: { $0.id == update.id }) {
                    circles[index].position = update.position
                }
            }
        }
    }
    
    deinit {
        timer?.invalidate()
        modeCompletionWorkItem?.cancel()
    }
}

