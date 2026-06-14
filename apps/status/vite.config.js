import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api/uptime': {
        target: 'http://localhost:3001',
        rewrite: path => path.replace(/^\/api\/uptime/, ''),
      },
    },
  },
})
