import SwiftUI

struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
                Section {
                    Button("Sign In") { run { try await SupabaseService.shared.signIn(email: email, password: password) } }
                    Button("Create Account") { run { try await SupabaseService.shared.signUp(email: email, password: password) } }
                }
                .disabled(busy || email.isEmpty || password.isEmpty)

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("CourtVision")
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        errorMessage = nil
        busy = true
        Task {
            do { try await op() } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }
}
