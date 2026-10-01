import { AppShell, NavLink, Title } from '@mantine/core'
import '@mantine/dates/styles.css'
import { Navigate, NavLink as RouterNavLink, Route, Routes } from 'react-router-dom'
import { humanize } from './components/labels'
import { DoctorCalendarPage } from './pages/DoctorCalendarPage'
import { DoctorPage } from './pages/DoctorPage'
import { HealthcareServicePage } from './pages/HealthcareServicePage'
import { IntakeRequestPage } from './pages/IntakeRequestPage'
import { PatientPage } from './pages/PatientPage'

// One page per entity with a collection read, in the order Domain.hs declares
// the entities; the app opens on the first.
const pages = [
  { entity: 'doctor', path: '/doctors', element: <DoctorPage /> },
  { entity: 'patient', path: '/patients', element: <PatientPage /> },
  { entity: 'healthcareService', path: '/healthcare-services', element: <HealthcareServicePage /> },
  { entity: 'intakeRequest', path: '/intake-requests', element: <IntakeRequestPage /> },
  { entity: 'doctorCalendar', path: '/doctor-calendar', element: <DoctorCalendarPage /> },
]

export default function App() {
  return (
    <AppShell header={{ height: 52 }} navbar={{ width: 220, breakpoint: 'sm' }} padding="md">
      <AppShell.Header px="md" style={{ display: 'flex', alignItems: 'center' }}>
        <Title order={3}>triage</Title>
      </AppShell.Header>
      <AppShell.Navbar p="xs">
        {pages.map((p) => (
          <NavLink key={p.path} component={RouterNavLink} to={p.path} label={humanize(p.entity)} />
        ))}
      </AppShell.Navbar>
      <AppShell.Main>
        <Routes>
          <Route path="/" element={<Navigate to={pages[0].path} replace />} />
          {pages.map((p) => (
            <Route key={p.path} path={p.path} element={p.element} />
          ))}
          <Route path="*" element={<Navigate to={pages[0].path} replace />} />
        </Routes>
      </AppShell.Main>
    </AppShell>
  )
}
