import SwiftUI
import ReverseOfPowerCore

@main
struct ReverseOfPowerApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @StateObject private var game = GameConnection()
    @AppStorage("serverAddress") private var serverAddress = ""

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [.purple, .indigo, .black], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                VStack(spacing: 24) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 72)).foregroundStyle(.yellow)
                    Text("Reverse of Power").font(.largeTitle.bold()).foregroundStyle(.white)
                    TextField("Adres IP konsoli", text: $serverAddress)
                        .textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation)
                        .padding().background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
                    Button(game.isConnected ? "Rozłącz" : "Połącz") {
                        game.isConnected ? game.disconnect() : game.connect(host: serverAddress)
                    }
                    .buttonStyle(.borderedProminent).tint(game.isConnected ? .red : .yellow).foregroundStyle(.black)
                    if game.isConnected {
                        Text("Połączono z grą").foregroundStyle(.green)
                        Button("Gotowy") { game.send(type: "ClientQuizCommandMessage", fields: ["action": 14, "time": 0]) }
                            .buttonStyle(.borderedProminent)
                    }
                    if let error = game.errorMessage { Text(error).foregroundStyle(.red) }
                    Spacer()
                    Text("Telefon i konsola muszą być w tej samej sieci Wi‑Fi.")
                        .font(.footnote).foregroundStyle(.white.opacity(0.7))
                }.padding(24)
            }.navigationBarHidden(true)
        }
    }
}
