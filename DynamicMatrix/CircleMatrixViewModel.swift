//
//  CircleMatrixViewModel.swift
//  DynamicMatrix
//
//  Created by 陈皆成 on 2025/12/21.
//

import SwiftUI
import Combine

class CircleMatrixViewModel: ObservableObject {
    // Published State (UI-facing)
    @Published var circles: [CircleData] = []

    /// Current touch location in the same coordinate space as the circles.
    /// - `nil` means no active touch (finger lifted).
    @Published var touchLocation: CGPoint? = nil

    // MARK: - Attraction Settings
    struct AttractionSettings: Equatable {
        var isEnabled: Bool = true
        /// Influence radius in points.
        var radius: CGFloat = 220
        /// Max displacement (points) when finger is very close.
        var maxOffset: CGFloat = 14
        /// Controls how quickly attraction decays with distance. Higher = tighter around finger.
        var falloffPower: CGFloat = 1
        /// Shapes the attraction *strength* response curve (applied after distance falloff).
        /// > 1 makes attraction ramp up more near the finger; < 1 makes it feel stronger overall.
        var strengthCurvePower: CGFloat = 1

        // Opacity animation (separate radius from attraction)
        /// Opacity influence radius in points (independent from `radius`).
        var opacityRadius: CGFloat = 160
        var baseOpacity: Double = 0.5
        var maxOpacity: Double = 1.0
        /// Controls how quickly opacity transitions from center to edge.
        var opacityFalloffPower: CGFloat = 0.8

        /// Spring for attraction smoothing (tweak for "very smooth").
        var springResponse: CGFloat = 0.22
        var springDampingFraction: CGFloat = 0.86
        var springBlendDuration: CGFloat = 0.0

        /// Optional UI/debug
        var showsTouchIndicator: Bool = false
    }

    @Published var attractionSettings: AttractionSettings = .init()

    // MARK: - Matrix Shift 
    /// slider-driven, only in `.matrix` mode
    /// Slider value in [-1, 1]. Positive shifts right; negative shifts left.
    @Published var matrixShiftValueX: CGFloat = 0
    /// Slider value in [-1, 1]. Positive shifts down; negative shifts up.
    @Published var matrixShiftValueY: CGFloat = 0

    struct MatrixShiftSettings: Equatable {
        var isEnabled: Bool = true
        /// Max horizontal displacement at the strongest point (matrix center).
        var maxXOffset: CGFloat = 120
        /// Optional vertical displacement (default 0 for pure horizontal shifting).
        var maxYOffset: CGFloat = 100

        /// Falloff "sharpness" from center to edges. Higher = tighter to center.
        /// (Used as a Gaussian sharpness factor; avoids hard cutoffs / banding.)
        var falloffPower: CGFloat = 1.8

        /// Shapes the slider input response curve.
        /// > 1 makes changes near 0 smaller, and changes near ±1 more significant.
        var inputCurvePower: CGFloat = 5

        // Opacity animation for matrix shift
        /// Enable/disable matrix-shift-driven opacity boost.
        var isOpacityEnabled: Bool = true
        /// Opacity influence radius in normalized matrix space (0...~1+). Smaller = tighter to center.
        /// This is independent from movement falloff to allow separate tuning.
        var opacityFalloffPower: CGFloat = 1.4
        /// Shapes how strongly opacity responds to slider magnitude (|x|/|y| near ±1).
        var opacityInputPower: CGFloat = 1.2

        // Color highlight overlay (reuses the same "effect weight" as opacity by default)
        var isHighlightEnabled: Bool = true
        /// Max overlay opacity for the highlight color.
        var highlightMaxOpacity: Double = 1.0
        /// Additional shaping on top of the computed effect weight.
        var highlightOpacityPower: CGFloat = 1.0

        /// Anisotropic influence: larger scale => stronger decay along that axis.
        /// Set horizontal > vertical to make the horizontal center band stronger (as requested).
        var horizontalFalloffScale: CGFloat = 1.0
        var verticalFalloffScale: CGFloat = 1.0

