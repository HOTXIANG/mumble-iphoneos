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
        colorScheme == .dark ? "TransparentLogoDarkGlass" : "TransparentLogoPurpleGlass"
    }

    private var logoShadowColor: Color {
        colorScheme == .light ? .clear : .black.opacity(0.22)
    }

    private var logoShadowRadius: CGFloat {
        colorScheme == .light ? 0 : 12
    }

    private var logoShadowYOffset: CGFloat {
        colorScheme == .light ? 0 : 5
    }

    private var logoGlowColor: Color {
        colorScheme == .light
            ? Color(red: 0.55, green: 0.50, blue: 1.0).opacity(0.14)
            : Color.white.opacity(0.16)
    }

    private var logoGlowRadius: CGFloat {
        colorScheme == .light ? 6 : 8
    }

    private var aboutLogoImage: Image {
        Image(preferredLogoName)
    }

    private var licenseDestination: some View {
        ScrollView {
            Text("Mumble for iOS is Free Software...")
                .padding()
        }
        .navigationTitle("License")
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("aboutLicense")
        }
    }

    private var acknowledgementsDestination: some View {
        List {
            Text("OpenSSL")
            Text("MumbleKit")
            Text("Protobuf")
        }
        .navigationTitle("Acknowledgements")
        .onAppear {
            AppState.shared.setAutomationCurrentScreen("aboutAcknowledgements")
        }
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
                    .shadow(color: logoGlowColor, radius: logoGlowRadius, x: 0, y: 0)
                    .shadow(color: logoGlowColor.opacity(0.30), radius: logoGlowRadius * 0.35, x: 0, y: 0)
                
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
            NavigationLink("License", destination: licenseDestination)
            NavigationLink("Third Party Libraries", destination: acknowledgementsDestination)
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
        .navigationDestination(isPresented: licenseAutomationBinding) {
            licenseDestination
        }
        .navigationDestination(isPresented: acknowledgementsAutomationBinding) {
            acknowledgementsDestination
        }
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

    private var licenseAutomationBinding: Binding<Bool> {
        Binding(
            get: { automationDestination == .license },
            set: { isPresented in
                if !isPresented, automationDestination == .license {
                    automationDestination = nil
                }
            }
        )
    }

    private var acknowledgementsAutomationBinding: Binding<Bool> {
        Binding(
            get: { automationDestination == .acknowledgements },
            set: { isPresented in
                if !isPresented, automationDestination == .acknowledgements {
                    automationDestination = nil
                }
            }
        )
    }
}
