import ReverseOfPowerCore
import SwiftUI

@main
struct ReverseOfPowerApp: App {
  var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
  @StateObject private var game = GameConnection()
  @AppStorage("serverAddress") private var serverAddress = ""
  @State private var consoles: [DiscoveredConsole] = []
  @State private var isSearching = false

  var body: some View {
    NavigationStack {
      ZStack {
        LinearGradient(colors: [.purple, .indigo, .black], startPoint: .top, endPoint: .bottom)
          .ignoresSafeArea()
        ScrollView {
          VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 72)).foregroundStyle(
              .yellow)
            Text("Reverse of Power").font(.largeTitle.bold()).foregroundStyle(.white)

            if !game.isConnected {
              discoverySection
              manualConnectionSection
            }

            if game.isConnecting {
              ProgressView("Łączenie z konsolą…")
                .tint(.yellow)
                .foregroundStyle(.white)
            } else if game.isConnected {
              Text("Połączono z grą").foregroundStyle(.green)
              Button("Gotowy") {
                game.send(type: "StartGameButtonPressedResponseMessage", fields: ["Response": 9])
              }
              .buttonStyle(.borderedProminent)
              Button("Rozłącz", role: .destructive) { game.disconnect() }
                .buttonStyle(.bordered)
            }

            if let error = game.errorMessage {
              Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            Text("Telefon i konsola muszą być w tej samej sieci Wi‑Fi.")
              .font(.footnote).foregroundStyle(.white.opacity(0.7))
          }
          .frame(maxWidth: 520)
          .padding(24)
          .frame(maxWidth: .infinity)
        }
      }
      .navigationBarHidden(true)
      .task { await searchForConsoles() }
    }
  }

  private var discoverySection: some View {
    VStack(spacing: 12) {
      HStack {
        Text("Konsole w sieci").font(.headline).foregroundStyle(.white)
        Spacer()
        Button("Szukaj ponownie") { Task { await searchForConsoles() } }
          .disabled(isSearching || game.isConnecting)
      }
      if isSearching {
        ProgressView("Wyszukiwanie konsoli…").tint(.yellow).foregroundStyle(.white)
      } else if consoles.isEmpty {
        Text("Nie znaleziono konsoli.").foregroundStyle(.white.opacity(0.75))
      } else {
        ForEach(consoles) { console in
          Button {
            serverAddress = console.address
            game.connect(host: console.address)
          } label: {
            HStack {
              Image(systemName: "playstation.logo")
              VStack(alignment: .leading) {
                Text(console.name).font(.headline)
                Text("\(console.type) • \(console.address)").font(.caption)
              }
              Spacer()
              Image(systemName: "chevron.right")
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .tint(.white.opacity(0.92))
          .foregroundStyle(.indigo)
        }
      }
    }
  }

  private var manualConnectionSection: some View {
    VStack(spacing: 12) {
      TextField("Adres IP konsoli", text: $serverAddress)
        .textInputAutocapitalization(.never)
        .keyboardType(.numbersAndPunctuation)
        .submitLabel(.connect)
        .onSubmit { game.connect(host: serverAddress) }
        .padding()
        .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 14))
      Button("Połącz") { game.connect(host: serverAddress) }
        .buttonStyle(.borderedProminent)
        .tint(.yellow)
        .foregroundStyle(.black)
        .disabled(game.isConnecting)
    }
  }

  @MainActor
  private func searchForConsoles() async {
    guard !isSearching else { return }
    isSearching = true
    consoles = await ConsoleDiscovery.search()
    isSearching = false
  }
}
