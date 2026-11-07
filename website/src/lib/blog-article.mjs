// Escape '<' in JSON so metadata cannot close the script element.
export function blogArticleScript(meta) {
  const blog = meta.blog;
  if (!blog || !meta.datePublished || !meta.dateModified) {
    throw new Error(`missing article metadata for ${meta.route}`);
  }
  const article = {
    '@context': 'https://schema.org',
    '@type': 'Article',
    headline: blog.schemaHeadline ?? blog.heading,
    description: blog.schemaDescription ?? meta.description,
    datePublished: meta.datePublished,
    dateModified: meta.dateModified,
    author: { '@type': 'Organization', name: 'TidyByte', url: 'https://tidybyte.yord.si' },
    publisher: {
      '@type': 'Organization', name: 'TidyByte', url: 'https://tidybyte.yord.si',
      logo: { '@type': 'ImageObject', url: 'https://tidybyte.yord.si/assets/img/icon-1024.png', width: 1024, height: 1024 },
    },
    mainEntityOfPage: { '@type': 'WebPage', url: meta.canonical },
    image: meta.ogImage,
  };
  const json = JSON.stringify(article, null, 2).replaceAll('<', '\\u003c');
  return `\n\n  <!-- Structured Data: Article -->\n  <script type="application/ld+json">\n${json}\n  </script>`;
}
