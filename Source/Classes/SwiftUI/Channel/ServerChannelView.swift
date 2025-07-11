// 文件: ServerChannelView.swift (已添加 Menu 标题)

import SwiftUI

struct ServerChannelView: View {
    @ObservedObject var serverManager: ServerModelManager

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.20, green: 0.20, blue: 0.25),
                    Color(red: 0.07, green: 0.07, blue: 0.10)
                ]),
                startPoint: .top,
                endPoint: .bottom
            ).ignoresSafeArea()

            List {
                ForEach(serverManager.modelItems) { item in
                    if item.isChannel {
                        Menu {
                            VStack {
                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                                Button("Join Channel", systemImage: "arrow.right.to.line") { joinChannel(item: item) }
                                Button("Channel Info", systemImage: "info.circle") { showChannelInfo(item: item) }
                            }
                        } label: {
                            ChannelRowView(item: item)
                        }
                    } else if item.isUser {
                        Menu {
                            VStack {
                                Text(item.title)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                    .padding(.bottom, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Divider()
                                Button("Send Message", systemImage: "message") { sendMessageToUser(item: item) }
                                Button("User Info", systemImage: "person.circle") { showUserInfo(item: item) }
                                // 可以在这里添加更多操作，如“踢出”、“静音”等
                            }
                        } label: {
                            UserRowView(item: item)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private func joinChannel(item: ChannelNavigationItem) { if let channel = item.object as? MKChannel { serverManager.joinChannel(channel) } }
    private func showChannelInfo(item: ChannelNavigationItem) { /* TODO */ }
    private func sendMessageToUser(item: ChannelNavigationItem) { /* TODO */ }
    private func showUserInfo(item: ChannelNavigationItem) { /* TODO */ }
}
