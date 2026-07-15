//
//  SoundCheckApp.swift
//  SoundCheck
//
//  Created by Victor Koeppel on 15/07/2026.
//

import SwiftUI

@main
struct SoundCheckApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .windowResizability(.contentSize)
        #endif
    }
}
