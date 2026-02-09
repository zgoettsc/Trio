import SwiftUI

/// Simple macro entry form for users who don't use Cronometer.
/// Creates a V2DetectedMeal in the meal feed when the user taps "Add Meal".
struct V2ManualMealEntryView: View {
    @Binding var carbs: Decimal
    @Binding var fat: Decimal
    @Binding var protein: Decimal
    @Binding var fiber: Decimal

    let onAdd: (Decimal, Decimal, Decimal, Decimal) -> Void
    let onDismiss: () -> Void

    private var mealFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumIntegerDigits = 3
        f.maximumFractionDigits = 0
        return f
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Meal Macros")) {
                    HStack {
                        Text("Carbs (g)")
                        Spacer()
                        TextField("0", value: $carbs, formatter: mealFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("Fat (g)")
                        Spacer()
                        TextField("0", value: $fat, formatter: mealFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("Protein (g)")
                        Spacer()
                        TextField("0", value: $protein, formatter: mealFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }

                    HStack {
                        Text("Fiber (g)")
                        Spacer()
                        TextField("0", value: $fiber, formatter: mealFormatter)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }

                Section {
                    Button {
                        onAdd(carbs, fat, protein, fiber)
                    } label: {
                        Text("Add Meal")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .disabled(carbs <= 0 && fat <= 0 && protein <= 0)
                }
            }
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }
}
