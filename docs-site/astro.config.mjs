// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://kaysauter.github.io',
	base: '/Azure-Data-Lab-Toolkit',
	integrations: [
		starlight({
			title: 'Azure Data Lab Toolkit',
			description:
				'Architecture, roadmap, and community documentation for the planned Azure Data Lab Toolkit.',
			components: {
				ThemeProvider: './src/components/ThemeProvider.astro',
				ThemeSelect: './src/components/ThemeSelect.astro',
			},
			customCss: ['./src/styles/custom.css'],
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/kaysauter/Azure-Data-Lab-Toolkit',
				},
			],
			sidebar: [
				{
					label: 'Start Here',
					items: [
						{ label: 'Overview', slug: 'overview' },
						{ label: 'Project Status', slug: 'status' },
						{
							label: 'Pitch Deck',
							link: '/pitch/deck/',
						},
					],
				},
				{
					label: 'Architecture',
					items: [
						{ label: 'Architecture Overview', slug: 'architecture' },
						{ label: 'Core', slug: 'architecture/core' },
						{ label: 'Providers And Targets', slug: 'architecture/providers' },
						{ label: 'Deployment Engines', slug: 'architecture/engines' },
						{ label: 'Provider Lifecycle', slug: 'architecture/provider-lifecycle' },
					],
				},
				{
					label: 'Trust And Guardrails',
					items: [
						{ label: 'Security And Sensitive Data', slug: 'security' },
						{ label: 'Cost And Lifecycle', slug: 'cost-and-lifecycle' },
						{ label: 'Licensing', slug: 'licensing' },
					],
				},
				{
					label: 'Capabilities',
					items: [
						{ label: 'Assessment', slug: 'assessment' },
						{ label: 'Microsoft Fabric Guidance', slug: 'fabric' },
						{ label: 'Git And CI/CD', slug: 'git-and-cicd' },
					],
				},
				{
					label: 'Community',
					items: [
						{ label: 'Tools And Solution Packs', slug: 'community/tools' },
						{ label: 'Sample And Data Sources', slug: 'community/data-sources' },
						{ label: 'Hall Of Fame', slug: 'community/hall-of-fame' },
						{ label: 'Suggest A Project', slug: 'community/suggest-a-project' },
					],
				},
				{
					label: 'Project',
					items: [
						{ label: 'Development', slug: 'development' },
						{ label: 'Testing Strategy', slug: 'testing' },
						{ label: 'Roadmap', slug: 'roadmap' },
						{ label: 'Third-party Notices', slug: 'third-party-notices' },
						{ label: 'Version History', slug: 'version-history' },
					],
				},
			],
		}),
	],
});
