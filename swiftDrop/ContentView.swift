//
//  ContentView.swift
//  swiftDrop
//
//  Created by Elena Gantner on 06.04.25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "paperplane")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Welcome to Swift Drop!")
            Spacer()
            Text("Use from the Share Menu!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
