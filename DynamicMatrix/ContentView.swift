//
//  ContentView.swift
//  DynamicMatrix
//
//  Created by 陈皆成 on 2025/12/21.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CircleMatrixViewModel()
    @State private var geometrySize: CGSize = .zero
    
    private let matrixSpaceName = "matrixSpace"
    
    private var matrixShiftXBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.matrixShiftValueX) },
            set: { viewModel.matrixShiftValueX = CGFloat($0) }
        )
    }

    private var matrixShiftYBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.matrixShiftValueY) },
            set: { viewModel.matrixShiftValueY = CGFloat($0) }
        )
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color.black
                    .ignoresSafeArea()
                
                // Circles
                ForEach(viewModel.circles) { circle in
                    let attraction = viewModel.attractionOffset(for: circle.position)
                    let matrixShift = viewModel.matrixShiftOffset(for: circle.targetPosition)
                    let touchOpacity = viewModel.attractionOpacity(for: circle.position)
                    let matrixOpacity = viewModel.matrixShiftOpacity(for: circle.targetPosition)
                    // Combine two independent opacity boosts, bounded to [base, 1].
                    let opacity = max(touchOpacity, matrixOpacity)
                    let highlightOpacity = viewModel.matrixShiftHighlightOpacity(for: circle.targetPosition)
                    let combinedOffset = CGSize(
                        width: attraction.width + matrixShift.width,
                        height: attraction.height + matrixShift.height
                    )
                    Circle()
                        .fill(Color(hex: "#FFFFFF"))
                        .opacity(opacity)
                        .overlay(
                            Circle()
                                .fill(Color(hex: "#7FDD60"))
                                .opacity(highlightOpacity)
                        )
                        .frame(width: viewModel.circleSize, height: viewModel.circleSize)
                        .position(circle.position)
                        .offset(combinedOffset)
                        // Timer-driven movement has animations disabled in ViewModel transactions.
                        .animation(
                            .interactiveSpring(
                                response: viewModel.attractionSettings.springResponse,
                                dampingFraction: viewModel.attractionSettings.springDampingFraction,
                                blendDuration: viewModel.attractionSettings.springBlendDuration
                            ),
                            value: viewModel.touchLocation
                        )
                        .animation(
                            .interactiveSpring(
                                response: viewModel.matrixShiftSettings.springResponse,
                                dampingFraction: viewModel.matrixShiftSettings.springDampingFraction,
                                blendDuration: viewModel.matrixShiftSettings.springBlendDuration
                            ),
                            value: viewModel.matrixShiftValueX
                        )
                        .animation(
                            .interactiveSpring(
                                response: viewModel.matrixShiftSettings.springResponse,
                                dampingFraction: viewModel.matrixShiftSettings.springDampingFraction,
                                blendDuration: viewModel.matrixShiftSettings.springBlendDuration
                            ),
                            value: viewModel.matrixShiftValueY
                        )
                        .allowsHitTesting(false)
                }

                // Full-screen touch pad (single finger), layered above circles but below button
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        // IMPORTANT: Use the same coordinate space as the circles, otherwise safe-area
                        // differences (e.g. status bar) can create a constant Y offset.
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(matrixSpaceName))
                            .onChanged { value in
                                viewModel.setTouchLocation(value.location)
                            }
                            .onEnded { _ in
                                viewModel.setTouchLocation(nil)
                            }
                    )
                    .ignoresSafeArea()
                    .allowsHitTesting(true)

                if viewModel.attractionSettings.showsTouchIndicator, let touch = viewModel.touchLocation {
                    Circle()
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                        .frame(width: 14, height: 14)
                        .position(touch)
                        .allowsHitTesting(false)
                }
                
                // Button overlay
                VStack {
                    Spacer()
                    
                    // Slider: only active/visible in matrix mode
                    if viewModel.mode == .matrix {
                        VStack(spacing: 10) {
                            Text("Matrix Shift")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.85))
                            
                            // Horizontal shift
                            Slider(value: matrixShiftXBinding, in: -1...1)
                                .tint(.white)
                            
                            HStack {
                                Text("Left")
                                Spacer()
                                Text("Right")
                            }
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))

                            // Vertical shift
                            Slider(value: matrixShiftYBinding, in: -1...1)
                                .tint(.white)

                            HStack {
                                Text("Up")
                                Spacer()
                                Text("Down")
                            }
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.65))
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    }
                    
                    Button(action: {
                        if viewModel.mode == .random {
                            viewModel.animateToMatrix()
                        } else {
                            viewModel.resetToRandomMovement()
                        }
                    }) {
                        Text(viewModel.mode == .random ? "Organize Matrix" : "Reset Movement")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                    .padding(.bottom, 50)
                }
            }
            .coordinateSpace(name: matrixSpaceName)
            .onAppear {
                geometrySize = geometry.size
                viewModel.setupCircles(in: CGRect(origin: .zero, size: geometry.size))
            }
            .onChange(of: geometry.size) { newSize in
                geometrySize = newSize
                viewModel.setupCircles(in: CGRect(origin: .zero, size: newSize))
            }
        }
    }
}

// Extension to create Color from hex string
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    ContentView()
}
