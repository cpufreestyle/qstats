//
//  settings.swift
//  Memory
//
//  Created by Serhiy Mytrovtsiy on 11/07/2020.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2020 Serhiy Mytrovtsiy. All rights reserved.
//

import Cocoa
import Kit

var textWidgetHelp = """
<h2>Description</h2>
You can use a combination of any of the variables.
<h3>Examples:</h3>
<ul>
<li>$mem.used/$mem.total ($pressure.value)</li>
<li>Pressure: $pressure.value</li>
<li>Free: $mem.free</li>
</ul>
<h2>Available variables</h2>
<ul>
<li><b>$mem.total</b>: <small>Total RAM memory.</small></li>
<li><b>$mem.used</b>: <small>Used RAM memory.</small></li>
<li><b>$mem.free</b>: <small>Free RAM memory.</small></li>
<li><b>$mem.active</b>: <small>Active RAM memory.</small></li>
<li><b>$mem.inactive</b>: <small>Inactive RAM memory.</small></li>
<li><b>$mem.wired</b>: <small>Wired RAM memory.</small></li>
<li><b>$mem.compressed</b>: <small>Compressed RAM memory.</small></li>
<li><b>$mem.app</b>: <small>Used RAM memory by applications.</small></li>
<li><b>$mem.cache</b>: <small>Cached RAM memory.</small></li>
<li><b>$mem.swapins</b>: <small>The number of memory pages loaded in from virtual memory to physical memory.</small></li>
<li><b>$mem.swapouts</b>: <small>The number of memory pages swapped out to physical memory from virtual memory.</small></li>
<li><b>$swap.total</b>: <small>Total swap memory.</small></li>
<li><b>$swap.used</b>: <small>Used swap memory.</small></li>
<li><b>$swap.free</b>: <small>Free swap memory.</small></li>
<li><b>$pressure.value</b>: <small>Pressure value (normal, warning, critical).</small></li>
<li><b>$pressure.level</b>: <small>Pressure level (1, 2, 4).</small></li>
</ul>
"""

internal class Settings: NSStackView, Settings_v, NSTextFieldDelegate {
    private var updateIntervalValue: Int = 1
    private var updateTopIntervalValue: Int = 1
    private var numberOfProcesses: Int = 8
    private var splitValueState: Bool = false
    private var notificationLevel: String = "Disabled"
    private var textValue: String = "$mem.used/$mem.total ($pressure.value)"
    private var combinedProcessesState: Bool = false

    // Memory optimizer settings (new)
    private var autoPurgeEnabled: Bool = false
    private var autoPurgeThreshold: Int = 80
    private var autoPurgeInterval: Int = 30
    private var autoPurgeSystemPurge: Bool = false

    private let title: String
    
    public var callback: (() -> Void) = {}
    public var callbackWhenUpdateNumberOfProcesses: (() -> Void) = {}
    public var setInterval: ((_ value: Int) -> Void) = {_ in }
    public var setTopInterval: ((_ value: Int) -> Void) = {_ in }
    
    private let textWidgetHelpPanel: HelpHUD = HelpHUD(textWidgetHelp)
    
