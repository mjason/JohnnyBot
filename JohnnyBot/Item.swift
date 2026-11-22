//
//  Item.swift
//  JohnnyBot
//
//  Created by 林满佳 on 2026/11/22.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
