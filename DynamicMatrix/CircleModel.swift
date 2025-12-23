//
//  CircleModel.swift
//  DynamicMatrix
//
//  Created by 陈皆成 on 2025/12/21.
//

import SwiftUI

struct CircleData: Identifiable {
    let id: UUID
    var position: CGPoint
    var velocity: CGVector
    var targetPosition: CGPoint
    var speed: CGFloat
    
    init(id: UUID = UUID(), position: CGPoint, velocity: CGVector, targetPosition: CGPoint, speed: CGFloat) {
        self.id = id
        self.position = position
        self.velocity = velocity
        self.targetPosition = targetPosition
        self.speed = speed
    }
}

