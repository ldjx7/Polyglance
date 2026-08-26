// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://polyglance.pages.dev',
  integrations: [
    starlight({
      title: 'Polyglance',
      description: '多语言内容，一眼看懂 —— 跨平台翻译工具',
      logo: {
        src: './src/assets/logo.png',
        alt: 'Polyglance',
      },
      favicon: '/favicon-48.png',
      defaultLocale: 'root',
      locales: {
        root: { label: '简体中文', lang: 'zh-CN' },
        en: { label: 'English', lang: 'en' },
      },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/ldjx7/Polyglance' },
      ],
      editLink: {
        baseUrl: 'https://github.com/ldjx7/Polyglance/edit/main/website/',
      },
      lastUpdated: true,
      customCss: ['./src/styles/custom.css'],
      sidebar: [
        { label: '首页', slug: 'index' },
        { label: '下载', slug: 'download' },
        {
          label: '使用指南',
          items: [
            { label: '安装', slug: 'guides/install' },
            { label: '快捷键', slug: 'guides/shortcuts' },
            { label: '常见问题', slug: 'guides/faq' },
          ],
        },
        { label: '更新日志', link: '/changelog' },
      ],
    }),
  ],
});
