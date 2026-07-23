import AwesoMuxBridgeProtocol
import Charts
import DesignSystem
import SwiftUI

struct DiagnosticsSettingsPane: View {
    private static let relativeDateTimeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    @Environment(DiagnosticsModel.self) private var model
    @State private var historyWindow: DiagnosticsHistoryWindow = .fifteenMinutes
    @State private var metric: DiagnosticsMetric = .cpu
    @State private var issueScope: LocalDiagnosticIssueScope = .all
    @State private var eventCategory: LocalDiagnosticCategory?
    @State private var openGroups = Set<String>()
    @State private var initializedDisclosureState = false

    private var presentation: DiagnosticsPresentation { model.presentation }

    // MARK: - Page

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            localHeader
            refreshStatus

            SettingsSection(
                index: 1,
                title: String(localized: "Live processes", comment: "Diagnostics settings section title"),
                subtitle: String(
                    localized: "awesoMux, background sessions, shells, agents, and command-bridge daemons.",
                    comment: "Diagnostics settings section subtitle")
            ) {
                liveProcesses
            }

            SettingsSection(
                index: 2,
                title: String(localized: "Resource history", comment: "Diagnostics settings section title"),
                subtitle: String(
                    localized: "After Refresh, sampled every 30 seconds while this pane is visible.",
                    comment: "Diagnostics settings section subtitle")
            ) {
                resourceHistory
            }