        /// Extra emphasis for circles near the horizontal center line.
        var horizontalCenterBoost: CGFloat = 0.8
        var horizontalCenterBoostPower: CGFloat = 3.8

        /// Spring for slider smoothing.
        var springResponse: CGFloat = 0.24
        var springDampingFraction: CGFloat = 0.88
        var springBlendDuration: CGFloat = 0.0
    }

    @Published var matrixShiftSettings: MatrixShiftSettings = .init()
    

    // MARK: - Matrix Configuration
    // Matrix configuration
    let rows: Int = 20
    let columns: Int = 12
    let gap: CGFloat = 32
    let circleSize: CGFloat = 3
    
    //  Mode / State Machine
    enum Mode: Equatable {
        case random
        case animatingToMatrix
        case matrix
    }
    
    /// Current behavior state (random movement vs organized matrix).
    @Published private(set) var mode: Mode = .random
    
    /// Back-compat convenience for the UI: true only while traveling to matrix.
    var isAnimatingToMatrix: Bool { mode == .animatingToMatrix }
    
    /// Extended bounds for random motion (includes padding beyond the visible screen).
    var frameBounds: CGRect = .zero
    let framePadding: CGFloat = 200 // Extends 200 points beyond screen in all directions

    // Matrix geometry (used for center-weighted effects)
    private(set) var matrixCenter: CGPoint = .zero
    /// Half extents of the matrix (width/2, height/2), used to normalize distances.
    private(set) var matrixHalfSize: CGSize = .zero
    
    // Physics constants Random Motion Tuning
    let minSpeed: CGFloat = 0.3
    let maxSpeed: CGFloat = 0.8
    let speedVariation: CGFloat = 0.5
    private let matrixAnimationDuration: TimeInterval = 0.8
    
    // Internal Timers / Scheduling
    private var timer: Timer?
    private var modeCompletionWorkItem: DispatchWorkItem?
    
    init() {
        // Initialization will happen when frame bounds are set
    }

    // MARK: - Public API: Touch
    func setTouchLocation(_ location: CGPoint?) {
        touchLocation = location
    }

    // Private Helpers: Curves / Shaping
    /// Clamp to [0, 1] for stable curve math.
    private func clamp01(_ x: CGFloat) -> CGFloat { max(0, min(1, x)) }

    /// Shapes a unit value [0, 1] via a power curve.
    private func curvedUnit(_ x: CGFloat, power: CGFloat) -> CGFloat {
        let p = max(0.0001, power)
        return pow(clamp01(x), p)
    }

    /// Shapes a signed unit value [-1, 1] via a power curve, preserving sign.
    /// Used for slider response shaping (more impact near ±1).
    private func curvedSigned(_ x: CGFloat, power: CGFloat) -> CGFloat {
        let p = max(0.0001, power)
        let a = pow(min(1, abs(x)), p)
        return x.sign == .minus ? -a : a
    }

    // MARK: - Touch Attraction
    /// Computes an additional render-time offset that attracts a circle toward the finger.
    /// Note: This does NOT mutate circle physics; it's applied as `.offset(...)` in the view.
    func attractionOffset(for basePosition: CGPoint) -> CGSize {
        guard attractionSettings.isEnabled, let touch = touchLocation else { return .zero }

        let dx = touch.x - basePosition.x
        let dy = touch.y - basePosition.y
        let distance = hypot(dx, dy)

        let radius = max(attractionSettings.radius, 0.0001)
        if distance >= radius { return .zero }

        // t = Normalized closeness in [0, 1]
        let t = max(0, min(1, 1 - (distance / radius)))

        // Smoothstep function, then adjustable power for artistic control
        let smooth = t * t * (3 - 2 * t) // s(t) = 3t^2 - 2t^3
        let falloffWeight = pow(smooth, attractionSettings.falloffPower) // w = s(t)^p
        /// s = 0.25
        /// p=1: w=0.25 (same as s)
        /// p=2: w=0.0625 (weaker)
        /// p=0.5: w=0.5 (stronger)

        let maxOffset = attractionSettings.maxOffset
        let magnitude = maxOffset * curvedUnit(falloffWeight, power: attractionSettings.strengthCurvePower)

        // Direction towards finger; when distance == 0, offset should be 0 (already at finger).
        if distance < 0.0001 { return .zero }
        let ux = dx / distance
        let uy = dy / distance
        return CGSize(width: ux * magnitude, height: uy * magnitude)
    }

