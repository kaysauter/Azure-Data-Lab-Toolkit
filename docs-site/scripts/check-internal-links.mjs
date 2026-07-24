import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, normalize, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const base = '/Azure-Data-Lab-Toolkit';
const distRoot = resolve(fileURLToPath(new URL('../dist', import.meta.url)));
const attributePattern = /\b(?:href|src)=["']([^"'<>]+)["']/g;

const findHtmlFiles = (directory) => {
	const files = [];
	for (const entry of readdirSync(directory, { withFileTypes: true })) {
		const path = join(directory, entry.name);
		if (entry.isDirectory()) {
			files.push(...findHtmlFiles(path));
		} else if (entry.isFile() && entry.name.endsWith('.html')) {
			files.push(path);
		}
	}
	return files;
};

const resolveCandidate = (htmlFile, rawReference) => {
	if (
		rawReference.startsWith('#') ||
		rawReference.startsWith('data:') ||
		rawReference.startsWith('mailto:') ||
		rawReference.startsWith('tel:') ||
		rawReference.startsWith('javascript:') ||
		/^https?:\/\//.test(rawReference)
	) {
		return null;
	}

	const reference = decodeURIComponent(rawReference.split('#')[0].split('?')[0]);
	if (!reference) return null;

	if (reference.startsWith('/') && !reference.startsWith(`${base}/`) && reference !== base) {
		return { error: `root-relative URL escapes the configured base: ${rawReference}` };
	}

	const webPath = reference.startsWith(base)
		? reference.slice(base.length) || '/'
		: join('/', relative(distRoot, dirname(htmlFile)), reference);
	const candidate = normalize(join(distRoot, webPath));

	if (!candidate.startsWith(`${distRoot}${sep}`) && candidate !== distRoot) {
		return { error: `URL resolves outside dist: ${rawReference}` };
	}

	if (existsSync(candidate) && statSync(candidate).isFile()) return { path: candidate };

	if (!extname(candidate)) {
		const index = join(candidate, 'index.html');
		if (existsSync(index) && statSync(index).isFile()) return { path: index };
	}

	return { error: `target not found: ${rawReference}` };
};

if (!existsSync(distRoot)) {
	console.error("Build output was not found. Run 'npm run build' first.");
	process.exit(1);
}

const failures = [];
let checked = 0;

for (const htmlFile of findHtmlFiles(distRoot)) {
	const source = readFileSync(htmlFile, 'utf8');
	for (const match of source.matchAll(attributePattern)) {
		const result = resolveCandidate(htmlFile, match[1]);
		if (!result) continue;
		checked += 1;
		if (result.error) {
			failures.push(`${relative(distRoot, htmlFile)}: ${result.error}`);
		}
	}
}

if (failures.length > 0) {
	console.error(`Found ${failures.length} broken internal reference(s):`);
	for (const failure of failures) console.error(`- ${failure}`);
	process.exit(1);
}

console.log(`Checked ${checked} internal references in the production build.`);