    public init(_ module: ModuleType) {
        self.title = module.stringValue
        self.updateIntervalValue = Store.shared.int(key: "\(self.title)_updateInterval", defaultValue: self.updateIntervalValue)
        self.updateTopIntervalValue = Store.shared.int(key: "\(self.title)_updateTopInterval", defaultValue: self.updateTopIntervalValue)
        self.numberOfProcesses = Store.shared.int(key: "\(self.title)_processes", defaultValue: self.numberOfProcesses)
        self.splitValueState = Store.shared.bool(key: "\(self.title)_splitValue", defaultValue: self.splitValueState)
        self.notificationLevel = Store.shared.string(key: "\(self.title)_notificationLevel", defaultValue: self.notificationLevel)
        self.textValue = Store.shared.string(key: "\(self.title)_textWidgetValue", defaultValue: self.textValue)
        self.combinedProcessesState = Store.shared.bool(key: "\(self.title)_combinedProcesses", defaultValue: self.combinedProcessesState)
        self.autoPurgeEnabled = Store.shared.bool(key: "RAM_autoPurge", defaultValue: self.autoPurgeEnabled)
        self.autoPurgeThreshold = Store.shared.int(key: "RAM_autoPurgeThreshold", defaultValue: self.autoPurgeThreshold)
        self.autoPurgeInterval = Store.shared.int(key: "RAM_autoPurgeInterval", defaultValue: self.autoPurgeInterval)
        self.autoPurgeSystemPurge = Store.shared.bool(key: "RAM_autoPurgeSystemPurge", defaultValue: self.autoPurgeSystemPurge)

        super.init(frame: NSRect.zero)
        
        self.orientation = .vertical
        self.distribution = .gravityAreas
        self.spacing = Constants.Settings.margin
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public func load(widgets: [widget_t]) {
        self.subviews.forEach{ $0.removeFromSuperview() }
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Update interval"), component: selectView(
                action: #selector(self.changeUpdateInterval),
                items: ReaderUpdateIntervals,
                selected: "\(self.updateIntervalValue)"
            )),
            PreferencesRow(localizedString("Update interval for top processes"), component: selectView(
                action: #selector(self.changeUpdateTopInterval),
                items: ReaderUpdateIntervals,
                selected: "\(self.updateTopIntervalValue)"
            ))
        ]))
        
        self.addArrangedSubview(PreferencesSection([
            PreferencesRow(localizedString("Combined processes"), component: switchView(
                action: #selector(toggleCombinedProcesses),
                state: self.combinedProcessesState
            )),
            PreferencesRow(localizedString("Number of top processes"), component: selectView(
                action: #selector(changeNumberOfProcesses),
                items: NumbersOfProcesses.map{ KeyValue_t(key: "\($0)", value: "\($0)") },
                selected: "\(self.numberOfProcesses)"
            ))
        ]))
        
        if !widgets.filter({ $0 == .barChart }).isEmpty {
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(localizedString("Split the value (App/Wired/Compressed)"), component: switchView(
                    action: #selector(toggleSplitValue),
                    state: self.splitValueState
                ))
            ]))
        }
        
        if widgets.contains(where: { $0 == .text }) {
            let textField = self.inputField(id: "text", value: self.textValue, placeholder: localizedString("This will be visible in the text widget"))
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow(localizedString("Text widget value"), component: textField) { [weak self] in
                    self?.textWidgetHelpPanel.show()
                }
            ]))
        }

        self.addArrangedSubview(PreferencesSection([
            PreferencesRow("Memory optimizer", component: switchView(
                action: #selector(toggleAutoPurge),
                state: self.autoPurgeEnabled
            ))
        ]))

        if self.autoPurgeEnabled {
            self.addArrangedSubview(PreferencesSection([
                PreferencesRow("Reclaim when used memory exceeds \(self.autoPurgeThreshold)%", component: self.thresholdSlider),
                PreferencesRow("Check interval", component: selectView(
                    action: #selector(changeAutoPurgeInterval),
                    items: [5, 15, 30, 60].map { KeyValue_t(key: "\($0)", value: "\($0) min") },
                    selected: "\(self.autoPurgeInterval)"
                )),
                PreferencesRow("Use system 'purge' (needs passwordless sudo)", component: switchView(
                    action: #selector(toggleAutoPurgeSystemPurge),
                    state: self.autoPurgeSystemPurge
                ))
            ]))
        }
    }

    private var thresholdSlider: NSView {
        let slider = NSSlider(value: Double(self.autoPurgeThreshold), minValue: 50, maxValue: 95, target: self, action: #selector(changeAutoPurgeThreshold(_:)))
        slider.numberOfTickMarks = 46
        slider.allowsTickMarkValuesOnly = false
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return slider
    }

    @objc private func changeAutoPurgeThreshold(_ sender: NSSlider) {
        self.autoPurgeThreshold = Int(sender.doubleValue)
        Store.shared.set(key: "RAM_autoPurgeThreshold", value: self.autoPurgeThreshold)
        AutoPurgeManager.shared.start(intervalMinutes: self.autoPurgeInterval, thresholdPercent: self.autoPurgeThreshold, useSystemPurge: self.autoPurgeSystemPurge)
    }
    @objc private func changeAutoPurgeInterval(_ sender: NSMenuItem) {
        guard let value = Int(sender.title.replacingOccurrences(of: " min", with: "")) else { return }
        self.autoPurgeInterval = value
        Store.shared.set(key: "RAM_autoPurgeInterval", value: value)
        AutoPurgeManager.shared.start(intervalMinutes: self.autoPurgeInterval, thresholdPercent: self.autoPurgeThreshold, useSystemPurge: self.autoPurgeSystemPurge)
    }
    @objc private func toggleAutoPurge(_ sender: NSControl) {
        self.autoPurgeEnabled = controlState(sender)
        Store.shared.set(key: "RAM_autoPurge", value: self.autoPurgeEnabled)
        if self.autoPurgeEnabled {
            AutoPurgeManager.shared.start(intervalMinutes: self.autoPurgeInterval, thresholdPercent: self.autoPurgeThreshold, useSystemPurge: self.autoPurgeSystemPurge)
        } else {
            AutoPurgeManager.shared.stop()
        }
    }
    @objc private func toggleAutoPurgeSystemPurge(_ sender: NSControl) {
        self.autoPurgeSystemPurge = controlState(sender)
        Store.shared.set(key: "RAM_autoPurgeSystemPurge", value: self.autoPurgeSystemPurge)
        if self.autoPurgeEnabled {
            AutoPurgeManager.shared.start(intervalMinutes: self.autoPurgeInterval, thresholdPercent: self.autoPurgeThreshold, useSystemPurge: self.autoPurgeSystemPurge)
        }
    }
    
    private func inputField(id: String, value: String, placeholder: String) -> NSView {
        let field: NSTextField = NSTextField()
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.widthAnchor.constraint(equalToConstant: 250).isActive = true
        field.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        field.textColor = .textColor
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.focusRingType = .none
        field.stringValue = value
        field.delegate = self
        field.placeholderString = placeholder
        return field
    }
    
    @objc private func changeUpdateInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.updateIntervalValue = value
        Store.shared.set(key: "\(self.title)_updateInterval", value: value)
        self.setInterval(value)
    }
    @objc private func changeUpdateTopInterval(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, let value = Int(key) else { return }
        self.updateTopIntervalValue = value
        Store.shared.set(key: "\(self.title)_updateTopInterval", value: value)
        self.setTopInterval(value)
    }
    @objc private func changeNumberOfProcesses(_ sender: NSMenuItem) {
        if let value = Int(sender.title) {
            self.numberOfProcesses = value
            Store.shared.set(key: "\(self.title)_processes", value: value)
            self.callbackWhenUpdateNumberOfProcesses()
        }
    }
    @objc private func toggleSplitValue(_ sender: NSControl) {
        self.splitValueState = controlState(sender)
        Store.shared.set(key: "\(self.title)_splitValue", value: self.splitValueState)
        self.callback()
    }
    @objc private func toggleCombinedProcesses(_ sender: NSControl) {
        self.combinedProcessesState = controlState(sender)
        Store.shared.set(key: "\(self.title)_combinedProcesses", value: self.combinedProcessesState)
        self.callback()
    }
    
    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField {
            if field.identifier == NSUserInterfaceItemIdentifier("text") {
                self.textValue = field.stringValue
                Store.shared.set(key: "\(self.title)_textWidgetValue", value: self.textValue)
            }
        }
    }
}
