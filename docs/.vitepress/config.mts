import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'ash',
  description: 'Spawn and manage virtle-based NixOS agent VMs',
  cleanUrls: true,
  themeConfig: {
    search: { provider: 'local' },
    nav: [
      { text: 'Quick start', link: '/quick-start' },
      { text: 'Commands', link: '/commands' },
      { text: 'Mounts', link: '/mounts' }
    ],
    sidebar: [
      {
        text: 'Guide',
        items: [
          { text: 'Overview', link: '/' },
          { text: 'Quick start', link: '/quick-start' },
          { text: 'Configuration', link: '/configuration' },
          { text: 'Runtime mounts', link: '/mounts' },
          { text: 'Commands', link: '/commands' },
          { text: 'Troubleshooting', link: '/troubleshooting' }
        ]
      }
    ],
    socialLinks: [
      { icon: 'github', link: 'https://github.com/0xferrous/ash' }
    ]
  }
})