    /// Computes a render-time opacity for a circle based on touch proximity.
    /// - Behavior: closer to the touch center -> opacity approaches `maxOpacity`;
    ///             farther away -> approaches `baseOpacity`.
    /// - Note: Uses `opacityRadius` (separate from attraction radius).
    func attractionOpacity(for basePosition: CGPoint) -> Double {
        guard attractionSettings.isEnabled, let touch = touchLocation else {
            return attractionSettings.baseOpacity
        }

        let dx = touch.x - basePosition.x
        let dy = touch.y - basePosition.y
        let distance = hypot(dx, dy)

        let radius = max(attractionSettings.opacityRadius, 0.0001)
        if distance >= radius { return attractionSettings.baseOpacity }

        let t = max(0, min(1, 1 - (distance / radius)))
        let smooth = t * t * (3 - 2 * t)
        let w = pow(smooth, attractionSettings.opacityFalloffPower)

        let base = attractionSettings.baseOpacity
        let maxO = attractionSettings.maxOpacity
        return base + (maxO - base) * Double(w)
    }

    // MARK: - Matrix Shift
    /// Computes an additional render-time offset driven by the slider.
    /// Influence is strongest near the matrix center and smoothly decays toward the edges.
    func matrixShiftOffset(for matrixPosition: CGPoint) -> CGSize {
        guard mode == .matrix, matrixShiftSettings.isEnabled else { return .zero }
        let shiftX = curvedSigned(matrixShiftValueX, power: matrixShiftSettings.inputCurvePower)
        let shiftY = curvedSigned(matrixShiftValueY, power: matrixShiftSettings.inputCurvePower)
        if abs(shiftX) < 0.0001, abs(shiftY) < 0.0001 { return .zero }

        // Normalize distance to matrix center in [0, 1] (per axis)
        let halfW = max(matrixHalfSize.width, 0.0001)
        let halfH = max(matrixHalfSize.height, 0.0001)
        let dx = matrixPosition.x - matrixCenter.x
        let dy = matrixPosition.y - matrixCenter.y

        let nx = min(1, abs(dx) / halfW)
        let ny = min(1, abs(dy) / halfH)

        // Elliptical distance with separate horizontal/vertical falloff scaling.
        // We intentionally avoid a hard cutoff (e.g. max(0, 1 - d)) because with a discrete grid
        // and aggressive parameters it can look like a sharp "on/off" band.
        var nxScaled = nx * matrixShiftSettings.horizontalFalloffScale
        let nyScaled = ny * matrixShiftSettings.verticalFalloffScale

        // Extra horizontal-center emphasis: reduce effective horizontal distance near nx≈0.
        // This strengthens the horizontal center without saturating many points to exactly the same weight.
        let xCenterCloseness = max(0, 1 - nx)
        let boost = max(0, min(1, matrixShiftSettings.horizontalCenterBoost))
        let xBoostFactor = 1 + boost * pow(xCenterCloseness, matrixShiftSettings.horizontalCenterBoostPower)
        nxScaled /= xBoostFactor

        let d = hypot(nxScaled, nyScaled)

        // Gaussian falloff: weight = exp(-k * d^2)
        // - Smooth everywhere (no edge discontinuity)
        // - Keeps a gradient near center (no plateau)
        let k = max(0.0001, matrixShiftSettings.falloffPower)
        let weight = exp(-k * d * d)

        let x = matrixShiftSettings.maxXOffset * shiftX * weight
        let y = matrixShiftSettings.maxYOffset * shiftY * weight
        return CGSize(width: x, height: y)
    }

