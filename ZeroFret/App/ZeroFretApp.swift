//  ZeroFretApp.swift
//  Zero Fret

import SwiftUI

@main
struct ZeroFretApp: App {
    @State private var engine = TunerEngine()

    var body: some Scene {
        WindowGroup {
            TunerView()
                .environment(engine)
        }
    }
}
