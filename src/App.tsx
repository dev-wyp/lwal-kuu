import React from 'react';
import { ThemeProvider, CssBaseline } from '@mui/material';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { RouterProvider } from 'react-router-dom';
import { theme } from './theme/theme';
import { router } from './routes';
import { AuthProvider } from './context/AuthContext';
import { OrgProvider } from './context/OrgContext';
import { NotificationProvider } from './context/NotificationContext';
import { I18nProvider } from './i18n/I18nContext';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 1000 * 30, // 30 seconds
      retry: 1,
      refetchOnWindowFocus: false,
    },
  },
});

export const App: React.FC = () => {
  return (
    <QueryClientProvider client={queryClient}>
      <ThemeProvider theme={theme}>
        <CssBaseline />
        <I18nProvider>
          <NotificationProvider>
            <AuthProvider>
              <OrgProvider>
                <RouterProvider router={router} />
              </OrgProvider>
            </AuthProvider>
          </NotificationProvider>
        </I18nProvider>
      </ThemeProvider>
    </QueryClientProvider>
  );
};

export default App;