    /// Computes a render-time opacity for a circle based on matrix shift sliders and proximity to matrix center.
    /// - Behavior: when |x| or |y| approaches 1, circles near the center fade towards maxOpacity.
    /// - Smooth falloff: uses the same distance field as matrix shift, but with separately tunable sharpness.
    func matrixShiftOpacity(for matrixPosition: CGPoint) -> Double {
        guard mode == .matrix, matrixShiftSettings.isEnabled, matrixShiftSettings.isOpacityEnabled else {
            return attractionSettings.baseOpacity
        }

        let w = matrixShiftEffectWeight(for: matrixPosition)
        let base = attractionSettings.baseOpacity
        let maxO = attractionSettings.maxOpacity
        return base + (maxO - base) * Double(w)
    }

    /// Normalized 0...1 "how strong is matrix shift currently affecting this position".
    /// This is shared by multiple visual effects (opacity + highlight overlay), to keep transitions consistent.
    private func matrixShiftEffectWeight(for matrixPosition: CGPoint) -> CGFloat {
        let sx = abs(curvedSigned(matrixShiftValueX, power: matrixShiftSettings.inputCurvePower))
        let sy = abs(curvedSigned(matrixShiftValueY, power: matrixShiftSettings.inputCurvePower))
        let sliderMagnitude = max(sx, sy)
        if sliderMagnitude < 0.0001 { return 0 }

        // Normalize distance to matrix center in [0, 1] (per axis)
        let halfW = max(matrixHalfSize.width, 0.0001)
        let halfH = max(matrixHalfSize.height, 0.0001)
        let dx = matrixPosition.x - matrixCenter.x
        let dy = matrixPosition.y - matrixCenter.y

        let nx = min(1, abs(dx) / halfW)
        let ny = min(1, abs(dy) / halfH)

        // Same distance field + horizontal-center emphasis as the shift function.
        var nxScaled = nx * matrixShiftSettings.horizontalFalloffScale
        let nyScaled = ny * matrixShiftSettings.verticalFalloffScale

        let xCenterCloseness = max(0, 1 - nx)
        let boost = max(0, min(1, matrixShiftSettings.horizontalCenterBoost))
        let xBoostFactor = 1 + boost * pow(xCenterCloseness, matrixShiftSettings.horizontalCenterBoostPower)
        nxScaled /= xBoostFactor

        let d = hypot(nxScaled, nyScaled)

        // Gaussian falloff for visual effects (separately tunable from displacement).
        let k = max(0.0001, matrixShiftSettings.opacityFalloffPower)
        let fieldWeight = exp(-k * d * d)

        // Slider magnitude shaping (separately tunable).
        let inputWeight = pow(min(1, sliderMagnitude), max(0.0001, matrixShiftSettings.opacityInputPower))

        return clamp01(fieldWeight * inputWeight)
    }

    /// Opacity for the green highlight overlay driven by matrix shift.
    /// Approaches 1 near the matrix center as sliders approach ±1; approaches 0 near slider center or far from center.
    func matrixShiftHighlightOpacity(for matrixPosition: CGPoint) -> Double {
        guard mode == .matrix, matrixShiftSettings.isEnabled, matrixShiftSettings.isHighlightEnabled else {
            return 0
        }
        let w = matrixShiftEffectWeight(for: matrixPosition)
        let shaped = curvedUnit(w, power: matrixShiftSettings.highlightOpacityPower)
        return matrixShiftSettings.highlightMaxOpacity * Double(shaped)
    }
    
    // MARK: - Setup / Layout
    func setupCircles(in bounds: CGRect) {
        // Reset mode/state on fresh setup (e.g. rotation)
        modeCompletionWorkItem?.cancel()
        mode = .random
        matrixShiftValueX = 0
        matrixShiftValueY = 0

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
    
    // MARK: - Random Motion Loop
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
    
    // MARK: - Mode Transitions
    func animateToMatrix() {
        guard mode == .random else { return }
        
        modeCompletionWorkItem?.cancel()
        mode = .animatingToMatrix
        timer?.invalidate()
        matrixShiftValueX = 0
        matrixShiftValueY = 0
        
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
        matrixShiftValueX = 0
        matrixShiftValueY = 0
        
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
    
    
    deinit {
        timer?.invalidate()
        modeCompletionWorkItem?.cancel()
    }
}