            SettingsSection(
                index: 3,
                title: String(localized: "Diagnostic events", comment: "Diagnostics settings section title"),
                subtitle: String(
                    localized: "Runtime issues plus restore, configuration, and terminal outcomes from this launch.",
                    comment: "Diagnostics settings section subtitle")
            ) {
                diagnosticEvents
            }

        }
        .onAppear {
            model.startSampling()
        }
        .onDisappear { model.stopSampling() }
        .onChange(of: presentation.revision) {
            initializeDisclosuresIfNeeded()
        }
        .onChange(of: model.refreshState) { previous, current in
            announceRefreshStateChange(from: previous, to: current)
        }
        .onChange(of: issueScope) {
            announceMatchingEventCount()
        }
        .onChange(of: eventCategory) {
            announceMatchingEventCount()
        }
    }

    // MARK: - Header and refresh

    private var localHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                localOnlyLabel
                freshnessLabel
                Spacer(minLength: 12)
                refreshButton
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    localOnlyLabel
                    freshnessLabel
                }
                refreshButton
            }
        }
        .padding(.bottom, 18)
    }

    private var localOnlyLabel: some View {
        Label("Local only", systemImage: "lock.shield")
            .awFont(AwFont.Mono.meta)
            .foregroundStyle(Color.aw.text)
            .accessibilityHint("Diagnostics in this pane stay on this Mac.")
    }

    private var freshnessLabel: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(freshnessText(at: context.date))
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refresh() }
        } label: {
            HStack(spacing: 6) {
                if model.refreshState == .refreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityHidden(true)
                }
                Text(
                    model.refreshState == .refreshing
                        ? String(localized: "Refreshing", comment: "Diagnostics refresh button busy state")
                        : String(localized: "Refresh all", comment: "Diagnostics refresh button"))
            }
        }
        .disabled(model.refreshState == .refreshing)
        .accessibilityHint("Collects a fresh process sample and shows the newest local events.")
    }

    @ViewBuilder
    private var refreshStatus: some View {
        switch model.refreshState {
        case .idle, .refreshing:
            EmptyView()
        case .partial:
            statusBanner(
                icon: "exclamationmark.triangle",
                text: String(
                    localized: "Session daemons could not be listed. App process data is current.",
                    comment: "Diagnostics partial refresh status"),
                color: Color.aw.peach
            )
        case let .failed(lastSuccess):
            statusBanner(
                icon: "xmark.octagon",
                text: lastSuccess == nil
                    ? String(
                        localized: "Process data could not be collected. Try refreshing again.",
                        comment: "Diagnostics failed refresh status")
                    : String(
                        localized: "Refresh failed. The last successful process snapshot is still shown.",
                        comment: "Diagnostics failed refresh status"),
                color: Color.aw.red
            )
        }
    }

    private func statusBanner(icon: String, text: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .awFont(AwFont.UI.meta)
            .foregroundStyle(Color.aw.text)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: AwRadius.button))
            .overlay {
                RoundedRectangle(cornerRadius: AwRadius.button)
                    .stroke(color.opacity(0.45), lineWidth: 0.5)
            }
            .padding(.bottom, 18)
    }

    // MARK: - Live processes

    @ViewBuilder
    private var liveProcesses: some View {
        if let snapshot = presentation.processSnapshot {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 118), spacing: 8)],
                    spacing: 8
                ) {
                    metricCard(label: "Child processes", value: "\(snapshot.childProcessCount)")
                    metricCard(label: "Aggregate CPU", value: percent(snapshot.aggregateCPUPercent))
                    metricCard(label: "Resident memory", value: bytes(snapshot.aggregateResidentBytes))
                    metricCard(label: "awesoMux PID", value: "\(snapshot.appPID)")
                }

                Text(
                    String(
                        localized: "CPU is measured per core: 100% = one fully used core, 200% = two.",
                        comment: "Explanation of CPU percentages in Diagnostics"
                    )
                )
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text2)
                .fixedSize(horizontal: false, vertical: true)

                if !snapshot.appProcesses.isEmpty {
                    let cpuPercent = snapshot.appProcesses.reduce(0) { $0 + $1.cpuPercent }
                    let residentBytes = snapshot.appProcesses.reduce(0) { $0 + $1.residentBytes }
                    processDisclosure(
                        key: "app",
                        title: String(localized: "awesoMux runtime", comment: "Diagnostics app process group"),
                        processes: snapshot.appProcesses,
                        cpuPercent: cpuPercent,
                        residentBytes: residentBytes
                    )
                }

                ForEach(snapshot.groups) { group in
                    processDisclosure(
                        key: group.id.rawValue,
                        title: group.title,
                        processes: group.processes,
                        cpuPercent: group.cpuPercent,
                        residentBytes: group.residentBytes
                    )
                }
            }
            .padding(.top, 18)
        } else {
            emptyCard(
                title: "No process snapshot yet",
                detail: "Refresh to collect local CPU and memory data."
            )
            .padding(.top, 18)
        }
    }

    private func metricCard(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text)
            Text(value)
                .awFont(AwFont.Mono.body)
                .fontWeight(.semibold)
                .foregroundStyle(Color.aw.text)
                .monospacedDigit()
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func processDisclosure(
        key: String,
        title: String,
        processes: [DiagnosticsProcess],
        cpuPercent: Double,
        residentBytes: Int64
    ) -> some View {
        DisclosureGroup(isExpanded: disclosureBinding(key)) {
            processTable(processes)
                .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: key == "app" ? "macwindow" : "terminal")
                    .foregroundStyle(Color.aw.text)
                    .accessibilityHidden(true)
                Text(title)
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(
                    processGroupSubtitle(
                        count: processes.count,
                        cpuPercent: cpuPercent,
                        residentBytes: residentBytes
                    )
                )
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
                .monospacedDigit()
            }
        }
        .padding(10)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
        .accessibilityLabel(title)
        .accessibilityValue(
            processGroupAccessibilityValue(
                count: processes.count,
                cpuPercent: cpuPercent,
                residentBytes: residentBytes
            ))
    }

    private func processTable(_ processes: [DiagnosticsProcess]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                processTableRow(
                    kind: String(localized: "Type", comment: "Diagnostics process table column"),
                    name: String(localized: "Name", comment: "Diagnostics process table column"),
                    pid: String(localized: "PID", comment: "Diagnostics process table column"),
                    cpu: String(localized: "CPU", comment: "Diagnostics process table column"),
                    memory: String(localized: "Memory", comment: "Diagnostics process table column"),
                    executable: String(localized: "Executable", comment: "Diagnostics process table column"),
                    isHeader: true
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                ForEach(processes) { process in
                    processTableRow(
                        kind: process.kind.displayName,
                        name: process.name,
                        pid: "\(process.pid)",
                        cpu: percent(process.cpuPercent),
                        memory: bytes(process.residentBytes),
                        executable: process.executablePath,
                        systemImage: process.kind.systemImage
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        String(
                            localized:
                                "\(process.kind.displayName), \(process.name), PID \(process.pid), CPU \(percent(process.cpuPercent)), memory \(bytes(process.residentBytes)), executable \(process.executablePath)",
                            comment: "VoiceOver summary for a Diagnostics process row"
                        )
                    )
                }
            }
            .frame(minWidth: 760, alignment: .leading)
        }
    }

    private func processTableRow(
        kind: String,
        name: String,
        pid: String,
        cpu: String,
        memory: String,
        executable: String,
        systemImage: String? = nil,
        isHeader: Bool = false
    ) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 13)
                        .accessibilityHidden(true)
                }
                Text(kind)
            }
            .frame(width: 82, alignment: .leading)
            Text(name).frame(width: 100, alignment: .leading)
            Text(pid).frame(width: 58, alignment: .trailing)
            Text(cpu).frame(width: 68, alignment: .trailing)
            Text(memory).frame(width: 82, alignment: .trailing)
            Text(executable)
                .frame(width: 300, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .awFont(isHeader ? AwFont.Mono.kicker : AwFont.Mono.meta)
        .foregroundStyle(Color.aw.text)
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(isHeader ? Color.aw.surface.chrome : Color.clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
        }
    }

    // MARK: - Resource history

    private var resourceHistory: some View {
        let projection = presentation.history.projection(
            metric: metric,
            window: historyWindow.duration,
            now: chartNow
        )
        return resourceHistoryCard(projection)
            .padding(.top, 18)
    }

    private func resourceHistoryCard(_ projection: DiagnosticsHistoryProjection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text("\(metric.displayName) usage")
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text)
                    Spacer(minLength: 12)
                    metricPicker
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(metric.displayName) usage")
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text)
                    metricPicker
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            historyWindowPicker
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)

            cardDivider

            historyMetrics(projection.summary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            cardDivider

            historyChart(projection)
                .padding(14)
        }
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
    }

    private var historyWindowPicker: some View {
        Picker("History window", selection: $historyWindow) {
            ForEach(DiagnosticsHistoryWindow.allCases) { window in
                Text(window.compactLabel)
                    .accessibilityLabel(window.accessibilityLabel)
                    .tag(window)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("History window")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var metricPicker: some View {
        Picker("Chart metric", selection: $metric) {
            ForEach(DiagnosticsMetric.allCases, id: \.self) { metric in
                Text(metric.displayName).tag(metric)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Chart metric")
        .fixedSize(horizontal: true, vertical: false)
    }

    private func historyMetrics(_ summary: DiagnosticsHistorySummary) -> some View {
        let hasSamples = summary.sampleCount > 0
        let emptyValue = String(
            localized: "Unavailable",
            comment: "Diagnostics history metric with no samples yet"
        )
        return HStack(spacing: 0) {
            historyMetric(label: "Current", value: hasSamples ? historyValue(summary.current) : emptyValue)
            inlineDivider
            historyMetric(label: "Average", value: hasSamples ? historyValue(summary.average) : emptyValue)
            inlineDivider
            historyMetric(label: "Peak", value: hasSamples ? historyValue(summary.peak) : emptyValue)
            inlineDivider
            historyMetric(
                label: "Trend",
                value: hasSamples
                    ? summary.trend.displayName
                    : String(localized: "Collecting", comment: "Diagnostics history state")
            )
        }
    }

    private func historyMetric(label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)
            Text(value)
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func historyChart(_ projection: DiagnosticsHistoryProjection) -> some View {
        if projection.samples.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("History is collecting")
                    .awFont(AwFont.UI.label)
                    .foregroundStyle(Color.aw.text)
                Text("Select Refresh all to begin; samples continue while this pane is visible.")
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        } else {
            Chart(projection.samples) { sample in
                BarMark(
                    x: .value("Time", sample.timestamp),
                    y: .value(metric.displayName, chartValue(sample))
                )
                .foregroundStyle(metric == .cpu ? Color.aw.accent : Color.aw.teal)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.aw.border)
                    AxisValueLabel {
                        if let value = value.as(Double.self) {
                            if metric == .cpu {
                                Text(value.formatted(.number.precision(.fractionLength(0))))
                            } else {
                                Text(
                                    "\(value.formatted(.number.precision(.fractionLength(0)))) MB"
                                )
                            }
                        }
                    }
                }
            }
            .frame(height: 176)
            // Chart is decorative; Current/Average/Peak/Trend above carry meaning (design).
            .accessibilityHidden(true)
        }
    }

    // MARK: - Diagnostic events

    private var diagnosticEvents: some View {
        let matching = presentation.events.filtered(scope: issueScope, category: eventCategory)
        let visible = LocalDiagnosticEventSnapshot.visibleEvents(
            matching,
            limit: LocalDiagnosticEventSnapshot.maxVisibleEvents
        )
        let truncationNotice = LocalizedPluralStrings.diagnosticsShowingMatchingEvents(
            visible: visible.count,
            total: matching.count
        )
        return VStack(alignment: .leading, spacing: 0) {
            eventFilters
                .padding(12)

            eventMetrics
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            cardDivider

            if matching.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No matching diagnostics")
                        .awFont(AwFont.UI.label)
                        .foregroundStyle(Color.aw.text)
                    Text("Try another filter or refresh the pane.")
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)

                cardDivider
            } else {
                if matching.count > visible.count {
                    Text(truncationNotice)
                        .awFont(AwFont.UI.meta)
                        .foregroundStyle(Color.aw.text)
                        .padding(.horizontal, 12)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                        .accessibilityLabel(truncationNotice)
                }
                // Plain VStack: this list sits inside SettingsShell's outer ScrollView,
                // so LazyVStack cannot virtualize (unbounded height). Cap is 100 rows.
                VStack(spacing: 0) {
                    ForEach(visible) { event in
                        eventRow(event)
                    }
                }
            }

            privacyFooter
                .padding(12)
        }
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(Color.aw.border2, lineWidth: 0.5)
        }
        .padding(.top, 18)
    }

    private var eventFilters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                issueScopePicker
                Spacer(minLength: 12)
                categoryPicker
            }
            VStack(alignment: .leading, spacing: 8) {
                issueScopePicker
                categoryPicker
            }
        }
    }

    private var issueScopePicker: some View {
        Picker("Event severity", selection: $issueScope) {
            ForEach(LocalDiagnosticIssueScope.allCases, id: \.self) { scope in
                Text(scope.displayName).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityLabel("Event severity")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var categoryPicker: some View {
        Picker("Event category", selection: $eventCategory) {
            Text("All categories").tag(LocalDiagnosticCategory?.none)
            ForEach(LocalDiagnosticCategory.allCases, id: \.self) { category in
                Text(category.displayName).tag(Optional(category))
            }
        }
        .labelsHidden()
        .accessibilityLabel("Event category")
        .fixedSize(horizontal: true, vertical: false)
    }

    private var eventMetrics: some View {
        HStack(spacing: 0) {
            eventMetric(label: "Events", value: presentation.events.events.count, color: Color.aw.accent)
            inlineDivider
            eventMetric(label: "Errors", value: presentation.events.errorCount)
            inlineDivider
            eventMetric(label: "Warnings", value: presentation.events.warningCount)
            inlineDivider
            eventMetric(
                label: "Malformed",
                value: presentation.events.malformedOrDroppedCount,
                accessibilityHint: String(
                    localized: "Count of malformed or oversized runtime event payloads ignored this launch",
                    comment: "VoiceOver hint for Diagnostics malformed-event count"
                )
            )
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func eventMetric(
        label: LocalizedStringKey,
        value: Int,
        color: Color = Color.aw.text,
        accessibilityHint: String? = nil
    ) -> some View {
        let content = HStack(spacing: 5) {
            Text("\(value)")
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(color)
            Text(label)
                .awFont(AwFont.UI.meta)
                .foregroundStyle(Color.aw.text)
        }
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)

        if let accessibilityHint {
            content.accessibilityHint(accessibilityHint)
        } else {
            content
        }
    }

    private func eventRow(_ event: LocalDiagnosticEvent) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: eventIcon(event))
                .foregroundStyle(eventColor(event))
                .frame(width: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary)
                    .awFont(AwFont.UI.meta)
                    .foregroundStyle(Color.aw.text)
                    .textSelection(.enabled)
                Text(
                    "\(event.severity.displayName) · \(event.category.displayName) · \(event.timestamp.formatted(date: .omitted, time: .standard))"
                )
                .awFont(AwFont.Mono.meta)
                .foregroundStyle(Color.aw.text)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.aw.border).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var privacyFooter: some View {
        Label(
            "Executable paths and session metadata may be sensitive. Review screenshots or copied text before sharing them.",
            systemImage: "hand.raised"
        )
        .awFont(AwFont.UI.meta)
        .foregroundStyle(Color.aw.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.aw.border)
            .frame(height: 0.5)
    }

    private var inlineDivider: some View {
        Rectangle()
            .fill(Color.aw.border)
            .frame(width: 0.5, height: 24)
            .padding(.horizontal, 10)
    }

    private func emptyCard(title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).awFont(AwFont.UI.label).foregroundStyle(Color.aw.text)
            Text(detail).awFont(AwFont.UI.meta).foregroundStyle(Color.aw.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.aw.surface.elevated, in: RoundedRectangle(cornerRadius: AwRadius.button))
        .overlay {
            RoundedRectangle(cornerRadius: AwRadius.button)
                .stroke(Color.aw.border, lineWidth: 0.5)
        }
    }

    // MARK: - Presentation helpers

    private var chartNow: Date {
        presentation.checkedAt ?? presentation.history.samples.last?.timestamp ?? Date()
    }

    private func chartValue(_ sample: DiagnosticsHistorySample) -> Double {
        metric == .cpu ? sample.cpuPercent : Double(sample.residentBytes) / 1_048_576
    }

    private func historyValue(_ value: Double) -> String {
        metric == .cpu ? percent(value) : bytes(Int64(value))
    }

    private func processGroupSubtitle(count: Int, cpuPercent: Double, residentBytes: Int64) -> String {
        "\(count) · \(percent(cpuPercent)) · \(bytes(residentBytes))"
    }

    private func processGroupAccessibilityValue(count: Int, cpuPercent: Double, residentBytes: Int64) -> String {
        let processCount = LocalizedPluralStrings.diagnosticsProcesses(count: count)
        return String(
            localized: "\(processCount). Aggregate CPU: \(percent(cpuPercent)). Resident memory: \(bytes(residentBytes)).",
            comment: "VoiceOver value for an expandable Diagnostics process group"
        )
    }

    private func disclosureBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { openGroups.contains(key) },
            set: { isOpen in
                if isOpen { openGroups.insert(key) } else { openGroups.remove(key) }
            }
        )
    }

    private func initializeDisclosuresIfNeeded() {
        guard !initializedDisclosureState,
            let snapshot = presentation.processSnapshot
        else { return }
        if let selected = snapshot.groups.first(where: \.isSelected) ?? snapshot.groups.first {
            openGroups = [selected.id.rawValue]
        } else if !snapshot.appProcesses.isEmpty {
            openGroups = ["app"]
        }
        initializedDisclosureState = true
    }

    private func freshnessText(at date: Date) -> String {
        guard let checkedAt = presentation.checkedAt else {
            return String(localized: "Not checked yet", comment: "Diagnostics freshness")
        }
        let seconds = max(0, Int(date.timeIntervalSince(checkedAt)))
        if seconds < 5 {
            return String(localized: "Checked just now", comment: "Diagnostics freshness")
        }
        return String(
            localized: "Checked \(relativeTime(from: checkedAt, to: date))",
            comment: "Diagnostics freshness using a localized relative time"
        )
    }

    private func percent(_ value: Double) -> String {
        value.formatted(
            .percent
                .scale(1)
                .precision(.fractionLength(1))
        )
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    private func relativeTime(from date: Date, to referenceDate: Date) -> String {
        Self.relativeDateTimeFormatter.localizedString(for: date, relativeTo: referenceDate)
    }

    private func announceRefreshStateChange(
        from previous: DiagnosticsRefreshState,
        to current: DiagnosticsRefreshState
    ) {
        // Manual refresh completion.
        if previous == .refreshing, current != .refreshing {
            announceRefreshCompletion(current)
            return
        }
        // Timed sample recovery: banner cleared or degraded without passing through refreshing.
        if case .failed = previous {
            switch current {
            case .idle:
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "Diagnostics sampling recovered. Process data is current.",
                        comment: "VoiceOver when a timed sample clears a failed Diagnostics banner"
                    )
                )
            case .partial:
                TerminalAccessibilityAnnouncer.announce(
                    String(
                        localized: "Diagnostics sampling recovered. Process data is current. Session daemons could not be listed.",
                        comment: "VoiceOver when a timed sample clears a failed banner into partial"
                    )
                )
            case .failed, .refreshing:
                break
            }
            return
        }
        if case .idle = previous, case .partial = current {
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Diagnostics sampling is partial. Session daemons could not be listed.",
                    comment: "VoiceOver when a timed sample discovers daemon list unavailability"
                )
            )
            return
        }
        if case .partial = previous, case .idle = current {
            TerminalAccessibilityAnnouncer.announce(
                String(
                    localized: "Diagnostics sampling recovered. Session daemons are listed again.",
                    comment: "VoiceOver when timed rediscovery clears a partial Diagnostics banner"
                )
            )
        }
    }

    private func announceRefreshCompletion(_ state: DiagnosticsRefreshState) {
        let message: String
        switch state {
        case .idle:
            let processCount = presentation.processSnapshot?.aggregateProcessCount ?? 0
            let processes = LocalizedPluralStrings.diagnosticsProcesses(count: processCount)
            let events = LocalizedPluralStrings.diagnosticsEvents(count: presentation.events.events.count)
            message = String(
                localized: "Diagnostics refreshed. \(processes). \(events).",
                comment: "VoiceOver announcement after refreshing Diagnostics"
            )
        case .partial:
            message = String(
                localized: "Diagnostics partially refreshed. Session daemons could not be listed.",
                comment: "VoiceOver announcement after a partial Diagnostics refresh"
            )
        case let .failed(lastSuccess):
            message =
                lastSuccess == nil
                ? String(
                    localized: "Diagnostics refresh failed. Process data could not be collected.",
                    comment: "VoiceOver announcement after a failed Diagnostics refresh with no prior snapshot"
                )
                : String(
                    localized: "Diagnostics refresh failed. The last successful snapshot remains visible.",
                    comment: "VoiceOver announcement after a failed Diagnostics refresh that kept last-good data"
                )
        case .refreshing:
            return
        }
        TerminalAccessibilityAnnouncer.announce(message)
    }

    private func announceMatchingEventCount() {
        let matching = presentation.events.filtered(scope: issueScope, category: eventCategory)
        let visibleCount = min(matching.count, LocalDiagnosticEventSnapshot.maxVisibleEvents)
        if matching.count > visibleCount {
            TerminalAccessibilityAnnouncer.announce(
                LocalizedPluralStrings.diagnosticsShowingMatchingEvents(
                    visible: visibleCount,
                    total: matching.count
                )
            )
        } else {
            TerminalAccessibilityAnnouncer.announce(
                LocalizedPluralStrings.diagnosticsMatchingEvents(count: matching.count)
            )
        }
    }

    // MARK: - Event styling

    private func eventIcon(_ event: LocalDiagnosticEvent) -> String {
        switch event.severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func eventColor(_ event: LocalDiagnosticEvent) -> Color {
        switch event.severity {
        case .info: Color.aw.sky
        case .warning: Color.aw.peach
        case .error: Color.aw.red
        }
    }
}

private enum DiagnosticsHistoryWindow: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"

    var id: Self { self }

    var compactLabel: String {
        switch self {
        case .fiveMinutes: String(localized: "5m", comment: "Compact Diagnostics history window")
        case .fifteenMinutes: String(localized: "15m", comment: "Compact Diagnostics history window")
        case .thirtyMinutes: String(localized: "30m", comment: "Compact Diagnostics history window")
        case .oneHour: String(localized: "1h", comment: "Compact Diagnostics history window")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .fiveMinutes: String(localized: "5 minutes", comment: "VoiceOver Diagnostics history window")
        case .fifteenMinutes: String(localized: "15 minutes", comment: "VoiceOver Diagnostics history window")
        case .thirtyMinutes: String(localized: "30 minutes", comment: "VoiceOver Diagnostics history window")
        case .oneHour: String(localized: "1 hour", comment: "VoiceOver Diagnostics history window")
        }
    }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        }
    }
}
