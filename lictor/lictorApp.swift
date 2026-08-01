//
//  lictorApp.swift
//  lictor
//
//  Created by hidemune on 8/1/26.
//
//  Menu bar resident app. It stays out of the Dock and out of Cmd-Tab
//  (INFOPLIST_KEY_LSUIElement = YES in build settings / docs/principles.md).
//
//  This app only displays and operates; it **does not enforce the deadline**.
//  Enforcement belongs to the launchd agent under agent/, so that SSH still
//  closes correctly even when the app is dead (principle 1).
//

import SwiftUI

/// Identifier for the history window, shared between the scene and whatever
/// opens it.
enum HistoryWindow {
    static let id = "history"
}

@main
struct lictorApp: App {
    @State private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(monitor: monitor)
        } label: {
            MenuBarLabel(display: monitor.display)
        }
        .menuBarExtraStyle(.window)

        // Suppressed at launch: this is a menu bar app, and a window appearing
        // on login would contradict that. It opens only from the panel.
        Window("Lictor History", id: HistoryWindow.id) {
            HistoryView()
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 520, height: 380)
    }
}
