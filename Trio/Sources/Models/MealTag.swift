import Foundation

/// User-owned vocabulary for tagging saved meals. Tags belong to one or
/// more categories — `beans` lives in both Protein and Carbs because it
/// is. When analytics asks "show me carb-heavy meals" it gets all meals
/// whose tags have Carbs in `categoryIds`, including beans. Same tag
/// also counts for "show me protein meals." No duplication, no forced
/// pick of the wrong dimension.
///
/// Rename-stable: identity is the UUID, name is mutable. Renaming
/// `chicken` → `chicken thigh` cascades through every tagged meal and
/// the next telemetry push reflects the new name.
struct MealTag: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// Category memberships. Empty == uncategorized (lives only under
    /// the seeded Misc category for the UI, but `categoryIds: []` is
    /// the canonical "no category" state for storage).
    var categoryIds: Set<UUID>
    /// Free-text user note, shown in the management UI.
    var notes: String?

    init(
        id: UUID = UUID(),
        name: String,
        categoryIds: Set<UUID> = [],
        notes: String? = nil
    ) {
        self.id = id
        self.name = name
        self.categoryIds = categoryIds
        self.notes = notes
    }
}

/// Top-level grouping for tags. User-owned: add, rename, delete (with
/// confirmation showing affected tags). Categories are the analytics
/// dimension; tags within them are the user's personal vocabulary.
struct TagCategory: Codable, Equatable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// SwiftUI Color identifier (hex or symbolic). Optional polish for
    /// distinguishing categories in the picker UI.
    var colorHex: String?
    /// SF Symbol name for the category badge (optional).
    var iconSymbol: String?

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String? = nil,
        iconSymbol: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.iconSymbol = iconSymbol
    }
}

// MARK: - Seeded defaults

/// Initial seeded categories + tags. Categories are STABLE in identity
/// (the seeded UUIDs are hardcoded so reinstalls/migrations don't
/// orphan tags). The user can rename / delete / add more freely. Tags
/// are also seeded with stable UUIDs; multi-category membership shown
/// explicitly via the category-id constants.
///
/// Multi-category examples: `beans` in BOTH Protein and Carbs;
/// `salmon` in Protein and Fats; `avocado` in Fats and Vegetables-via-
/// Misc; `tortilla chips` in Carbs and Fats.
enum SeededTags {
    // Stable category UUIDs — hardcoded so they survive
    // reinstall/migration. New IDs ONLY when adding a new seeded
    // category; never change these.
    static let proteinCatID    = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let carbsCatID      = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let fatsCatID       = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static let cuisineCatID    = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    static let styleCatID      = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
    static let formCatID       = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!
    static let sizeCatID       = UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
    static let formatCatID     = UUID(uuidString: "00000000-0000-4000-8000-000000000008")!
    static let descriptorCatID = UUID(uuidString: "00000000-0000-4000-8000-000000000009")!
    static let miscCatID       = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!

    static let defaultCategories: [TagCategory] = [
        TagCategory(id: proteinCatID,    name: "Protein",     colorHex: "#E45757", iconSymbol: "drumstick"),
        TagCategory(id: carbsCatID,      name: "Carbs",       colorHex: "#E4A957", iconSymbol: "leaf"),
        TagCategory(id: fatsCatID,       name: "Fats",        colorHex: "#E4D157", iconSymbol: "drop"),
        TagCategory(id: cuisineCatID,    name: "Cuisine",     colorHex: "#7AC957", iconSymbol: "globe"),
        TagCategory(id: styleCatID,      name: "Style",       colorHex: "#57C9A8", iconSymbol: "fork.knife"),
        TagCategory(id: formCatID,       name: "Form",        colorHex: "#5798C9", iconSymbol: "bowl"),
        TagCategory(id: sizeCatID,       name: "Meal Size",   colorHex: "#7857C9", iconSymbol: "ruler"),
        TagCategory(id: formatCatID,     name: "Format",      colorHex: "#C957A8", iconSymbol: "house"),
        TagCategory(id: descriptorCatID, name: "Descriptors", colorHex: "#C9577A", iconSymbol: "tag"),
        TagCategory(id: miscCatID,       name: "Misc",        colorHex: "#8E8E93", iconSymbol: "questionmark.circle")
    ]

