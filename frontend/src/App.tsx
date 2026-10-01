import { AppShell, NavLink } from '@mantine/core'
import { Link, Navigate, Route, Routes, useLocation } from 'react-router-dom'
import '@mantine/dates/styles.css'
import { humanize } from './components/humanize'
import { DoctorCalendarPage } from './pages/DoctorCalendarPage'
import { DoctorPage } from './pages/DoctorPage'
import { HealthcareServicePage } from './pages/HealthcareServicePage'
import { IntakeRequestPage } from './pages/IntakeRequestPage'
import { PatientPage } from './pages/PatientPage'

/** One page per entity, in the order Domain.hs declares them. */
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
        {pages.map((p) => (
          <NavLink
            key={p.path}
            component={Link}
            to={p.path}
            label={humanize(p.entity)}
            active={location.pathname === p.path}
          />
        ))}
      </AppShell.Navbar>
      <AppShell.Main>
        <Routes>
          {pages.map((p) => (
            <Route key={p.path} path={p.path} element={p.element} />
          ))}
          <Route path="*" element={<Navigate to={pages[0].path} replace />} />
        </Routes>
      </AppShell.Main>
    </AppShell>
  )
}
