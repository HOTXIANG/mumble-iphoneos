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
    
    var body: some View {
        List {
            // App 图标与版本区
            Section {
                VStack(spacing: 4) {
                    Image(uiImage: UIImage(named: "TransparentLogo") ?? UIImage(systemName: "mic.circle.fill")!)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                        .shadow(radius: 10)
                    
                    VStack(spacing: 4) {
                        Text("Mumble for iOS")
                            .font(.title2)
                            .bold()
                        
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
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
