import SwiftUI

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var region: Region = .us
    @State private var customBase = "https://api-us.vicohome.io"
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focus: Field?

    enum Field { case email, password, base }

    var body: some View {
        ZStack {
            Theme.background(strength: 0.24)
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        Image(systemName: "eye.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.accent)
                        Text("Nightjar").font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Sign in with your Vicohome account")
                            .foregroundStyle(Theme.dim)
                    }
                    .padding(.top, 50)

                    VStack(spacing: 12) {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focus = .password }
                            .field()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focus, equals: .password)
                            .submitLabel(.go)
                            .onSubmit { Task { await go() } }
                            .field()

                        Picker("Region", selection: $region) {
                            ForEach(Region.allCases) { Text($0 == .us ? "Americas" : $0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        if region == .custom {
                            TextField("API base URL", text: $customBase)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .focused($focus, equals: .base)
                                .field()
                        }
                    }
                    .card()

                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Task { await go() }
                    } label: {
                        HStack {
                            if busy { ProgressView().tint(.black) }
                            Text(busy ? "Signing in" : "Sign in").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.black)
                    }
                    .disabled(busy || email.isEmpty || password.isEmpty)
                    .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Use a second account", systemImage: "person.2.fill")
                            .font(.subheadline.weight(.semibold))
                        Text("Vicohome can sign an account out when it logs in from somewhere new, so using your main login here may kick the Vicohome app off. Make a second Vicohome account, share your cameras to it from the main one, and sign in with that here. Shared viewers still see cloud clips.")
                            .font(.footnote)
                            .foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()

                    Text("Unofficial. Not affiliated with Vicohome.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func go() async {
        guard !email.isEmpty, !password.isEmpty, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await model.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password, region: region, customBase: customBase)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func field() -> some View { modifier(FieldStyle()) }
}
