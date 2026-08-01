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
    }
}
