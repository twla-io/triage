import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MantineProvider } from '@mantine/core'
import { Notifications } from '@mantine/notifications'

import '@mantine/core/styles.css'
import '@mantine/notifications/styles.css'
import './theme.css'

import App from './App'
import { ErrorBoundary } from './components/ErrorBoundary'
import { cssVariablesResolver, theme } from './theme'

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { retry: 1 },
  },
})

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    {/* forceColorScheme: the ported palette is light-only (the mockup gave
        no dark tokens) and there's no scheme toggle in the UI, so pinning
        to light avoids the OS's own preference silently mixing these
        surface/text colors with Mantine's stock dark theme. */}
    <MantineProvider theme={theme} cssVariablesResolver={cssVariablesResolver} forceColorScheme="light">
      <Notifications />
      <ErrorBoundary>
        <QueryClientProvider client={queryClient}>
          <BrowserRouter>
            <App />
          </BrowserRouter>
        </QueryClientProvider>
      </ErrorBoundary>
    </MantineProvider>
  </React.StrictMode>,
)
