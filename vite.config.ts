import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    port: 3000,
    host: true,
  },
  build: {
    rollupOptions: {
      output: {
        manualChunks: {
          // Core React runtime
          'vendor-react': ['react', 'react-dom', 'react-router-dom'],
          // MUI component library (largest chunk)
          'vendor-mui': ['@mui/material', '@mui/icons-material', '@emotion/react', '@emotion/styled'],
          // Data fetching and forms
          'vendor-data': ['@tanstack/react-query', 'react-hook-form', '@hookform/resolvers', 'zod'],
          // Supabase client
          'vendor-supabase': ['@supabase/supabase-js'],
          // Charts and utilities
          'vendor-utils': ['date-fns', 'axios'],
        },
      },
    },
    chunkSizeWarningLimit: 600,
  },
});

