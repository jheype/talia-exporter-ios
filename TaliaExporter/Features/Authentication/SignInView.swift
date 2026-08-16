import SwiftUI

struct SignInView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty && !appModel.isWorking
    }

    var body: some View {
        ZStack {
            Color.taliaBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    BrandLockup()
                        .padding(.top, 18)

                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 48, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.taliaBlue)
                        .padding(.top, 72)

                    Text("Sign in to Talia")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .tracking(-1.1)
                        .padding(.top, 26)

                    VStack(spacing: 14) {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .email)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .password }

                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .focused($focusedField, equals: .password)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    }
                    .font(.body)
                    .textFieldStyle(TaliaTextFieldStyle())
                    .padding(.top, 32)

                    Button(action: submit) {
                        Group {
                            if appModel.isWorking {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Sign in")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TaliaPrimaryButtonStyle())
                    .disabled(!canSubmit)
                    .padding(.top, 20)
                }
                .padding(.horizontal, TaliaLayout.screenPadding)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear { focusedField = .email }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        Task {
            await appModel.signIn(email: email, password: password)
        }
    }
}

private struct TaliaTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Color.taliaSecondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
            }
    }
}

#Preview("Sign in") {
    SignInView()
        .environmentObject(AppModel.preview(route: .signedOut))
}
