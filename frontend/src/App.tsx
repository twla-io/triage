import { AppShell, Group, NavLink, Title } from '@mantine/core'
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom'

import { DirectoryPage } from './pages/DirectoryPage'
import { CalendarPage } from './pages/CalendarPage'
import { SlotsPage } from './pages/SlotsPage'
import { IntakeRequestsPage } from './pages/IntakeRequestsPage'

const NAV_ITEMS = [
  { to: '/directory', label: 'Directory' },
  { to: '/calendar', label: 'Calendar' },
  { to: '/slots', label: 'Slots' },
  { to: '/intake-requests', label: 'Intake Requests' },
]

export default function App() {
  const location = useLocation()
  const navigate = useNavigate()

  return (
    <AppShell navbar={{ width: 220, breakpoint: 'sm' }} padding="md">
      <AppShell.Navbar p="md">
        <Group mb="md">
          <Title order={4}>triage</Title>
        </Group>
        {NAV_ITEMS.map((item) => (
          <NavLink
            key={item.to}
            label={item.label}
            active={location.pathname.startsWith(item.to)}
            onClick={() => navigate(item.to)}
          />
        ))}
      </AppShell.Navbar>
      <AppShell.Main>
        <Routes>
          <Route path="/" element={<Navigate to="/directory" replace />} />
          <Route path="/directory" element={<DirectoryPage />} />
          <Route path="/calendar" element={<CalendarPage />} />
          <Route path="/slots" element={<SlotsPage />} />
          <Route path="/intake-requests" element={<IntakeRequestsPage />} />
        </Routes>
      </AppShell.Main>
    </AppShell>
  )
}
