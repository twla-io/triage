import '@mantine/dates/styles.css'
import { AppShell, NavLink, Stack } from '@mantine/core'
import { Link, Navigate, Route, Routes, useLocation } from 'react-router-dom'
import { humanize } from './components/humanize'
import { DoctorCalendarPage } from './pages/DoctorCalendarPage'
import { DoctorPage } from './pages/DoctorPage'
import { HealthcareServicePage } from './pages/HealthcareServicePage'
import { IntakeRequestPage } from './pages/IntakeRequestPage'
import { PatientPage } from './pages/PatientPage'

// Pages in the order Domain.hs declares their entities; the app opens on the first.
const pages = [
  { path: '/doctor', entity: 'Doctor', element: <DoctorPage /> },
  { path: '/patient', entity: 'Patient', element: <PatientPage /> },
  { path: '/healthcare-service', entity: 'HealthcareService', element: <HealthcareServicePage /> },
  { path: '/intake-request', entity: 'IntakeRequest', element: <IntakeRequestPage /> },
  { path: '/doctor-calendar', entity: 'DoctorCalendar', element: <DoctorCalendarPage /> },
]

export default function App() {
  const location = useLocation()
  return (
    <AppShell navbar={{ width: 220, breakpoint: 'sm' }} padding="md">
      <AppShell.Navbar p="xs">
        <Stack gap={2}>
          {pages.map((page) => (
            <NavLink
              key={page.path}
              component={Link}
              to={page.path}
              label={humanize(page.entity)}
              active={location.pathname === page.path}
              color="gray"
            />
          ))}
        </Stack>
      </AppShell.Navbar>
      <AppShell.Main>
        <Routes>
          {pages.map((page) => (
            <Route key={page.path} path={page.path} element={page.element} />
          ))}
          <Route path="*" element={<Navigate to={pages[0].path} replace />} />
        </Routes>
      </AppShell.Main>
    </AppShell>
  )
}
