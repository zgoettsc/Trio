import SwiftUI

/// Individual meal card in the V2 meal feed. Shows macro breakdown, source, timing,
/// and a checkbox for selection. Already-dosed meals are dimmed.
struct V2MealCardView: View {
    let meal: V2DetectedMeal
    let isSelected: Bool
    let isDosed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 12) {
                // Selection indicator
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    // Meal name and time
                    HStack {
                        Text(meal.label)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(meal.date, style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Macros
                    HStack(spacing: 10) {
                        macroChip("C", value: meal.carbs, color: .orange)
                        macroChip("F", value: meal.fat, color: .yellow)
                        macroChip("P", value: meal.protein, color: .red)
                    }

                    // Source and timing
                    HStack(spacing: 6) {
                        if isDosed {
                            HStack(spacing: 3) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption2)
                                Text("Dosed")
                                    .font(.caption2)
                                    .foregroundStyle(.green)
                            }
                        }

                        Text("via \(meal.source)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(timeAgoText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // Warning for already-dosed meals
                    if isDosed && isSelected {
                        Text("This meal was already dosed. Selecting it will add additional insulin coverage.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.vertical, 4)
            .opacity(isDosed && !isSelected ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
    }

    private var timeAgoText: String {
        let minutes = Date().timeIntervalSince(meal.date) / 60
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(Int(minutes)) min ago" }
        let hours = minutes / 60
        if hours < 1.5 { return "1 hour ago" }
        return String(format: "%.1fh ago", hours)
    }

    private func macroChip(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(color)
            Text("\(Int(value))g")
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .cornerRadius(4)
    }
}
