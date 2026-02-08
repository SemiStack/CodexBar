import SwiftUI

struct ProviderSettingsSection<Content: View>: View {
    let title: String
    let spacing: CGFloat
    let verticalPadding: CGFloat
    let horizontalPadding: CGFloat
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        spacing: CGFloat = 12,
        verticalPadding: CGFloat = 10,
        horizontalPadding: CGFloat = 4,
        @ViewBuilder content: @escaping () -> Content)
    {
        self.title = title
        self.spacing = spacing
        self.verticalPadding = verticalPadding
        self.horizontalPadding = horizontalPadding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.spacing) {
            Text(self.title.appLocalized)
                .font(.headline)
            self.content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.verticalPadding)
        .padding(.horizontal, self.horizontalPadding)
    }
}

@MainActor
struct ProviderSettingsToggleRowView: View {
    let toggle: ProviderSettingsToggleDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(self.toggle.title.appLocalized)
                        .font(.subheadline.weight(.semibold))
                    Text(self.toggle.subtitle.appLocalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: self.toggle.binding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            if self.toggle.binding.wrappedValue {
                if let status = self.toggle.statusText?(), !status.isEmpty {
                    Text(status.appLocalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                let actions = self.toggle.actions.filter { $0.isVisible?() ?? true }
                if !actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(actions) { action in
                            Button(action.title.appLocalized) {
                                Task { @MainActor in
                                    await action.perform()
                                }
                            }
                            .applyProviderSettingsButtonStyle(action.style)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .onChange(of: self.toggle.binding.wrappedValue) { _, enabled in
            guard let onChange = self.toggle.onChange else { return }
            Task { @MainActor in
                await onChange(enabled)
            }
        }
        .task(id: self.toggle.binding.wrappedValue) {
            guard self.toggle.binding.wrappedValue else { return }
            guard let onAppear = self.toggle.onAppearWhenEnabled else { return }
            await onAppear()
        }
    }
}

@MainActor
struct ProviderSettingsPickerRowView: View {
    let picker: ProviderSettingsPickerDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(self.picker.title.appLocalized)
                    .font(.subheadline.weight(.semibold))
                    .frame(width: ProviderSettingsMetrics.pickerLabelWidth, alignment: .leading)

                Picker("", selection: self.picker.binding) {
                    ForEach(self.picker.options) { option in
                        Text(option.title.appLocalized).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                if let trailingText = self.picker.trailingText?(), !trailingText.isEmpty {
                    Text(trailingText.appLocalized)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 4)
                }

                Spacer(minLength: 0)
            }

            let subtitle = self.picker.dynamicSubtitle?() ?? self.picker.subtitle
            if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(subtitle.appLocalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: self.picker.binding.wrappedValue) { _, selection in
            guard let onChange = self.picker.onChange else { return }
            Task { @MainActor in
                await onChange(selection)
            }
        }
    }
}

@MainActor
struct ProviderSettingsFieldRowView: View {
    let field: ProviderSettingsFieldDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let trimmedTitle = self.field.title.appLocalized.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSubtitle = self.field.subtitle.appLocalized.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasHeader = !trimmedTitle.isEmpty || !trimmedSubtitle.isEmpty

            if hasHeader {
                VStack(alignment: .leading, spacing: 4) {
                    if !trimmedTitle.isEmpty {
                        Text(trimmedTitle)
                            .font(.subheadline.weight(.semibold))
                    }
                    if !trimmedSubtitle.isEmpty {
                        Text(trimmedSubtitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            switch self.field.kind {
            case .plain:
                TextField((self.field.placeholder ?? "").appLocalized, text: self.field.binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .onTapGesture { self.field.onActivate?() }
            case .secure:
                SecureField((self.field.placeholder ?? "").appLocalized, text: self.field.binding)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                    .onTapGesture { self.field.onActivate?() }
            }

            let actions = self.field.actions.filter { $0.isVisible?() ?? true }
            if !actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(actions) { action in
                        Button(action.title.appLocalized) {
                            Task { @MainActor in
                                await action.perform()
                            }
                        }
                        .applyProviderSettingsButtonStyle(action.style)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}

@MainActor
struct ProviderSettingsTokenAccountsRowView: View {
    let descriptor: ProviderSettingsTokenAccountsDescriptor
    @State private var newLabel: String = ""
    @State private var newToken: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.descriptor.title.appLocalized)
                .font(.subheadline.weight(.semibold))

            if !self.descriptor.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(self.descriptor.subtitle.appLocalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let accounts = self.descriptor.accounts()
            if accounts.isEmpty {
                Text("No token accounts yet.".appLocalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let selectedIndex = min(self.descriptor.activeIndex(), max(0, accounts.count - 1))
                Picker("", selection: Binding(
                    get: { selectedIndex },
                    set: { index in self.descriptor.setActiveIndex(index) }))
                {
                    ForEach(Array(accounts.enumerated()), id: \.offset) { index, account in
                        Text(account.displayName).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)

                Button("Remove selected account".appLocalized) {
                    let account = accounts[selectedIndex]
                    self.descriptor.removeAccount(account.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                TextField("Label".appLocalized, text: self.$newLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                SecureField(self.descriptor.placeholder.appLocalized, text: self.$newToken)
                    .textFieldStyle(.roundedBorder)
                    .font(.footnote)
                Button("Add".appLocalized) {
                    let label = self.newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    let token = self.newToken.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !label.isEmpty, !token.isEmpty else { return }
                    self.descriptor.addAccount(label, token)
                    self.newLabel = ""
                    self.newToken = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(self.newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    self.newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 10) {
                Button("Open token file".appLocalized) {
                    self.descriptor.openConfigFile()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                Button("Reload".appLocalized) {
                    self.descriptor.reloadFromDisk()
                }
                .buttonStyle(.link)
                .controlSize(.small)
            }
        }
    }
}

@MainActor
struct ProviderSettingsCodexAccountsRowView: View {
    let descriptor: ProviderSettingsCodexAccountsDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(self.descriptor.title.appLocalized)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button(self.descriptor.addAccountTitle.appLocalized) {
                    self.descriptor.addAccount()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if !self.descriptor.subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(self.descriptor.subtitle.appLocalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let accounts = self.descriptor.accounts()
            if accounts.isEmpty {
                Text("No accounts added yet.".appLocalized)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(accounts) { account in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                let title: String = if account.isActive {
                                    AppLocalization.format(
                                        "%@ · Current",
                                        language: AppLocalization.currentLanguage(),
                                        account.displayName)
                                } else {
                                    account.displayName
                                }
                                Text(title)
                                    .font(.footnote.weight(account.isActive ? .semibold : .regular))
                                if let detail = account.detailText, !detail.isEmpty {
                                    Text(detail.appLocalized)
                                        .font(.footnote)
                                        .foregroundStyle(account.isUsingCachedData ? .orange : .secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 6)
                            if !account.isActive {
                                Button("Switch".appLocalized) {
                                    self.descriptor.switchAccount(account.email)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                if let removeAccount = self.descriptor.removeAccount {
                                    Button {
                                        removeAccount(account.email)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.footnote.weight(.semibold))
                                    }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .foregroundStyle(.secondary)
                                    .help("Delete account".appLocalized)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

extension View {
    @ViewBuilder
    fileprivate func applyProviderSettingsButtonStyle(_ style: ProviderSettingsActionDescriptor.Style) -> some View {
        switch style {
        case .bordered:
            self.buttonStyle(.bordered)
        case .link:
            self.buttonStyle(.link)
        }
    }
}
