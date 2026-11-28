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
  const active = "inline-flex cursor-pointer items-center rounded-full bg-ink px-4 py-1.5 text-sm font-bold text-canvas shadow-[0_0_0_2px_rgb(var(--c-ink))] transition focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cp-orange";
  const inactive = "badge cursor-pointer px-4 py-1.5 text-sm font-semibold transition hover:-translate-y-px focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cp-orange";
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
          <a href="${page.route}" class="card-link block h-full rounded-[18px] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-cp-orange">
            <div class="clay-card h-full overflow-hidden">
              <div class="overflow-hidden border-b-2 border-ink">
                <img src="/assets/img/blog/${slug}-card.webp" alt="${escapeHtml(blog.imageAlt)}" width="640" height="427" loading="lazy" decoding="async" class="aspect-[3/2] w-full object-cover">
              </div>
              <div class="p-5">
                <p><span class="badge">${primaryLabel}</span></p>
                <h3 class="mt-3 font-display text-xl font-bold leading-snug text-ink">${escapeHtml(blog.heading)}</h3>
                <p class="mt-2 line-clamp-2 text-sm leading-relaxed text-body">${escapeHtml(blog.summary ?? page.description)}</p>
                <p class="mt-4 text-xs font-medium text-muted"><time datetime="${date}">${dateLabel(date)}</time> <span aria-hidden="true">&middot;</span> ${blog.readingMinutes} min read</p>
              </div>
            </div>
          </a>
        </article>`;
  }).join("\n        ");
}
