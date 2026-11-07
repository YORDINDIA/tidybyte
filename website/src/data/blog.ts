export interface BlogPostMeta {
  heading: string;
  imageAlt: string;
  categories: BlogCategory[];
  readingMinutes: number;
  summary?: string;
  // Editorial variants where the structured-data copy differs.
  schemaHeadline?: string;
  schemaDescription?: string;
}

export const BLOG_CATEGORIES = [
  { id: "tutorials", label: "Tutorials" },
  { id: "comparisons", label: "Comparisons" },
  { id: "features", label: "Features" },
  { id: "storage", label: "Storage" },
  { id: "privacy", label: "Privacy" },
  { id: "reviews", label: "Reviews" },
] as const;

export type BlogCategory = (typeof BLOG_CATEGORIES)[number]["id"];
