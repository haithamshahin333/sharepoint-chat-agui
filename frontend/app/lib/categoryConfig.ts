export interface Category {
  value: string;
  label: string;
}

export interface CategoryConfig {
  categories: Category[];
  defaultCategory: string;
}

/**
 * Get category configuration from environment variables with fallback to defaults
 */
export function getCategoryConfig(): CategoryConfig {
  // Fallback categories (same as current hardcoded ones)
  const defaultCategories: Category[] = [
    { value: "all", label: "All Categories" },
    { value: "basketball", label: "Basketball" },
    { value: "golf", label: "Golf" },
  ];

  try {
    const categoriesJson = process.env.NEXT_PUBLIC_SEARCH_CATEGORIES;
    const categories: Category[] = categoriesJson ? JSON.parse(categoriesJson) : defaultCategories;
    const defaultCategory = process.env.NEXT_PUBLIC_DEFAULT_CATEGORY || "all";
    
    // Validate that categories is an array and has at least one item
    if (!Array.isArray(categories) || categories.length === 0) {
      console.warn("Invalid categories configuration, using defaults");
      return { categories: defaultCategories, defaultCategory: "all" };
    }

    // Validate that default category exists in the categories list
    const categoryExists = categories.some(cat => cat.value === defaultCategory);
    const finalDefaultCategory = categoryExists ? defaultCategory : categories[0].value;

    if (!categoryExists) {
      console.warn(`Default category "${defaultCategory}" not found in categories, using "${finalDefaultCategory}"`);
    }
    
    return { categories, defaultCategory: finalDefaultCategory };
  } catch (error) {
    console.warn("Error parsing categories configuration, using defaults:", error);
    return { categories: defaultCategories, defaultCategory: "all" };
  }
}
