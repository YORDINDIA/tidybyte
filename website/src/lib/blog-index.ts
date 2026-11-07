import { BLOG_CATEGORIES } from "../data/blog";
import type { PageMeta } from "../data/page-meta";
import { escapeHtml } from "./escape-html.mjs";

export function blogPosts(pages: PageMeta[]): PageMeta[] {
  return pages.filter((page) => page.blog);
}

export function categoryLabel(id: string): string {
  const category = BLOG_CATEGORIES.find((item) => item.id === id);
  if (!category) throw new Error(`unknown blog category ${id}`);
  return category.label;
}

export function dateLabel(date: string): string {
  return new Date(`${date}T00:00:00Z`).toLocaleDateString("en-US", {
    year: "numeric", month: "long", day: "numeric", timeZone: "UTC",
  });
}

export function blogFilters(pages: PageMeta[]): string {
  const posts = blogPosts(pages);
  const active = "inline-flex cursor-pointer items-center rounded-full bg-primary px-4 py-1.5 text-sm font-semibold text-on-primary transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40";
  const inactive = "badge cursor-pointer px-4 py-1.5 text-sm font-medium transition hover:text-ink focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40";
  return [{ id: "all", label: "All" }, ...BLOG_CATEGORIES].map((category) => {
    const count = category.id === "all" ? posts.length : posts.filter((post) => post.blog!.categories.some((id) => id === category.id)).length;
    return `<button class="${category.id === "all" ? active : inactive}" data-filter="${category.id}" data-label="${category.label}" aria-pressed="${category.id === "all"}">${category.label} (${count})</button>`;
  }).join("\n          ");
}

export function blogCards(pages: PageMeta[]): string {
  return blogPosts(pages).map((page) => {
    const blog = page.blog!;
    if (!page.datePublished) throw new Error(`missing publication date for ${page.route}`);
    if (!blog.categories.length) throw new Error(`missing blog category for ${page.route}`);
    blog.categories.forEach(categoryLabel);
    const date = page.datePublished.slice(0, 10);
    const slug = page.route.slice("/blog/".length);
    const primaryLabel = categoryLabel(blog.categories[0]);
    return `<article data-cats="${blog.categories.join(" ")}" data-date="${date}">
          <a href="${page.route}" class="card-link block h-full rounded-2xl focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40">
            <div class="clay-card h-full overflow-hidden transition hover:border-hairline-strong">
              <div class="overflow-hidden">
                <img src="/assets/img/blog/${slug}-card.webp" alt="${escapeHtml(blog.imageAlt)}" width="640" height="427" loading="lazy" decoding="async" class="aspect-[3/2] w-full object-cover">
              </div>
              <div class="p-5">
                <p><span class="badge">${primaryLabel}</span></p>
                <h3 class="mt-3 font-display text-lg font-medium leading-snug text-ink">${escapeHtml(blog.heading)}</h3>
                <p class="muted mt-2 line-clamp-2 text-sm leading-relaxed">${escapeHtml(blog.summary ?? page.description)}</p>
                <p class="mt-4 text-xs text-muted"><time datetime="${date}">${dateLabel(date)}</time> <span aria-hidden="true">&middot;</span> ${blog.readingMinutes} min read</p>
              </div>
            </div>
          </a>
        </article>`;
  }).join("\n        ");
}
