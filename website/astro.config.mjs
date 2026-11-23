// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	site: 'https://zedis.barddoo.com',
	integrations: [
		starlight({
			title: 'Zedis',
			description:
				'A Redis-compatible in-memory data store written in Zig.',
			logo: {
				src: './src/assets/zedis.svg',
				alt: 'Zedis',
				replacesTitle: true,
			},
			favicon: '/zedis.svg',
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/barddoo/zedis',
				},
			],
			editLink: {
				baseUrl: 'https://github.com/barddoo/zedis/edit/main/website/',
			},
			lastUpdated: true,
			sidebar: [
				{
					label: 'Getting started',
					items: [
						{ label: 'Overview', link: '/' },
						{ label: 'Install and run', slug: 'getting-started' },
						{ label: 'Configuration', slug: 'configuration' },
					],
				},
				{
					label: 'Guides',
					items: [
						{ label: 'Migrating from Redis', slug: 'migrating-from-redis' },
						{ label: 'Persistence', slug: 'persistence' },
						{ label: 'Monitoring', slug: 'monitoring' },
						{ label: 'Data types', slug: 'data-types' },
					],
				},
				{
					label: 'Architecture',
					items: [
						{ label: 'Server', slug: 'architecture/overview' },
						{ label: 'Memory', slug: 'architecture/memory' },
						{ label: 'Store cache layout', slug: 'architecture/store' },
					],
				},
				{
					label: 'Reference',
					items: [
						{ label: 'Redis compatibility', slug: 'compatibility' },
						{ label: 'FAQ', slug: 'faq' },
					],
				},
			],
		}),
	],
});