    /// Tag seeds. `beans` and `quinoa` belong to both Protein and Carbs.
    /// `salmon` is in Protein and Fats (oily fish). `avocado` and
    /// `tortilla chips` show how a tag can span Carbs / Fats / etc.
    static let defaultTags: [MealTag] = [
        // Protein
        MealTag(name: "chicken",  categoryIds: [proteinCatID]),
        MealTag(name: "beef",     categoryIds: [proteinCatID]),
        MealTag(name: "fish",     categoryIds: [proteinCatID]),
        MealTag(name: "salmon",   categoryIds: [proteinCatID, fatsCatID]),
        MealTag(name: "tofu",     categoryIds: [proteinCatID, styleCatID]),
        MealTag(name: "eggs",     categoryIds: [proteinCatID]),
        MealTag(name: "lentils",  categoryIds: [proteinCatID, carbsCatID]),
        MealTag(name: "lamb",     categoryIds: [proteinCatID]),
        MealTag(name: "pork",     categoryIds: [proteinCatID]),
        MealTag(name: "beans",    categoryIds: [proteinCatID, carbsCatID]),

        // Carbs
        MealTag(name: "rice",          categoryIds: [carbsCatID]),
        MealTag(name: "pasta",         categoryIds: [carbsCatID]),
        MealTag(name: "bread",         categoryIds: [carbsCatID]),
        MealTag(name: "tortilla",      categoryIds: [carbsCatID]),
        MealTag(name: "tortilla chips", categoryIds: [carbsCatID, fatsCatID]),
        MealTag(name: "potato",        categoryIds: [carbsCatID]),
        MealTag(name: "corn",          categoryIds: [carbsCatID]),
        MealTag(name: "fries",         categoryIds: [carbsCatID, fatsCatID]),
        MealTag(name: "oats",          categoryIds: [carbsCatID]),
        MealTag(name: "quinoa",        categoryIds: [carbsCatID, proteinCatID]),

        // Fats
        MealTag(name: "butter",        categoryIds: [fatsCatID]),
        MealTag(name: "oil",           categoryIds: [fatsCatID]),
        MealTag(name: "avocado",       categoryIds: [fatsCatID]),
        MealTag(name: "cheese",        categoryIds: [fatsCatID, proteinCatID]),
        MealTag(name: "nuts",          categoryIds: [fatsCatID, proteinCatID]),
        MealTag(name: "coconut",       categoryIds: [fatsCatID]),
        MealTag(name: "peanut butter", categoryIds: [fatsCatID, proteinCatID]),

        // Cuisine
        MealTag(name: "Mexican",       categoryIds: [cuisineCatID]),
        MealTag(name: "Italian",       categoryIds: [cuisineCatID]),
        MealTag(name: "Asian",         categoryIds: [cuisineCatID]),
        MealTag(name: "Indian",        categoryIds: [cuisineCatID]),
        MealTag(name: "Mediterranean", categoryIds: [cuisineCatID]),
        MealTag(name: "American",      categoryIds: [cuisineCatID]),
        MealTag(name: "Thai",          categoryIds: [cuisineCatID]),

        // Style
        MealTag(name: "vegetarian",  categoryIds: [styleCatID]),
        MealTag(name: "vegan",       categoryIds: [styleCatID]),
        MealTag(name: "gluten-free", categoryIds: [styleCatID]),
        MealTag(name: "low-carb",    categoryIds: [styleCatID, descriptorCatID]),
        MealTag(name: "keto",        categoryIds: [styleCatID]),
        MealTag(name: "dessert",     categoryIds: [styleCatID]),

        // Form
        MealTag(name: "soup",      categoryIds: [formCatID]),
        MealTag(name: "salad",     categoryIds: [formCatID]),
        MealTag(name: "sandwich",  categoryIds: [formCatID, carbsCatID]),
        MealTag(name: "bowl",      categoryIds: [formCatID]),
        MealTag(name: "pizza",     categoryIds: [formCatID, carbsCatID, fatsCatID]),
        MealTag(name: "burger",    categoryIds: [formCatID, proteinCatID, carbsCatID]),
        MealTag(name: "stir-fry",  categoryIds: [formCatID]),

        // Meal Size
        MealTag(name: "small",  categoryIds: [sizeCatID]),
        MealTag(name: "medium", categoryIds: [sizeCatID]),
        MealTag(name: "large",  categoryIds: [sizeCatID]),

        // Format
        MealTag(name: "home",       categoryIds: [formatCatID]),
        MealTag(name: "take out",   categoryIds: [formatCatID]),
        MealTag(name: "restaurant", categoryIds: [formatCatID]),

        // Descriptors
        MealTag(name: "high carb",     categoryIds: [descriptorCatID]),
        MealTag(name: "high protein",  categoryIds: [descriptorCatID]),
        MealTag(name: "high fat",      categoryIds: [descriptorCatID]),
        MealTag(name: "low carb",      categoryIds: [descriptorCatID]),
        MealTag(name: "low protein",   categoryIds: [descriptorCatID]),
        MealTag(name: "low fat",       categoryIds: [descriptorCatID])
    ]
}
