//
//  CalendarTab.swift
//  snoodle
//

import SwiftUI
import Foundation
import FirebaseFirestore
import FirebaseStorage
import Combine

struct CalendarTab: View {
    @EnvironmentObject var store: SnoodleStore
    @State private var selectedDate: Date? = nil
    @State private var displayMonth: Date = Date()
    @State private var selectedDayIndex: Int? = nil
    @State private var showingDetail: Bool = false

    private let cal = Calendar.current
    private let monthFmt: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "MMMM yyyy"; return df
    }()
    private let dayFmt: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "d"; return df
    }()
    private let tileFmt: DateFormatter = {
        let df = DateFormatter(); df.dateFormat = "h:mm a"; return df
    }()

    var daysInMonth: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: displayMonth),
              let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth)) else { return [] }
        let weekday = cal.component(.weekday, from: firstDay) - 1
        var days: [Date?] = Array(repeating: nil, count: weekday)
        for day in range {
            if let date = cal.date(byAdding: .day, value: day - 1, to: firstDay) {
                days.append(date)
            }
        }
        return days
    }

    var dayEntries: [SnoodleEntry] {
        guard let date = selectedDate else { return [] }
        return store.entries(for: date)
    }

    // Last snoodle of the day (most recent timestamp)
    func lastEntry(for date: Date) -> SnoodleEntry? {
        store.entries(for: date).sorted { $0.timestamp > $1.timestamp }.first
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Month navigation
                HStack {
                    Button(action: { changeMonth(-1) }) {
                        Image(systemName: "chevron.left").font(.system(size: 20, weight: .semibold))
                    }
                    Spacer()
                    Text(monthFmt.string(from: displayMonth))
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Button(action: { changeMonth(1) }) {
                        Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                // Day of week headers
                HStack(spacing: 0) {
                    ForEach(["S","M","T","W","T","F","S"], id: \.self) { d in
                        Text(d).font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 6)

                // Calendar grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                    ForEach(daysInMonth.indices, id: \.self) { i in
                        if let date = daysInMonth[i] {
                            let count = store.entries(for: date).count
                            let isToday = cal.isDateInToday(date)
                            let isSelected = selectedDate.map { cal.isDate($0, inSameDayAs: date) } ?? false
                            let thumbnail = lastEntry(for: date)

                            ZStack(alignment: .topTrailing) {
                                VStack(spacing: 2) {
                                    // Thumbnail or plain day number
                                    if let entry = thumbnail {
                                        ZStack(alignment: .bottom) {
                                            GeometryReader { geo in
                                                AsyncThumbnailImage(entry: entry)
                                                    .frame(width: geo.size.width, height: geo.size.width)
                                                    .clipped()
                                                    .cornerRadius(8)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 8)
                                                            .stroke(isSelected ? Color.purple : (isToday ? Color.blue : Color.clear), lineWidth: 2)
                                                    )
                                            }

                                            // Day number overlay at bottom
                                            Text(dayFmt.string(from: date))
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.white)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(Color.black.opacity(0.45))
                                                .cornerRadius(4)
                                                .padding(3)
                                        }
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    } else {
                                        // Empty day
                                        Text(dayFmt.string(from: date))
                                            .font(.system(size: 16, weight: isToday ? .bold : .regular))
                                            .foregroundColor(isToday ? .white : .secondary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(isToday ? Color.blue : Color(UIColor.secondarySystemBackground))
                                            .cornerRadius(8)
                                    }
                                }

                                // Count badge
                                if count > 1 {
                                    Text("\(count)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Color.purple)
                                        .clipShape(Circle())
                                        .offset(x: 2, y: -2)
                                }
                            }
                            .aspectRatio(1, contentMode: .fit)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if count == 1 {
                                    selectedDate = date
                                    selectedDayIndex = 0
                                } else {
                                    selectedDate = date
                                    selectedDayIndex = nil
                                }
                            }
                        } else {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                        }
                    }
                }
                .padding(.horizontal, 4)

                Divider().padding(.top, 12)

                // Day detail grid
                if let _ = selectedDate {
                    if dayEntries.isEmpty {
                        Text("No doodles this day").foregroundColor(.secondary).padding(.top, 40)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                                ForEach(dayEntries, id: \.id) { entry in
                                    SnoodleTile(entry: entry, dateFmt: tileFmt)
                                        .onTapGesture {
                                            if let i = dayEntries.firstIndex(where: { $0.id == entry.id }) {
                                                selectedDayIndex = i
                                            }
                                        }
                                }
                            }
                            .padding(12)
                        }
                    }
                } else {
                    VStack {
                        Spacer()
                        Text("Tap a day to see your doodles")
                            .foregroundColor(.secondary).font(.system(size: 15))
                        Spacer()
                    }
                }
            }
            .background(
                LinearGradient(
                    colors: [Color(red: 0.92, green: 0.88, blue: 0.98), Color(UIColor.systemBackground)],
                    startPoint: .top,
                    endPoint: .bottom
                ).ignoresSafeArea()
            )
            .navigationTitle("Calendar")
            .fullScreenCover(item: Binding(
                get: { selectedDayIndex.map { IdentifiableInt(value: $0) } },
                set: { selectedDayIndex = $0?.value }
            )) { idx in
                SnoodleDetailView(entries: dayEntries, startIndex: idx.value)
                    .environmentObject(store)
            }
        }
    }

    func changeMonth(_ delta: Int) {
        if let newMonth = cal.date(byAdding: .month, value: delta, to: displayMonth) {
            displayMonth = newMonth
            selectedDate = nil
        }
    }
}

// MARK: - Settings Tab

