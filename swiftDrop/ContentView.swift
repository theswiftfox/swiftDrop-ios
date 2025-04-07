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
            Spacer()
            HStack {
                Image(systemName: "paperplane")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Welcome to Swift Drop!")
            }
            Spacer()
            Text("Use from the Share Menu!")
                .padding(.bottom, 50)
        }
        .padding()
        HStack {
            Spacer()
            Text("Created by Elena")
                .font(.system(.footnote))
        }.padding([.trailing], 25)
    }
}

#Preview {
    ContentView()
}
