//
//  AboutView.swift
//  Mumble
//
//  Created by 王梓田 on 1/2/26.
//

import SwiftUI

struct AboutView: View {
    // 动态获取版本号
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    
    @ViewBuilder
    private var aboutContent: some View {
        // App 图标与版本区
        Section {
            VStack(spacing: 4) {
                #if os(iOS)
                Image(uiImage: UIImage(named: "TransparentLogo") ?? UIImage(systemName: "mic.circle.fill")!)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .shadow(radius: 10)
                #else
                Image(nsImage: NSImage(named: "TransparentLogo") ?? NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: nil)!)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .shadow(radius: 10)
                #endif
                
                VStack(spacing: 4) {
                    #if os(macOS)
                    Text("Mumble for macOS")
                        .font(.title2)
                        .bold()
                    #else
                    Text("Mumble for iOS")
                        .font(.title2)
                        .bold()
                    #endif
                    
                    Text("Version \(version) (Build \(build))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
            .listRowBackground(Color.clear)
        }
        
        // 链接区
        Section(header: Text("Links")) {
            Link(destination: URL(string: "https://www.mumble.info")!) {
                Label("Official Website", systemImage: "globe")
            }
            
            Link(destination: URL(string: "https://github.com/mumble-voip/mumble-iphoneos")!) {
                Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            
            Link(destination: URL(string: "https://github.com/mumble-voip/mumble-iphoneos/issues")!) {
                Label("Report an Issue", systemImage: "exclamationmark.bubble")
            }
        }
        
        // 法律信息区
        Section(header: Text("Legal")) {
            NavigationLink("License") {
                ScrollView {
                    Text("Mumble for iOS is Free Software...")
                        .padding()
                }
                .navigationTitle("License")
            }
            
            NavigationLink("Third Party Libraries") {
                List {
                    Text("OpenSSL")
                    Text("MumbleKit")
                    Text("Protobuf")
                }
                .navigationTitle("Acknowledgements")
            }
        }
        
        // 版权区
        Section {
            Text("Copyright © 2009-2026 The Mumble for iOS Developers")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .listRowBackground(Color.clear)
        }
    }

    var body: some View {
        Group {
            #if os(macOS)
            Form {
                aboutContent
            }
            .formStyle(.grouped)
            #else
            List {
                aboutContent
            }
            #endif
        }
        .navigationTitle("About")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
