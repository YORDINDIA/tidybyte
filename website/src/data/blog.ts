export interface BlogPostMeta {
  heading: string;
  imageAlt: string;
  categories: string[];
  readingMinutes: number;
  summary?: string;
}

export const BLOG_CATEGORIES = [
  { id: "tutorials", label: "Tutorials" },
  { id: "comparisons", label: "Comparisons" },
  { id: "features", label: "Features" },
  { id: "storage", label: "Storage" },
  { id: "privacy", label: "Privacy" },
  { id: "reviews", label: "Reviews" },
];
