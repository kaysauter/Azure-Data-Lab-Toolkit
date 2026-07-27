import { readFile } from 'node:fs/promises';

const sourceUrl = new URL('../pitch.md', import.meta.url);
const source = await readFile(sourceUrl, 'utf8');
const rawExternalLink = /\[[^\]\n]+\]\(\s*https?:\/\/[^)\n]+\)/g;
const matches = [...source.matchAll(rawExternalLink)];
const externalHtmlAnchor = /<a\b[^>]*\bhref=["']https?:\/\/[^"']+["'][^>]*>/gi;
const externalAnchors = [...source.matchAll(externalHtmlAnchor)];

if (matches.length > 0) {
  const findings = matches.map((match) => {
    const line = source.slice(0, match.index).split('\n').length;
    return `  line ${line}: ${match[0]}`;
  });

  console.error(
    [
      'Raw Markdown external links are not allowed in pitch.md.',
      'Use an explicit HTML <a> element so Slidev renders the link consistently.',
      ...findings,
    ].join('\n'),
  );
  process.exitCode = 1;
} else {
  console.log(
    `Slide source check passed: ${externalAnchors.length} external links use explicit HTML anchors.`,
  );
}
