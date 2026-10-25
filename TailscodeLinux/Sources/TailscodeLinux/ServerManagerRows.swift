import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ServerManager {
    func makeConfiguredGroup(on page: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), Localized.text("Configured"))
        adw_preferences_page_add(ptr(page), ptr(group))
        return group
    }

    func makeAddGroup(on page: UnsafeMutablePointer<GtkWidget>)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), Localized.text("Add a server"))
        adw_preferences_group_set_description(
            ptr(group), Localized.text("Reading this machine's tailnet address…"))
        adw_preferences_page_add(ptr(page), ptr(group))

        let addMachine = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.margins(addMachine, top: 6, bottom: 12)
        let addButton = Gtk.button(ConnectLinkReading.addMachine + "…", css: ["pill"]) {
            [weak self] in
            self?.addMachine()
        }
        gtk_widget_set_halign(addButton, GTK_ALIGN_START)
        gtk_widget_set_tooltip_text(addButton, ConnectLinkReading.addMachineDetail)
        gtk_box_append(ptr(addMachine), addButton)
        gtk_box_append(
            ptr(addMachine),
            Gtk.label(ConnectLinkReading.addMachineDetail, css: "dim", wrap: true, selectable: false))
        adw_preferences_group_add(ptr(group), ptr(addMachine))

        let address = Self.entryRow(
            title: Localized.text("Tailnet address"),
            tooltip: Localized.text("100.x.y.z, name.tailnet.ts.net, host:port — or a whole line pasted out of the server's terminal"))
        addressRow = address
        adw_preferences_group_add(ptr(group), ptr(address))

        let name = Self.entryRow(title: Localized.text("Name (optional)"), tooltip: nil)
        nameRow = name
        adw_preferences_group_add(ptr(group), ptr(name))

        let password = Self.passwordRow(title: Localized.text("Password"))
        gtk_widget_set_tooltip_text(password, ServerPasswordRule.summary)
        passwordRow = password
        adw_preferences_group_add(ptr(group), ptr(password))
        let passwordHint = Gtk.label(ServerPasswordRule.summary, css: "dim", wrap: true, selectable: false)
        gtk_widget_set_margin_top(passwordHint, 6)
        gtk_widget_set_margin_start(passwordHint, 12)
        gtk_widget_set_margin_end(passwordHint, 12)
        adw_preferences_group_add(ptr(group), ptr(passwordHint))

        for row in [address, name, password] {
            Gtk.connect(UnsafeMutableRawPointer(row), "entry-activated") { [weak self] in
                self?.probeAndSave()
            }
        }

        let agent = adw_combo_row_new()!
        adw_preferences_row_set_title(ptr(agent), Localized.text("Agent"))
        adw_preferences_row_set_use_markup(ptr(agent), 0)
        adw_action_row_set_subtitle(
            ptr(agent),
            Localized.text("Every port is tried anyway when you don't name one."))
        let model = gtk_string_list_new(nil)!
        gtk_string_list_append(model, "claude-bridge · 4098")
        gtk_string_list_append(model, "opencode · 4096")
        gtk_string_list_append(model, "oh-my-pi · 4099")
        adw_combo_row_set_model(
            ptr(UnsafeMutableRawPointer(agent)),
            OpaquePointer(UnsafeMutableRawPointer(model)))
        adw_combo_row_set_selected(ptr(UnsafeMutableRawPointer(agent)), 0)
        agentRow = agent
        adw_preferences_group_add(ptr(group), ptr(agent))

        let (status, statusActions) = Self.factRow(title: "")
        gtk_widget_set_visible(status, 0)
        statusRow = status
        self.statusActions = statusActions
        adw_preferences_group_add(ptr(group), ptr(status))

        let buttons = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(buttons, GTK_ALIGN_END)
        Gtk.margins(buttons, top: 6)
        let probe = Gtk.button(
            Localized.text("Probe and save"), css: ["suggested-action", "pill"]
        ) { [weak self] in
            self?.probeAndSave()
        }
        probeButton = probe
        gtk_box_append(ptr(buttons), probe)
        adw_preferences_group_add(ptr(group), ptr(buttons))
        return group
    }

    func reload() {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            Gtk.onMain { [weak self] in self?.render(profiles) }
        }
    }

    func render(_ profiles: [ConnectionProfile]) {
        guard let group = configuredGroup else { return }
        for row in configuredRows { adw_preferences_group_remove(ptr(group), ptr(row)) }
        configuredRows = []
        for slots in rows.values { slots.capabilities?.stop() }
        rows = [:]
        self.profiles = profiles

        let expanding = expandAfterReload
        expandAfterReload = nil
        defer {
            if expandAll { for row in configuredRows where !profiles.isEmpty { adw_expander_row_set_expanded(ptr(row), 1) } }
        }
        adw_preferences_group_set_description(
            ptr(group),
            profiles.isEmpty
                ? Localized.text("No machines yet. Add the one running your agent below.")
                : Localized.text("%@ machines. Open one to check it, update it, or change it.",
                    "\(profiles.count)"))

        guard !profiles.isEmpty else {
            let row = adw_action_row_new()!
            adw_preferences_row_set_title(ptr(row), Localized.text("Nothing configured"))
            adw_preferences_row_set_use_markup(ptr(row), 0)
            adw_action_row_set_subtitle(ptr(row), ConnectLinkReading.addMachineDetail)
            adw_action_row_set_subtitle_lines(ptr(row), 0)
            adw_action_row_add_suffix(
                ptr(row),
                Self.inlineButton(ConnectLinkReading.addMachine + "…") { [weak self] in
                    self?.addMachine()
                })
            adw_preferences_group_add(ptr(group), ptr(row))
            configuredRows.append(row)
            return
        }

        for profile in profiles {
            let row = makeRow(profile)
            if profile.id == expanding { adw_expander_row_set_expanded(ptr(row), 1) }
            adw_preferences_group_add(ptr(group), ptr(row))
            configuredRows.append(row)
        }
        refreshSoftwareCards()
    }

    func makeRow(_ profile: ConnectionProfile) -> UnsafeMutablePointer<GtkWidget> {
        let slots = ServerRow()
        rows[profile.id] = slots

        let row = adw_expander_row_new()!
        adw_preferences_row_set_title(ptr(row), profile.name)
        adw_preferences_row_set_use_markup(ptr(row), 0)
        adw_expander_row_set_subtitle(
            ptr(row), "\(ServerLabel.agent(profile.backend)) · \(ServerLabel.address(profile))")

        let glyph = Gtk.label("○", css: "glyph-pending", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        slots.glyph = glyph
        adw_expander_row_add_prefix(ptr(row), glyph)

        let refresh = gtk_button_new_from_icon_name("view-refresh-symbolic")!
        Gtk.addClass(refresh, "flat")
        gtk_widget_set_valign(refresh, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(refresh, Localized.text("Ask this machine again"))
        let refreshID = profile.id
        Gtk.connect(UnsafeMutableRawPointer(refresh), "clicked") { [weak self] in
            self?.recheck(refreshID)
        }
        adw_expander_row_add_suffix(ptr(row), refresh)

        let (health, healthActions) = Self.factRow(title: Localized.text("Connection"))
        slots.health = health
        slots.healthActions = healthActions
        adw_expander_row_add_row(ptr(row), health)

        let capabilities = SetupCapabilitiesRows(
            profileURL: profile.baseURL, profileID: profile.id, parent: { [weak self] in self?.window })
        slots.capabilities = capabilities
        adw_expander_row_add_row(ptr(row), capabilities.row)
        capabilities.start()

        let isDemo = profile.id.hasPrefix(DemoWorld.profilePrefix)
        let isEnvironment = profile.id == "environment"

        if !isDemo {
            let cardView = UpdateCardView(style: .embedded)
            slots.softwareCard = cardView
            let wrapper = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.margins(wrapper, top: 10, bottom: 10, leading: 12, trailing: 12)
            gtk_box_append(ptr(wrapper), cardView.widget)
            let cardRow = adw_preferences_row_new()!
            gtk_list_box_row_set_child(ptr(cardRow), wrapper)
            gtk_list_box_row_set_activatable(ptr(cardRow), 0)
            gtk_list_box_row_set_selectable(ptr(cardRow), 0)
            adw_expander_row_add_row(ptr(row), cardRow)

            let id = profile.id
            cardView.onAction = { [weak self] action in
                guard let self,
                    let reading = UpdateLedger.rollup().readings.first(where: {
                        $0.component == .server(profileID: id)
                    })
                else { return }
                UpdatePress.perform(action, for: reading, parent: self.window) { [weak self] text in
                    Gtk.onMain { [weak self] in self?.toast(text) }
                }
            }
            cardView.onAutomation = { [weak self, weak cardView] enabled in
                guard let self, let cardView,
                    let reading = UpdateLedger.rollup().readings.first(where: {
                        $0.component == .server(profileID: id)
                    })
                else { return }
                UpdatePress.setAutomation(
                    enabled, for: reading,
                    restore: { [weak cardView] in cardView?.restoreAutomation() },
                    toast: { [weak self] text in Gtk.onMain { [weak self] in self?.toast(text) } })
            }

            let updatesRow = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(updatesRow), 0)
            adw_preferences_row_set_title(ptr(updatesRow), Localized.text("All software updates"))
            adw_action_row_set_subtitle(
                ptr(updatesRow),
                Localized.text("This app and every server, and what each one is running"))
            adw_action_row_set_subtitle_lines(ptr(updatesRow), 0)
            gtk_list_box_row_set_activatable(ptr(updatesRow), 1)
            let chevron = Gtk.label("›", css: "dim", selectable: false)
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(updatesRow), chevron)
            Gtk.connect(UnsafeMutableRawPointer(updatesRow), "activated") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let window = self.window else { return }
                    UpdatePanel.present(parent: window)
                }
            }
            adw_expander_row_add_row(ptr(row), updatesRow)
        }

        if profile.backend == .claudeCode && !isDemo {
            let (account, accountActions) = Self.factRow(title: Localized.text("Claude account"))
            slots.account = account
            slots.accountActions = accountActions
            adw_expander_row_add_row(ptr(row), account)

            let permissionsBox = MachinePermissionsBox(local: false)
            slots.permissionsBox = permissionsBox
            permissionsBox.onRequest = { [weak self] kind in
                self?.requestPermission(kind, profileID: profile.id)
            }
            let wrapper = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.margins(wrapper, top: 10, bottom: 10, leading: 12, trailing: 12)
            gtk_box_append(ptr(wrapper), permissionsBox.widget)
            gtk_widget_set_visible(wrapper, 0)
            let permissionsRow = adw_preferences_row_new()!
            gtk_list_box_row_set_child(ptr(permissionsRow), wrapper)
            gtk_list_box_row_set_activatable(ptr(permissionsRow), 0)
            gtk_list_box_row_set_selectable(ptr(permissionsRow), 0)
            slots.permissionsWrapper = wrapper
            adw_expander_row_add_row(ptr(row), permissionsRow)
        }

        if isDemo || isEnvironment {
            let note = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(note), 0)
            adw_preferences_row_set_title(
                ptr(note),
                isDemo ? Localized.text("Demo world") : Localized.text("Set by the environment"))
            adw_action_row_set_subtitle(
                ptr(note),
                isDemo
                    ? Localized.text("Nothing here reaches a machine. Leave it to add a real one.")
                    : Localized.text(
                        "TAILSCODE_HOST defines this one, so it can't be edited or removed here."))
            adw_action_row_set_subtitle_lines(ptr(note), 0)
            adw_expander_row_add_row(ptr(row), note)
        } else {
            let address = Self.entryRow(title: Localized.text("Address"), tooltip: nil)
            gtk_editable_set_text(op(address), Self.editableAddress(profile))
            adw_entry_row_set_show_apply_button(ptr(address), 1)
            slots.address = address
            let id = profile.id
            Gtk.connect(UnsafeMutableRawPointer(address), "apply") { [weak self] in
                self?.applyAddress(id)
            }
            adw_expander_row_add_row(ptr(row), address)

            let name = Self.entryRow(title: Localized.text("Name"), tooltip: nil)
            gtk_editable_set_text(op(name), profile.name)
            adw_entry_row_set_show_apply_button(ptr(name), 1)
            slots.name = name
            Gtk.connect(UnsafeMutableRawPointer(name), "apply") { [weak self] in
                self?.applyName(id)
            }
            adw_expander_row_add_row(ptr(row), name)

            let password = Self.passwordRow(title: Localized.text("Password"))
            gtk_widget_set_tooltip_text(
                password,
                Localized.text(
                    "A stored password is never shown. Type a new one to replace it, or apply an empty field to connect without one."
                ))
            adw_entry_row_set_show_apply_button(ptr(password), 1)
            slots.password = password
            Gtk.connect(UnsafeMutableRawPointer(password), "apply") { [weak self] in
                self?.applyPassword(id)
            }
            adw_expander_row_add_row(ptr(row), password)
        }

        if !isDemo {
            let restart = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(restart), 0)
            adw_preferences_row_set_title(ptr(restart), ServerRestart.title)
            adw_action_row_set_subtitle(ptr(restart), ServerRestart.detail)
            adw_action_row_set_subtitle_lines(ptr(restart), 0)
            let id = profile.id
            let name = profile.name
            let agent = profile.backend
            adw_action_row_add_suffix(
                ptr(restart),
                Self.inlineButton(ServerRestart.action, css: []) { [weak self] in
                    self?.confirmRestart(id: id, name: name, agent: agent)
                })
            adw_expander_row_add_row(ptr(row), restart)
        }

        if !isDemo {
            let delegateRow = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(delegateRow), 0)
            adw_preferences_row_set_title(ptr(delegateRow), DelegateEntryPoint.serverRowTitle)
            adw_action_row_set_subtitle(ptr(delegateRow), DelegateEntryPoint.subtitle)
            adw_action_row_set_subtitle_lines(ptr(delegateRow), 0)
            gtk_list_box_row_set_activatable(ptr(delegateRow), 1)
            let chevron = Gtk.label("›", css: "dim", selectable: false)
            gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
            adw_action_row_add_suffix(ptr(delegateRow), chevron)
            let delegateHost = profile.baseURL.host ?? profile.name
            Gtk.connect(UnsafeMutableRawPointer(delegateRow), "activated") { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, let window = self.window else { return }
                    DelegateWindow.present(parent: window, host: delegateHost)
                }
            }
            adw_expander_row_add_row(ptr(row), delegateRow)
        }

        if !isDemo, let previewHost = profile.baseURL.host {
            let previews = PreviewHostRow(host: previewHost)
            slots.previewHost = previews
            previews.add(to: row)
        }

        if !isEnvironment {
            let remove = adw_action_row_new()!
            adw_preferences_row_set_use_markup(ptr(remove), 0)
            adw_preferences_row_set_title(
                ptr(remove),
                isDemo ? Localized.text("Leave the demo") : Localized.text("Remove this server"))
            adw_action_row_set_subtitle(
                ptr(remove),
                Localized.text("Conversations stay on the machine — only this app forgets it."))
            adw_action_row_set_subtitle_lines(ptr(remove), 0)
            let id = profile.id
            let name = profile.name
            adw_action_row_add_suffix(
                ptr(remove),
                Self.inlineButton(Localized.text("Remove"), css: ["destructive-action"]) {
                    [weak self] in
                    self?.confirmRemove(id: id, name: name)
                })
            adw_expander_row_add_row(ptr(row), remove)
        }

        checkHealth(profile)
        if !isDemo { UpdateWatch.recheck(.server(profileID: profile.id)) }
        if profile.backend == .claudeCode && !isDemo {
            checkAccount(profile)
            checkPermissions(profile)
        }
        return row
    }
}
