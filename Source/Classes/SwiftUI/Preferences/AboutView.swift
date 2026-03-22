//
//  AboutView.swift
//  Mumble
//
//  Created by 王梓田 on 1/2/26.
//

import SwiftUI

struct AboutView: View {
    private enum AboutDestination: Hashable {
        case license
        case acknowledgements
    }

    @Environment(\.colorScheme) private var colorScheme
    // 动态获取版本号
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? NSLocalizedString("Unknown", comment: "")
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? NSLocalizedString("Unknown", comment: "")
    @State private var automationDestination: AboutDestination? = nil

    private var preferredLogoName: String {
        colorScheme == .dark ? "TransparentLogoDarkGlass" : "TransparentLogoBrightGlass"
    }

    private var logoShadowColor: Color {
        colorScheme == .light ? .black.opacity(0.30) : .black.opacity(0.22)
    }

    private var logoShadowRadius: CGFloat {
        colorScheme == .light ? 22 : 12
    }

    private var logoShadowYOffset: CGFloat {
        colorScheme == .light ? 10 : 5
    }

    private var aboutLogoImage: Image {
        Image(preferredLogoName)
    }
    
    @ViewBuilder
    private var aboutContent: some View {
        // App 图标与版本区
        Section {
            VStack(spacing: 4) {
                aboutLogoImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .shadow(color: logoShadowColor, radius: logoShadowRadius, x: 0, y: logoShadowYOffset)
                
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
            NavigationLink(
                "License",
                destination: ScrollView {
                    Text("Mumble for iOS is Free Software...")
                        .padding()
                }
                .navigationTitle("License")
                .onAppear {
                    AppState.shared.setAutomationCurrentScreen("aboutLicense")
                },
                tag: .license,
                selection: $automationDestination
            )
            
            NavigationLink(
                "Third Party Libraries",
                destination: List {
                    Text("OpenSSL")
                    Text("MumbleKit")
                    Text("Protobuf")
                }
                .navigationTitle("Acknowledgements")
                .onAppear {
                    AppState.shared.setAutomationCurrentScreen("aboutAcknowledgements")
                },
                tag: .acknowledgements,
                selection: $automationDestination
            )
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
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("about")
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationOpenUI)) { notification in
            guard let target = notification.userInfo?["target"] as? String else { return }
            switch target {
            case "aboutLicense":
                automationDestination = .license
            case "aboutAcknowledgements":
                automationDestination = .acknowledgements
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .muAutomationDismissUI)) { notification in
            let target = notification.userInfo?["target"] as? String
            switch target {
            case nil:
                automationDestination = nil
            case "aboutLicense" where automationDestination == .license:
                automationDestination = nil
            case "aboutAcknowledgements" where automationDestination == .acknowledgements:
                automationDestination = nil
            default:
                break
            }
        }
    }
}
